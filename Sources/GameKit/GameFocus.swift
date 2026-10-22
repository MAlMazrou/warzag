import Foundation
import WarzagCore

// Keeping the game in front: macOS composites a game that is not frontmost, which costs GPU time, and Game Mode stays
// off. Steam can take the front several times while Warframe starts. WorkspaceFocusEnvironment is the live
// environment.

/// An app as the focus rules see it.
public struct FocusApp: Equatable, Sendable {
    public var processIdentifier: Int32
    public var bundleIdentifier: String?

    public init(processIdentifier: Int32, bundleIdentifier: String?) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
    }
}

/// One process of the game host bundle. Wine runs every Windows program as a Mac process of its own, and LaunchServices
/// lists each one that talks to the window server under the host's bundle identifier: the steam.exe shim Play opens,
/// Warframe, DE's launcher, Wine's helpers.
public struct HostProcess: Equatable, Sendable {
    public var processIdentifier: Int32
    /// A regular app (Dock, menu bar). winemac makes a process one when it shows a window; the shim (it holds only a
    /// hidden window) and Wine's helpers stay accessory apps (LSUIElement).
    public var isRegular: Bool
    /// The area of its largest visible window (on screen, at the normal window level, at least 64 x 64 points), in
    /// square points; 0 when it shows none.
    public var visibleWindowArea: Double
    public var launchDate: Date?

    public init(processIdentifier: Int32, isRegular: Bool, visibleWindowArea: Double = 0, launchDate: Date? = nil) {
        self.processIdentifier = processIdentifier
        self.isRegular = isRegular
        self.visibleWindowArea = visibleWindowArea
        self.launchDate = launchDate
    }
}

/// Which process is the window the player means.
public enum GameWindow {
    public static let hostBundleIdentifier = "com.warzag.gamehost"
    public static let steamBundleIdentifier = "com.valvesoftware.steam"

    /// The process whose window is showing: a regular app with a visible window, never `excluded` (the steam.exe shim
    /// LaunchServices opened for Play). The largest window wins (Warframe's during a session, DE's launcher's during
    /// setup), then the newest process.
    public static func showing(in processes: [HostProcess], excluding excluded: Int32?) -> Int32? {
        processes.filter { $0.isRegular && $0.visibleWindowArea > 0 && $0.processIdentifier != excluded }
            .max {
                ($0.visibleWindowArea, $0.started, $0.processIdentifier)
                    < ($1.visibleWindowArea, $1.started, $1.processIdentifier)
            }?.processIdentifier
    }

    /// What Return to Game and Show the Window bring forward: the process `showing` finds, or, when no window is
    /// visible here (minimised, or in another Space), the newest regular process, never `excluded`. Nil when there is
    /// none: activating the shim or a helper would only take the front away from Warzag and show nothing.
    public static func target(in processes: [HostProcess], excluding excluded: Int32?) -> Int32? {
        showing(in: processes, excluding: excluded)
            ?? processes.filter { $0.isRegular && $0.processIdentifier != excluded }
            .max { ($0.started, $0.processIdentifier) < ($1.started, $1.processIdentifier) }?.processIdentifier
    }

    /// The apps the game may ever take the front from: nobody, Warzag itself, the game host's own processes and Steam.
    /// Any other app is one the player chose.
    public static func mayTakeFront(from app: FocusApp?, ownProcessIdentifier: Int32) -> Bool {
        guard let app else { return true }
        return app.processIdentifier == ownProcessIdentifier || app.bundleIdentifier == hostBundleIdentifier
            || isSteam(app)
    }

    /// Steam itself or one of its helpers.
    public static func isSteam(_ app: FocusApp?) -> Bool {
        guard let identifier = app?.bundleIdentifier else { return false }
        return identifier == steamBundleIdentifier || identifier.hasPrefix(steamBundleIdentifier + ".")
    }
}

