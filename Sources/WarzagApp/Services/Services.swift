import EngineKit
import Foundation
import GameKit
import ProfileKit
import SteamHostKit
import WarzagCore

// The app talks to the kits only through these protocols: live implementations wrap EngineKit, SteamHostKit and GameKit
// (Live/), demo implementations simulate them (Demo/), and the tests use fakes. No method here may block the main
// actor; the long ones are async and run wherever their caller's task runs (never on the main actor).

/// Everything the app needs, swapped as a whole for Demo mode and tests.
struct AppServices: Sendable {
    var system: any SystemServicing
    var engine: any EngineServicing
    var steam: any SteamServicing
    var game: any GameServicing
    var clock: any WallClock
    /// Warzag's own updates (UpdateServices.swift); a build without an update feed has nothing to check.
    var appUpdate: any AppUpdateServicing = UnconfiguredAppUpdates()
    /// Labelled "Demo" everywhere: nothing real is installed or started.
    var isDemo: Bool
}

// MARK: - This Mac

/// Where Warzag runs from.
struct ApplicationLocation: Equatable, Sendable {
    var url: URL
    /// In /Applications or ~/Applications.
    var inApplicationsFolder: Bool
}

/// The library volume, for the free-space check.
struct StorageCheck: Equatable, Sendable {
    var volume: VolumeInfo?
    /// Bytes Warframe already occupies in the library (an installed game needs room for updates only).
    var libraryBytes: Int64
}

/// Facts about this Mac and side effects outside Warzag's own data.
protocol SystemServicing: Sendable {
    func hardware() -> HardwareProfile
    func powerAdvice(for tier: PerformanceTier) -> [PowerAdvice]
    func applicationLocation() -> ApplicationLocation
    /// Copies Warzag into an Applications folder, opens that copy and asks this one to quit; throws if that failed.
    func moveToApplications() async throws
    func storage(for library: URL) -> StorageCheck
    func networkIsAvailable() async -> Bool
    /// true each time the network comes back (and once at the start when it is up).
    func networkAvailability() -> AsyncStream<Bool>

    @MainActor func open(_ url: URL)
    /// Selects the item in a Finder window without opening it (opening an app bundle would start it).
    @MainActor func revealInFinder(_ url: URL)
    /// Opens Steam's own window (it starts hidden with `-silent`).
    @MainActor func showSteam()
    /// Show the Window, Return to Game: brings the window the player means to the front, DE's launcher's or
    /// Warframe's (GameKit's `GameWindow.target`). Never `openedProcess`, the steam.exe shim LaunchServices opened for
    /// Play: it holds only a hidden window, and several processes share the game host's bundle identifier.
    @MainActor func showGameHost(openedProcess: Int32?)
    /// After Play opened the game: brings its window to the front when it appears, then for a minute back from Steam,
    /// at most three times, never from another app the player chose (GameKit's `GameFocusKeeper`). Returns when that is
    /// over; the model cancels it when the session ends.
    func keepGameInFront(openedProcess: Int32, hidingSteam: Bool,
                         events: @escaping @Sendable (GameFocusEvent) -> Void) async
    @MainActor func setDockBadge(_ text: String?)
    @MainActor func requestAttention()
    /// Keeps the Mac (and, for a session, the display) awake while long work runs; nil ends it.
    @MainActor func keepAwake(_ reason: KeepAwakeReason?)
    /// Hide Warzag while playing: `.hidden` takes Warzag out of the Dock and the app switcher (an accessory app; its
    /// windows stay open, nothing is closed), `.shown` makes it a regular app again.
    @MainActor func setDockPresence(_ presence: DockPresence)
    /// Asks macOS to make Warzag the active app and brings its main window to the front, opening it again if it was
    /// closed. macOS keeps another app in front if the player is using it.
    @MainActor func showMainWindow()
    /// Quits Warzag the way ⌘Q does (`AppTermination`: the model's clean shutdown runs first), after Warzag's own
    /// update was installed: the new Warzag opens once this one has quit.
    @MainActor func quit()
}

