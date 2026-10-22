import EngineKit
import Foundation
import WarzagCore
import WineKit

/// What GameKit is about to do in a prefix; each needs a different part of the setup.
public enum GameTask: Sendable, Equatable {
    /// `msiexec /a` of Warframe.msi into X:\.
    case extractInstaller
    /// DE's launcher, on DXMT, for the first download or an update.
    case runLauncher
    /// The game, through the steam.exe shim; `steam` adds the Steam bridge's needs.
    case play(steam: Bool, renderer: Renderer)
}

/// Something that keeps a task from working, found by reading the prefix (nothing is changed or started).
public enum PrefixIssue: Equatable, Sendable, CustomStringConvertible {
    case hostMissing(String)
    case rendererMissing(String)
    case prefixMissing(String)
    case libraryDriveMissing(expected: String)
    case libraryDriveElsewhere(found: String?, expected: String)
    /// A DLL Wine must find on its search path before it uses the renderer's or the bridge's builtin (Windows path).
    case placeholderMissing(String)
    /// `HKCU\Software\Wine\AppDefaults\Launcher.exe\DllOverrides` does not disable these yet.
    case launcherOverridesMissing([String])
    case steamFileMissing(String)
    case steamRegistryMissing
    case launcherNotExtracted
    case gameNotDownloaded
    /// A wineserver runs for the prefix: something (Warframe, DE's launcher) is still running in it.
    case prefixBusy(wineserver: Int32)

    public var description: String {
        switch self {
        case .hostMissing(let path): "no runtime host at \(path)"
        case .rendererMissing(let path): "the runtime has no renderer at \(path)"
        case .prefixMissing(let path): "no Wine prefix at \(path)"
        case .libraryDriveMissing(let expected): "the prefix has no X: drive (dosdevices/x: -> \(expected))"
        case .libraryDriveElsewhere(let found, let expected):
            "the prefix's X: drive points at \(found ?? "something else") instead of \(expected)"
        case .placeholderMissing(let path): "\(path) is missing from the prefix"
        case .launcherOverridesMissing(let dlls):
            "DE's launcher would load \(dlls.joined(separator: ", ")) (AppDefaults\\Launcher.exe\\DllOverrides)"
        case .steamFileMissing(let path): "the Steam bridge's \(path) is missing from the prefix"
        case .steamRegistryMissing: "the prefix has no Steam bridge registry keys (HKCU\\Software\\Valve\\Steam\\ActiveProcess)"
        case .launcherNotExtracted: "Warframe.msi has not been unpacked into the library (no Tools\\Launcher.exe)"
        case .gameNotDownloaded: "DE's launcher has not downloaded the game yet (no Warframe.x64.exe)"
        case .prefixBusy(let pid): "something is still running in the prefix (wineserver pid \(pid)); close Warframe and DE's launcher first"
        }
    }

    /// Fixed by setting the prefix up again (the engine's prefix repair), not by a content step or by waiting.
    public var needsPrefixRepair: Bool {
        switch self {
        case .prefixMissing, .libraryDriveMissing, .libraryDriveElsewhere, .placeholderMissing,
             .launcherOverridesMissing, .steamFileMissing, .steamRegistryMissing:
            true
        case .hostMissing, .rendererMissing, .launcherNotExtracted, .gameNotDownloaded, .prefixBusy:
            false
        }
    }
}

/// Read-only checks that a prefix has what DE's launcher and the game need. Preparing the prefix is the engine's job
/// (EngineKit, bridge/install-prefix.sh); GameKit only refuses to start in a prefix that would fail in a confusing way.
public struct PrefixInspector: Sendable {
    public static let steamBridgeFiles = ["steam.exe", "steamclient64.dll"]

    public let installation: GameInstallation
    public let fileSystem: any FileSystem
    public let files: any GameFiles
    public let probe: any PrefixActivityProbing

    public init(installation: GameInstallation, fileSystem: any FileSystem, files: any GameFiles,
                probe: any PrefixActivityProbing) {
        self.installation = installation
        self.fileSystem = fileSystem
        self.files = files
        self.probe = probe
    }

    /// Everything wrong for `task`, in the order a person would fix it. Empty means go.
    public func issues(for task: GameTask, ignoringActivity: Bool = false) -> [PrefixIssue] {
        let host = installation.host
        let prefix = installation.prefix
        var issues: [PrefixIssue] = []
        if !fileSystem.fileExists(at: host.wine) || !fileSystem.fileExists(at: host.wineserver) {
            issues.append(.hostMissing(host.bundle.plainPath))
        }
        let renderer: Renderer? = switch task {
        case .extractInstaller: nil
        case .runLauncher: .dxmt
        case .play(_, let renderer): renderer
        }
        if let renderer, let directory = host.rendererWindowsDLLs(renderer),
           !fileSystem.directoryExists(at: directory) {
            issues.append(.rendererMissing(directory.plainPath))
        }
        guard fileSystem.fileExists(at: installation.systemRegistry) else {
            return issues + [.prefixMissing(prefix.root.plainPath)]
        }

        let drive = prefix.libraryDrive
        if !files.isSameDirectory(drive, installation.library) {
            if let target = files.symbolicLinkDestination(of: drive) {
                issues.append(.libraryDriveElsewhere(found: target.plainPath, expected: installation.library.plainPath))
            } else if fileSystem.fileExists(at: drive) {
                issues.append(.libraryDriveElsewhere(found: nil, expected: installation.library.plainPath))
            } else {
                issues.append(.libraryDriveMissing(expected: installation.library.plainPath))
            }
        }

        if renderer == .dxmt {
            for name in PrefixFiles.dxmtPlaceholders
            where !fileSystem.fileExists(at: installation.system32.appending(path: name)) {
                issues.append(.placeholderMissing(#"C:\windows\system32\"# + name))
            }
        }

        let registry = WineRegistryHive.load(installation.userRegistry, fileSystem: fileSystem)
        switch task {
        case .extractInstaller:
            break
        case .runLauncher:
            let overrides = #"Software\Wine\AppDefaults\Launcher.exe\DllOverrides"#
            let missing = PrefixTemplate.launcherDisabledDLLs.filter { registry?.string(overrides, $0) != "" }
            if !missing.isEmpty { issues.append(.launcherOverridesMissing(missing)) }
            if !fileSystem.fileExists(at: installation.launcherExecutable) { issues.append(.launcherNotExtracted) }
        case .play(let steam, _):
            let steamDirectory = prefix.steamDirectory
            for name in steam ? Self.steamBridgeFiles : ["steam.exe"]
            where !fileSystem.fileExists(at: steamDirectory.appending(path: name)) {
                issues.append(.steamFileMissing(PrefixTemplate.steamDirectory + "\\" + name))
            }
            if steam {
                if !fileSystem.fileExists(at: installation.system32.appending(path: "lsteamclient.dll")) {
                    issues.append(.placeholderMissing(#"C:\windows\system32\lsteamclient.dll"#))
                }
                if registry?.string(#"Software\Valve\Steam\ActiveProcess"#, "SteamClientDll64") == nil {
                    issues.append(.steamRegistryMissing)
                }
            }
            if !fileSystem.fileExists(at: installation.gameExecutable) { issues.append(.gameNotDownloaded) }
        }

        if !ignoringActivity, let pid = probe.wineserver(for: prefix.root) {
            issues.append(.prefixBusy(wineserver: pid))
        }
        return issues
    }
}
