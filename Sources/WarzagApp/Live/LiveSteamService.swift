import Foundation
import GameKit
import SteamHostKit
import Synchronization
import WarzagCore

/// SteamHostKit and GameKit's Steam controls for the app: the user's own Mac Steam, read-only detection, Valve's
/// installer, background starts, Log In / Log Out through Steam's own windows and hiding (like ⌘H). Warzag never
/// touches Steam.app, its config or credentials.
struct LiveSteamService: SteamServicing {
    let locations: SteamLocations
    /// Where Valve's disk image is downloaded and mounted.
    let workDirectory: URL
    /// Steam's apps and windows, shared with the game's focus keeper (one hide gate for both).
    let environment: WorkspaceSteamEnvironment
    /// When Warzag last started Steam, so the card says "Starting" until steam_osx is up.
    let launches = LaunchMemory()

    final class LaunchMemory: Sendable {
        private let record = Mutex<SteamLaunchRecord?>(nil)
        var last: SteamLaunchRecord? { record.withLock { $0 } }
        func started(_ mode: SteamStartMode) { record.withLock { $0 = SteamLaunchRecord(mode: mode, at: Date()) } }
        func clear() { record.withLock { $0 = nil } }
    }

    func status() -> SteamSnapshot {
        let status = SteamDetector(locations: locations).status()
        return SteamSnapshot(installed: status.installed, running: status.running, signedIn: status.signedIn)
    }

    func install() async throws {
        let installer = SteamInstaller(locations: locations, workDirectory: workDirectory, http: URLSessionHTTPClient(),
                                       runner: SystemProcessRunner(), fileSystem: LocalFileSystem())
        _ = try await installer.install()
    }

    /// In the background (`-silent`), by the detected Steam.app's path.
    func start() async throws {
        guard let app = SteamDetector(locations: locations).installedApp() else {
            throw SteamLaunchError(reason: "Steam is not installed")
        }
        launches.started(.background)
        try await SteamLauncher(runner: SystemProcessRunner()).launch(app: app, mode: .background)
    }

    func card() async -> SteamCard {
        let detector = SteamDetector(locations: locations)
        let status = detector.status()
        let state = SteamCard.state(for: detector.phase(for: status, launch: launches.last, now: Date()))
        guard state == .signedIn, let account = detector.account(for: status) else { return SteamCard(state: state) }
        return SteamCard(state: state, name: account.displayName, avatar: account.avatarPNG())
    }

    func logIn() async -> Bool {
        let detector = SteamDetector(locations: locations)
        let status = detector.status()
        let phase = detector.phase(for: status, launch: launches.last, now: Date())
        let action = SteamLogInPlan.next(phase: phase, hints: detector.loginHints(),
                                         startedSilently: detector.startedSilently(),
                                         windowsOnScreen: await environment.windowsOnScreen().count)
        switch action {
        case .installSteam: return false
        case .nothing, .wait: return true
        case .startInBackground: launches.started(.background)
        case .startWithSignInWindow, .restartWithSignInWindow: launches.started(.withSignInWindow)
        case .bringForward: break
        }
        // The player is signing in: Steam's sign-in window must stay visible until the model hides Steam again.
        environment.gate.set(false)
        _ = await SteamSequences(control: environment, clock: SystemClock()).perform(action)
        return true
    }

    func logOut() async {
        // Steam restarts itself after signing out; that is Steam's start, not Warzag's.
        launches.clear()
        environment.gate.set(false)
        _ = await environment.hider.unhideWhatWarzagHid()
        _ = await SteamSequences(control: environment, clock: SystemClock()).requestSignOut()
    }

    func hideSteam() async {
        _ = await environment.hideIfAllowed()
    }

    func allowHiding(_ allowed: Bool) {
        environment.gate.set(allowed)
    }
}