/// Whether Warzag shows in the Dock (Hide Warzag while playing).
enum DockPresence: Equatable, Sendable {
    case shown
    case hidden
}

enum KeepAwakeReason: Equatable, Sendable {
    /// Downloads and installs: no idle system sleep.
    case setup
    /// A game session: no idle display sleep either.
    case playing
}

// MARK: - Engine

struct RuntimeSummary: Equatable, Sendable {
    var id: String
    var version: String
    var channel: RuntimeChannel
    /// Registered from a local build (use-local), not a signed pack.
    var development: Bool
    var hostPath: String
}

/// The engine the release page offers: a signed manifest that passed every check.
struct EngineOffer: Equatable, Sendable {
    var id: String
    var version: String
    /// The pack's size.
    var bytes: Int64
    /// Already the current engine: nothing to download or install.
    var installed: Bool
}

/// A development engine named by WARZAG_DEV_RUNTIME or Settings › Advanced.
struct DevelopmentRuntime: Equatable, Sendable {
    var bundle: URL
    /// Read from the host (its loader and Info.plist); nil when the bundle is not a Warzag game host.
    var channel: RuntimeChannel?
}

struct PrefixSummary: Equatable, Sendable {
    var created: Bool
    var library: String
    var log: String
}

/// One line of Troubleshoot's checklist.
struct HealthCheck: Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var passed: Bool
    var detail: String
}

/// What wz-steamprobe.exe found (its exit status; bridge/steamprobe/steamprobe.c).
enum LicenseProbeResult: Equatable, Sendable {
    case owned
    case notOwned
    case signedOut
    case steamNotRunning
    /// The bridge did not load (registry, forwarder, lsteamclient or steamclient.dylib).
    case bridgeFailed(stage: String)
    case timedOut
    case failed(String)

    /// The probe's exit status, as EngineKit's `SteamProbe.Outcome` reads it (bridge/steamprobe/steamprobe.c).
    init(exitCode: Int32) {
        switch SteamProbe.Outcome(exitCode: exitCode) {
        case .owned: self = .owned
        case .notOwned: self = .notOwned
        case .signedOut: self = .signedOut
        case .steamNotRunning: self = .steamNotRunning
        case .bridgeFailed(let stage): self = .bridgeFailed(stage: stage)
        case .timedOut: self = .timedOut
        case .failed(let exitCode): self = .failed("wz-steamprobe.exe exited with status \(exitCode)")
        }
    }
}

protocol EngineServicing: Sendable {
    /// The development engine to register, if one is configured.
    func developmentRuntime() -> DevelopmentRuntime?
    /// The current runtime, if it is on disk and not revoked.
    func activeRuntime() -> RuntimeSummary?
    /// `runtime use-local`, skipped when the same build is already the current runtime.
    func registerDevelopmentRuntime(_ runtime: DevelopmentRuntime) async throws -> RuntimeSummary
    /// The signed runtime manifest's URL (Info.plist `WarzagRuntimeManifestURL`, App/make-app.sh `--feed-url`); nil
    /// in a build without one, which uses a development engine or one installed with warzagctl.
    func feedURL() -> URL?
    /// fetchManifest: the feed's manifest, verified (pinned keys, serial, expiry, revocations) and kept for the next
    /// steps. Its serial floor and revocations are recorded: a revoked current engine rolls back to the previous one,
    /// and the revoked copy is deleted.
    func fetchEngineManifest() async throws -> EngineOffer
    /// Check for Updates: what `fetchEngineManifest` would offer, verified the same way, with nothing recorded or kept
    /// (EngineKit's `checkManifest`), so a check never changes the engine under a game. The feed's revocations apply
    /// when the engine is updated, which fetches the manifest again first.
    func checkEngineManifest() async throws -> EngineOffer
    /// downloadRuntime: the offered pack, resumable, reporting bytes received and the total; size and SHA-256 checked.
    /// Nothing to do when the offered engine is already current.
    func downloadEngine(progress: @escaping @Sendable (_ received: Int64, _ total: Int64) -> Void) async throws
    /// verifyRuntime: the pack unpacked and checked (code signature by the pinned certificate, an arm64 host).
    func verifyEngine() async throws
    /// activateRuntime: the checked engine becomes current; the one it replaces is kept as the previous engine.
    func activateEngine() async throws -> RuntimeSummary
    func setUpPrefix() async throws -> PrefixSummary
    func repairPrefix() async throws -> PrefixSummary
    /// The runtime the prefix was last set up for (its warzag-prefix.json); nil without a prefix or a readable record.
    /// Any other than the active one means the prefix still has to be set up for the engine that replaced it.
    func prefixRuntimeID() -> String?
    func doctor() async -> [HealthCheck]
    /// wz-steamprobe.exe in the prefix: registers with Steam as Warframe for a moment ("Playing").
    func probeSteamLicense() async -> LicenseProbeResult
}

