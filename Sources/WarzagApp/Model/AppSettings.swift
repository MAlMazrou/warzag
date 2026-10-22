import Foundation
import ProfileKit
import Synchronization
import WarzagCore

/// What the player chose in Settings, stored in State/app-settings.json (a demo run keeps its own under WARZAG_HOME or
/// `$TMPDIR/Warzag-Demo`, so it never touches the real settings).
struct AppSettings: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var schema = AppSettings.schemaVersion
    /// The graphics preset (ProfileKit's `GraphicsChoice`: a frame cap, see `GraphicsTuning`, plus the upscaler the
    /// player sets once in Warframe); nil: the preset recommended for this Mac.
    var graphics: GraphicsChoice?
    /// Apple's Metal Performance HUD in the game (Settings › Advanced).
    var performanceHUD = false
    /// A development engine chosen in Settings › Advanced (WARZAG_DEV_RUNTIME takes precedence).
    var developmentRuntimePath: String?
    /// The player clicked Get Started; until then only the read-only checks on this Mac run.
    var welcomed = false
    /// Hide Warzag while playing: once the game's first minute in front is over, Warzag leaves the Dock (the game's
    /// host shows as Warzag there already) until the session ends or the player opens Warzag again.
    var hideWhilePlaying = true
    /// Keep Steam out of sight: Warzag hides Steam (like ⌘H) after a sign-in and while Warframe starts.
    var keepSteamOutOfSight = true
    /// Check for updates automatically: once a day Warzag looks for a newer Warzag and engine (it never downloads or
    /// installs anything by itself).
    var checkForUpdatesAutomatically = true
    /// When a check for updates last got an answer from every feed it asked (manual or automatic): the automatic check
    /// runs a day after it.
    var lastUpdateCheck: Date?

    init() {}

    enum CodingKeys: String, CodingKey {
        case schema, graphics, performanceHUD, developmentRuntimePath, welcomed, hideWhilePlaying
        case keepSteamOutOfSight, checkForUpdatesAutomatically, lastUpdateCheck
    }

    /// Missing keys take their defaults, so older files keep working.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(Int.self, forKey: .schema) ?? Self.schemaVersion
        graphics = try container.decodeIfPresent(GraphicsChoice.self, forKey: .graphics)
        performanceHUD = try container.decodeIfPresent(Bool.self, forKey: .performanceHUD) ?? false
        developmentRuntimePath = try container.decodeIfPresent(String.self, forKey: .developmentRuntimePath)
        welcomed = try container.decodeIfPresent(Bool.self, forKey: .welcomed) ?? false
        hideWhilePlaying = try container.decodeIfPresent(Bool.self, forKey: .hideWhilePlaying) ?? true
        keepSteamOutOfSight = try container.decodeIfPresent(Bool.self, forKey: .keepSteamOutOfSight) ?? true
        checkForUpdatesAutomatically = try container.decodeIfPresent(Bool.self, forKey: .checkForUpdatesAutomatically)
            ?? true
        lastUpdateCheck = try container.decodeIfPresent(Date.self, forKey: .lastUpdateCheck)
    }

    func graphics(for tier: PerformanceTier) -> GraphicsChoice {
        graphics ?? .recommended(for: tier)
    }
}

/// Reads and writes State/app-settings.json. A file Warzag cannot read gives the defaults.
struct AppSettingsStore: Sendable {
    let url: URL
    let fileSystem: any FileSystem

    init(paths: WarzagPaths, fileSystem: any FileSystem) {
        url = paths.state.appending(path: "app-settings.json")
        self.fileSystem = fileSystem
    }

    func load() -> AppSettings {
        guard let data = try? fileSystem.contents(of: url),
              let settings = try? WarzagJSON.decoder().decode(AppSettings.self, from: data),
              settings.schema == AppSettings.schemaVersion else { return AppSettings() }
        return settings
    }

    func save(_ settings: AppSettings) throws {
        try fileSystem.writeAtomically(try WarzagJSON.encoder(pretty: true).encode(settings), to: url)
    }
}

/// The engine the services use, resolved from the launch options and the settings.
struct EngineConfiguration: Equatable, Sendable {
    /// WARZAG_DEV_RUNTIME, else Settings › Advanced.
    var developmentRuntime: URL?
}

/// The settings as the step performers and services see them: a thread-safe copy the model keeps current.
final class SettingsBox: Sendable {
    private let state: Mutex<AppSettings>
    let launchDevelopmentRuntime: URL?

    init(_ settings: AppSettings, launchDevelopmentRuntime: URL? = nil) {
        state = Mutex(settings)
        self.launchDevelopmentRuntime = launchDevelopmentRuntime
    }

    var settings: AppSettings { state.withLock { $0 } }

    func update(_ settings: AppSettings) { state.withLock { $0 = settings } }

    var engine: EngineConfiguration {
        let settings = self.settings
        return EngineConfiguration(
            developmentRuntime: launchDevelopmentRuntime
                ?? settings.developmentRuntimePath.map { URL(filePath: $0, directoryHint: .isDirectory) })
    }
}
