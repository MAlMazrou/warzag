import CoreGraphics
import Foundation
import Synchronization
import Testing
import WarzagCore
import WarzagTestSupport
@testable import GameKit

@Suite struct GameWindowTests {
    let launched = Date(timeIntervalSince1970: 1_792_000_000)

    @Test func theGameIsTheRegularProcessWithAVisibleWindowNeverTheShim() {
        let processes = [
            HostProcess(processIdentifier: 42, isRegular: true, visibleWindowArea: 900_000),  // the shim Play opened
            HostProcess(processIdentifier: 43, isRegular: false, visibleWindowArea: 2_000_000),  // a helper
            HostProcess(processIdentifier: 44, isRegular: true, visibleWindowArea: 0),  // no window on screen
            HostProcess(processIdentifier: 45, isRegular: true, visibleWindowArea: 1_890_000),  // Warframe
        ]
        #expect(GameWindow.showing(in: processes, excluding: 42) == 45)
        #expect(GameWindow.showing(in: Array(processes.prefix(3)), excluding: 42) == nil)
    }

    @Test func theLargestWindowWinsThenTheNewestProcess() {
        let small = HostProcess(processIdentifier: 50, isRegular: true, visibleWindowArea: 120_000,
                                launchDate: launched)
        let large = HostProcess(processIdentifier: 51, isRegular: true, visibleWindowArea: 1_890_000,
                                launchDate: launched.addingTimeInterval(-60))
        #expect(GameWindow.showing(in: [large, small], excluding: nil) == 51)
        let newer = HostProcess(processIdentifier: 49, isRegular: true, visibleWindowArea: 1_890_000,
                                launchDate: launched)
        #expect(GameWindow.showing(in: [large, newer, small], excluding: nil) == 49)
    }

    @Test func withoutAVisibleWindowTheNewestRegularProcessIsTheTargetButNeverTheShimOrAHelper() {
        let shim = HostProcess(processIdentifier: 42, isRegular: true, launchDate: launched)
        let helper = HostProcess(processIdentifier: 43, isRegular: false, launchDate: launched.addingTimeInterval(9))
        let older = HostProcess(processIdentifier: 44, isRegular: true, launchDate: launched.addingTimeInterval(1))
        let game = HostProcess(processIdentifier: 45, isRegular: true, launchDate: launched.addingTimeInterval(5))
        #expect(GameWindow.target(in: [shim, helper, older, game], excluding: 42) == 45)
        #expect(GameWindow.target(in: [shim, helper], excluding: 42) == nil)
        // A visible window still comes first.
        let showing = HostProcess(processIdentifier: 46, isRegular: true, visibleWindowArea: 500_000,
                                  launchDate: launched)
        #expect(GameWindow.target(in: [game, showing], excluding: 42) == 46)
    }

