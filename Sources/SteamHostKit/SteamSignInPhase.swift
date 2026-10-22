import Foundation

/// Where Steam is on its way to a signed-in account, worked out from Steam's own files only. The Home card, Setup's
/// sign-in card, Play's waiting line and Log In all start from it.
public enum SteamSignInPhase: Equatable, Hashable, Sendable, CustomStringConvertible {
    /// No Steam.app in /Applications or ~/Applications.
    case notInstalled
    /// No steam_osx, and no start of Warzag's in flight.
    case notRunning
    /// Warzag started Steam and steam_osx is not up yet (90 s), or steam_osx is up and has logged nothing that says
    /// more (90 s since it started). `firstRun`: steamclient.dylib is missing; Steam's first start downloads its
    /// client, so both limits are 5 minutes.
    case starting(firstRun: Bool)
    /// Steam's sign-in moves by itself. `step`: the latest SetLoginState, nil when only the connection log says so
    /// (a line naming an account before "Logged On"); `since`: when Steam reached that step.
    case signingIn(step: SteamLoginStep?, since: Date?)
    /// Steam waits for the player: its sign-in screen, or its "sign in again" dialog after a "Logged In Elsewhere"
    /// sign-out.
    case needsCredentials(SteamLoginReason)
    /// A live steam_osx whose latest connection state since it started is "Logged On".
    case signedIn
    /// Steam runs but its logs say nothing Warzag understands (unreadable, or a changed format): callers fall back to
    /// the coarse running / signed-in states of `SteamStatus`.
    case unknown

    /// Fixed tokens for Warzag.log, diagnostics and warzagctl, e.g. "needs credentials (logged in elsewhere)".
    public var description: String {
        switch self {
        case .notInstalled: "not installed"
        case .notRunning: "not running"
        case .starting(let firstRun): firstRun ? "starting (first run)" : "starting"
        case .signingIn(let step, _): step.map { "signing in (\($0.token))" } ?? "signing in"
        case .needsCredentials(let reason):
            switch reason {
            case .ok: "needs credentials"
            case .loggedInElsewhere: "needs credentials (logged in elsewhere)"
            case .other: "needs credentials (other reason)"
            }
        case .signedIn: "signed in"
        case .unknown: "unknown"
        }
    }

    public var isSignedIn: Bool { self == .signedIn }

    /// Without a SetLoginState line, a run whose connection lines never named an account for this long since Steam
    /// started is at Steam's sign-in screen.
    public static let anonymousGrace: TimeInterval = 20

    /// The checks run in order and the first match wins. `processStart`: steam_osx's start; `connection` and `login`:
    /// what was logged since then (nil when unreadable); `launch`: Warzag's latest start of Steam, if any.
    public static func derive(
        status: SteamStatus,
        processStart: Date?,
        connection: ConnectionLogSummary?,
        login: SteamLoginTransition?,
        launch: SteamLaunchRecord?,
        now: Date
    ) -> SteamSignInPhase {
        let firstRun = !status.clientRuntimeInstalled
        let inFlight = launch?.isInFlight(at: now, clientInstalled: status.clientRuntimeInstalled) ?? false
        guard status.installed else { return .notInstalled }
        guard status.running else { return inFlight ? .starting(firstRun: firstRun) : .notRunning }
        if status.signedIn { return .signedIn }
        if let login, login.step == .waitingForCredentials { return .needsCredentials(login.reason) }
        if let login, login.step.isMoving { return .signingIn(step: login.step, since: login.at) }
        if connection?.latest?.carriesAccount == true { return .signingIn(step: nil, since: nil) }
        let running = processStart.map { now.timeIntervalSince($0) }
        if connection?.onlyAnonymous == true, let running, running > anonymousGrace {
            return .needsCredentials(.ok)
        }
        // A start of Warzag's in flight can only be this process's when its start time is unknown: a process up for
        // longer than the limit started before that record.
        let startLimit = firstRun ? SteamLaunchRecord.firstRunInFlight : SteamLaunchRecord.inFlight
        return (running.map { $0 < startLimit } ?? inFlight) ? .starting(firstRun: firstRun) : .unknown
    }
}
