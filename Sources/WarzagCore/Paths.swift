import Darwin
import Foundation

/// The engine channel, as runtime manifests, the engine store, prefix records and the runtime host's Info.plist name
/// it. Warzag has one engine, N: native ARM64 Wine with FEX (ARM64EC/ARM64X Windows DLLs; only the game's own x86-64
/// code is emulated).
public enum RuntimeChannel: String, Codable, Sendable {
    case n

    /// The key in a runtime host's Contents/Info.plist that names its channel (runtime/gamehost/Info.plist.in).
    public static let infoPlistKey = "WarzagRuntimeChannel"

    /// The Wine loader's Mach-O architecture, as runtime manifests name it.
    public var architecture: String { "arm64" }

    /// Wine's name for the architecture in `lib/wine/<name>-unix|windows` and `renderers/<renderer>/<name>-windows`.
    public var wineArchitecture: String { "aarch64" }

    public var prefixDirectoryName: String { "warframe-\(architecture)" }
}

/// One named location, for `warzagctl paths` and diagnostics.
public struct NamedPath: Sendable, Equatable, Codable {
    public let name: String
    public let url: URL
}

/// Every on-disk location Warzag owns.
///
/// Everything derives from an injectable home directory, so tests and `warzagctl --home` can run against a
/// scratch tree without touching the real one.
public struct WarzagPaths: Sendable, Equatable {
    public let home: URL
    /// `$(getconf DARWIN_USER_CACHE_DIR)`, where Metal and DXMT keep shader caches.
    public let userCacheDirectory: URL?

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        userCacheDirectory: URL? = WarzagPaths.darwinUserCacheDirectory()
    ) {
        self.home = home.standardizedFileURL
        self.userCacheDirectory = userCacheDirectory
    }

    public var applicationSupport: URL { home.directory("Library/Application Support/Warzag") }

    public var state: URL { applicationSupport.directory("State") }
    /// Resumable first-run state (schema-versioned JSON).
    public var setupStateFile: URL { state.appending(path: "setup.json") }

    /// The engine store: `active.json`, every installed engine copy (`n/<version>/Warzag.app`) and `staging/`.
    /// Each copy is an app bundle named Warzag (com.warzag.gamehost, for the Dock name and Game Mode); the `.noindex`
    /// suffix keeps Spotlight and the Apps view from listing the copies next to Warzag itself.
    public var runtimes: URL { applicationSupport.directory(Self.runtimesFolderName) }
    public static let runtimesFolderName = "Runtimes.noindex"
    /// Atomic pointer to the active `Runtimes.noindex/n/<version>/Warzag.app`.
    public var activeRuntimePointer: URL { runtimes.appending(path: "active.json") }
    public func runtimeDirectory(_ channel: RuntimeChannel) -> URL { runtimes.directory(channel.rawValue) }
    public func runtimeVersionDirectory(_ channel: RuntimeChannel, version: String) -> URL {
        runtimeDirectory(channel).directory(version)
    }
    public func gameHost(_ channel: RuntimeChannel, version: String) -> URL {
        runtimeVersionDirectory(channel, version: version).directory(Self.gameHostName)
    }
    public static let gameHostName = "Warzag.app"
    /// Engine copies on their way into the store: a feed pack unpacked and checked, a `use-local` clone. Inside the
    /// store, so they are out of Spotlight too and activation is a rename on the same volume.
    public var runtimeStaging: URL { runtimes.directory("staging") }
    /// Downloaded runtime packs and the feed's manifest: files, never app bundles.
    public var runtimeDownloads: URL { caches.directory("runtime") }

    public var prefixes: URL { applicationSupport.directory("Prefixes") }
    public func prefix(for channel: RuntimeChannel) -> URL { prefixes.directory(channel.prefixDirectoryName) }

    public var identity: URL { applicationSupport.directory("Identity") }
    /// MachineGuid, ComputerName, volume serials and Windows user name, re-applied on prefix rebuilds.
    public var identityFile: URL { identity.appending(path: "identity.json") }

    public var library: URL { applicationSupport.directory("Library") }
    /// The X:\ Steam-style game tree. `.noindex` keeps Spotlight out of the game's files.
    public var warframeLibrary: URL { library.directory("Warframe.noindex") }

    public var caches: URL { home.directory("Library/Caches/Warzag") }
    public var logs: URL { home.directory("Library/Logs/Warzag") }

    /// Warzag's own updates (AppUpdateKit): the downloaded archive, the accepted app manifest, and the new Warzag.app,
    /// unpacked and checked, in `staging/` until it replaces the installed one. `.noindex`, like the engine store, so
    /// Spotlight never lists that copy as another Warzag.
    public var appUpdates: URL { caches.directory("AppUpdate.noindex") }
    /// The highest app-manifest serial this Mac accepted: an older manifest served again is refused.
    public var appUpdateStateFile: URL { state.appending(path: "app-update.json") }

    /// DXMT's AIR and Metal pipeline cache for the game. Warzag updates never purge it.
    public var dxmtShaderCache: URL? { userCacheDirectory?.directory("dxmt/Warframe.x64.exe") }

    /// All locations in layout order.
    public var all: [NamedPath] {
        var paths = [
            NamedPath(name: "applicationSupport", url: applicationSupport),
            NamedPath(name: "state", url: state),
            NamedPath(name: "setupState", url: setupStateFile),
            NamedPath(name: "runtimes", url: runtimes),
            NamedPath(name: "activeRuntime", url: activeRuntimePointer),
            NamedPath(name: "prefixes", url: prefixes),
            NamedPath(name: "prefix.n", url: prefix(for: .n)),
            NamedPath(name: "identity", url: identityFile),
            NamedPath(name: "library", url: warframeLibrary),
            NamedPath(name: "caches", url: caches),
            NamedPath(name: "appUpdates", url: appUpdates),
            NamedPath(name: "logs", url: logs),
        ]
        if let dxmtShaderCache { paths.append(NamedPath(name: "dxmtCache", url: dxmtShaderCache)) }
        return paths
    }

    /// `confstr(_CS_DARWIN_USER_CACHE_DIR)`, the per-user cache folder under /var/folders.
    public static func darwinUserCacheDirectory() -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count)
        guard length > 1, length <= buffer.count else { return nil }
        let path = String(decoding: buffer.prefix(length - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(filePath: path, directoryHint: .isDirectory)
    }
}