    @Test func theGameOnlyEverTakesTheFrontFromNobodyWarzagItsHostOrSteam() {
        let own: Int32 = 100
        #expect(GameWindow.mayTakeFront(from: nil, ownProcessIdentifier: own))
        #expect(GameWindow.mayTakeFront(from: FocusApp(processIdentifier: own, bundleIdentifier: "com.warzag.app"),
                                        ownProcessIdentifier: own))
        #expect(GameWindow.mayTakeFront(from: FocusApp(processIdentifier: 42,
                                                       bundleIdentifier: GameWindow.hostBundleIdentifier),
                                        ownProcessIdentifier: own))
        #expect(GameWindow.mayTakeFront(from: FocusApp(processIdentifier: 300,
                                                       bundleIdentifier: GameWindow.steamBundleIdentifier),
                                        ownProcessIdentifier: own))
        let browser = FocusApp(processIdentifier: 200, bundleIdentifier: "com.example.browser")
        #expect(!GameWindow.mayTakeFront(from: browser, ownProcessIdentifier: own))
        #expect(!GameWindow.mayTakeFront(from: FocusApp(processIdentifier: 201, bundleIdentifier: nil),
                                         ownProcessIdentifier: own))
    }

    @Test func steamAndItsHelpersAreSteam() {
        #expect(GameWindow.isSteam(FocusApp(processIdentifier: 1, bundleIdentifier: "com.valvesoftware.steam")))
        #expect(GameWindow.isSteam(FocusApp(processIdentifier: 1, bundleIdentifier: "com.valvesoftware.steam.helper")))
        #expect(!GameWindow.isSteam(FocusApp(processIdentifier: 1, bundleIdentifier: "com.valvesoftware.steamlink")))
        #expect(!GameWindow.isSteam(FocusApp(processIdentifier: 1, bundleIdentifier: GameWindow.hostBundleIdentifier)))
        #expect(!GameWindow.isSteam(FocusApp(processIdentifier: 1, bundleIdentifier: nil)))
        #expect(!GameWindow.isSteam(nil))
    }

    @Test func theWindowListCountsNormalVisibleWindowsOfTheGivenOwners() {
        func window(_ owner: Int32, layer: Int = 0, alpha: Double = 1, _ rect: CGRect) -> [String: Any] {
            [kCGWindowOwnerPID as String: NSNumber(value: owner), kCGWindowLayer as String: NSNumber(value: layer),
             kCGWindowAlpha as String: NSNumber(value: alpha),
             kCGWindowBounds as String: rect.dictionaryRepresentation as NSDictionary]
        }
        let windows = [
            window(45, CGRect(x: 0, y: 0, width: 1710, height: 1107)),  // Warframe
            window(45, CGRect(x: 10, y: 10, width: 300, height: 200)),  // a smaller one of the same process
            window(45, layer: 25, CGRect(x: 0, y: 0, width: 3000, height: 3000)),  // above the normal level
            window(46, alpha: 0, CGRect(x: 0, y: 0, width: 800, height: 600)),  // fully transparent
            window(47, CGRect(x: 0, y: 0, width: 63, height: 400)),  // a helper strip
            window(99, CGRect(x: 0, y: 0, width: 800, height: 600)),  // another app's
            [kCGWindowOwnerPID as String: NSNumber(value: 48)],  // no bounds at all
        ]
        #expect(WindowList.largestVisibleWindowAreas(in: windows, owners: [45, 46, 47, 48])
            == [45: 1710.0 * 1107.0])
    }
}

/// A Mac as the focus rules see it, driven by a script on the manual clock: from `at` seconds after the start, the
/// change applies. Activating a process makes it frontmost (unless `honoursActivation` is false).
final class ScriptedMac: FocusEnvironment {
    struct State {
        var front: FocusApp?
        var processes: [HostProcess] = []
        var honoursActivation = true
        var activations: [Int32] = []
        var polls = 0
        /// What `hideSteam()` answers (whether Warzag may hide Steam now and hid something).
        var hidesSteam = true
        /// Hides and activations in order: "hide", "activate 43".
        var log: [String] = []
    }

    let clock: ManualClock
    let start: Date
    private let state: Mutex<State>
    private let script: Mutex<[(at: TimeInterval, change: @Sendable (inout State) -> Void)]>

    init(clock: ManualClock, front: FocusApp?, processes: [HostProcess] = [],
         script: [(at: TimeInterval, change: @Sendable (inout State) -> Void)] = []) {
        self.clock = clock
        start = clock.now
        var initial = State()
        initial.front = front
        initial.processes = processes
        state = Mutex(initial)
        self.script = Mutex(script.sorted { $0.at < $1.at })
    }

    var activations: [Int32] { state.withLock { $0.activations } }
    var polls: Int { state.withLock { $0.polls } }
    var log: [String] { state.withLock { $0.log } }

    func change(_ change: (inout State) -> Void) { state.withLock { change(&$0) } }

    private func applyScript() {
        let elapsed = clock.now.timeIntervalSince(start)
        let due = script.withLock { script -> [(at: TimeInterval, change: @Sendable (inout State) -> Void)] in
            let due = script.prefix { $0.at <= elapsed }
            script.removeFirst(due.count)
            return Array(due)
        }
        state.withLock { state in due.forEach { $0.change(&state) } }
    }

    func frontmostApp() async -> FocusApp? {
        applyScript()
        return state.withLock { state in
            state.polls += 1
            return state.front
        }
    }

    func hostProcesses() async -> [HostProcess] {
        applyScript()
        return state.withLock { $0.processes }
    }

