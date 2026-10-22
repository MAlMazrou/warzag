import Foundation
import WarzagCore

/// Where the user's native Mac Steam keeps things. Warzag only reads these, and of Steam's own files only the ones
/// named here: never local.vdf, config.vdf's Accounts, userdata/, htmlcache/, the webhelper or cef logs. Of
/// connection_log.txt only the state and the account bracket are read, and the account number stays package-internal
/// (`ConnectionLogEntry`).
public struct SteamLocations: Sendable, Equatable {
    public let home: URL
    public let systemApplications: URL

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        systemApplications: URL = URL(filePath: "/Applications", directoryHint: .isDirectory)
    ) {
        self.home = home.standardizedFileURL
        self.systemApplications = systemApplications
    }

    public var userApplications: URL { home.appending(path: "Applications", directoryHint: .isDirectory) }

    /// Steam.app is a bootstrapper; it may live in either Applications folder.
    public var applicationCandidates: [URL] {
        [systemApplications, userApplications].map { $0.appending(path: "Steam.app", directoryHint: .isDirectory) }
    }

    public var supportDirectory: URL {
        home.appending(path: "Library/Application Support/Steam", directoryHint: .isDirectory)
    }

    /// The real client the bootstrapper installs; also `STEAM_COMPAT_CLIENT_INSTALL_PATH` for lsteamclient.
    public var clientDirectory: URL {
        supportDirectory.appending(path: "Steam.AppBundle/Steam/Contents/MacOS", directoryHint: .isDirectory)
    }

    public var steamClientLibrary: URL { clientDirectory.appending(path: "steamclient.dylib") }
    /// The client's package manifests, `steam_client*osx.manifest` (`isClientManifest`).
    public var packageDirectory: URL { clientDirectory.appending(path: "package", directoryHint: .isDirectory) }
    public var registryFile: URL { supportDirectory.appending(path: "registry.vdf") }

    public var configDirectory: URL { supportDirectory.appending(path: "config", directoryHint: .isDirectory) }
    /// Steam's saved accounts. Read through `LoginUsers` only: an allowlist of keys, never the PIN keys.
    public var loginUsersFile: URL { configDirectory.appending(path: "loginusers.vdf") }
    /// `<SteamID64>.png`, Steam's cached profile pictures.
    public var avatarCacheDirectory: URL {
        configDirectory.appending(path: "avatarcache", directoryHint: .isDirectory)
    }

    public var logsDirectory: URL { supportDirectory.appending(path: "logs", directoryHint: .isDirectory) }
    public var connectionLog: URL { logsDirectory.appending(path: "connection_log.txt") }
    /// steamui's sign-in steps (`SetLoginState: <step> - <reason>`), read by `LoginStateLog`.
    public var loginStateLog: URL { logsDirectory.appending(path: "steamui_login.txt") }
    /// The bootstrapper's start and shutdown lines, read by `BootstrapLog`.
    public var bootstrapLog: URL { logsDirectory.appending(path: "bootstrap_log.txt") }
    /// Games Steam tracks as running; developer diagnostics only (`warzagctl steam timeline`).
    public var gameProcessLog: URL { logsDirectory.appending(path: "gameprocess_log.txt") }

    /// `steam_client*osx.manifest`: steam_client_osx.manifest, steam_client_signed-2_osx.manifest, a beta's.
    public static func isClientManifest(_ name: String) -> Bool {
        name.hasPrefix("steam_client") && name.hasSuffix("osx.manifest")
    }
}