// MARK: - Steam

struct SteamSnapshot: Equatable, Sendable {
    var installed: Bool
    var running: Bool
    var signedIn: Bool
}

/// What the Home screen's Steam card shows. The name and the picture are personal data held in memory only: never
/// logged, never in diagnostics (SteamHostKit's `SteamAccount` rules).
struct SteamCard: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case notInstalled
        case off
        case starting
        case signingIn
        case signedOut
        /// Steam signed this Mac out because the account is in use somewhere else (Steam's one-session rule).
        case signedOutElsewhere
        case signedIn
    }

    var state: State
    /// Steam's profile name (what other players see), only while signed in; nil when Steam keeps none.
    var name: String?
    /// Steam's cached picture (PNG), only while signed in.
    var avatar: Data?

    init(state: State, name: String? = nil, avatar: Data? = nil) {
        self.state = state
        self.name = name
        self.avatar = avatar
    }

    static func state(for phase: SteamSignInPhase) -> State {
        switch phase {
        case .notInstalled: .notInstalled
        case .notRunning: .off
        case .starting: .starting
        case .signingIn: .signingIn
        case .needsCredentials(.loggedInElsewhere): .signedOutElsewhere
        case .needsCredentials, .unknown: .signedOut
        case .signedIn: .signedIn
        }
    }
}

protocol SteamServicing: Sendable {
    func status() -> SteamSnapshot
    /// Valve's installer, checked against Valve's signature (only after the player approved it).
    func install() async throws
    /// `open -g -a <Steam.app> --args -silent` (SteamHostKit's `SteamLauncher`, background mode).
    func start() async throws
    /// The Home card: Steam's sign-in state, and the profile name and picture while signed in.
    func card() async -> SteamCard
    /// Log In: the next step for Steam's state (start it in the background, start it with its sign-in window, or bring
    /// Steam's own window forward). Warzag never asks for or sees credentials. False when Steam is not installed.
    func logIn() async -> Bool
    /// Log Out: Steam's own sign-out confirmation (Warzag never deletes Steam's saved sign-in).
    func logOut() async
    /// Hides Steam like ⌘H (only while hiding is allowed).
    func hideSteam() async
    /// Keep Steam out of sight is on and the player signs in with Steam: Warzag may hide Steam.
    func allowHiding(_ allowed: Bool)
}

// MARK: - Game

/// How DE's launcher run ended, as the setup steps see it.
enum ContentRunOutcome: Equatable, Sendable {
    case completed
    case eulaDeclined
    case stuck(LauncherRestartReason)
}

/// While setup waits for DE's EULA.
enum EULAOutcome: Equatable, Sendable {
    case accepted
    case declined
    case stuck(LauncherRestartReason)
}

/// How a run of DE's launcher for Updates › Warframe ended.
enum GameUpdateOutcome: Equatable, Sendable {
    /// DE's launcher finished and nothing on disk shows it changed anything: the library did not grow and
    /// Warframe.x64.exe was not replaced.
    case upToDate
    /// DE's launcher finished after downloading an update (the library grew, or Warframe.x64.exe was replaced).
    case updated
    /// DE's window closed while it showed its EULA.
    case eulaDeclined
    /// DE's launcher stalled or ended early, again after its restarts.
    case stuck
}

