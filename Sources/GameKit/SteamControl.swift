import Foundation
import SteamHostKit
import WarzagCore

// Log In and Log Out: Warzag only ever starts Steam, brings it forward, asks it things through its own steam:// links
// and asks it to quit. Steam's own windows do the rest: its sign-in window, its sign-out confirmation, its store page.
// Warzag never handles, stores or deletes credentials (no -login, no password field, no deleting Steam's files to
// sign out).

/// The steam:// links Warzag sends, only ever to a running Steam (Steam.app handles them and would start Steam without
/// -silent and with its window).
public enum SteamLink: Equatable, Hashable, Sendable {
    /// Steam's own sign-out confirmation ("This will sign you out of Steam…"); on OK Steam forgets the saved sign-in
    /// for that account and restarts at its sign-in screen. Steam's only supported sign-out besides Steam › Sign Out….
    case signOut
    /// Steam's own quit, the one its Quit menu item uses.
    case exit

    public var url: URL {
        switch self {
        case .signOut: URL(string: "steam://signout")!
        case .exit: URL(string: "steam://exit")!
        }
    }
}

/// The few things Warzag ever does to Steam, behind a protocol so the sequences run against fakes.
/// `WorkspaceSteamEnvironment` is the live one.
public protocol SteamControlling: Sendable {
    /// steam_osx runs, or Steam's app is still up (opening Steam.app then would be a reopen event).
    func isRunning() async -> Bool
    /// Opens a steam:// link; false, and nothing sent, when Steam isn't running.
    func send(_ link: SteamLink, activates: Bool) async -> Bool
    /// `NSRunningApplication.terminate()` on Steam's app: the standard quit Apple event, no Automation prompt. Never
    /// `forceTerminate` or a kill: Steam may be writing its files.
    func terminate() async -> Bool
    /// Starts Steam (`SteamLauncher`, by the detected path). Callers make sure it isn't running.
    func start(_ mode: SteamStartMode) async throws
    /// Brings a running Steam forward with the cooperative handoff (`yieldActivation(to:)`, `activate(from:)`): never a
    /// reopen, never `activate(ignoringOtherApps:)` on Steam. Steam unhides itself as it activates.
    func bringForward() async -> Bool
}

public struct SteamControlPolicy: Equatable, Sendable {
    /// After steam://exit, how long Steam gets before `terminate()`.
    public var exitGrace: TimeInterval = 5
    /// After the request, how long until the Log In restart gives up ("Steam didn't close").
    public var closeLimit: TimeInterval = 20
    public var pollInterval: Duration = .milliseconds(500)

    public init() {}
}

public enum SteamRestartOutcome: Equatable, Sendable {
    case started
    /// "Steam didn't close. Quit it from its Dock icon, then click Log In." Warzag never forces it.
    case didNotClose
    case startFailed(String)
}

/// The timed parts of Log In and Log Out, over `SteamControlling` and a clock.
public struct SteamSequences: Sendable {
    public let control: any SteamControlling
    public let clock: any WallClock
    public let policy: SteamControlPolicy

    public init(control: any SteamControlling, clock: any WallClock, policy: SteamControlPolicy = SteamControlPolicy()) {
        self.control = control
        self.clock = clock
        self.policy = policy
    }

    /// The Log In restart: Steam waits for credentials invisibly (started with -silent, its sign-in window created
    /// hidden and never shown again by Steam's own code), so it quits (steam://exit, `terminate()` after `exitGrace`),
    /// and once steam_osx has ended (at most `closeLimit` after the request) starts with its sign-in window.
    public func restartWithSignInWindow() async -> SteamRestartOutcome {
        if await control.isRunning() {
            let requested = clock.now
            _ = await control.send(.exit, activates: false)
            if !(await stopped(by: requested.addingTimeInterval(policy.exitGrace))) {
                _ = await control.terminate()
                guard await stopped(by: requested.addingTimeInterval(policy.closeLimit)) else { return .didNotClose }
            }
        }
        do {
            try await control.start(.withSignInWindow)
            return .started
        } catch {
            return .startFailed(String(describing: error))
        }
    }

    /// Log Out: Steam's own sign-out confirmation, `steam://signout` with Steam activated, only while Steam runs. The
    /// caller unhides what Warzag hid first.
    public func requestSignOut() async -> Bool {
        guard await control.isRunning() else { return false }
        return await control.send(.signOut, activates: true)
    }

    /// Does one Log In action (`SteamLogInPlan`). A start never goes to a Steam that runs.
    public func perform(_ action: SteamLogInAction) async -> SteamLogInOutcome {
        switch action {
        case .startInBackground, .startWithSignInWindow:
            guard !(await control.isRunning()) else { return .alreadyRunning }
            do {
                try await control.start(action == .startInBackground ? .background : .withSignInWindow)
                return .done
            } catch {
                return .startFailed(String(describing: error))
            }
        case .restartWithSignInWindow:
            switch await restartWithSignInWindow() {
            case .started: return .done
            case .didNotClose: return .didNotClose
            case .startFailed(let reason): return .startFailed(reason)
            }
        case .bringForward:
            return await control.bringForward() ? .done : .notRunning
        case .installSteam, .wait, .nothing:
            return .done
        }
    }

    /// Polls until steam_osx (and Steam's app) has ended, or the deadline passes.
    private func stopped(by deadline: Date) async -> Bool {
        while await control.isRunning() {
            guard clock.now < deadline else { return false }
            do {
                try await clock.sleep(for: policy.pollInterval)
            } catch {
                return !(await control.isRunning())
            }
        }
        return true
    }
}

// MARK: - Log In

/// What Log In does next (`SteamLogInPlan`).
public enum SteamLogInAction: Equatable, Hashable, Sendable {
    /// Steam missing: go to Install Steam.
    case installSteam
    /// Not running, a saved sign-in likely: start invisibly (`-silent`).
    case startInBackground
    /// Not running, no saved sign-in: start with Steam's sign-in window.
    case startWithSignInWindow
    /// Starting or signing in: wait and show the step.
    case wait
    /// Signed in.
    case nothing
    /// Bring Steam forward: its "sign in again" dialog after "Logged In Elsewhere", its sign-in window already on
    /// screen, or a Steam whose state Warzag cannot tell.
    case bringForward
    /// Steam waits for credentials invisibly: restart it with its sign-in window (`SteamSequences`).
    case restartWithSignInWindow
}

public enum SteamLogInOutcome: Equatable, Sendable {
    case done
    case alreadyRunning
    case notRunning
    case didNotClose
    case startFailed(String)
}

public enum SteamLogInPlan {
    /// `startedSilently`: bootstrap_log says the running Steam was started with `-silent`; `windowsOnScreen`: Steam's
    /// windows on screen now. A Steam that waits for credentials invisibly is restarted with its sign-in window.
    public static func next(phase: SteamSignInPhase, hints: SteamLoginHints, startedSilently: Bool?,
                            windowsOnScreen: Int) -> SteamLogInAction {
        switch phase {
        case .notInstalled: return .installSteam
        case .notRunning: return hints.quietSignInLikely ? .startInBackground : .startWithSignInWindow
        case .starting, .signingIn: return .wait
        case .signedIn: return .nothing
        case .needsCredentials(.loggedInElsewhere): return .bringForward
        case .needsCredentials:
            let invisible = startedSilently == true || windowsOnScreen == 0
            return invisible ? .restartWithSignInWindow : .bringForward
        case .unknown: return .bringForward
        }
    }
}
