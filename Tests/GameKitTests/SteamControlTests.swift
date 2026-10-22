import Foundation
import Synchronization
import Testing
import SteamHostKit
import WarzagCore
import WarzagTestSupport
@testable import GameKit

/// A Steam that quits when told to, or not, on the manual clock. It records everything Warzag does to it.
final class FakeSteamControl: SteamControlling {
    struct State {
        var running = true
        /// steam://exit makes Steam quit this many seconds later (nil: it ignores it).
        var quitsAfterExit: TimeInterval? = 1
        /// terminate() makes Steam quit this many seconds later (nil: it ignores it).
        var quitsAfterTerminate: TimeInterval?
        var quitAt: Date?
        var startFails = false
        var calls: [String] = []
    }

    let clock: ManualClock
    let state: Mutex<State>

    init(clock: ManualClock, _ state: State = State()) {
        self.clock = clock
        self.state = Mutex(state)
    }

    var calls: [String] { state.withLock { $0.calls } }

    func isRunning() async -> Bool {
        let now = clock.now
        return state.withLock { state in
            if let quitAt = state.quitAt, now >= quitAt {
                state.running = false
                state.quitAt = nil
            }
            return state.running
        }
    }

    func send(_ link: SteamLink, activates: Bool) async -> Bool {
        let running = await isRunning()
        let now = clock.now
        return state.withLock { state in
            // The live environment refuses too: a link to a Steam that isn't running would start it with its window.
            guard running else { return false }
            state.calls.append("\(link.url.absoluteString) activates=\(activates)")
            if link == .exit, let delay = state.quitsAfterExit { state.quitAt = now.addingTimeInterval(delay) }
            return true
        }
    }

    func terminate() async -> Bool {
        let now = clock.now
        return state.withLock { state in
            state.calls.append("terminate")
            if let delay = state.quitsAfterTerminate { state.quitAt = now.addingTimeInterval(delay) }
            return state.running
        }
    }

    func start(_ mode: SteamStartMode) async throws {
        try state.withLock { state in
            state.calls.append("start \(mode.rawValue)")
            if state.startFails { throw SteamLaunchError(reason: "made-up failure") }
            state.running = true
        }
    }

    func bringForward() async -> Bool {
        state.withLock { state in
            state.calls.append("bringForward")
            return state.running
        }
    }
}

@Suite struct SteamSequencesTests {
    let clock = ManualClock()

    func sequences(_ control: FakeSteamControl) -> SteamSequences {
        SteamSequences(control: control, clock: clock)
    }

    @Test func noLinkGoesToASteamThatIsNotRunning() async {
        let control = FakeSteamControl(clock: clock, .init(running: false))
        #expect(await sequences(control).requestSignOut() == false)
        #expect(control.calls.isEmpty)
    }

    @Test func logOutIsSteamsOwnConfirmationWithSteamActivated() async {
        let control = FakeSteamControl(clock: clock)
        #expect(await sequences(control).requestSignOut())
        #expect(control.calls == ["steam://signout activates=true"])
    }

    @Test func theLogInRestartIsExitThenTerminateThenTheSignInWindow() async {
        let control = FakeSteamControl(clock: clock, .init(quitsAfterExit: nil, quitsAfterTerminate: 3))
        #expect(await sequences(control).restartWithSignInWindow() == .started)
        #expect(control.calls == ["steam://exit activates=false", "terminate", "start withSignInWindow"])

        let polite = FakeSteamControl(clock: clock)
        #expect(await sequences(polite).restartWithSignInWindow() == .started)
        #expect(polite.calls == ["steam://exit activates=false", "start withSignInWindow"])
    }

    @Test func aSteamThatDoesNotCloseFor20SecondsIsNotStartedAgain() async {
        let control = FakeSteamControl(clock: clock, .init(quitsAfterExit: nil, quitsAfterTerminate: nil))
        let start = clock.now
        #expect(await sequences(control).restartWithSignInWindow() == .didNotClose)
        #expect(control.calls == ["steam://exit activates=false", "terminate"])
        #expect(clock.now.timeIntervalSince(start) >= 20)
    }

    @Test func performingLogInActions() async {
        let stopped = FakeSteamControl(clock: clock, .init(running: false))
        #expect(await sequences(stopped).perform(.startInBackground) == .done)
        #expect(await sequences(stopped).perform(.startWithSignInWindow) == .alreadyRunning, "never a second start")
        #expect(await sequences(stopped).perform(.bringForward) == .done)
        #expect(stopped.calls == ["start background", "bringForward"])
        let failing = FakeSteamControl(clock: clock, .init(running: false, startFails: true))
        #expect(await sequences(failing).perform(.startWithSignInWindow)
            == .startFailed("Could not start Steam: made-up failure"))
        let gone = FakeSteamControl(clock: clock, .init(running: false))
        #expect(await sequences(gone).perform(.bringForward) == .notRunning)
        #expect(await sequences(gone).perform(.wait) == .done && gone.calls == ["bringForward"])
    }

    @Test func links() {
        #expect(SteamLink.signOut.url.absoluteString == "steam://signout")
        #expect(SteamLink.exit.url.absoluteString == "steam://exit")
    }
}

@Suite struct SteamLogInTests {
    static let saved = SteamLoginHints(quietSignInLikely: true)
    static let unsaved = SteamLoginHints.none

    func plan(_ phase: SteamSignInPhase, _ hints: SteamLoginHints = saved, silent: Bool? = nil,
              windows: Int = 0) -> SteamLogInAction {
        SteamLogInPlan.next(phase: phase, hints: hints, startedSilently: silent, windowsOnScreen: windows)
    }

    @Test func eachPhaseGetsItsAction() {
        #expect(plan(.notInstalled) == .installSteam)
        #expect(plan(.notRunning) == .startInBackground)
        #expect(plan(.notRunning, Self.unsaved) == .startWithSignInWindow)
        #expect(plan(.starting(firstRun: true)) == .wait)
        #expect(plan(.signingIn(step: .waitingForNetwork, since: nil)) == .wait)
        #expect(plan(.signedIn) == .nothing)
        #expect(plan(.needsCredentials(.loggedInElsewhere), silent: true, windows: 0) == .bringForward)
        #expect(plan(.needsCredentials(.ok), silent: true, windows: 2) == .restartWithSignInWindow)
        #expect(plan(.needsCredentials(.ok), silent: false, windows: 0) == .restartWithSignInWindow)
        #expect(plan(.needsCredentials(.other), silent: nil, windows: 0) == .restartWithSignInWindow)
        #expect(plan(.needsCredentials(.ok), silent: false, windows: 1) == .bringForward)
        #expect(plan(.unknown) == .bringForward)
    }
}
