import EngineKit
import Foundation
import GameKit
import Testing
import WarzagCore
import WarzagTestSupport
@testable import RuntimeKit
@testable import WarzagApp

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct StepPerformerTests {
    let fixture = AppFixture()

    private func perform(_ step: SetupStep, approvals: [UserAction] = []) async -> StepOutcome {
        await fixture.performer().perform(step, in: SetupState(approvals: approvals))
    }

    // MARK: Preflight

    @Test func anIntelMacOrAnOldMacOSIsUnsupported() async {
        fixture.system.set { $0.hardware.isAppleSilicon = false }
        #expect(await perform(.checkPlatform) == .failed(SetupFailure(.unsupported, L10n.failureNeedsAppleSilicon)))
        fixture.system.set {
            $0.hardware.isAppleSilicon = true
            $0.hardware.macOSVersion = "14.7"
        }
        #expect(await perform(.checkPlatform) == .failed(SetupFailure(.unsupported, L10n.failureNeedsMacOS("15.0"))))
        fixture.system.set { $0.hardware.macOSVersion = "26.5.1" }
        #expect(await perform(.checkPlatform) == .completed)
    }

    @Test func outsideApplicationsItAsksBeforeMovingItself() async {
        fixture.system.set {
            $0.location = ApplicationLocation(url: URL(filePath: "/Users/t/Downloads/Warzag.app"), inApplicationsFolder: false)
        }
        #expect(await perform(.checkLocation) == .needsUser(.moveToApplications))
        #expect(fixture.system.calls.isEmpty)
        fixture.system.set { $0.moveFails = true }
        #expect(await perform(.checkLocation, approvals: [.moveToApplications])
            == .failed(SetupFailure(.permanent, L10n.failureMove)))
        #expect(fixture.system.calls == ["moveToApplications"])
    }

    /// Moving opens the copy in Applications and asks this one to quit, later, from the run loop (AppTermination).
    /// Until the quit cancels the step, this copy must not carry on with setup next to the new one.
    @Test func afterMovingItselfThisCopyWaitsToQuitInsteadOfCarryingOn() async {
        fixture.system.set {
            $0.location = ApplicationLocation(url: URL(filePath: "/Users/t/Downloads/Warzag.app"), inApplicationsFolder: false)
        }
        let performer = fixture.performer()
        let finished = Flag()
        let step = Task {
            let outcome = await performer.perform(.checkLocation, in: SetupState(approvals: [.moveToApplications]))
            finished.set()
            return outcome
        }
        #expect(await eventually { fixture.system.calls == ["moveToApplications"] })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!finished.isSet)
        // Quitting shuts setup down, which cancels the step; the orchestrator drops its result.
        step.cancel()
        #expect(await step.value == .offline)
    }

    @Test func storageNeedsRoomOnACaseInsensitiveVolumeMinusWhatWarframeAlreadyUses() async {
        func volume(_ free: Int64, caseSensitive: Bool = false) -> VolumeInfo {
            VolumeInfo(availableCapacity: free, isCaseSensitive: caseSensitive, isLocal: true, format: "apfs")
        }
        fixture.system.set { $0.storage = StorageCheck(volume: volume(400_000_000_000, caseSensitive: true), libraryBytes: 0) }
        #expect(await perform(.checkStorage) == .needsUser(.chooseStorage))
        fixture.system.set { $0.storage = StorageCheck(volume: volume(50_000_000_000), libraryBytes: 0) }
        #expect(await perform(.checkStorage) == .needsUser(.chooseStorage))
        // An installed game (52.6 GB) needs room for updates only: 80 - 52.6 = 27.4 GB.
        fixture.system.set { $0.storage = StorageCheck(volume: volume(50_000_000_000), libraryBytes: 52_600_000_000) }
        #expect(await perform(.checkStorage) == .completed)
        // ...but never less than 10 GB.
        fixture.system.set { $0.storage = StorageCheck(volume: volume(9_000_000_000), libraryBytes: 79_000_000_000) }
        #expect(await perform(.checkStorage) == .needsUser(.chooseStorage))
        fixture.system.set { $0.storage = StorageCheck(volume: nil, libraryBytes: 0) }
        #expect(await perform(.checkStorage) == .needsUser(.chooseStorage))
    }

    @Test func noNetworkPausesTheStep() async {
        fixture.system.set { $0.network = false }
        #expect(await perform(.checkNetwork) == .offline)
        fixture.system.set { $0.network = true }
        #expect(await perform(.checkNetwork) == .completed)
    }

    // MARK: Engine

    @Test func withoutAnEngineSetupSaysSoInsteadOfDownloadingNothing() async {
        #expect(await perform(.fetchManifest) == .failed(SetupFailure(.permanent, L10n.failureNoEngine)))
        fixture.engine.useDevelopmentEngine(nil)
        #expect(await perform(.fetchManifest) == .failed(SetupFailure(.permanent, L10n.failureNotAnEngine)))
    }

    @Test func aDevelopmentEngineIsRegistered() async {
        fixture.engine.useDevelopmentEngine(.n)
        #expect(await perform(.fetchManifest) == .completed)
        #expect(await perform(.downloadRuntime) == .completed)
        #expect(fixture.engine.calls == ["register"])
        #expect(fixture.engine.activeRuntime()?.channel == .n)
        #expect(await perform(.verifyRuntime) == .completed)
        #expect(await perform(.activateRuntime) == .completed)
    }

    @Test func anInstalledEngineIsUsedAsIs() async {
        fixture.engine.set { $0.active = FakeEngine.runtime(.n, development: false) }
        #expect(await perform(.fetchManifest) == .completed)
        #expect(await perform(.downloadRuntime) == .completed)
        #expect(fixture.engine.calls.isEmpty)
    }

    // MARK: Engine from the release page

    @Test func withAFeedTheEngineComesFromTheReleasePageStepByStep() async {
        fixture.engine.set { $0.feed = FakeEngine.feedURL }
        #expect(await perform(.fetchManifest) == .completed)
        #expect(await perform(.downloadRuntime) == .completed)
        #expect(await perform(.verifyRuntime) == .completed)
        #expect(fixture.engine.activeRuntime() == nil, "checked, not installed yet")
        #expect(await perform(.activateRuntime) == .completed)
        #expect(fixture.engine.calls == ["fetch", "download", "verify", "activate"])
        #expect(fixture.engine.activeRuntime()?.id == "n-0.3.0")
        #expect(fixture.engine.activeRuntime()?.development == false)
    }

    @Test func theEngineDownloadShowsItsBytes() async {
        fixture.engine.set { $0.feed = FakeEngine.feedURL }
        let sink = ActivitySink()
        let performer = AppStepPerformer(services: fixture.services, paths: fixture.paths, activity: sink, log: .disabled)
        #expect(await performer.perform(.downloadRuntime, in: SetupState()) == .completed)
        sink.finish()
        var updates: [ActivityUpdate] = []
        for await update in sink.updates { updates.append(update) }
        #expect(updates.allSatisfy { $0.track == .engine && $0.activity?.detail == .downloadingEngine })
        #expect(updates.compactMap(\.activity?.progress) == [.bytes(90_000_000, of: 180_000_000),
                                                             .bytes(180_000_000, of: 180_000_000)])
    }

    @Test func aDevelopmentEngineWinsOverTheFeed() async {
        fixture.engine.set { $0.feed = FakeEngine.feedURL }
        fixture.engine.useDevelopmentEngine(.n)
        #expect(await perform(.fetchManifest) == .completed)
        #expect(await perform(.downloadRuntime) == .completed)
        #expect(await perform(.verifyRuntime) == .completed)
        #expect(await perform(.activateRuntime) == .completed)
        #expect(fixture.engine.calls == ["register"])
    }

    @Test func aFailedFeedStepKeepsAnInstalledEngine() async {
        fixture.engine.set {
            $0.feed = FakeEngine.feedURL
            $0.active = FakeEngine.runtime(.n, development: false)
            $0.feedErrors = ["fetch": URLError(.cannotFindHost), "verify": RuntimeInstallError.signerMismatch(
                expected: RuntimeTrust.projectCertificate, actual: RuntimeSigner.adHoc)]
        }
        // An update that fails never stands between the player and the game: the installed engine stays.
        #expect(await perform(.fetchManifest) == .completed)
        #expect(await perform(.verifyRuntime) == .completed)
        // Without one, the failure is the step's: paused while offline, retried while the network is up.
        fixture.engine.set { $0.active = nil }
        #expect(await perform(.fetchManifest) == .failed(SetupFailure(.transient, L10n.failureEngineDownload)))
        fixture.system.set { $0.network = false }
        #expect(await perform(.fetchManifest) == .offline)
        // A security refusal waits for the player even offline.
        #expect(await perform(.verifyRuntime) == .failed(SetupFailure(.permanent, L10n.failureEngineRejected)))
    }

    @Test func feedFailuresBecomeOneSentence() {
        let expired = Date(timeIntervalSince1970: 1_792_000_000)
        let cases: [(any Error, SetupFailure)] = [
            (URLError(.timedOut), SetupFailure(.transient, L10n.failureEngineDownload)),
            (HTTPError.status(503, FakeEngine.feedURL), SetupFailure(.transient, L10n.failureEngineDownload)),
            (DownloadError.gaveUp(attempts: 6, lastError: "x"), SetupFailure(.transient, L10n.failureEngineDownload)),
            (DigestMismatch(expected: "a", actual: "b"), SetupFailure(.transient, L10n.failureEngineDamaged)),
            (SizeMismatch(expected: 2, actual: 1), SetupFailure(.transient, L10n.failureEngineDamaged)),
            (RuntimeServiceError.manifestRejected(.badSignature), SetupFailure(.permanent, L10n.failureEngineRejected)),
            (RuntimeServiceError.manifestRejected(.unknownKey("k")), SetupFailure(.permanent, L10n.failureEngineRejected)),
            (RuntimeServiceError.manifestRejected(.olderSerial(received: 1, accepted: 2)),
             SetupFailure(.permanent, L10n.failureEngineRejected)),
            (RuntimeServiceError.manifestRejected(.expired(expired)), SetupFailure(.transient, L10n.failureEngineFeed)),
            (RuntimeServiceError.manifestRejected(.requiresNewerApp("0.5.0")),
             SetupFailure(.permanent, L10n.failureEngineNeedsNewerApp)),
            (RuntimeServiceError.manifestRejected(.requiresNewerMacOS("27.0")),
             SetupFailure(.permanent, L10n.failureEngineNeedsMacOS("27.0"))),
            (RuntimeServiceError.insecureFeed("http://x/m.json"), SetupFailure(.permanent, L10n.failureEngineRejected)),
            (RuntimeInstallError.blocked("a bad build"), SetupFailure(.permanent, L10n.failureEnginePaused)),
            (RuntimeInstallError.channelMismatch(expected: .n, actual: "Contents/MacOS/wine is x86_64, not arm64"),
             SetupFailure(.permanent, L10n.failureEngineRejected)),
            (CocoaError(.fileWriteOutOfSpace), SetupFailure(.transient, L10n.failureEngineInstall)),
        ]
        for (error, failure) in cases {
            #expect(EngineFeedFailure.failure(for: error) == failure, "\(error)")
        }
    }

    @Test func onlyAnHTTPSFeedInInfoPlistCounts() {
        let key = RuntimeFeedSource.infoPlistKey
        #expect(key == "WarzagRuntimeManifestURL")
        #expect(RuntimeFeedSource.url(in: [key: FakeEngine.feedURL.absoluteString]) == FakeEngine.feedURL)
        #expect(RuntimeFeedSource.url(in: [key: " \(FakeEngine.feedURL.absoluteString)\n"]) == FakeEngine.feedURL)
        for text in ["http://releases.example.org/m.json", "file:///tmp/m.json", "https://", "not a url", ""] {
            #expect(RuntimeFeedSource.url(in: [key: text]) == nil, "\(text)")
        }
        #expect(RuntimeFeedSource.url(in: [:]) == nil)
        #expect(RuntimeFeedSource.url(in: nil) == nil)
    }

    @Test func withoutAnActiveEngineTheChecksFail() async {
        #expect(await perform(.verifyRuntime) == .failed(SetupFailure(.permanent, L10n.failureEngineMissing)))
        #expect(await perform(.activateRuntime) == .failed(SetupFailure(.permanent, L10n.failureEngineMissing)))
    }

    @Test func prefixErrorsBecomeTheRightCard() async {
        fixture.engine.set { $0.prefixError = PrefixError.libraryUnavailable("/Volumes/Games/Warframe") }
        #expect(await perform(.createPrefix) == .needsUser(.chooseStorage))
        fixture.engine.set { $0.prefixError = PrefixError.bootFailed(log: "/x/prefix-n.log") }
        #expect(await perform(.createPrefix) == .failed(SetupFailure(.transient, L10n.failurePrefix)))
        fixture.engine.set { $0.prefixError = nil }
        #expect(await perform(.createPrefix) == .completed)
    }

    // MARK: Steam

    @Test func steamIsInstalledOnlyAfterThePlayerAgrees() async {
        fixture.steam.set { $0.installed = false }
        #expect(await perform(.installSteam) == .needsUser(.installSteam))
        #expect(fixture.steam.calls.isEmpty)
        #expect(await perform(.installSteam, approvals: [.installSteam]) == .completed)
        #expect(fixture.steam.calls == ["install"])
    }

    @Test func aFailedSteamDownloadWhileOfflineWaitsForTheNetwork() async {
        fixture.steam.set {
            $0.installed = false
            $0.installFails = true
        }
        #expect(await perform(.installSteam, approvals: [.installSteam])
            == .failed(SetupFailure(.transient, L10n.failureSteamInstall)))
        fixture.system.set { $0.network = false }
        #expect(await perform(.installSteam, approvals: [.installSteam]) == .offline)
    }

    @Test func steamIsStartedAndWatchedUntilItRuns() async {
        fixture.steam.set { $0.running = false }
        #expect(await perform(.startSteam) == .completed)
        #expect(fixture.steam.calls == ["start"])
        fixture.steam.set {
            $0.running = false
            $0.startMakesRunning = false
        }
        #expect(await perform(.startSteam) == .failed(SetupFailure(.transient, L10n.failureSteamStart)))
    }

    @Test func signInWaitsBrieflyThenAsksThePlayer() async {
        fixture.steam.set { $0.signedIn = false }
        #expect(await perform(.waitForSignIn) == .needsUser(.signInToSteam))
        fixture.steam.set { $0.signedIn = true }
        #expect(await perform(.waitForSignIn) == .completed)
    }

    @Test func theLicenseProbeDecidesTheNextCard() async {
        let cases: [(LicenseProbeResult, StepOutcome)] = [
            (.owned, .completed),
            (.notOwned, .needsUser(.addWarframeToLibrary)),
            (.steamNotRunning, .failed(SetupFailure(.transient, L10n.failureSteamNotRunning))),
            (.timedOut, .failed(SetupFailure(.transient, L10n.failureProbe))),
            (.bridgeFailed(stage: "client"), .failed(SetupFailure(.permanent, L10n.failureBridge))),
        ]
        for (probe, expected) in cases {
            fixture.engine.set { $0.probe = probe }
            #expect(await perform(.checkLicense) == expected)
        }
    }

    @Test func aSignedOutProbeAsksForSignInOnlyWhenSteamsLogAgrees() async {
        fixture.engine.set { $0.probe = .signedOut }
        fixture.steam.set { $0.signedIn = false }
        #expect(await perform(.checkLicense) == .needsUser(.signInToSteam))
        // Steam's own log says signed in (still connecting, or offline mode): the heartbeat would dismiss a sign-in card
        // at once and run the probe again, every few seconds, without end.
        fixture.steam.set { $0.signedIn = true }
        #expect(await perform(.checkLicense) == .failed(SetupFailure(.transient, L10n.failureSteamOffline)))
    }

    @Test func theProbesExitStatusMeansWhatSteamprobeCSays() {
        #expect(LicenseProbeResult(exitCode: 0) == .owned)
        #expect(LicenseProbeResult(exitCode: 24) == .notOwned)
        #expect(LicenseProbeResult(exitCode: 23) == .signedOut)
        #expect(LicenseProbeResult(exitCode: 20) == .steamNotRunning)
        #expect(LicenseProbeResult(exitCode: 21) == .steamNotRunning)
        #expect(LicenseProbeResult(exitCode: 13) == .bridgeFailed(stage: "client"))
        #expect(LicenseProbeResult(exitCode: 25) == .timedOut)
        #expect(LicenseProbeResult(exitCode: 2) == .failed("wz-steamprobe.exe exited with status 2"))
    }

    // MARK: Game

    @Test func anUnpackedLauncherSkipsTheInstallerSteps() async {
        fixture.game.set { $0.launcherExtracted = true }
        #expect(await perform(.downloadInstaller) == .completed)
        #expect(await perform(.extractGame) == .completed)
        #expect(fixture.game.calls.isEmpty)
    }

    @Test func theInstallerIsDownloadedThenUnpacked() async {
        #expect(await perform(.downloadInstaller) == .completed)
        #expect(await perform(.extractGame) == .completed)
        #expect(fixture.game.calls == ["downloadInstaller", "extractInstaller"])
    }

    @Test func aRejectedInstallerIsNotRetriedAutomatically() async {
        fixture.game.set { $0.installerError = InstallerCheckError.notAnInstaller }
        #expect(await perform(.downloadInstaller) == .failed(SetupFailure(.permanent, L10n.failureInstallerCheck)))
        fixture.game.set { $0.installerError = DownloadError.gaveUp(attempts: 6, lastError: "timed out") }
        #expect(await perform(.downloadInstaller) == .failed(SetupFailure(.transient, L10n.failureInstallerDownload)))
    }

    @Test func theEULAIsThePlayersAndAClosedWindowAsksAgain() async {
        fixture.game.set { $0.eulaAccepted = true }
        #expect(await perform(.acceptEULA) == .completed)
        #expect(fixture.game.calls.isEmpty)
        fixture.game.set {
            $0.eulaAccepted = false
            $0.eulaOutcome = .declined
        }
        #expect(await perform(.acceptEULA) == .needsUser(.acceptEULA))
        fixture.game.set { $0.eulaOutcome = .stuck(.exited) }
        #expect(await perform(.acceptEULA) == .failed(SetupFailure(.transient, L10n.failureLauncherStuck)))
    }

    @Test func theDownloadsOutcomesMapToSetupOutcomes() async {
        #expect(await perform(.downloadContent) == .completed)
        fixture.game.set { $0.downloadOutcome = .eulaDeclined }
        #expect(await perform(.downloadContent) == .needsUser(.acceptEULA))
        fixture.game.set { $0.downloadOutcome = .stuck(.stalled) }
        #expect(await perform(.downloadContent) == .failed(SetupFailure(.transient, L10n.failureDownloadStuck)))
        fixture.system.set { $0.network = false }
        #expect(await perform(.downloadContent) == .offline)
    }

    @Test func aPrefixThatNeedsRepairIsReportedAsSuch() async {
        fixture.game.set {
            $0.downloadError = ContentError.prefixNotReady([.placeholderMissing(#"C:\windows\system32\winemetal.dll"#)])
        }
        #expect(await perform(.downloadContent) == .failed(SetupFailure(.permanent, L10n.failureNeedsRepair)))
        // A busy prefix (the license probe still finishing) is retried, not repaired.
        fixture.game.set { $0.downloadError = ContentError.prefixNotReady([.prefixBusy(wineserver: 99)]) }
        #expect(await perform(.downloadContent) == .failed(SetupFailure(.transient, L10n.failureDownload)))
    }

    @Test func theProfileIsSeededOnce() async {
        #expect(await perform(.applyProfile) == .completed)
        #expect(fixture.game.calls == ["seedProfile"])
    }
}
