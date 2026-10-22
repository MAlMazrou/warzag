import Foundation
import WarzagCore
import WineKit

/// Where one Warframe installation lives: the runtime host that runs it, the Wine prefix, and the library folder the
/// prefix sees as `X:\` (a Steam-style tree: `Warframe.x64.exe`, `Tools\`, `Cache.Windows\`).
public struct GameInstallation: Sendable, Equatable {
    public var host: GameHost
    public var prefix: PrefixLayout
    public var library: URL

    public init(host: GameHost, prefix: PrefixLayout, library: URL) {
        self.host = host
        self.prefix = prefix
        self.library = library.standardized
    }

    // Windows-side names.
    public static let libraryRoot = #"X:\"#
    public static let launcherWindowsPath = #"X:\Tools\Launcher.exe"#
    public static let gameWindowsPath = #"X:\Warframe.x64.exe"#
    public static let steamWindowsPath = PrefixTemplate.steamDirectory + #"\steam.exe"#
    /// What Steam passes DE's launcher; `-registry:Steam` keeps its settings (and the EULA flag) under
    /// `HKCU\Software\Digital Extremes\Warframe\SteamLauncher`.
    public static let launcherArguments = ["-cluster:public", "-registry:Steam"]
    /// The launcher's image name, for a graceful close (`taskkill /IM`).
    public static let launcherImageName = "Launcher.exe"

    /// The game's image name, for a graceful close (`taskkill /IM`).
    public static let gameImageName = "Warframe.x64.exe"

    public var toolsDirectory: URL { library.appending(path: "Tools", directoryHint: .isDirectory) }
    public var launcherExecutable: URL { toolsDirectory.appending(path: "Launcher.exe") }
    public var gameExecutable: URL { library.appending(path: "Warframe.x64.exe") }
    /// The prefix's system32, where DXMT's placeholder DLLs must exist.
    public var system32: URL { prefix.driveC.appending(path: "windows/system32", directoryHint: .isDirectory) }
    public var userRegistry: URL { prefix.root.appending(path: "user.reg") }
    public var systemRegistry: URL { prefix.root.appending(path: "system.reg") }

    /// The prefix's Windows user: Wine names the profile folder after the user who created the prefix, so a prefix
    /// with one profile (besides Public) says which; otherwise `fallback`, the current user, as Wine would choose.
    public static func windowsUserName(inPrefix prefix: URL, fileSystem: any FileSystem, fallback: String) -> String {
        let users = prefix.appending(path: "drive_c/users", directoryHint: .isDirectory)
        guard let entries = try? fileSystem.contentsOfDirectory(at: users) else { return fallback }
        let profiles = entries.filter {
            fileSystem.directoryExists(at: $0) && $0.lastPathComponent.caseInsensitiveCompare("Public") != .orderedSame
        }
        return profiles.count == 1 ? profiles[0].lastPathComponent : fallback
    }

    /// The installation `warzagctl` and the app use: explicit locations first, then the library the prefix's `x:`
    /// drive already points at, then Warzag's own default locations.
    public static func resolve(host: GameHost, prefix: URL?, library: URL?, paths: WarzagPaths, files: any GameFiles,
                               windowsUserName: String = NSUserName()) -> GameInstallation {
        let layout = PrefixLayout(root: (prefix ?? paths.prefix(for: host.channel)).standardized,
                                  windowsUserName: windowsUserName)
        let library = library ?? files.symbolicLinkDestination(of: layout.libraryDrive) ?? paths.warframeLibrary
        return GameInstallation(host: host, prefix: layout, library: library)
    }
}
