import EngineKit
import Foundation
import GameKit
import Testing
import WarzagCore
import WarzagTestSupport
@testable import WarzagApp

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AppModelTests {
    let fixture = AppFixture()

    private func startedModel() async -> AppModel {
        let model = fixture.makeModel()
        await model.launch()
        return model
    }

    // MARK: First run

    @Test func aFreshMacOnlyChecksItselfBehindWelcomeThenReachesHome() async throws {
        let fixture = AppFixture(welcomed: false)
        fixture.engine.useDevelopmentEngine(.n)
        let model = fixture.makeModel()
        #expect(model.screen == .welcome)
        await model.launch()
        #expect(model.screen == .welcome)
        // The read-only checks run (and setup.json exists); nothing is downloaded, registered or started.
        #expect(await eventually { fixture.store.load()?.preflight.status == .done })
        #expect(fixture.engine.calls.isEmpty)
        #expect(fixture.steam.calls.isEmpty)
        #expect(fixture.game.calls.isEmpty)
        #expect(model.screen == .welcome)

        model.getStarted()
        #expect(AppSettingsStore(paths: fixture.paths, fileSystem: fixture.fileSystem).load().welcomed)
        #expect(await eventually { model.screen == .home })
        #expect(fixture.store.load()?.isReadyToPlay == true)
        #expect(fixture.engine.calls == ["register", "setUpPrefix", "probe"])
        #expect(fixture.game.calls == ["downloadInstaller", "extractInstaller", "seedProfile", "pinDirectX11",
                                       "waitForEULA", "downloadContent"])
        #expect(model.activities.isEmpty)
    }

    @Test func aBuildWithAFeedGetsItsEngineFromTheReleasePage() async throws {
        fixture.engine.set { $0.feed = FakeEngine.feedURL }
        let model = await startedModel()
        #expect(await eventually { model.screen == .home })
        #expect(fixture.engine.calls == ["fetch", "download", "verify", "activate", "setUpPrefix", "probe"])
        #expect(fixture.engine.activeRuntime()?.id == "n-0.3.0")
    }

    @Test func setupResumesTheInterruptedStepAfterARestart() async throws {
        var state = SetupState()
        for track in [SetupTrack.preflight, .engine, .steam] {
            state[track] = TrackState(step: track.steps.last!, status: .done)
        }
        state.game = TrackState(step: .downloadContent, status: .running)
        try fixture.store.save(state)
        fixture.engine.set { $0.active = FakeEngine.runtime(.n) }
        fixture.game.set {
            $0.launcherExtracted = true
            $0.eulaAccepted = true
        }

        let model = fixture.makeModel()
        #expect(model.screen == .setup)
        await model.launch()
        #expect(await eventually { model.screen == .home })
        #expect(fixture.game.calls == ["downloadContent"])
        #expect(fixture.engine.calls.isEmpty)
    }

    @Test func quittingBeforeGetStartedShowsWelcomeAgainNextTime() async throws {
        let fixture = AppFixture(welcomed: false)
        let first = fixture.makeModel()
        await first.launch()
        #expect(await eventually { fixture.store.load()?.preflight.status == .done })
        await first.shutdown()
        let second = fixture.makeModel()
        #expect(second.screen == .welcome)
        await second.launch()
        #expect(fixture.engine.calls.isEmpty)
    }

    @Test func aSetupThatGotFurtherCountsAsStartedEvenWithoutTheSetting() throws {
        let fixture = AppFixture(welcomed: false)
        var state = SetupState()
        state.preflight = TrackState(step: .checkNetwork, status: .done)
        state.engine = TrackState(step: .createPrefix, status: .running)
        try fixture.store.save(state)
        let model = fixture.makeModel()
        #expect(model.welcomed)
        #expect(model.screen == .setup)
        #expect(model.startGate.isOpen)
    }

    @Test func aSteamTrackSkippedFromSettingsBeforeGetStartedIsNotProgress() async throws {
        let fixture = AppFixture(welcomed: false)
        fixture.engine.useDevelopmentEngine(.n)
        let first = fixture.makeModel()
        await first.launch()
        // Settings (⌘,) works behind the Welcome screen too.
        first.setLoginMode(.warframeAccount)
        #expect(await eventually { fixture.store.load()?.steam.status == .skipped })
        await first.shutdown()

        let second = fixture.makeModel()
        #expect(!second.welcomed)
        #expect(second.screen == .welcome)
        #expect(!second.startGate.isOpen)
        await second.launch()
        #expect(await eventually { fixture.store.load()?.preflight.status == .done })
        #expect(fixture.engine.calls.isEmpty)
    }

    @Test func theWelcomeScreenDoesNotKeepTheMacAwake() async {
        let fixture = AppFixture(welcomed: false)
        fixture.engine.useDevelopmentEngine(.n)
        fixture.game.set { $0.holdDownload = true }
        let model = fixture.makeModel()
        await model.launch()
        // The engine, Steam and game tracks wait at the start gate, which setup.json records as running.
        #expect(await eventually {
            [SetupTrack.engine, .steam, .game].allSatisfy { model.setup[$0].status == .running }
        })
        await model.tick()
        #expect(!fixture.system.keptAwake.contains(.setup))
        model.getStarted()
        #expect(await eventually { fixture.system.keptAwake.last == .setup })
        fixture.game.set { $0.holdDownload = false }
        #expect(await eventually { model.screen == .home })
    }

    @Test func aReadyMacOpensOnHomeAndDoesNotRunSetupAgain() async throws {
        try fixture.saveReadyState()
        let model = fixture.makeModel()
        #expect(model.screen == .home)
        await model.launch()
        #expect(await eventually { model.content?.state == .installed })
        #expect(fixture.game.calls.isEmpty)
        #expect(model.runtime?.channel == .n)
    }

    // MARK: The player's part

    @Test func signInCardShowsUntilSteamSaysSignedInThenSetupContinues() async {
        fixture.engine.useDevelopmentEngine(.n)
        fixture.steam.set { $0.signedIn = false }
        let model = await startedModel()
        #expect(await eventually { model.attentionItems.contains(.action(.steam, .signInToSteam)) })
        #expect(model.trackStatus(.steam) == .needsYou)
        #expect(model.stepStatus(.waitForSignIn) == .needsYou)
        #expect(model.stepStatus(.installSteam) == .done)
        #expect(await eventually { fixture.system.badges.last == "!" })
        #expect(fixture.system.calls.contains("requestAttention"))

        await model.tick()
        #expect(model.setup.steam.status == .waitingForUser)
        fixture.steam.set { $0.signedIn = true }
        await model.tick()
        #expect(await eventually { model.screen == .home })
        #expect(model.attentionItems.isEmpty)
        #expect(fixture.system.badges.last == .some(nil))
    }

    /// The probe says nobody is logged on while Steam's own log says someone is (offline mode, still connecting): no
    /// sign-in card that the heartbeat would dismiss at once, so the probe runs a bounded number of times.
    @Test func aProbeThatDisagreesWithSteamsOwnLogRetriesInsteadOfLooping() async {
        fixture.engine.useDevelopmentEngine(.n)
        fixture.engine.set { $0.probe = .signedOut }
        let model = await startedModel()
        #expect(await eventually {
            model.setup.steam.status == .failed && SetupMachine.automaticRetryDelay(for: model.setup.steam) == nil
        })
        for _ in 0..<3 { await model.tick() }
        await model.waitUntilSetupIsIdle()
        #expect(fixture.engine.calls.filter { $0 == "probe" }.count == 1 + SetupMachine.automaticRetryLimit)
        #expect(model.setup.steam.failure == SetupFailure(.transient, L10n.failureSteamOffline))
        #expect(!model.attentionItems.contains(.action(.steam, .signInToSteam)))
    }

    @Test func steamIsInstalledAfterTheCardIsAnswered() async {
        fixture.engine.useDevelopmentEngine(.n)
        fixture.steam.set {
            $0.installed = false
            $0.running = false
        }
        let model = await startedModel()
        #expect(await eventually { model.attentionItems.contains(.action(.steam, .installSteam)) })
        #expect(fixture.steam.calls.isEmpty)
        model.respond(.installSteam)
        #expect(await eventually { model.screen == .home })
        #expect(fixture.steam.calls == ["install", "start"])
        #expect(model.setup.approvals == [.installSteam])
    }

    @Test func aWarframeAccountSkipsSteamEntirely() async {
        fixture.engine.useDevelopmentEngine(.n)
        fixture.steam.set {
            $0.installed = false
            $0.running = false
        }
        let model = await startedModel()
        #expect(await eventually { model.attentionItems.contains(.action(.steam, .installSteam)) })
        model.setLoginMode(.warframeAccount)
        #expect(await eventually { model.screen == .home })
        #expect(model.setup.steam.status == .skipped)
        #expect(model.trackStatus(.steam) == .skipped)
        #expect(!fixture.engine.calls.contains("probe"))
    }

    @Test func theEULACardShowsWhileDEsWindowWaits() async {
        fixture.engine.useDevelopmentEngine(.n)
        fixture.game.set { $0.eulaOutcome = .declined }
        let model = await startedModel()
        #expect(await eventually { model.attentionItems.contains(.action(.game, .acceptEULA)) })
        fixture.game.set { $0.eulaOutcome = .accepted }
        model.respond(.acceptEULA)
        #expect(await eventually { model.screen == .home })
        #expect(fixture.game.calls.filter { $0 == "waitForEULA" }.count == 2)
    }

    @Test func liveDownloadProgressCarriesRealNumbers() async throws {
        fixture.engine.useDevelopmentEngine(.n)
        fixture.game.set {
            $0.holdDownload = true
            $0.downloadProgress = [.downloading(bytesThisRun: 23_400_000_000, bytesOnDisk: 23_400_000_000, expectedBytes: 55_700_000_000,
                                                megabytesPerSecond: 47)]
        }
        let model = await startedModel()
        #expect(await eventually { model.activities[.game]?.progress?.completed == 23_400_000_000 })
        let activity = try #require(model.activities[.game])
        #expect(activity.detail == .downloadingGame)
        #expect(model.stepStatus(.downloadContent) == .active)
        let progress = try #require(activity.progress)
        #expect(progress.bytesPerSecond == 47_000_000)
        let remaining = try #require(progress.secondsRemaining)
        #expect(abs(remaining - 32_300_000_000 / 47_000_000.0) < 1)
        #expect(await eventually { fixture.system.badges.last == "42%" })
        #expect(await eventually { fixture.system.keptAwake.last == .setup })
        fixture.game.set { $0.holdDownload = false }
        #expect(await eventually { model.screen == .home })
        #expect(await eventually { fixture.system.keptAwake.last == .some(nil) })
    }

    // MARK: Failures and retry

    @Test func aFailingStepRetriesThenWaitsForTryAgain() async {
        fixture.engine.useDevelopmentEngine(.n)
        fixture.engine.set { $0.prefixError = PrefixError.bootFailed(log: "/home/Library/Logs/Warzag/prefix-n.log") }
        let model = await startedModel()
        // Three automatic retries (ManualClock: no real waiting), then the card.
        #expect(await eventually { model.setup.engine.status == .failed && model.setup.engine.attempts == 4 })
        await model.waitUntilSetupIsIdle()
        #expect(model.failedTracks == [.engine])
        #expect(model.setup.engine.failure == SetupFailure(.transient, L10n.failurePrefix))
        #expect(SetupMachine.automaticRetryDelay(for: model.setup.engine) == nil)
        #expect(fixture.engine.calls.filter { $0 == "setUpPrefix" }.count == 4)

        fixture.engine.set { $0.prefixError = nil }
        model.retry(.engine)
        #expect(await eventually { model.screen == .home })
    }

    @Test func noEngineIsAPermanentFailureWithoutRetries() async {
        let model = await startedModel()
        #expect(await eventually { model.setup.engine.status == .failed })
        #expect(model.setup.engine.step == .fetchManifest)
        #expect(model.setup.engine.failure == SetupFailure(.permanent, L10n.failureNoEngine))
        #expect(model.setup.engine.attempts == 1)
        // The download of DE's installer goes ahead without the engine; the rest waits for it.
        #expect(await eventually { model.setup.game.step == .extractGame })
        #expect(model.setup.game.status == .pending)
    }

    @Test func choosingADevelopmentEngineRestartsTheEngineTrack() async {
        let model = await startedModel()
        #expect(await eventually { model.setup.engine.status == .failed })
        let chosen = URL(filePath: "/build/n/Warzag.app", directoryHint: .isDirectory)
        fixture.engine.useDevelopmentEngine(.n)
        model.revealDeveloperSettings()
        await model.setDevelopmentRuntime(chosen)
        #expect(model.settings.developmentRuntimePath == chosen.plainPath)
        #expect(AppSettingsStore(paths: fixture.paths, fileSystem: fixture.fileSystem).load().developmentRuntimePath
            == chosen.plainPath)
        #expect(await eventually { model.screen == .home })
    }

    /// Choose Engine… and Settings' development engine register a bundle without the checks runtime packs get, so a
    /// player never sees them: only a run with WARZAG_DEV_RUNTIME or the Option-click reveal does.
    @Test func theDevelopmentEngineChoiceIsForDevelopersOnly() async {
        let build = URL(filePath: "/build/n/Warzag.app", directoryHint: .isDirectory)
        #expect(!AppModel.showsDevelopmentEngineChoice(launchDevelopmentRuntime: nil, revealed: false))
        #expect(AppModel.showsDevelopmentEngineChoice(launchDevelopmentRuntime: build, revealed: false))
        #expect(AppModel.showsDevelopmentEngineChoice(launchDevelopmentRuntime: nil, revealed: true))

        let model = await startedModel()
        #expect(await eventually { model.setup.engine.status == .failed })
        #expect(!model.showsDevelopmentEngineChoice)
        // The failure card does not ask the player to choose one.
        #expect(model.setup.engine.failure?.message == L10n.failureNoEngine)
        #expect(!L10n.failureNoEngine.contains("Choose"))
        // Nor does the model take a bundle without the reveal.
        await model.setDevelopmentRuntime(URL(filePath: "/Users/tenno/Downloads/Other.app", directoryHint: .isDirectory))
        #expect(model.settings.developmentRuntimePath == nil)
        #expect(AppSettingsStore(paths: fixture.paths, fileSystem: fixture.fileSystem).load().developmentRuntimePath == nil)

        model.revealDeveloperSettings()
        #expect(model.developerSettingsRevealed && model.showsDevelopmentEngineChoice)
    }

    @Test func aRunWithADevelopmentEngineShowsTheChoice() {
        fixture.options = LaunchOptions(home: URL(filePath: "/home", directoryHint: .isDirectory),
                                        developmentRuntime: URL(filePath: "/build/n/Warzag.app", directoryHint: .isDirectory))
        let model = fixture.makeModel()
        #expect(model.showsDevelopmentEngineChoice)
        #expect(!model.developerSettingsRevealed)
    }

    // MARK: Home

    @Test func homeShowsWarframesVersionOnceTheGameIsKnown() async throws {
        try fixture.saveReadyState()
        fixture.game.set { $0.holdContentStatus = true }
        let model = fixture.makeModel()
        await model.launch()
        #expect(model.screen == .home)
        // The game's state is still being read: no claim yet.
        #expect(model.homeStatus == L10n.homeChecking)
        fixture.game.set { $0.holdContentStatus = false }
        #expect(await eventually { model.homeStatus == L10n.homeWarframeVersion("2026.10.15.13.08") })

        // A read that finds nothing (no engine, an unreadable prefix) claims nothing either.
        fixture.game.set { $0.content = nil }
        model.refreshHome()
        #expect(await eventually { !model.checkingContent })
        #expect(model.homeStatus == nil)

        // An update due changes nothing on Home: Play installs it.
        fixture.game.set {
            $0.content = ContentSummary(state: .needsUpdate, lastUpdate: nil, libraryBytes: nil, build: "2026.10.15.13.08")
        }
        model.refreshHome()
        #expect(await eventually { model.homeStatus == L10n.homeWarframeVersion("2026.10.15.13.08") })
        // Before Warframe's first start there is no version to show.
        fixture.game.set { $0.content = ContentSummary(state: .installed, lastUpdate: nil, libraryBytes: nil) }
        model.refreshHome()
        #expect(await eventually { !model.checkingContent && model.homeStatus == nil })
        fixture.game.set { $0.content = ContentSummary(state: .notInstalled, lastUpdate: nil, libraryBytes: nil) }
        model.refreshHome()
        #expect(await eventually { model.homeStatus == L10n.homeNotInstalled })
    }

    // MARK: Play

    @Test func playRunsASessionAndComesBackHome() async throws {
        try fixture.saveReadyState()
        fixture.game.set {
            $0.holdPlayUntilQuit = true
            $0.playUpdates = [.game(.updating(.preprocessing(fraction: 0.5))), .game(.opening),
                              .game(.started(processIdentifier: 42)), .game(.signal(.steamActive))]
        }
        let model = fixture.makeModel()
        await model.launch()
        #expect(model.canPlay)
        model.playGame()
        #expect(!model.canPlay)
        #expect(await eventually { model.screen == .playing })
        #expect(await eventually {
            if case .running(let session) = model.play { session.signals == [.steamActive] } else { false }
        })
        guard case .running(let session) = model.play else { Issue.record("not running"); return }
        #expect(session.processIdentifier == 42)
        #expect(await eventually { fixture.system.keptAwake.last == .playing })
        // The game's window is kept in front from the moment LaunchServices opened the shim (pid 42).
        #expect(await eventually { fixture.system.calls.contains("keepGameInFront(42)") })
        #expect(!fixture.system.calls.contains("keepGameInFront ended"))

        // Return to Game looks for the game's window and never activates the shim Play opened.
        model.returnToGame()
        #expect(fixture.system.calls.contains("showGameHost(42)"))
        model.quitGame()
        #expect(!model.canForceQuit(at: fixture.clock.now))
        #expect(model.canForceQuit(at: fixture.clock.now.addingTimeInterval(11)))
        #expect(await eventually { model.screen == .home && model.play == .idle })
        #expect(fixture.game.calls.contains("play(steam,balanced)"))
        #expect(fixture.game.calls.contains("quitGame"))
        #expect(model.lastSession == SessionResult(seconds: 600, problems: [], failure: nil))
        #expect(fixture.system.keptAwake.last == .some(nil))
        // The session is over, and with it the guard of the game's window.
        #expect(await eventually { fixture.system.calls.contains("keepGameInFront ended") })
    }

    @Test func showTheWindowLooksForDEsWindowAmongTheHostsProcesses() async throws {
        let model = fixture.makeModel()
        model.showDEWindow()
        #expect(fixture.system.calls == ["showGameHost(nil)"])
    }

    @Test func theGameInFrontGuardIsLoggedWithoutTheOtherAppsName() {
        #expect(AppModel.describe(.windowAppeared(processIdentifier: 7, broughtForward: true, front: nil))
            == "Warframe's window appeared; brought it to the front")
        #expect(AppModel.describe(.windowAppeared(processIdentifier: 7, broughtForward: false, front: nil))
            == "Warframe's window appeared in front")
        let elsewhere = AppModel.describe(.windowAppeared(processIdentifier: 7, broughtForward: false,
                                                          front: "com.example.browser"))
        #expect(elsewhere == "Warframe's window appeared while the player was in another app; left there")
        #expect(AppModel.describe(.steamTookFront(count: 2)) == "Steam took the front; brought Warframe back (2 of 3)")
        #expect(AppModel.describe(.finished(returns: 1))
            == "kept Warframe in front for its first minute (brought back from Steam: 1)")
    }

    /// DE's launcher stopping at its EULA during the update before Play: Home says so, more softly when the EULA is
    /// only guessed (the launcher went quiet at its start).
    @Test(arguments: [(ContentRunState.needsEULA, false), (ContentRunState.mayNeedEULA, true)])
    func anUpdateWaitingAtDEsEULASaysHowSureItIs(state: ContentRunState, guessed: Bool) async throws {
        try fixture.saveReadyState()
        fixture.game.set {
            $0.playUpdates = [.game(.updating(state))]
            $0.holdPlayAfterUpdates = true
        }
        let model = fixture.makeModel()
        await model.launch()
        model.playGame()
        #expect(await eventually { model.play == .needsEULA(guessed: guessed) })
        #expect(model.play.isBeforeLaunch)
        await model.shutdown()
        #expect(await eventually { model.play == .idle })
    }

    @Test func aPlayThatCannotStartSaysWhyOnHome() async throws {
        try fixture.saveReadyState()
        fixture.game.set { $0.playFailure = .steamNotSignedIn }
        let model = fixture.makeModel()
        await model.launch()
        model.playGame()
        #expect(await eventually { model.play == .idle && model.lastSession != nil })
        #expect(model.lastSession?.failure == L10n.playFailureSteam)
        #expect(model.screen == .home)
        model.dismissSessionResult()
        #expect(model.lastSession == nil)
    }

    @Test func aWarframeAccountPlaysWithoutSteamAndThePresetChosen() async throws {
        try fixture.saveReadyState(loginMode: .warframeAccount)
        let model = fixture.makeModel()
        await model.launch()
        model.setGraphics(.quality)
        model.playGame()
        #expect(await eventually { model.play == .idle && model.lastSession != nil })
        #expect(fixture.game.calls.contains("play(account,quality)"))
    }

    /// A game that hung while closing, ended by GameKit: the Playing screen says Warframe is closing meanwhile, the end
    /// is one line in Warzag.log, and Home shows no banner, as for any session that ends normally.
    @Test func aGameEndedAfterHangingWhileClosingIsOneLogLineAndNoBanner() async throws {
        let logs = try temporaryDirectory("hung-at-exit")
        defer { try? FileManager.default.removeItem(at: logs) }
        fixture.log = AppLog(directory: logs)
        try fixture.saveReadyState()
        fixture.game.set {
            $0.holdPlayAfterUpdates = true
            $0.playUpdates = [.game(.opening), .game(.started(processIdentifier: 42)), .game(.signal(.loggedIn)),
                              .game(.signal(.closing)), .game(.hungAtExit(seconds: 30))]
        }
        let model = await startedModel()
        model.playGame()
        #expect(await eventually {
            if case .running(let session) = model.play { session.signals == [.loggedIn, .closing] } else { false }
        })
        #expect(L10n.signal(.closing) == "Warframe is closing…")
        fixture.game.set { $0.holdPlayAfterUpdates = false }
        #expect(await eventually { model.play == .idle && model.lastSession != nil })
        #expect(model.lastSession == SessionResult(seconds: 600, problems: [], failure: nil))
        let log = try String(contentsOf: logs.appending(path: AppLog.fileName), encoding: .utf8)
        let lines = log.split(separator: "\n").filter { $0.contains("stopped responding") }
        #expect(lines.count == 1)
        #expect(lines.first?.hasSuffix(" play: Warframe stopped responding while closing; Warzag is ending it "
            + "(wineserver -k, 30 s after it began closing)") == true)
    }

    /// Warframe handing over to DE's launcher while it closes (an update or a restart): one line in Warzag.log, the
    /// session goes on, and it ends without a banner.
    @Test func aHandOverToDEsLauncherWhileClosingIsOneLogLine() async throws {
        let logs = try temporaryDirectory("handed-over")
        defer { try? FileManager.default.removeItem(at: logs) }
        fixture.log = AppLog(directory: logs)
        try fixture.saveReadyState()
        fixture.game.set {
            $0.holdPlayAfterUpdates = true
            $0.playUpdates = [.game(.opening), .game(.started(processIdentifier: 42)), .game(.signal(.loggedIn)),
                              .game(.signal(.closing)), .game(.handedOverToLauncher)]
        }
        let model = await startedModel()
        model.playGame()
        #expect(await eventually {
            if case .running(let session) = model.play { session.signals == [.loggedIn, .closing] } else { false }
        })
        fixture.game.set { $0.holdPlayAfterUpdates = false }
        #expect(await eventually { model.play == .idle && model.lastSession != nil })
        #expect(model.lastSession == SessionResult(seconds: 600, problems: [], failure: nil))
        let log = try String(contentsOf: logs.appending(path: AppLog.fileName), encoding: .utf8)
        let lines = log.split(separator: "\n").filter { $0.contains("handed over") }
        #expect(lines.count == 1)
        #expect(lines.first?.hasSuffix(" play: Warframe handed over to DE's launcher while closing (an update or a "
            + "restart); Warzag leaves it running") == true)
        #expect(!log.contains("stopped responding"))
    }

    // MARK: Cancellation

    @Test func quittingWarzagStopsSetupAndClosesDEsLauncher() async {
        fixture.engine.useDevelopmentEngine(.n)
        fixture.game.set { $0.holdDownload = true }
        let model = await startedModel()
        #expect(await eventually { fixture.game.calls.contains("downloadContent") })
        await model.shutdown()
        #expect(fixture.game.calls.contains("cancelContentRun"))
        // The cancelled step has ended by the time shutdown returns.
        #expect(fixture.game.calls.contains("downloadContent.cancelled"))
        // setup.json still says the download was in progress, so the next launch resumes it.
        #expect(fixture.store.load()?.game.step == .downloadContent)
    }

    /// Quitting while msiexec /a runs: the step's cleanup (`wineserver -k`, in a task of its own) has run before
    /// shutdown returns, so it is not cut off when Warzag exits.
    @Test func quittingWaitsForACancelledStepsCleanup() async {
        fixture.engine.useDevelopmentEngine(.n)
        fixture.game.set { $0.holdExtract = true }
        let model = await startedModel()
        #expect(await eventually { fixture.game.calls.contains("extractInstaller") })
        await model.shutdown()
        #expect(fixture.game.calls.contains("extractInstaller.cleanedUp"))
        #expect(fixture.store.load()?.game.step == .extractGame)
    }

    /// The download step waits for DE's launcher run, which only `cancelContentRun` ends (as in LiveGameService):
    /// shutdown closes the launcher first, then waits for the step, instead of waiting for a step that cannot end.
    @Test func quittingClosesDEsLauncherBeforeWaitingForTheDownloadStep() async throws {
        fixture.engine.useDevelopmentEngine(.n)
        fixture.game.set { $0.downloadWaitsForTheRun = true }
        let model = await startedModel()
        #expect(await eventually { fixture.game.calls.contains("downloadContent.waitingForTheRun") })
        await model.shutdown()
        let calls = fixture.game.calls
        let closed = try #require(calls.firstIndex(of: "cancelContentRun"))
        let ended = try #require(calls.firstIndex(of: "downloadContent.runEnded"))
        #expect(closed < ended)
    }

    /// DE's launcher updating the game before Play is Warzag's child process, like setup's run: quitting closes it
    /// (GameKit closes the launcher of a cancelled run) instead of leaving it behind unwatched.
    @Test func quittingWarzagWhileDEsLauncherUpdatesTheGameClosesIt() async throws {
        try fixture.saveReadyState()
        fixture.game.set {
            $0.playUpdates = [.game(.updating(.downloading(bytesThisRun: 52_700_000_000, bytesOnDisk: 52_700_000_000, expectedBytes: 55_700_000_000,
                                                           megabytesPerSecond: 40)))]
            $0.holdPlayAfterUpdates = true
        }
        let model = fixture.makeModel()
        await model.launch()
        model.playGame()
        #expect(await eventually { if case .updating = model.play { true } else { false } })
        await model.shutdown()
        #expect(fixture.game.calls.contains("play.cancelled"))
        #expect(await eventually { model.play == .idle })
    }

    @Test func quittingWarzagLeavesARunningGameAlone() async throws {
        try fixture.saveReadyState()
        fixture.game.set { $0.holdPlayUntilQuit = true }
        let model = fixture.makeModel()
        await model.launch()
        model.playGame()
        #expect(await eventually { model.screen == .playing })
        await model.shutdown()
        #expect(!fixture.game.calls.contains("play.cancelled"))
        #expect(model.screen == .playing)
        model.quitGame()
        #expect(await eventually { model.play == .idle })
    }

    // MARK: Troubleshooting

    @Test func doctorAndRepairReportBack() async throws {
        try fixture.saveReadyState()
        let model = fixture.makeModel()
        await model.launch()
        await model.runDoctor()
        guard case .finished(let checks, _) = model.doctor else { Issue.record("no doctor result"); return }
        #expect(checks.map(\.id) == ["storage", "steam", "content", "engine.runtime", "engine.dxmt"])
        #expect(checks.first { $0.id == "engine.dxmt" }?.passed == false)

        await model.repairNow()
        #expect(fixture.engine.calls.contains("repairPrefix"))
        guard case .succeeded = model.repair else { Issue.record("repair did not succeed"); return }

        fixture.engine.set { $0.prefixError = PrefixError.notCreated("/home/Prefixes/warframe-arm64") }
        await model.repairNow()
        #expect(model.repair == .failed(L10n.repairFailed))
    }

    @Test func powerAdviceIsShownBeforePlay() async throws {
        try fixture.saveReadyState()
        fixture.system.set {
            $0.lowPowerMode = true
            $0.battery = true
        }
        let model = fixture.makeModel()
        await model.launch()
        #expect(model.powerAdvice.map(\.kind) == [.lowPowerMode, .battery])
        #expect(GraphicsTuning.sessionFrameRateCap(model.graphics, hardware: model.hardware) == 30)
    }

    /// Warzag cannot switch motion blur off for a player (the game's per-account settings win at startup, and Warzag
    /// never edits them): Home says so while EE.cfg says it is on, and reads it again after a session.
    @Test func homeSaysWhenMotionBlurIsOn() async throws {
        try fixture.saveReadyState()
        fixture.game.set {
            $0.motionBlur = .on
            $0.holdPlayUntilQuit = true
        }
        let model = fixture.makeModel()
        await model.launch()
        #expect(await eventually { model.motionBlur == .on })
        model.playGame()
        #expect(await eventually { if case .running = model.play { true } else { false } })
        // The player turns it off in Warframe; the game writes that back to EE.cfg.
        fixture.game.set { $0.motionBlur = .off }
        model.quitGame()
        #expect(await eventually { model.play == .idle && model.motionBlur == .off })
    }

    @Test func noMotionBlurNoticeWhenEECfgDoesNotSay() async throws {
        try fixture.saveReadyState()
        let model = fixture.makeModel()
        await model.launch()
        #expect(await eventually { model.content != nil })
        #expect(model.motionBlur == .unknown)
    }

    /// GameKit's advice carries its values; the app writes the sentence, so it can be localised.
    @Test func chargerAndBatteryAdviceIsShownBeforePlay() async throws {
        try fixture.saveReadyState()
        fixture.system.set {
            $0.adapterWatts = 8
            $0.batteryPercent = 7
        }
        let model = fixture.makeModel()
        await model.launch()
        #expect(model.powerAdvice == [PowerAdvice(kind: .weakCharger, adapterWatts: 8, recommendedWatts: 30),
                                      PowerAdvice(kind: .lowBattery, batteryPercent: 7)])
        #expect(L10n.power(model.powerAdvice[0]) == L10n.powerWeakCharger(Formatting.watts(8), Formatting.watts(30)))
        #expect(L10n.power(model.powerAdvice[1]) == L10n.powerLowBattery(Formatting.percent(0.07)))
    }

    @Test func milestonesAreReportedOnceEach() async {
        let fixture = AppFixture(welcomed: false)
        fixture.engine.useDevelopmentEngine(.n)
        fixture.steam.set { $0.signedIn = false }
        let model = fixture.makeModel()
        var seen: [String] = []
        model.onMilestone = { seen.append($0) }
        await model.launch()
        model.getStarted()
        #expect(await eventually { seen.contains("needs-you-action-steam-signInToSteam") })
        fixture.steam.set { $0.signedIn = true }
        await model.tick()
        #expect(await eventually { seen.contains("home") })
        #expect(seen.first == "welcome")
        #expect(Set(seen).count == seen.count)
    }
}
