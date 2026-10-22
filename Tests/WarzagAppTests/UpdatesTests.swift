import EngineKit
import Foundation
import GameKit
import RuntimeKit
import Testing
import WarzagCore
import WarzagTestSupport
@testable import WarzagApp

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct UpdatesTests {
    /// Most tests check by hand: the automatic check at launch would race them.
    static var manualChecks: AppSettings {
        var settings = AppSettings()
        settings.checkForUpdatesAutomatically = false
        return settings
    }

    /// The engine setup installed from the release page's feed.
    static let installed = RuntimeSummary(id: "n-0.2.0", version: "0.2.0", channel: .n, development: false,
                                          hostPath: "/home/Runtimes.noindex/n/0.2.0/Warzag.app")

    let fixture = AppFixture(settings: UpdatesTests.manualChecks)

    /// A Mac that finished setup with a signed engine (and the prefix set up for it), on Home; `feed`: the build names
    /// the release page's runtime feed.
    private func home(_ fixture: AppFixture? = nil, feed: Bool = true) async throws -> AppModel {
        let fixture = fixture ?? self.fixture
        try fixture.saveReadyState()
        fixture.engine.set {
            $0.feed = feed ? FakeEngine.feedURL : nil
            $0.active = Self.installed
            $0.prefixRuntime = Self.installed.id
        }
        let model = fixture.makeModel()
        await model.launch()
        #expect(model.screen == .home)
        return model
    }

    private func checked(_ model: AppModel) async -> Bool {
        model.updates.checkForUpdates()
        return await eventually { !model.updates.checking }
    }

    // MARK: Check for Updates

    @Test func aCheckFindsANewerWarzagAndEngineAndDownloadsNothing() async throws {
        fixture.appUpdate.set { $0.check = .success(.available(FakeAppUpdates.offer)) }
        let model = try await home()
        #expect(model.updates.warzag == .unchecked)
        #expect(model.updates.row(.warzag).status == L10n.updatesNotChecked)
        #expect(!model.updates.updateAvailable)

        #expect(await checked(model))
        let offer = fixture.engine.state.withLock { $0.offer }
        #expect(model.updates.warzag == .available(FakeAppUpdates.offer))
        #expect(model.updates.engine == .available(offer))
        #expect(model.updates.updateAvailable, "Home's Updates button shows its badge")
        // Only the feeds were asked: nothing downloaded, installed or started, and the engine's manifest was only
        // read (its revocations wait for an engine update).
        #expect(fixture.appUpdate.calls == ["check"])
        #expect(fixture.engine.calls == ["check"])
        #expect(fixture.game.calls.isEmpty)

        let warzag = model.updates.row(.warzag)
        #expect(warzag.detail == L10n.updatesVersionBuild("0.1.0", "100"))
        #expect(warzag.status == L10n.updatesAvailable("0.2.0", Formatting.bytes(48_000_000)))
        #expect(warzag.tone == .available)
        #expect(warzag.action == .update && warzag.actionEnabled)
        #expect(warzag.releaseNotes == FakeAppUpdates.offer.releaseNotes)
        let engine = model.updates.row(.engine)
        #expect(engine.detail == L10n.updatesVersion("0.2.0"))
        #expect(engine.status == L10n.updatesAvailable("0.3.0", Formatting.bytes(180_000_000)))
        #expect(engine.action == .update)
        // Only DE's launcher knows about Warframe's updates: its row offers to run it.
        let warframe = model.updates.row(.warframe)
        #expect(warframe.status == L10n.updatesWarframeBeforePlay)
        #expect(warframe.action == .updateNow && warframe.actionEnabled)

        // A check that got every answer is remembered: the automatic one waits a day from now.
        #expect(model.settings.lastUpdateCheck == fixture.clock.now)
        #expect(AppSettingsStore(paths: fixture.paths, fileSystem: fixture.fileSystem).load().lastUpdateCheck
            == fixture.clock.now)
    }

    @Test func aBuildWithoutAnUpdateFeedSaysSoAndAnInstalledOfferIsUpToDate() async throws {
        fixture.appUpdate.set { $0.check = .success(.notConfigured) }
        fixture.engine.set { $0.offer.installed = true }
        let model = try await home()
        #expect(await checked(model))
        #expect(model.updates.warzag == .notConfigured)
        #expect(model.updates.row(.warzag).status == L10n.updatesNotConfigured)
        #expect(model.updates.row(.warzag).detail == L10n.updatesVersionBuild("0.1.0", "100"))
        #expect(model.updates.row(.warzag).action == nil)
        #expect(model.updates.engine == .upToDate)
        #expect(model.updates.row(.engine).status == L10n.updatesUpToDate)
        #expect(model.updates.row(.engine).tone == .upToDate)
        #expect(!model.updates.updateAvailable)
    }

    /// The engine row checks the feed only where setup would install from it: never for a build without a feed or a
    /// development engine, nor before setup has installed the engine.
    @Test func theEngineRowSaysWhyItHasNoUpdates() async throws {
        let noFeed = try await home(feed: false)
        #expect(noFeed.updates.engineSource == .noFeed)
        #expect(await checked(noFeed))
        #expect(fixture.engine.calls.isEmpty)
        #expect(noFeed.updates.row(.engine).status == L10n.updatesEngineNoFeed)
        #expect(noFeed.updates.row(.engine).action == nil)

        let development = AppFixture(settings: Self.manualChecks)
        let developmentModel = try await home(development)
        development.engine.useDevelopmentEngine(.n)
        #expect(developmentModel.updates.engineSource == .development)
        #expect(developmentModel.updates.row(.engine).status == L10n.updatesEngineDevelopment)

        let fresh = AppFixture(settings: Self.manualChecks)
        fresh.engine.set { $0.feed = FakeEngine.feedURL }
        fresh.game.set { $0.holdDownload = true }
        let setup = fresh.makeModel()
        await setup.launch()
        #expect(setup.screen == .setup)
        #expect(setup.updates.engineSource == .setup)
        #expect(setup.updates.row(.engine).status == L10n.updatesEngineSetup)
        #expect(setup.updates.row(.warframe).status == L10n.updatesWarframeSetup)
        #expect(setup.updates.row(.warframe).action == nil)
        fresh.game.set { $0.holdDownload = false }
        #expect(await eventually { setup.screen == .home })
    }

    @Test func aFailedCheckIsOneSentenceAndIsNotRemembered() async throws {
        fixture.appUpdate.set { $0.check = .failure(.unreachable("The Internet connection appears to be offline.")) }
        fixture.engine.set { $0.feedErrors["check"] = URLError(.notConnectedToInternet) }
        let model = try await home()
        #expect(await checked(model))
        #expect(model.updates.warzag == .failed(L10n.updatesUnreachable, offer: nil))
        #expect(model.updates.engine == .failed(L10n.updatesUnreachable, offer: nil))
        #expect(model.updates.row(.warzag).tone == .problem)
        #expect(model.updates.row(.warzag).action == nil)
        #expect(model.settings.lastUpdateCheck == nil)

        // An engine that needs a newer Warzag: Updates can install that one first.
        fixture.engine.set { $0.feedErrors["check"] = RuntimeServiceError.manifestRejected(.requiresNewerApp("0.2.0")) }
        #expect(await checked(model))
        #expect(model.updates.engine == .failed(L10n.updatesEngineNeedsNewerWarzag, offer: nil))
    }

    @Test func theSentencesForEachFailure() {
        #expect(UpdateMessages.warzag(AppUpdateError.rejected("digest")) == L10n.updatesWarzagRejected)
        #expect(UpdateMessages.warzag(AppUpdateError.requiresNewerMacOS("26.0")) == L10n.updatesWarzagNeedsMacOS("26.0"))
        #expect(UpdateMessages.warzag(AppUpdateError.cannotReplace("read-only volume")) == L10n.updatesWarzagCannotReplace)
        #expect(UpdateMessages.warzag(AppUpdateError.gameRunning) == L10n.updatesGameRunning)
        #expect(UpdateMessages.warzag(CocoaError(.fileWriteNoPermission)) == L10n.updatesWarzagFailed)
        #expect(UpdateMessages.engine(GameIsRunning(), checking: false) == L10n.updatesGameRunning)
        #expect(UpdateMessages.engine(RuntimeInstallError.blocked("crashes"), checking: false) == L10n.failureEnginePaused)
        #expect(UpdateMessages.engine(URLError(.timedOut), checking: false) == L10n.failureEngineDownload)
        #expect(UpdateMessages.engine(CocoaError(.fileReadCorruptFile), checking: true) == L10n.updatesEngineCheckFailed)
        // A check that fails is never "couldn't be installed"; the feed's refusals read as in setup.
        #expect(UpdateMessages.engine(RuntimeServiceError.unreadableManifest("truncated"), checking: true)
            == L10n.updatesEngineCheckFailed)
        #expect(UpdateMessages.engine(RuntimeServiceError.manifestRejected(.expired(Date(timeIntervalSince1970: 0))),
                                      checking: true) == L10n.failureEngineFeed)
        #expect(UpdateMessages.engine(RuntimeServiceError.manifestRejected(.badSignature), checking: true)
            == L10n.failureEngineRejected)
        #expect(UpdateMessages.warframe(PlayFailure.busy) == L10n.updatesGameRunning)
        #expect(UpdateMessages.warframe(PlayFailure.needsRepair("placeholder")) == L10n.updatesWarframeNeedsRepair)
        #expect(UpdateMessages.warframe(PlayFailure.notInstalled) == L10n.playFailureNotInstalled)
        #expect(UpdateMessages.warframe(PlayFailure.other("launcher")) == L10n.updatesWarframeFailed)
    }

    /// Opening the Updates window checks once when nothing was checked in this run.
    @Test func openingTheWindowChecksOnce() async throws {
        let model = try await home()
        model.updates.windowOpened()
        #expect(await eventually { !model.updates.checking && model.updates.warzag == .upToDate })
        model.updates.windowOpened()
        // A check starts at once (`checking`); the feeds are asked in a task that has not run yet.
        #expect(!model.updates.checking, "a second opening checks nothing")
        #expect(fixture.appUpdate.calls == ["check"])
    }

    // MARK: Warzag

    @Test func warzagsUpdateDownloadsWithProgressInstallsThenQuits() async throws {
        fixture.appUpdate.set {
            $0.check = .success(.available(FakeAppUpdates.offer))
            $0.holdPrepare = true
        }
        let model = try await home()
        #expect(await checked(model))
        model.updates.updateWarzag()
        #expect(model.updates.running == .warzag)
        #expect(await eventually {
            if case .downloading(_, let progress?) = model.updates.warzag { progress.completed == 24_000_000 } else { false }
        })
        let row = model.updates.row(.warzag)
        #expect(row.working)
        #expect(row.status == L10n.updatesDownloadingWarzag("0.2.0"))
        #expect(row.progress?.total == 48_000_000)
        #expect(row.action == nil)
        #expect(!model.canPlay)
        #expect(!model.canRepair)
        #expect(fixture.system.keptAwake.last == .setup)
        // One update at a time.
        #expect(model.updates.blocker(for: .warframe) == .updating(.warzag))
        model.updates.updateWarframe()
        #expect(!fixture.game.calls.contains("updateGame"))

        fixture.appUpdate.set { $0.holdPrepare = false }
        #expect(await eventually { fixture.system.calls.contains("quit") })
        #expect(fixture.appUpdate.calls == ["check", "prepare(0.2.0)", "install"])
        #expect(model.updates.warzag == .installing(FakeAppUpdates.offer))
        #expect(model.updates.row(.warzag).status == L10n.updatesInstallingWarzag)
        // Nothing else may start before Warzag has quit.
        #expect(model.updates.running == .warzag)
        #expect(!model.canPlay)
    }

    /// The player quits while Warzag's update installs: quitting waits for it, the install is not cut short (also when
    /// the quit comes before the row shows it installing), and Warzag does not ask to quit again.
    @Test func quittingWhileWarzagInstallsLetsItFinish() async throws {
        fixture.appUpdate.set {
            $0.check = .success(.available(FakeAppUpdates.offer))
            $0.holdInstall = true
        }
        let model = try await home()
        #expect(await checked(model))
        model.updates.updateWarzag()
        #expect(await eventually { fixture.appUpdate.calls.contains("install") })
        let quit = Flag()
        let quitting = Task {
            await model.shutdown()
            quit.set()
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(!quit.isSet, "quitting waits for the install")
        fixture.appUpdate.set { $0.holdInstall = false }
        await quitting.value
        #expect(fixture.appUpdate.calls == ["check", "prepare(0.2.0)", "install"])
        #expect(model.updates.warzag == .installing(FakeAppUpdates.offer), "the install finished")
        #expect(!fixture.system.calls.contains("quit"))
    }

    /// The player quits while Warzag's download is still being checked (digest, code signature: work that goes on when
    /// cancelled), or just after it: the install never begins, so nothing is half-installed while Warzag quits.
    @Test func quittingBeforeWarzagsInstallBeginsInstallsNothing() async throws {
        fixture.appUpdate.set {
            $0.check = .success(.available(FakeAppUpdates.offer))
            $0.holdChecks = true
        }
        let model = try await home()
        #expect(await checked(model))
        model.updates.updateWarzag()
        #expect(await eventually { fixture.appUpdate.calls == ["check", "prepare(0.2.0)"] })
        let quitting = Task { await model.shutdown() }
        #expect(await eventually { fixture.appUpdate.calls.contains("prepare.cancelled") })
        fixture.appUpdate.set { $0.holdChecks = false }
        await quitting.value
        #expect(fixture.appUpdate.calls == ["check", "prepare(0.2.0)", "prepare.cancelled"])
        #expect(model.updates.running == nil)
        #expect(!fixture.system.calls.contains("quit"))
    }

    @Test func aFailedWarzagUpdateKeepsItsOfferForTryAgain() async throws {
        fixture.appUpdate.set {
            $0.check = .success(.available(FakeAppUpdates.offer))
            $0.prepareError = .rejected("the code signature is not the project certificate's")
        }
        let model = try await home()
        #expect(await checked(model))
        model.updates.updateWarzag()
        #expect(await eventually { model.updates.running == nil })
        #expect(model.updates.warzag == .failed(L10n.updatesWarzagRejected, offer: FakeAppUpdates.offer))
        #expect(model.updates.row(.warzag).action == .update)
        #expect(model.updates.updateAvailable)
        #expect(!fixture.appUpdate.calls.contains("install"))
        #expect(!fixture.system.calls.contains("quit"))
        #expect(model.canPlay)

        fixture.appUpdate.set { $0.prepareError = nil }
        model.updates.updateWarzag()
        #expect(await eventually { fixture.system.calls.contains("quit") })
    }

    /// macOS refused the replace: nothing quits, and the row offers the checked copy in Finder instead of the same
    /// install again.
    @Test func whenWarzagCannotReplaceItselfTheRowShowsTheCheckedCopy() async throws {
        let copy = URL(filePath: "/home/Library/Caches/Warzag/AppUpdate.noindex/staging/Warzag.app")
        fixture.appUpdate.set {
            $0.check = .success(.available(FakeAppUpdates.offer))
            $0.installError = .cannotReplace("the volume is read-only")
            $0.copy = copy
        }
        let model = try await home()
        #expect(await checked(model))
        model.updates.updateWarzag()
        #expect(await eventually { model.updates.running == nil })
        #expect(model.updates.warzag == .failed(L10n.updatesWarzagCannotReplaceCopy, offer: FakeAppUpdates.offer))
        #expect(model.updates.row(.warzag).action == .showCopy)
        #expect(!fixture.system.calls.contains("quit"))
        model.updates.showWarzagCopy()
        #expect(fixture.system.calls.contains("reveal"))

        // Without a kept copy the sentence points to the website, and Update stays.
        fixture.appUpdate.set { $0.copy = nil }
        #expect(await checked(model))
        #expect(model.updates.row(.warzag).action == .update)
        model.updates.updateWarzag()
        #expect(await eventually { model.updates.running == nil })
        #expect(model.updates.warzag == .failed(L10n.updatesWarzagCannotReplace, offer: FakeAppUpdates.offer))
        #expect(model.updates.row(.warzag).action == .update)
    }

    /// An update whose swap failed after Warzag quit (the helper put this Warzag back) is said once at the next launch.
    @Test func anInstallThatFailedAfterQuittingIsReportedAtLaunch() async throws {
        let copy = URL(filePath: "/home/Library/Caches/Warzag/AppUpdate.noindex/staging/Warzag.app")
        fixture.appUpdate.set {
            $0.lastInstall = .cannotReplace("macOS refused the change")
            $0.copy = copy
        }
        let model = try await home()
        #expect(model.updates.warzag == .failed(L10n.updatesWarzagCannotReplaceCopy, offer: nil))
        #expect(model.updates.row(.warzag).action == .showCopy)
        #expect(fixture.appUpdate.lastInstallResult() == nil)
    }

    /// A game an earlier run of Warzag left running (quitting Warzag never ends one): Warzag's download may finish, but
    /// nothing is installed under it, and the engine's update stops before it fetches the manifest again (which may
    /// roll the engine back).
    @Test func nothingInstallsUnderAGameAnEarlierRunLeftRunning() async throws {
        fixture.appUpdate.set { $0.check = .success(.available(FakeAppUpdates.offer)) }
        fixture.game.set { $0.prefixBusy = true }
        let model = try await home()
        #expect(await checked(model))

        model.updates.updateWarzag()
        #expect(await eventually { model.updates.running == nil })
        #expect(model.updates.warzag == .failed(L10n.updatesGameRunning, offer: FakeAppUpdates.offer))
        #expect(!fixture.appUpdate.calls.contains("install"))
        #expect(!fixture.system.calls.contains("quit"))

        model.updates.updateEngine()
        #expect(await eventually { model.updates.running == nil })
        let offer = fixture.engine.state.withLock { $0.offer }
        #expect(model.updates.engine == .failed(L10n.updatesGameRunning, offer: offer))
        #expect(fixture.engine.calls == ["check"])
        #expect(fixture.engine.activeRuntime() == Self.installed)
    }

    // MARK: Engine

    @Test func theEngineUpdateDownloadsVerifiesInstallsThenSetsUpThePrefix() async throws {
        fixture.engine.set { $0.holdFeedSteps = ["download", "setUpPrefix"] }
        let model = try await home()
        #expect(await checked(model))
        model.updates.updateEngine()
        #expect(model.updates.running == .engine)
        #expect(await eventually {
            if case .downloading(_, let progress?) = model.updates.engine { progress.completed == 90_000_000 } else { false }
        })
        #expect(model.updates.row(.engine).status == L10n.activity(.downloadingEngine))
        #expect(model.updates.progress(of: .engine)?.total == 180_000_000)
        #expect(!model.canPlay)
        #expect(!model.canRepair)
        // Settings cannot switch the engine from under it.
        model.revealDeveloperSettings()
        await model.setDevelopmentRuntime(URL(filePath: "/build/n/Warzag.app", directoryHint: .isDirectory))
        #expect(model.settings.developmentRuntimePath == nil)

        fixture.engine.set { $0.holdFeedSteps = ["setUpPrefix"] }
        #expect(await eventually { model.updates.engine == .settingUpWindows })
        #expect(model.updates.row(.engine).status == L10n.activity(.settingUpWindows))
        #expect(fixture.engine.activeRuntime()?.id == "n-0.3.0")
        #expect(!model.canPlay, "Play waits until the prefix is set up for the new engine")

        fixture.engine.set { $0.holdFeedSteps = [] }
        #expect(await eventually { model.updates.running == nil })
        #expect(fixture.engine.calls == ["check", "fetch", "download", "verify", "activate", "setUpPrefix"])
        #expect(model.updates.engine == .upToDate)
        #expect(fixture.engine.prefixRuntimeID() == "n-0.3.0")
        #expect(await eventually { model.runtime?.id == "n-0.3.0" })
        #expect(model.updates.row(.engine).detail == L10n.updatesVersion("0.3.0"))
        #expect(model.canPlay)
        #expect(await eventually { fixture.system.keptAwake.last == .some(nil) })
    }

    /// The new engine is current but the prefix could not be set up for it: Play and Update Now (DE's launcher runs in
    /// the prefix too) wait, Home says to Repair, and both Repair and Try Again set it up.
    @Test func anEngineWhosePrefixSetUpFailedWaitsForRepair() async throws {
        let model = try await home()
        #expect(await checked(model))
        fixture.engine.set { $0.prefixError = PrefixError.bootFailed(log: "/home/Library/Logs/Warzag/prefix-n.log") }
        model.updates.updateEngine()
        #expect(await eventually { model.updates.running == nil })
        #expect(model.updates.engine == .failed(L10n.updatesEnginePrefixFailed, offer: nil))
        #expect(model.updates.prefixNeedsSetUp)
        #expect(!model.canPlay)
        #expect(model.homeStatus == L10n.homePrefixNeedsSetUp)
        let row = model.updates.row(.engine)
        #expect(row.action == .setUpAgain && row.actionEnabled)
        #expect(row.status == L10n.updatesEnginePrefixFailed)
        let warframe = model.updates.row(.warframe)
        #expect(warframe.action == .updateNow && !warframe.actionEnabled)
        #expect(warframe.status == L10n.updatesWarframeWaitsForPrefix)
        model.updates.updateWarframe()
        #expect(model.updates.running == nil)
        #expect(!fixture.game.calls.contains("updateGame"))

        // Try Again, while it still fails.
        model.updates.setUpPrefixAgain()
        #expect(await eventually { model.updates.running == nil })
        #expect(model.updates.prefixNeedsSetUp)

        fixture.engine.set { $0.prefixError = nil }
        await model.repairNow()
        #expect(!model.updates.prefixNeedsSetUp)
        #expect(model.updates.engine == .unchecked)
        #expect(model.canPlay)
        #expect(model.homeStatus != L10n.homePrefixNeedsSetUp)
        #expect(model.updates.row(.warframe).actionEnabled)
        model.updates.updateWarframe()
        #expect(await eventually { model.updates.running == nil && fixture.game.calls == ["updateGame"] })
    }

    /// Warzag quit (or crashed) after the new engine became current and before the prefix was set up for it: the next
    /// launch sets it up before Play.
    @Test func anEngineUpdateCutShortIsFinishedAtLaunch() async throws {
        try fixture.saveReadyState()
        fixture.engine.set {
            $0.feed = FakeEngine.feedURL
            $0.active = Self.installed
            $0.prefixRuntime = "n-0.1.0"
            $0.holdFeedSteps = ["setUpPrefix"]
        }
        let model = fixture.makeModel()
        await model.launch()
        // Found before anything else could start: Play and Update Now wait from now on.
        #expect(model.updates.prefixNeedsSetUp)
        #expect(!model.canPlay)
        #expect(await eventually { model.updates.engine == .settingUpWindows })
        #expect(model.updates.running == .engine)
        #expect(!model.updates.row(.warframe).actionEnabled)
        // Play's place says what runs; Home does not ask for Repair meanwhile.
        #expect(model.homeStatus != L10n.homePrefixNeedsSetUp)
        fixture.engine.set { $0.holdFeedSteps = [] }
        #expect(await eventually { model.updates.running == nil })
        #expect(fixture.engine.calls == ["setUpPrefix"])
        #expect(fixture.engine.prefixRuntimeID() == Self.installed.id)
        #expect(model.updates.engine == .unchecked)
        #expect(!model.updates.prefixNeedsSetUp)
        #expect(model.canPlay)

        // A prefix set up for the current engine, or none Warzag set up, is left alone.
        let matching = AppFixture(settings: Self.manualChecks)
        let launched = try await home(matching)
        try await Task.sleep(for: .milliseconds(50))
        #expect(launched.updates.running == nil)
        #expect(!matching.engine.calls.contains("setUpPrefix"))
    }

    /// A development engine made current with warzagctl while Warzag was closed: its prefix is set up too, and the
    /// engine row shows it, although a development engine gets no updates.
    @Test func aPrefixBehindADevelopmentEngineIsSetUpAtLaunch() async throws {
        try fixture.saveReadyState()
        fixture.engine.set {
            $0.prefixRuntime = "n-dev-20261016"
            $0.holdFeedSteps = ["setUpPrefix"]
        }
        let model = fixture.makeModel()
        await model.launch()
        #expect(await eventually { model.updates.running == .engine })
        #expect(model.updates.engineSource == .development)
        #expect(model.updates.row(.engine).status == L10n.activity(.settingUpWindows))
        #expect(model.updates.row(.engine).working)
        fixture.engine.set { $0.holdFeedSteps = [] }
        #expect(await eventually { model.updates.running == nil })
        #expect(model.updates.row(.engine).status == L10n.updatesEngineDevelopment)
        #expect(fixture.engine.prefixRuntimeID() == FakeEngine.runtime(.n).id)
    }

    /// The prefix is behind the engine while a game an earlier run of Warzag left running is still in it: nothing is
    /// set up under the game (at launch, nor with Try Again), Play and Update Now wait, and the engine row says why.
    /// Once the game has closed, Try Again sets the prefix up.
    @Test func aPrefixBehindTheEngineWaitsForAGameStillRunningInIt() async throws {
        try fixture.saveReadyState()
        fixture.engine.set {
            $0.feed = FakeEngine.feedURL
            $0.active = Self.installed
            $0.prefixRuntime = "n-0.1.0"
        }
        fixture.game.set { $0.prefixBusy = true }
        let model = fixture.makeModel()
        await model.launch()
        #expect(await eventually { model.updates.running == nil })
        #expect(model.updates.prefixNeedsSetUp)
        #expect(model.updates.engine == .failed(L10n.updatesGameRunning, offer: nil))
        #expect(!fixture.engine.calls.contains("setUpPrefix"))
        #expect(!model.canPlay)
        #expect(model.homeStatus == L10n.homePrefixNeedsSetUp)
        let row = model.updates.row(.engine)
        #expect(row.status == L10n.updatesGameRunning)
        #expect(row.action == .setUpAgain && row.actionEnabled)
        #expect(!model.updates.row(.warframe).actionEnabled)

        model.updates.setUpPrefixAgain()
        #expect(await eventually { model.updates.running == nil })
        #expect(!fixture.engine.calls.contains("setUpPrefix"))
        #expect(model.updates.prefixNeedsSetUp)

        fixture.game.set { $0.prefixBusy = false }
        model.updates.setUpPrefixAgain()
        #expect(await eventually { model.updates.running == nil && !model.updates.prefixNeedsSetUp })
        #expect(fixture.engine.calls == ["setUpPrefix"])
        #expect(fixture.engine.prefixRuntimeID() == Self.installed.id)
        #expect(model.canPlay)
    }

    /// The release page revokes the current engine. A check, even during a game, only reads the feed. Update fetches
    /// the manifest again once nothing runs on the engine, which applies the revocation (the previous engine becomes
    /// current); the prefix follows the current engine even when the download then fails, and Try Again installs the
    /// offered one.
    @Test func aRevocationWaitsForTheEngineUpdate() async throws {
        let previous = RuntimeSummary(id: "n-0.1.0", version: "0.1.0", channel: .n, development: false,
                                      hostPath: "/home/Runtimes.noindex/n/0.1.0/Warzag.app")
        fixture.engine.set { $0.revocationRollsBackTo = previous }
        fixture.game.set { $0.holdPlayUntilQuit = true }
        let model = try await home()
        model.playGame()
        #expect(await eventually { model.screen == .playing })
        #expect(await checked(model))
        let offer = fixture.engine.state.withLock { $0.offer }
        #expect(model.updates.engine == .available(offer))
        #expect(fixture.engine.calls == ["check"])
        #expect(fixture.engine.activeRuntime() == Self.installed, "the game's engine stays")
        model.quitGame()
        #expect(await eventually { model.play == .idle })

        fixture.engine.set { $0.feedErrors["download"] = URLError(.timedOut) }
        model.updates.updateEngine()
        #expect(await eventually { model.updates.running == nil })
        #expect(fixture.engine.calls == ["check", "fetch", "download", "setUpPrefix"])
        #expect(fixture.engine.activeRuntime() == previous)
        #expect(fixture.engine.prefixRuntimeID() == previous.id)
        #expect(model.updates.engine == .failed(L10n.failureEngineDownload, offer: offer))
        #expect(!model.updates.prefixNeedsSetUp)
        #expect(await eventually { model.runtime == previous })
        #expect(model.canPlay)

        fixture.engine.set { $0.feedErrors = [:] }
        model.updates.updateEngine()
        #expect(await eventually { model.updates.running == nil })
        #expect(model.updates.engine == .upToDate)
        #expect(fixture.engine.activeRuntime()?.id == offer.id)
        #expect(fixture.engine.prefixRuntimeID() == offer.id)
        #expect(model.canPlay)
    }

    // MARK: Warframe

    @Test(arguments: [GameUpdateOutcome.upToDate, .updated])
    func warframesUpdateSaysWhetherDEsLauncherChangedAnything(_ outcome: GameUpdateOutcome) async throws {
        let fixture = AppFixture(settings: Self.manualChecks)
        let downloading = ContentRunState.downloading(bytesThisRun: 1_200_000_000, bytesOnDisk: 53_800_000_000,
                                                      expectedBytes: nil, megabytesPerSecond: 45)
        fixture.game.set {
            $0.updateOutcome = outcome
            $0.holdUpdate = true
            $0.updateProgress = [.startingLauncher(attempt: 0), downloading]
        }
        let model = try await home(fixture)
        model.updates.updateWarframe()
        #expect(model.updates.running == .warframe)
        #expect(await eventually { model.updates.warframe == .updating(TrackActivity(downloading)) })
        let row = model.updates.row(.warframe)
        #expect(row.status == L10n.activity(.downloadingGame))
        #expect(row.working)
        #expect(row.progress?.completed == 1_200_000_000)
        #expect(row.action == .cancel)
        #expect(model.updates.progress(of: .warframe)?.bytesPerSecond == 45_000_000)
        #expect(!model.canPlay)

        fixture.game.set { $0.holdUpdate = false }
        #expect(await eventually { model.updates.running == nil })
        #expect(model.updates.warframe == .finished(updated: outcome == .updated))
        #expect(model.updates.row(.warframe).status
            == (outcome == .updated ? L10n.updatesWarframeUpdated : L10n.updatesWarframeUpToDate))
        #expect(model.updates.row(.warframe).action == .updateNow)
        #expect(fixture.game.calls == ["updateGame"])
        #expect(model.canPlay)
    }

    @Test func cancellingWarframesUpdateClosesDEsLauncher() async throws {
        fixture.game.set { $0.holdUpdate = true }
        let model = try await home()
        model.updates.updateWarframe()
        #expect(await eventually { fixture.game.calls.contains("updateGame") })
        model.updates.cancelWarframeUpdate()
        #expect(model.updates.warframe == .cancelling)
        #expect(model.updates.row(.warframe).status == L10n.activity(.closingLauncher))
        #expect(model.updates.row(.warframe).action == nil)
        #expect(await eventually { model.updates.running == nil })
        #expect(model.updates.warframe == .idle)
        #expect(await eventually { fixture.game.calls.contains("cancelContentRun") })
        #expect(fixture.game.calls.contains("updateGame.closed"))
        #expect(model.canPlay)
    }

    @Test(arguments: [(GameUpdateOutcome.eulaDeclined, L10n.playFailureEULA),
                      (GameUpdateOutcome.stuck, L10n.playFailureStuck)])
    func aWarframeUpdateThatDidNotFinishSaysWhy(_ outcome: GameUpdateOutcome, _ message: String) async throws {
        let fixture = AppFixture(settings: Self.manualChecks)
        fixture.game.set { $0.updateOutcome = outcome }
        let model = try await home(fixture)
        model.updates.updateWarframe()
        #expect(await eventually { model.updates.running == nil })
        #expect(model.updates.warframe == .failed(message))
        #expect(model.updates.row(.warframe).tone == .problem)
        #expect(model.updates.row(.warframe).action == .updateNow)
    }

    @Test func aGameThatCannotBeUpdatedNowSaysWhy() async throws {
        fixture.game.set { $0.updateFailure = .busy }
        let model = try await home()
        model.updates.updateWarframe()
        #expect(await eventually { model.updates.running == nil })
        #expect(model.updates.warframe == .failed(L10n.updatesGameRunning))
        fixture.game.set { $0.updateFailure = .needsRepair("C:\\windows\\system32\\winemetal.dll is missing") }
        model.updates.updateWarframe()
        #expect(await eventually { model.updates.warframe == .failed(L10n.updatesWarframeNeedsRepair) })
    }

    /// DE's changed EULA during Updates' run: the row and Home (in Play's place) point at DE's window, as Play does.
    @Test func anUpdatedEULADuringWarframesUpdateShowsAsInPlay() async throws {
        fixture.game.set {
            $0.updateProgress = [.mayNeedEULA]
            $0.holdUpdate = true
        }
        let model = try await home()
        model.updates.updateWarframe()
        #expect(await eventually { model.updates.warframe == .needsEULA(guessed: true) })
        let row = model.updates.row(.warframe)
        #expect(row.showsDEWindow)
        #expect(row.status == L10n.playEULAGuessed)
        #expect(row.action == .cancel)
        model.showDEWindow()
        #expect(fixture.system.calls == ["showGameHost(nil)"])
        model.updates.cancelWarframeUpdate()
        #expect(await eventually { model.updates.running == nil })
    }

    // MARK: What updates wait for

    @Test func nothingUpdatesDuringPlay() async throws {
        fixture.appUpdate.set { $0.check = .success(.available(FakeAppUpdates.offer)) }
        fixture.game.set { $0.holdPlayUntilQuit = true }
        let model = try await home()
        #expect(await checked(model))
        model.playGame()
        #expect(await eventually { model.screen == .playing })
        for part in UpdatePart.allCases { #expect(model.updates.blocker(for: part) == .playing) }
        #expect(model.updates.waitingFor == .playing)
        #expect(!model.updates.row(.warzag).actionEnabled)
        model.updates.updateWarzag()
        model.updates.updateEngine()
        model.updates.updateWarframe()
        #expect(model.updates.running == nil)
        #expect(!fixture.appUpdate.calls.contains("prepare(0.2.0)"))
        #expect(!fixture.engine.calls.contains("download"))
        #expect(!fixture.game.calls.contains("updateGame"))

        model.quitGame()
        #expect(await eventually { model.play == .idle })
        #expect(model.updates.waitingFor == nil)
        #expect(model.updates.row(.warzag).actionEnabled)
    }

    @Test func nothingUpdatesDuringARepair() async throws {
        let model = try await home()
        #expect(await checked(model))
        fixture.engine.set { $0.holdFeedSteps = ["repairPrefix"] }
        let repair = Task { await model.repairNow() }
        #expect(await eventually { model.repair == .running })
        #expect(model.updates.blocker(for: .engine) == .repairing)
        #expect(model.updates.waitingFor == .repairing)
        model.updates.updateEngine()
        model.updates.updateWarframe()
        #expect(model.updates.running == nil)
        fixture.engine.set { $0.holdFeedSteps = [] }
        await repair.value
        #expect(model.updates.blocker(for: .engine) == nil)
    }

    @Test func nothingUpdatesWhileSetupWorks() async {
        fixture.appUpdate.set { $0.check = .success(.available(FakeAppUpdates.offer)) }
        fixture.engine.useDevelopmentEngine(.n)
        fixture.game.set { $0.holdDownload = true }
        let model = fixture.makeModel()
        await model.launch()
        #expect(await eventually { fixture.game.calls.contains("downloadContent") })
        // Checking is fine: it only reads the feed.
        #expect(await checked(model))
        #expect(model.updates.warzag == .available(FakeAppUpdates.offer))
        #expect(model.updates.blocker(for: .warzag) == .settingUp)
        model.updates.updateWarzag()
        #expect(model.updates.running == nil)
        #expect(!fixture.appUpdate.calls.contains("prepare(0.2.0)"))
        fixture.game.set { $0.holdDownload = false }
        #expect(await eventually { model.screen == .home })
        #expect(model.updates.blocker(for: .warzag) == nil)
    }

    @Test func oneUpdateAtATime() async throws {
        fixture.appUpdate.set { $0.check = .success(.available(FakeAppUpdates.offer)) }
        fixture.game.set { $0.holdUpdate = true }
        let model = try await home()
        #expect(await checked(model))
        model.updates.updateWarframe()
        #expect(await eventually { fixture.game.calls.contains("updateGame") })
        #expect(model.updates.blocker(for: .warzag) == .updating(.warframe))
        #expect(model.updates.blocker(for: .engine) == .updating(.warframe))
        #expect(model.updates.waitingFor == nil, "the running row shows it")
        model.updates.updateWarzag()
        model.updates.updateEngine()
        #expect(fixture.appUpdate.calls == ["check"])
        #expect(fixture.engine.calls == ["check"])
        // Nor Repair or Play.
        #expect(!model.canRepair)
        model.playGame()
        #expect(model.play == .idle)
        model.updates.cancelWarframeUpdate()
        #expect(await eventually { model.updates.running == nil })
    }

    /// Quitting Warzag while DE's launcher updates the game closes it, as for setup's run, and a download of Warzag
    /// stops; quitting returns once both have ended.
    @Test func quittingStopsARunningUpdate() async throws {
        fixture.game.set { $0.holdUpdate = true }
        let model = try await home()
        model.updates.updateWarframe()
        #expect(await eventually { fixture.game.calls.contains("updateGame") })
        await model.shutdown()
        #expect(fixture.game.calls.contains("cancelContentRun"))
        #expect(fixture.game.calls.contains("updateGame.closed"))
        #expect(model.updates.running == nil)

        let downloading = AppFixture(settings: Self.manualChecks)
        downloading.appUpdate.set {
            $0.check = .success(.available(FakeAppUpdates.offer))
            $0.holdPrepare = true
        }
        let other = try await home(downloading)
        #expect(await checked(other))
        other.updates.updateWarzag()
        #expect(await eventually { downloading.appUpdate.calls.contains("prepare(0.2.0)") })
        await other.shutdown()
        #expect(other.updates.running == nil)
        #expect(!downloading.appUpdate.calls.contains("install"))
        #expect(!downloading.system.calls.contains("quit"))
    }

    // MARK: The automatic check

    @Test func theAutomaticCheckRunsAtLaunchAtMostOnceADay() async throws {
        let fixture = AppFixture()
        let model = try await home(fixture)
        #expect(await eventually { fixture.appUpdate.calls == ["check"] && model.settings.lastUpdateCheck != nil })
        #expect(fixture.engine.calls == ["check"])
        #expect(!model.updates.checking)
        // Quietly: no banner, no Dock badge, nothing downloaded.
        #expect(model.lastSession == nil)
        #expect(!fixture.system.badges.contains { $0 != nil })
        #expect(!fixture.engine.calls.contains("download"))

        await model.tick()
        fixture.clock.advance(by: 23 * 3600)
        await model.tick()
        // A check starts at once (`checking`); the feeds are asked in a task that has not run yet.
        #expect(!model.updates.checking, "not before a day has passed")
        #expect(fixture.appUpdate.calls == ["check"])
        fixture.clock.advance(by: 3600)
        await model.tick()
        #expect(await eventually { fixture.appUpdate.calls == ["check", "check"] && !model.updates.checking })

        // The next launch the same day does not check again.
        await model.shutdown()
        let next = fixture.makeModel()
        await next.launch()
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.appUpdate.calls == ["check", "check"])
    }

    @Test func aCheckThatGotNoAnswerIsTriedAgainAnHourLater() async throws {
        let fixture = AppFixture()
        fixture.appUpdate.set { $0.check = .failure(.unreachable("offline")) }
        let model = try await home(fixture)
        #expect(await eventually { fixture.appUpdate.calls == ["check"] && !model.updates.checking })
        #expect(model.settings.lastUpdateCheck == nil)
        await model.tick()
        #expect(!model.updates.checking, "not before an hour has passed")
        #expect(fixture.appUpdate.calls == ["check"])
        fixture.clock.advance(by: 3600)
        fixture.appUpdate.set { $0.check = .success(.upToDate) }
        await model.tick()
        #expect(await eventually { fixture.appUpdate.calls == ["check", "check"] && !model.updates.checking })
        #expect(model.settings.lastUpdateCheck == fixture.clock.now)
    }

    @Test func noAutomaticCheckWhenItIsOffBeforeGetStartedOrDuringPlay() async throws {
        let off = try await home(fixture)
        try await Task.sleep(for: .milliseconds(50))
        await off.tick()
        #expect(fixture.appUpdate.calls.isEmpty)
        off.setCheckForUpdatesAutomatically(true)
        #expect(AppSettingsStore(paths: fixture.paths, fileSystem: fixture.fileSystem).load().checkForUpdatesAutomatically)
        await off.tick()
        #expect(await eventually { fixture.appUpdate.calls == ["check"] })

        let welcome = AppFixture(welcomed: false)
        let first = welcome.makeModel()
        await first.launch()
        await first.tick()
        #expect(!first.updates.checking, "not before Get Started")
        #expect(welcome.appUpdate.calls.isEmpty)

        // Checked at the manual clock's start: the launch does not check; a day later Play is under way.
        var settings = AppSettings()
        settings.lastUpdateCheck = ManualClock().now
        let playing = AppFixture(settings: settings)
        playing.game.set { $0.holdPlayUntilQuit = true }
        let model = try await home(playing)
        try await Task.sleep(for: .milliseconds(50))
        #expect(playing.appUpdate.calls.isEmpty)
        model.playGame()
        #expect(await eventually { model.screen == .playing })
        playing.clock.advance(by: 25 * 3600)
        await model.tick()
        #expect(!model.updates.checking, "not during Play")
        #expect(playing.appUpdate.calls.isEmpty)
        model.quitGame()
        #expect(await eventually { model.play == .idle })
        await model.tick()
        #expect(await eventually { playing.appUpdate.calls == ["check"] })
    }

    // MARK: The live game service's verdict

    /// LiveGameService.updateGame: whether DE's launcher changed anything, from the library's growth and
    /// Warframe.x64.exe's modification time.
    @Test func aFinishedRunSaysUpdatedOnlyWhenSomethingChanged() {
        let modified = Date(timeIntervalSince1970: 1_792_000_000)
        let before = GameFilesStamp(gameModified: modified, libraryBytes: 52_600_000_000)
        #expect(GameFilesStamp.outcome(before: before, after: before, grewDuringRun: false) == .upToDate)
        #expect(GameFilesStamp.outcome(before: before, after: before, grewDuringRun: true) == .updated)
        #expect(GameFilesStamp.outcome(before: before, after: GameFilesStamp(gameModified: modified,
                                                                            libraryBytes: 52_700_000_000),
                                       grewDuringRun: false) == .updated)
        // Defragmenting the caches only shrinks them.
        #expect(GameFilesStamp.outcome(before: before, after: GameFilesStamp(gameModified: modified,
                                                                            libraryBytes: 52_000_000_000),
                                       grewDuringRun: false) == .upToDate)
        #expect(GameFilesStamp.outcome(before: before, after: GameFilesStamp(gameModified: modified.addingTimeInterval(60),
                                                                            libraryBytes: 52_600_000_000),
                                       grewDuringRun: false) == .updated)
        let unknown = GameFilesStamp(gameModified: nil, libraryBytes: nil)
        #expect(GameFilesStamp.outcome(before: unknown, after: before, grewDuringRun: false) == .upToDate)

        let growth = LibraryGrowth()
        growth.note(.preprocessing(fraction: 0.5))
        growth.note(.downloading(bytesThisRun: 0, bytesOnDisk: 52_600_000_000, expectedBytes: nil, megabytesPerSecond: nil))
        #expect(!growth.seen)
        growth.note(.downloading(bytesThisRun: 4_096, bytesOnDisk: 52_600_004_096, expectedBytes: nil, megabytesPerSecond: 1))
        #expect(growth.seen)
    }

    // MARK: Demo mode

    /// The demo's release page, updater and DE's launcher, quickly: the engine setup installs is followed by a newer
    /// one, Warzag offers its next version, and the first Warframe update after setup downloads one.
    @Test func demoModeSimulatesAllThreeUpdates() async throws {
        let world = DemoWorld(speed: 100)
        let engine = DemoEngine(world: world)
        #expect(engine.feedURL()?.host()?.hasSuffix(".invalid") == true)
        #expect(engine.developmentRuntime() == nil)
        let first = try await engine.fetchEngineManifest()
        #expect(first.version == DemoEngine.firstVersion && !first.installed)
        try await engine.downloadEngine { _, _ in }
        try await engine.verifyEngine()
        #expect(try await engine.activateEngine().version == DemoEngine.firstVersion)
        _ = try await engine.setUpPrefix()
        #expect(engine.prefixRuntimeID() == "n-\(DemoEngine.firstVersion)")
        // Updates' check sees the newer engine and keeps nothing for the steps; the update fetches it.
        let checked = try await engine.checkEngineManifest()
        #expect(checked.version == DemoEngine.newerVersion && !checked.installed)
        #expect(world.read { $0.offeredEngine }?.version == DemoEngine.firstVersion)
        let newer = try await engine.fetchEngineManifest()
        #expect(newer == checked)
        let received = Recorder<Int64>()
        try await engine.downloadEngine { bytes, _ in received.append(bytes) }
        #expect(received.all.last == DemoEngine.packBytes)

        #expect(DemoAppUpdates.offer(after: AppVersion(version: "0.1.0", build: "12")).version == "0.1.1")
        #expect(DemoAppUpdates.offer(after: AppVersion(version: "0.1.0", build: "12")).build == "13")
        #expect(DemoAppUpdates.offer(after: AppVersion(version: "0", build: "0")).version == "1")

        let game = DemoGame(world: world)
        let states = Recorder<ContentRunState>()
        #expect(try await game.updateGame { states.append($0) } == .updated)
        #expect(states.all.contains { if case .downloading = $0 { true } else { false } })
        #expect(try await game.updateGame { _ in } == .upToDate)
        await game.cancelContentRun()
        await #expect(throws: CancellationError.self) {
            _ = try await game.updateGame { _ in Task { await game.cancelContentRun() } }
        }
    }
}