private extension HostProcess {
    var started: Date { launchDate ?? .distantPast }
}

/// What the focus rules read and do.
public protocol FocusEnvironment: Sendable {
    /// The app that receives key events now, if any.
    func frontmostApp() async -> FocusApp?
    /// Every running process of the game host bundle.
    func hostProcesses() async -> [HostProcess]
    /// Asks macOS to make `processIdentifier`'s app active with its windows in front; true when it is frontmost then.
    func activate(_ processIdentifier: Int32) async -> Bool
    /// Hides Steam like ⌘H when `SteamHideGate` allows it; true when it hid something. Hiding the active Steam hands
    /// the front back to the app before it. The default hides nothing.
    func hideSteam() async -> Bool
}

public extension FocusEnvironment {
    func hideSteam() async -> Bool { false }
}

public extension FocusEnvironment {
    /// Return to Game, Show the Window: the window the player means (`GameWindow.target`), if there is one.
    @discardableResult
    func bringGameWindowForward(excluding openedProcess: Int32?) async -> Int32? {
        guard let target = GameWindow.target(in: await hostProcesses(), excluding: openedProcess) else { return nil }
        _ = await activate(target)
        return target
    }
}

public struct GameFocusPolicy: Sendable, Equatable {
    public var pollInterval: Duration
    /// For how long after the game's window appears Steam does not get to keep the front.
    public var guardDuration: TimeInterval
    /// How many times Steam taking the front is answered in that time: Steam episodes, not requests.
    public var maximumReturns: Int
    /// The least time between two requests while Steam stays in front (a request macOS did not honour is asked again).
    public var retryInterval: TimeInterval
    /// Steam in front again this soon after it last was is the same episode: Steam's app and helper may take turns as
    /// the front app.
    public var episodeGap: TimeInterval
    /// The most requests within one episode (the first and the ones macOS did not honour).
    public var maximumRequestsPerReturn: Int

    public init(pollInterval: Duration = .milliseconds(500), guardDuration: TimeInterval = 60, maximumReturns: Int = 3,
                retryInterval: TimeInterval = 1, episodeGap: TimeInterval = 2, maximumRequestsPerReturn: Int = 3) {
        self.pollInterval = pollInterval
        self.guardDuration = guardDuration
        self.maximumReturns = maximumReturns
        self.retryInterval = retryInterval
        self.episodeGap = episodeGap
        self.maximumRequestsPerReturn = maximumRequestsPerReturn
    }
}

public enum GameFocusEvent: Equatable, Sendable {
    /// The game's window appeared. `broughtForward` is false when it was already in front, or when the player had
    /// gone to another app (`front`, its bundle identifier), which is left alone.
    case windowAppeared(processIdentifier: Int32, broughtForward: Bool, front: String?)
    /// Steam took the front from the game (or from Warzag) and the game was brought back: return `count` of at most
    /// `GameFocusPolicy.maximumReturns`, one per Steam episode.
    case steamTookFront(count: Int)
    /// Steam was hidden (like ⌘H) before the game was brought back (`hidesSteam`).
    case steamHidden
    /// The guard is over (`GameFocusPolicy.guardDuration` after the window appeared).
    case finished(returns: Int)
}

/// After Play opens the game: waits for its window and brings it to the front, then for `guardDuration` brings it
/// back whenever Steam takes the front, at most `maximumReturns` times, counted per Steam episode. It only ever takes
/// the front from Warzag, the game host's own processes and Steam, never from an app the player chose. With
/// `hidesSteam`, Steam is hidden before each request, which keeps its pop-ups off a full-screen game.
public struct GameFocusKeeper: Sendable {
    public let environment: any FocusEnvironment
    public let clock: any WallClock
    public let policy: GameFocusPolicy
    /// Warzag's own process.
    public let ownProcessIdentifier: Int32
    /// Keep Steam out of sight is on: hide Steam before bringing the game back from it.
    public let hidesSteam: Bool

