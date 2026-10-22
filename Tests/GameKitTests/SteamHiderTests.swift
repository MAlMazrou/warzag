import CoreGraphics
import Foundation
import Synchronization
import Testing
import WarzagCore
import WarzagTestSupport
@testable import GameKit

/// Steam's app and helper as a script decides: which hides work and which windows they take away.
final class FakeSteamApps: SteamApps {
    struct State {
        var processes: [SteamAppProcess] = []
        var windows: [SteamWindow] = []
        /// Hiding the key takes away the windows of these owners (Steam passes hiding from its app to its helper).
        var hidingRemoves: [Int32: Set<Int32>] = [:]
        /// hide() answers false for these (no windows: Steam's GPU and renderer helpers).
        var hideFails: Set<Int32> = []
        var calls: [String] = []
    }

    let state: Mutex<State>

    init(_ state: State) {
        self.state = Mutex(state)
    }

    var calls: [String] { state.withLock { $0.calls } }

    func processes() async -> [SteamAppProcess] { state.withLock { $0.processes } }

    func hide(_ processIdentifier: Int32) async -> Bool {
        state.withLock { state in
            state.calls.append("hide \(processIdentifier)")
            guard !state.hideFails.contains(processIdentifier),
                  let index = state.processes.firstIndex(where: { $0.processIdentifier == processIdentifier })
            else { return false }
            state.processes[index].isHidden = true
            let gone = state.hidingRemoves[processIdentifier] ?? []
            state.windows.removeAll { gone.contains($0.processIdentifier) }
            return true
        }
    }

    func unhide(_ processIdentifier: Int32) async -> Bool {
        state.withLock { state in
            state.calls.append("unhide \(processIdentifier)")
            guard let index = state.processes.firstIndex(where: { $0.processIdentifier == processIdentifier })
            else { return false }
            state.processes[index].isHidden = false
            return true
        }
    }

    func windowsOnScreen() async -> [SteamWindow] { state.withLock { $0.windows } }
}

@Suite struct SteamHiderTests {
    static let app = SteamAppProcess(processIdentifier: 100, kind: .app)
    static let helper = SteamAppProcess(processIdentifier: 200, kind: .helper)
    static let gpu = SteamAppProcess(processIdentifier: 201, kind: .helper)
    static let mainWindow = SteamWindow(processIdentifier: 200, layer: 0, width: 1280, height: 800)
    static let popUp = SteamWindow(processIdentifier: 200, layer: 3, width: 283, height: 70)
    let clock = ManualClock()

    func hider(_ state: FakeSteamApps.State) -> (SteamHider, FakeSteamApps) {
        let apps = FakeSteamApps(state)
        return (SteamHider(apps: apps, clock: clock), apps)
    }

    @Test func hidingTheAppIsEnoughWhenSteamPassesItToItsHelper() async {
        let (hider, apps) = hider(.init(processes: [Self.app, Self.helper], windows: [Self.mainWindow, Self.popUp],
                                        hidingRemoves: [100: [200]]))
        let result = await hider.hide()
        #expect(result == SteamHideResult(hidApps: 1, hidHelpers: 0, windowsStillOnScreen: 0, gaveUp: false))
        #expect(apps.calls == ["hide 100"])
        #expect(clock.sleeps == [.milliseconds(300)])
        #expect(await hider.hidden == [100: .app])
    }

    @Test func theHelperToo300msLaterWhenSteamsWindowsStay() async {
        let (hider, apps) = hider(.init(processes: [Self.app, Self.helper, Self.gpu], windows: [Self.mainWindow],
                                        hidingRemoves: [200: [200]], hideFails: [201]))
        let result = await hider.hide()
        #expect(result == SteamHideResult(hidApps: 1, hidHelpers: 1, windowsStillOnScreen: 0, gaveUp: false))
        #expect(apps.calls == ["hide 100", "hide 200", "hide 201"])
        #expect(clock.sleeps == [.milliseconds(300), .milliseconds(300)])
        // The GPU helper's false answer is ignored, and it is not recorded.
        #expect(await hider.hidden == [100: .app, 200: .helper])
    }

    @Test func onlyWhatWarzagHidIsUnhiddenNeverWhatThePlayerHid() async {
        var playerHid = Self.app
        playerHid.isHidden = true
        let (hider, apps) = hider(.init(processes: [playerHid, Self.helper], windows: [Self.mainWindow],
                                        hidingRemoves: [200: [200]]))
        let result = await hider.hide()
        #expect(result.hidApps == 0 && result.hidHelpers == 1)
        #expect(await hider.hidden == [200: .helper])
        #expect(await hider.unhideWhatWarzagHid() == 1)
        #expect(apps.calls == ["hide 200", "unhide 200"])
        #expect(await hider.hidden.isEmpty)
        #expect(await hider.unhideWhatWarzagHid() == 0)
    }