    func activate(_ processIdentifier: Int32) async -> Bool {
        state.withLock { state in
            state.activations.append(processIdentifier)
            state.log.append("activate \(processIdentifier)")
            guard state.honoursActivation else { return false }
            state.front = FocusApp(processIdentifier: processIdentifier,
                                   bundleIdentifier: GameWindow.hostBundleIdentifier)
            return true
        }
    }

    func hideSteam() async -> Bool {
        state.withLock { state in
            state.log.append("hide")
            return state.hidesSteam
        }
    }
}

@Suite struct GameFocusKeeperTests {
    let clock = ManualClock()
    static let warzag = FocusApp(processIdentifier: 100, bundleIdentifier: "com.warzag.app")
    static let steam = FocusApp(processIdentifier: 300, bundleIdentifier: GameWindow.steamBundleIdentifier)
    static let browser = FocusApp(processIdentifier: 200, bundleIdentifier: "com.example.browser")
    /// The steam.exe shim Play opened: listed under the host's bundle identifier, no visible window.
    static let shim = HostProcess(processIdentifier: 42, isRegular: false)
    static let game = HostProcess(processIdentifier: 43, isRegular: true, visibleWindowArea: 1710 * 1107)

    static func gameWindowAppears(_ state: inout ScriptedMac.State) { state.processes.append(game) }
    static func steamTakesTheFront(_ state: inout ScriptedMac.State) { state.front = steam }

    func run(_ mac: ScriptedMac, hidesSteam: Bool = false) async -> [GameFocusEvent] {
        let events = Recorder<GameFocusEvent>()
        let keeper = GameFocusKeeper(environment: mac, clock: clock,
                                     ownProcessIdentifier: Self.warzag.processIdentifier, hidesSteam: hidesSteam)
        await keeper.run(openedProcess: Self.shim.processIdentifier) { events.append($0) }
        return events.all
    }