    public init(environment: any FocusEnvironment, clock: any WallClock, policy: GameFocusPolicy = GameFocusPolicy(),
                ownProcessIdentifier: Int32, hidesSteam: Bool = false) {
        self.environment = environment
        self.clock = clock
        self.policy = policy
        self.ownProcessIdentifier = ownProcessIdentifier
        self.hidesSteam = hidesSteam
    }

    /// One stretch of Steam in front.
    private struct Episode {
        /// When a Steam process was last seen in front.
        var lastInFront: Date
        /// Whether it is answered (Steam took the front from the game or Warzag, and a return was left).
        var answered: Bool
        var requests = 0
    }

    /// `openedProcess`: the process LaunchServices opened for Play, the steam.exe shim; never the game's window.
    public func run(openedProcess: Int32?, events: @Sendable (GameFocusEvent) -> Void = { _ in }) async {
        // The last app in front that was not Steam: whose front Steam took.
        var lastOtherFront: FocusApp?
        var appearedAt: Date?
        var returns = 0
        var lastRequest: Date?
        var episode: Episode?
        while !Task.isCancelled {
            let front = await environment.frontmostApp()
            let now = clock.now
            if let appeared = appearedAt {
                if now.timeIntervalSince(appeared) >= policy.guardDuration {
                    events(.finished(returns: returns))
                    return
                }
                if GameWindow.isSteam(front) {
                    if let current = episode, now.timeIntervalSince(current.lastInFront) < policy.episodeGap {
                        episode?.lastInFront = now
                    } else {
                        // A new episode: answered only when Steam took the front from the game or Warzag.
                        let answered = isSession(lastOtherFront) && returns < policy.maximumReturns
                        if answered { returns += 1 }
                        episode = Episode(lastInFront: now, answered: answered)
                    }
                    // `target`, not `showing`: in full screen the game's window is in a Space of its own, off screen
                    // while Steam is in front.
                    if let current = episode, current.answered, current.requests < policy.maximumRequestsPerReturn,
                       lastRequest.map({ now.timeIntervalSince($0) >= policy.retryInterval }) ?? true,
                       let game = GameWindow.target(in: await environment.hostProcesses(), excluding: openedProcess) {
                        episode?.requests += 1
                        lastRequest = now
                        await hideSteam(events)
                        _ = await environment.activate(game)
                        if current.requests == 0 { events(.steamTookFront(count: returns)) }
                    }
                } else if let current = episode, now.timeIntervalSince(current.lastInFront) >= policy.episodeGap {
                    episode = nil
                }
            } else if let game = GameWindow.showing(in: await environment.hostProcesses(), excluding: openedProcess) {
                appearedAt = now
                let mayTakeFront = front == nil || isSession(front)
                    || (GameWindow.isSteam(front) && isSession(lastOtherFront))
                let bringForward = mayTakeFront && front?.processIdentifier != game
                if bringForward {
                    if GameWindow.isSteam(front) { await hideSteam(events) }
                    _ = await environment.activate(game)
                }
                events(.windowAppeared(processIdentifier: game, broughtForward: bringForward,
                                       front: mayTakeFront ? nil : front?.bundleIdentifier))
            }
            if let front, !GameWindow.isSteam(front) { lastOtherFront = front }
            do {
                try await clock.sleep(for: policy.pollInterval)
            } catch {
                return
            }
        }
    }

    private func hideSteam(_ events: @Sendable (GameFocusEvent) -> Void) async {
        guard hidesSteam else { return }
        if await environment.hideSteam() { events(.steamHidden) }
    }

    /// Warzag, one of the game host's processes, or nobody: apps whose front the game may take.
    private func isSession(_ app: FocusApp?) -> Bool {
        guard let app else { return true }
        return app.processIdentifier == ownProcessIdentifier || app.bundleIdentifier == GameWindow.hostBundleIdentifier
    }
}
