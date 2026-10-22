import Foundation
import GameKit
import Testing
import WarzagCore
import WarzagTestSupport
@testable import WarzagApp

/// Hide Warzag while playing: once the game's first minute in front is over, Warzag leaves the Dock (the game's host
/// shows there as Warzag already), and it comes back with its window when the session ends, however it ends, or as soon
/// as the player opens it again. Through the fakes only: no NSApp.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HideWhilePlayingTests {
    let fixture = AppFixture()

    /// The game's window appeared and was brought to the front, then its first minute in front ended.
    static let firstMinute: [GameFocusEvent] = [
        .windowAppeared(processIdentifier: 42, broughtForward: true, front: nil), .finished(returns: 0),
    ]

    /// A ready Mac, Play pressed, the game running until it is told to end; the focus keeper reports `focus`.
    private func startSession(_ fixture: AppFixture, focus: [GameFocusEvent] = firstMinute,
                              before: (AppModel) -> Void = { _ in }) async throws -> AppModel {
        try fixture.saveReadyState()
        fixture.game.set { $0.holdPlayUntilQuit = true }
        fixture.system.set { $0.focusEvents = focus }
        let model = fixture.makeModel()
        await model.launch()
        before(model)
        model.playGame()
        #expect(await eventually { if case .running = model.play { true } else { false } })
        #expect(await eventually { fixture.system.calls.contains("keepGameInFront(42)") })
        return model
    }

    @Test func warzagLeavesTheDockAfterTheGamesFirstMinuteAndComesBackWhenItEnds() async throws {
        let model = try await startSession(fixture)
        #expect(await eventually { model.hiddenWhilePlaying })
        #expect(fixture.system.dock == [.hidden])
        #expect(fixture.system.mainWindowShown == 0)

        model.quitGame()
        #expect(await eventually { model.play == .idle })
        #expect(fixture.system.dock == [.hidden, .shown])
        #expect(fixture.system.mainWindowShown == 1)
        #expect(!model.hiddenWhilePlaying)
    }

    /// The Steam take-back of the first minute activates Warzag itself and hands the front on (GameFocusKeeper,
    /// WorkspaceFocusEnvironment): Warzag stays a regular app until that minute is over, and never hides for a game
    /// whose window did not appear.
    @Test func theFirstMinuteRunsWithWarzagInTheDock() async throws {
        let appeared = try await startSession(fixture, focus: [Self.firstMinute[0], .steamTookFront(count: 1)])
        #expect(await eventually { appeared.lastFocusEvent == .steamTookFront(count: 1) })
        appeared.appResignedActive()
        #expect(!appeared.focusWatchOver)
        #expect(fixture.system.dock.isEmpty)
        appeared.quitGame()
        #expect(await eventually { appeared.play == .idle })
        #expect(fixture.system.dock.isEmpty)
        #expect(fixture.system.mainWindowShown == 0, "nothing to bring back")

        let noWindow = AppFixture()
        let model = try await startSession(noWindow, focus: [])
        try await Task.sleep(for: .milliseconds(50))
        model.appResignedActive()
        #expect(noWindow.system.dock.isEmpty)
        model.quitGame()
        #expect(await eventually { model.play == .idle })
        #expect(noWindow.system.dock.isEmpty)
    }

    enum Ending: String, CaseIterable, Sendable {
        case quit, forceQuit, gameExited, playFailed, playCancelled
    }

    @Test(arguments: Ending.allCases)
    func everyWayTheSessionEndsBringsWarzagBack(_ ending: Ending) async throws {
        let fixture = AppFixture()
        let model = try await startSession(fixture)
        fixture.game.set {
            switch ending {
            case .gameExited, .playFailed, .playCancelled:
                // The game ends without Warzag being asked: an exit from its own menu, a crash, a broken-off session.
                $0.holdPlayUntilQuit = false
                $0.holdPlayAfterUpdates = true
                $0.errorAfterUpdates = ending == .playFailed ? PlayFailure.other("the session broke off")
                    : ending == .playCancelled ? CancellationError() : nil
            case .quit, .forceQuit: break
            }
        }
        #expect(await eventually { model.hiddenWhilePlaying })
        switch ending {
        case .quit: model.quitGame()
        case .forceQuit: model.forceQuitGame()
        case .gameExited, .playFailed, .playCancelled: fixture.game.set { $0.holdPlayAfterUpdates = false }
        }
        #expect(await eventually { model.play == .idle })
        #expect(fixture.system.dock == [.hidden, .shown])
        #expect(fixture.system.mainWindowShown == 1)
        #expect(!model.hiddenWhilePlaying)
        #expect((model.lastSession?.failure != nil) == [.playFailed, .playCancelled].contains(ending))
    }

    @Test func openingWarzagAgainWhileItHidesBringsItBackAtOnce() async throws {
        let model = try await startSession(fixture)
        #expect(await eventually { model.hiddenWhilePlaying })
        // Finder, Spotlight or `open`: AppKit's reopen event. Handled here, so AppKit does nothing more.
        #expect(!model.reopened())
        #expect(fixture.system.dock == [.hidden, .shown])
        #expect(fixture.system.mainWindowShown == 1)
        #expect(!model.hiddenWhilePlaying)
        // macOS's activation notification may come after it: nothing more to do.
        model.appBecameActive()
        #expect(fixture.system.dock == [.hidden, .shown])

        // Back to the game (Return to Game hands it the front): Warzag leaves the Dock again.
        model.returnToGame()
        model.appResignedActive()
        #expect(fixture.system.dock == [.hidden, .shown, .hidden])
        model.quitGame()
        #expect(await eventually { model.play == .idle })
        #expect(fixture.system.dock == [.hidden, .shown, .hidden, .shown])

        // Outside a game, reopening is left to AppKit.
        #expect(model.reopened())
        #expect(fixture.system.dock.count == 4)
    }

    /// Reopening Warzag while it is still in the Dock (the game's first minute, or the setting off) is left to AppKit,
    /// as outside a game. It still counts as the player using Warzag: the end of the first minute, coming before
    /// macOS's activation notice, does not hide Warzag under them.
    @Test func reopeningWarzagWhileItIsInTheDockIsAppKitsOwn() async throws {
        let model = try await startSession(fixture, focus: [Self.firstMinute[0]])
        #expect(await eventually { model.lastFocusEvent == Self.firstMinute[0] })
        #expect(model.reopened())
        #expect(fixture.system.dock.isEmpty)
        #expect(fixture.system.mainWindowShown == 0)
        fixture.system.set { $0.laterFocusEvents = [Self.firstMinute[1]] }
        #expect(await eventually { model.focusWatchOver })
        #expect(fixture.system.dock.isEmpty, "the player is opening Warzag")
        // Back to the game: now Warzag leaves the Dock.
        model.appResignedActive()
        #expect(fixture.system.dock == [.hidden])
        model.quitGame()
        #expect(await eventually { model.play == .idle })
        #expect(fixture.system.dock == [.hidden, .shown])

        var settings = AppSettings()
        settings.hideWhilePlaying = false
        let settingOff = AppFixture(settings: settings)
        let shown = try await startSession(settingOff)
        #expect(await eventually { shown.focusWatchOver })
        shown.appResignedActive()
        #expect(shown.reopened())
        #expect(settingOff.system.dock.isEmpty)
        #expect(settingOff.system.mainWindowShown == 0)
        shown.quitGame()
        #expect(await eventually { shown.play == .idle })
        #expect(settingOff.system.mainWindowShown == 0, "it never left")
    }

    @Test func clickingOneOfWarzagsWindowsBringsItBackToTheDock() async throws {
        let model = try await startSession(fixture)
        #expect(await eventually { model.hiddenWhilePlaying })
        model.appBecameActive()
        #expect(fixture.system.dock == [.hidden, .shown])
        #expect(fixture.system.mainWindowShown == 0, "the window the player clicked is in front already")
        model.appResignedActive()
        #expect(fixture.system.dock == [.hidden, .shown, .hidden])
        model.quitGame()
        #expect(await eventually { model.play == .idle })
    }

    @Test func warzagStaysWhileThePlayerUsesIt() async throws {
        // The player is in Warzag when the game's first minute ends.
        let model = try await startSession(fixture) { $0.appBecameActive() }
        #expect(await eventually { model.focusWatchOver })
        #expect(fixture.system.dock.isEmpty)
        // They go back to the game: now Warzag leaves the Dock.
        model.appResignedActive()
        #expect(fixture.system.dock == [.hidden])
        model.quitGame()
        #expect(await eventually { model.play == .idle })
        #expect(fixture.system.dock == [.hidden, .shown])
    }

    @Test func withTheSettingOffWarzagStaysInTheDock() async throws {
        var settings = AppSettings()
        settings.hideWhilePlaying = false
        let fixture = AppFixture(settings: settings)
        let model = try await startSession(fixture)
        #expect(await eventually { model.focusWatchOver })
        model.appResignedActive()
        #expect(fixture.system.dock.isEmpty)

        // Turned on in Settings during the game (Warzag in front), it applies once the player is back in the game.
        model.appBecameActive()
        model.setHideWhilePlaying(true)
        #expect(fixture.system.dock.isEmpty)
        #expect(AppSettingsStore(paths: fixture.paths, fileSystem: fixture.fileSystem).load().hideWhilePlaying)
        #expect(fixture.settings.settings.hideWhilePlaying)
        model.appResignedActive()
        #expect(fixture.system.dock == [.hidden])

        // Turned off again, Warzag comes back at once, window and all.
        model.setHideWhilePlaying(false)
        #expect(fixture.system.dock == [.hidden, .shown])
        #expect(fixture.system.mainWindowShown == 1)
        #expect(!AppSettingsStore(paths: fixture.paths, fileSystem: fixture.fileSystem).load().hideWhilePlaying)
        model.quitGame()
        #expect(await eventually { model.play == .idle })
        #expect(fixture.system.dock == [.hidden, .shown])
    }

    /// Each session watches its own first minute: what the last one reported does not hide Warzag in the next.
    @Test func aNewSessionStartsWithWarzagInTheDock() async throws {
        let model = try await startSession(fixture)
        #expect(await eventually { model.hiddenWhilePlaying })
        model.quitGame()
        #expect(await eventually { model.play == .idle })

        fixture.game.set { $0.quitRequested = false }
        fixture.system.set { $0.focusEvents = [Self.firstMinute[0]] }
        model.playGame()
        #expect(await eventually { if case .running = model.play { true } else { false } })
        #expect(await eventually { model.lastFocusEvent == Self.firstMinute[0] })
        model.appResignedActive()
        #expect(!model.focusWatchOver)
        #expect(fixture.system.dock == [.hidden, .shown])
        model.quitGame()
        #expect(await eventually { model.play == .idle })
    }
}