    @Test func theGamesWindowComesToTheFrontWhenItAppearsAndTheGuardEndsAMinuteLater() async {
        let mac = ScriptedMac(clock: clock, front: Self.warzag, processes: [Self.shim],
                              script: [(at: 3, change: Self.gameWindowAppears)])
        let events = await run(mac)
        #expect(mac.activations == [43])
        #expect(events == [.windowAppeared(processIdentifier: 43, broughtForward: true, front: nil),
                           .finished(returns: 0)])
        // Polled twice a second from the start until a minute after the window appeared.
        #expect(clock.now.timeIntervalSince(mac.start) >= 63)
        #expect(clock.now.timeIntervalSince(mac.start) <= 64)
        #expect(clock.sleeps.allSatisfy { $0 == .milliseconds(500) })
    }

    @Test func steamTakingTheFrontInTheFirstMinuteIsAnsweredAtMostThreeTimes() async {
        let mac = ScriptedMac(clock: clock, front: Self.warzag, processes: [Self.shim], script: [
            (at: 1, change: Self.gameWindowAppears),
            (at: 5, change: Self.steamTakesTheFront), (at: 10, change: Self.steamTakesTheFront),
            (at: 15, change: Self.steamTakesTheFront), (at: 20, change: Self.steamTakesTheFront),
        ])
        let events = await run(mac)
        #expect(mac.activations == [43, 43, 43, 43], "the window's first appearance, then three returns")
        #expect(events == [.windowAppeared(processIdentifier: 43, broughtForward: true, front: nil),
                           .steamTookFront(count: 1), .steamTookFront(count: 2), .steamTookFront(count: 3),
                           .finished(returns: 3)])
    }

    @Test func aFullScreenGameOffScreenBehindSteamIsStillBroughtBack() async {
        // In full screen the game's window has a Space of its own, which is not on screen while Steam is in front.
        let mac = ScriptedMac(clock: clock, front: Self.warzag, processes: [Self.shim], script: [
            (at: 1, change: Self.gameWindowAppears),
            (at: 5, change: {
                $0.front = GameFocusKeeperTests.steam
                $0.processes = [GameFocusKeeperTests.shim,
                                HostProcess(processIdentifier: 43, isRegular: true, visibleWindowArea: 0)]
            }),
        ])
        let events = await run(mac)
        #expect(mac.activations == [43, 43])
        #expect(events.contains(.steamTookFront(count: 1)))
    }

    @Test func steamInFrontWhenTheWindowAppearsGivesItUp() async {
        // Steam took the front from Warzag while the game was starting.
        let mac = ScriptedMac(clock: clock, front: Self.warzag, processes: [Self.shim], script: [
            (at: 1, change: Self.steamTakesTheFront), (at: 4, change: Self.gameWindowAppears),
        ])
        let events = await run(mac)
        #expect(mac.activations == [43])
        #expect(events.first == .windowAppeared(processIdentifier: 43, broughtForward: true, front: nil))
    }

    @Test func anotherAppThePlayerChoseKeepsTheFrontEvenWhenSteamPopsUpOverIt() async {
        let mac = ScriptedMac(clock: clock, front: Self.warzag, processes: [Self.shim], script: [
            (at: 2, change: { $0.front = GameFocusKeeperTests.browser }),
            (at: 4, change: Self.gameWindowAppears),
            (at: 10, change: Self.steamTakesTheFront),
        ])
        let events = await run(mac)
        #expect(mac.activations.isEmpty)
        #expect(events == [.windowAppeared(processIdentifier: 43, broughtForward: false, front: "com.example.browser"),
                           .finished(returns: 0)])
    }

    @Test func thePlayerLeavingTheGameForAnotherAppIsLeftAlone() async {
        let mac = ScriptedMac(clock: clock, front: Self.warzag, processes: [Self.shim], script: [
            (at: 1, change: Self.gameWindowAppears),
            (at: 5, change: { $0.front = GameFocusKeeperTests.browser }),
            (at: 8, change: Self.steamTakesTheFront),
        ])
        let events = await run(mac)
        #expect(mac.activations == [43], "only when the window appeared")
        #expect(events.last == .finished(returns: 0))
    }

    @Test func aRequestMacOSDoesNotHonourIsAskedAgainAfterASecondStillAtMostThreeTimes() async {
        let mac = ScriptedMac(clock: clock, front: Self.warzag, processes: [Self.shim], script: [
            (at: 1, change: Self.gameWindowAppears),
            (at: 5, change: {
                $0.front = GameFocusKeeperTests.steam
                $0.honoursActivation = false
            }),
        ])
        let events = await run(mac)
        #expect(mac.activations == [43, 43, 43, 43], "the window's first appearance, then three requests")
        // One Steam episode: one return, however many requests it took.
        #expect(events.dropFirst() == [.steamTookFront(count: 1), .finished(returns: 1)])
    }

    static let steamHelper = FocusApp(processIdentifier: 301, bundleIdentifier: "com.valvesoftware.steam.helper")

    @Test func steamsAppAndHelperTakingTurnsInFrontIsOneEpisode() async {
        let mac = ScriptedMac(clock: clock, front: Self.warzag, processes: [Self.shim], script: [
            (at: 1, change: Self.gameWindowAppears),
            (at: 5, change: Self.steamTakesTheFront),
            // The game came back at once; Steam's helper takes the front a moment later, then the app again.
            (at: 6, change: { $0.front = GameFocusKeeperTests.steamHelper }),
            (at: 7, change: Self.steamTakesTheFront),
            // Much later: a new episode.
            (at: 30, change: Self.steamTakesTheFront),
        ])
        let events = await run(mac)
        #expect(mac.activations == [43, 43, 43, 43, 43])
        #expect(events.filter { if case .steamTookFront = $0 { true } else { false } }
            == [.steamTookFront(count: 1), .steamTookFront(count: 2)])
        #expect(events.last == .finished(returns: 2))
    }

    @Test func withHidesSteamSteamIsHiddenBeforeTheGameIsBroughtBack() async {
        let mac = ScriptedMac(clock: clock, front: Self.warzag, processes: [Self.shim], script: [
            (at: 1, change: Self.gameWindowAppears),
            (at: 5, change: Self.steamTakesTheFront), (at: 10, change: Self.steamTakesTheFront),
            (at: 15, change: Self.steamTakesTheFront), (at: 20, change: Self.steamTakesTheFront),
        ])
        let events = await run(mac, hidesSteam: true)
        #expect(mac.log == ["activate 43", "hide", "activate 43", "hide", "activate 43", "hide", "activate 43"],
                "hide before every return; still three returns")
        #expect(events == [.windowAppeared(processIdentifier: 43, broughtForward: true, front: nil),
                           .steamHidden, .steamTookFront(count: 1), .steamHidden, .steamTookFront(count: 2),
                           .steamHidden, .steamTookFront(count: 3), .finished(returns: 3)])
    }

    @Test func steamInFrontWhenTheWindowAppearsIsHiddenFirst() async {
        let mac = ScriptedMac(clock: clock, front: Self.warzag, processes: [Self.shim], script: [
            (at: 1, change: Self.steamTakesTheFront), (at: 4, change: Self.gameWindowAppears),
        ])
        let events = await run(mac, hidesSteam: true)
        #expect(mac.log == ["hide", "activate 43"])
        #expect(events.prefix(2) == [.steamHidden, .windowAppeared(processIdentifier: 43, broughtForward: true,
                                                                   front: nil)])
    }

    @Test func noHidesWhenHidesSteamIsOffOrWarzagMayNotHide() async {
        let off = ScriptedMac(clock: clock, front: Self.warzag, processes: [Self.shim], script: [
            (at: 1, change: Self.gameWindowAppears), (at: 5, change: Self.steamTakesTheFront),
        ])
        let events = await run(off)
        #expect(!off.log.contains("hide"))
        #expect(!events.contains(.steamHidden))
    }

    @Test func whenTheEnvironmentDeclinesToHideTheReturnStillHappens() async {
        // Steam is the player's, or waits for credentials: `hideSteam()` hides nothing, so there is no event.
        let mac = ScriptedMac(clock: clock, front: Self.warzag, processes: [Self.shim], script: [
            (at: 1, change: Self.gameWindowAppears), (at: 5, change: Self.steamTakesTheFront),
        ])
        mac.change { $0.hidesSteam = false }
        let events = await run(mac, hidesSteam: true)
        #expect(mac.log == ["activate 43", "hide", "activate 43"])
        #expect(!events.contains(.steamHidden))
        #expect(events.contains(.steamTookFront(count: 1)))
    }

    @Test func steamTakingTheFrontFromAnotherAppIsNeverHiddenOrAnswered() async {
        let mac = ScriptedMac(clock: clock, front: Self.warzag, processes: [Self.shim], script: [
            (at: 1, change: Self.gameWindowAppears),
            (at: 5, change: { $0.front = GameFocusKeeperTests.browser }),
            (at: 8, change: Self.steamTakesTheFront),
        ])
        _ = await run(mac, hidesSteam: true)
        #expect(mac.log == ["activate 43"], "only when the window appeared")
    }

    @Test func aWindowAlreadyInFrontIsNotActivatedAgain() async {
        // Wine brought its own window forward first.
        let mac = ScriptedMac(clock: clock, front: Self.warzag, processes: [Self.shim], script: [
            (at: 2, change: {
                $0.processes.append(GameFocusKeeperTests.game)
                $0.front = FocusApp(processIdentifier: 43, bundleIdentifier: GameWindow.hostBundleIdentifier)
            }),
        ])
        let events = await run(mac)
        #expect(mac.activations.isEmpty)
        #expect(events.first == .windowAppeared(processIdentifier: 43, broughtForward: false, front: nil))
    }

    @Test func theShimIsNeverTheGamesWindowEvenWithAWindow() async {
        let shimWithWindow = HostProcess(processIdentifier: 42, isRegular: true, visibleWindowArea: 4_000_000)
        let mac = ScriptedMac(clock: clock, front: Self.warzag, processes: [shimWithWindow],
                              script: [(at: 6, change: Self.gameWindowAppears)])
        let events = await run(mac)
        #expect(mac.activations == [43])
        #expect(events.first == .windowAppeared(processIdentifier: 43, broughtForward: true, front: nil))
    }

    @Test func aSessionThatEndsBeforeTheWindowAppearsStopsTheGuard() async {
        let mac = ScriptedMac(clock: clock, front: Self.warzag, processes: [Self.shim])
        let keeper = GameFocusKeeper(environment: mac, clock: clock,
                                     ownProcessIdentifier: Self.warzag.processIdentifier)
        let events = Recorder<GameFocusEvent>()
        let task = Task { await keeper.run(openedProcess: 42) { events.append($0) } }
        while mac.polls < 5 { await Task.yield() }
        task.cancel()
        await task.value
        #expect(mac.activations.isEmpty)
        #expect(events.all.isEmpty)
    }
}