    @Test func aSteamThatShowedItselfAgainIsHiddenAgain() async {
        let (hider, apps) = hider(.init(processes: [Self.app, Self.helper], windows: [Self.popUp],
                                        hidingRemoves: [100: [200]]))
        _ = await hider.hide()
        // Steam activated itself (a dialog): activation unhides it, and its window is back.
        apps.state.withLock {
            $0.processes[0].isHidden = false
            $0.windows = [Self.mainWindow]
        }
        let again = await hider.hide()
        #expect(again.hidApps == 1 && again.windowsStillOnScreen == 0)
        #expect(apps.calls == ["hide 100", "hide 100"])
        #expect(await hider.hidden == [100: .app])
    }

    @Test func aProcessThatQuitIsNeverTouchedAgain() async {
        let (hider, apps) = hider(.init(processes: [Self.app, Self.helper], windows: [], hidingRemoves: [:]))
        _ = await hider.hide()
        apps.state.withLock { $0.processes = [Self.helper] }  // Steam's app quit; its pid may be another app's now
        #expect(await hider.unhideWhatWarzagHid() == 0)
        #expect(!apps.calls.contains("unhide 100"))
    }

    @Test func twoHidesWithNoEffectAndWarzagStopsTryingForThoseProcesses() async {
        let (hider, apps) = hider(.init(processes: [Self.app, Self.helper], windows: [Self.mainWindow]))
        let first = await hider.hide()
        #expect(first.windowsStillOnScreen == 1 && !first.gaveUp)
        let second = await hider.hide()
        #expect(second.gaveUp)
        let calls = apps.calls.count
        let third = await hider.hide()
        #expect(apps.calls.count == calls, "no more tries")
        #expect(third.hidApps == 0 && third.hidHelpers == 0)
    }

    @Test func aHideThatWorksAgainForgivesTheCount() async {
        let (hider, apps) = hider(.init(processes: [Self.app, Self.helper], windows: [Self.mainWindow]))
        _ = await hider.hide()
        // Steam shows a pop-up again later; this time the hide works.
        _ = await hider.unhideWhatWarzagHid()
        apps.state.withLock {
            $0.hidingRemoves = [200: [200]]
            $0.windows = [Self.popUp]
        }
        #expect(await hider.hide().windowsStillOnScreen == 0)
        apps.state.withLock {
            $0.hidingRemoves = [:]
            $0.windows = [Self.popUp]
            $0.processes = [Self.app, Self.helper]
        }
        _ = await hider.unhideWhatWarzagHid()
        #expect(await !hider.hide().gaveUp, "one failure after a success is not two in a row")
    }

    @Test func theHideGateStartsClosed() {
        let gate = SteamHideGate()
        #expect(!gate.isOpen)
        gate.set(true)
        #expect(gate.isOpen)
    }

    @Test func steamsWindowsOnScreenAreOwnerLayerAndSizeOnly() {
        func window(_ owner: Int32, layer: Int = 0, alpha: Double = 1, _ rect: CGRect) -> [String: Any] {
            [kCGWindowOwnerPID as String: NSNumber(value: owner), kCGWindowLayer as String: NSNumber(value: layer),
             kCGWindowAlpha as String: NSNumber(value: alpha), kCGWindowName as String: "a friend's name",
             kCGWindowBounds as String: rect.dictionaryRepresentation as NSDictionary]
        }
        let windows = [
            window(200, CGRect(x: 0, y: 0, width: 1280, height: 800)),  // the main window
            window(200, layer: 3, CGRect(x: 0, y: 0, width: 283, height: 70)),  // the "signed in" pop-up
            window(100, layer: 25, CGRect(x: 0, y: 0, width: 30, height: 24)),  // the menu bar extra
            window(200, alpha: 0, CGRect(x: 0, y: 0, width: 700, height: 440)),  // fully transparent
            window(999, CGRect(x: 0, y: 0, width: 800, height: 600)),  // another app's
        ]
        #expect(WindowList.steamWindows(in: windows, owners: [100, 200]) == [
            SteamWindow(processIdentifier: 200, layer: 0, width: 1280, height: 800),
            SteamWindow(processIdentifier: 200, layer: 3, width: 283, height: 70),
        ])
    }

    @Test func bundleIdentifiers() {
        #expect(SteamAppProcess.kind(ofBundle: "com.valvesoftware.steam") == .app)
        #expect(SteamAppProcess.kind(ofBundle: "com.valvesoftware.steam.helper") == .helper)
        #expect(SteamAppProcess.kind(ofBundle: "com.valvesoftware.steamlink") == nil)
        #expect(SteamAppProcess.kind(ofBundle: nil) == nil)
    }
}