struct ContentSummary: Equatable, Sendable {
    var state: ContentStatus.State
    var lastUpdate: Date?
    var libraryBytes: Int64?
    /// The build Warframe reported when it last started; nil before its first start.
    var build: String? = nil
}

/// What the player chose for one Play.
struct PlayRequest: Equatable, Sendable {
    var steam: Bool
    var graphics: GraphicsChoice
    var hud: Bool
}

/// Play's progress, in order.
enum PlayUpdate: Equatable, Sendable {
    case startingSteam
    case waitingForSteamSignIn
    case game(PlayEvent)
}

struct PlaySummary: Equatable, Sendable {
    var seconds: TimeInterval
    var signals: [GameSignal]
    var forcedCleanup: Bool
}

enum PlayFailure: Error, Equatable, Sendable {
    case steamNotSignedIn
    /// The prefix lacks something; Repair fixes it.
    case needsRepair(String)
    /// Something else is still running in the prefix.
    case busy
    case updateDeclinedEULA
    case updateStuck
    case notInstalled
    case other(String)
}

protocol GameServicing: Sendable {
    /// Warframe.msi has been unpacked into the library (Tools/Launcher.exe exists).
    func launcherExtracted() -> Bool
    func downloadInstaller(progress: @escaping @Sendable (ContentRunState) -> Void) async throws
    func extractInstaller(progress: @escaping @Sendable (ContentRunState) -> Void) async throws
    /// The one-time EE.cfg seed for this Mac's tier; false when the player already has an EE.cfg.
    func seedProfile() throws -> Bool
    /// Warframe's motion blur as the player's EE.cfg last recorded it (read-only: Warzag never changes it there, and
    /// never touches the per-account settings file that wins at startup).
    func motionBlur() -> MotionBlurSetting
    /// DE's ReadEula is set in the prefix.
    func eulaAccepted() -> Bool
    /// Starts DE's launcher (if it is not running yet) and waits until the player has accepted the EULA in DE's
    /// window; the launcher keeps downloading afterwards.
    func waitForEULA(progress: @escaping @Sendable (ContentRunState) -> Void) async throws -> EULAOutcome
    /// Keeps DE's launcher on DirectX 11 (GraphicsAPI 0).
    func pinDirectX11() async throws
    /// Waits for the launcher run (starting one if none runs) until DE's launcher says it is done.
    func downloadContent(progress: @escaping @Sendable (ContentRunState) -> Void) async throws -> ContentRunOutcome
    /// Closes DE's launcher if a setup or update run (`updateGame`) is in progress; returns once it has ended.
    func cancelContentRun() async
    func contentStatus() -> ContentSummary?
    /// Updates › Warframe: DE's launcher brings the installed game up to date, as it does before every Play (hidden
    /// once its EULA is accepted), without opening the game. `cancelContentRun` closes it. Throws `PlayFailure` when
    /// the game cannot be updated now (something runs in the prefix, it is not installed, the prefix needs Repair).
    func updateGame(progress: @escaping @Sendable (ContentRunState) -> Void) async throws -> GameUpdateOutcome
    /// Something runs in the prefix (a wineserver serves it): Warframe or DE's launcher, also one an earlier run of
    /// Warzag left running (quitting Warzag never ends a game). Updates never install under it.
    func prefixIsBusy() -> Bool
    /// Update, open the game host, follow EE.log until Warframe exits, clean up.
    func play(_ request: PlayRequest, updates: @escaping @Sendable (PlayUpdate) -> Void) async throws -> PlaySummary
    /// Asks Warframe to close (WM_CLOSE through `taskkill`).
    func quitGame() async
    /// `wineserver -k`: ends everything in the prefix.
    func forceQuitGame() async
}