/// Locations inside one Wine prefix that Warzag reads (DE's logs) or seeds once (EE.cfg).
public struct PrefixLayout: Sendable, Equatable {
    public let root: URL
    /// Wine names the profile folder after the macOS user.
    public let windowsUserName: String

    public init(root: URL, windowsUserName: String = NSUserName()) {
        self.root = root
        self.windowsUserName = windowsUserName
    }

    public var driveC: URL { root.directory("drive_c") }
    /// `dosdevices/x:` links to the game library, so the game sees an X:\ Steam-style tree.
    public var libraryDrive: URL { root.appending(path: "dosdevices/x:") }
    /// `C:\windows\temp`, where Warzag drops .reg files for `reg import`.
    public var windowsTemp: URL { driveC.directory("windows/temp") }
    public var userProfile: URL { driveC.directory("users/\(windowsUserName)") }
    /// `%LOCALAPPDATA%\Warframe`: EE.cfg, EE.log, Launcher.log, Preprocess.log.
    public var warframeAppData: URL { userProfile.directory("AppData/Local/Warframe") }
    public var eeConfig: URL { warframeAppData.appending(path: "EE.cfg") }
    public var eeLog: URL { warframeAppData.appending(path: "EE.log") }
    public var launcherLog: URL { warframeAppData.appending(path: "Launcher.log") }
    public var preprocessLog: URL { warframeAppData.appending(path: "Preprocess.log") }
    /// `C:\Program Files (x86)\Steam`, where the steam.exe shim and the steamclient64 forwarder live.
    public var steamDirectory: URL { driveC.directory("Program Files (x86)/Steam") }

    /// The `C:\…` form of a path inside drive_c, for Windows programs; nil for paths outside drive_c.
    public func windowsPath(for url: URL) -> String? {
        // `standardized` only removes "." and ".."; `standardizedFileURL` also drops a leading /private, but only
        // for paths that exist, so a prefix under /private/tmp would compare an existing file against its base
        // inconsistently and fall outside drive_c.
        let base = driveC.standardized.plainPath
        let path = url.standardized.plainPath
        guard path == base || path.hasPrefix(base + "/") else { return nil }
        let relative = path.dropFirst(base.count).split(separator: "/").joined(separator: "\\")
        return "C:\\" + relative
    }
}

/// Facts about the game that several modules need.
public enum Warframe {
    /// Steam AppID of Warframe (Windows-only on Steam).
    public static let steamAppID = 230410
}

extension URL {
    func directory(_ relativePath: String) -> URL {
        appending(path: relativePath, directoryHint: .isDirectory)
    }

    /// The file-system path without percent-encoding or a trailing slash (except for "/" itself).
    public var plainPath: String {
        let path = self.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
