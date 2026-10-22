import Foundation
import GameKit
import Testing
import WarzagCore
@testable import WarzagApp

/// Progress as the player reads it: "23.4 GB of 55.7 GB · 47 MB/s".
struct ProgressTests {
    let english = Locale(identifier: "en_US")

    /// Formatters may use a no-break space between number and unit.
    private func plain(_ text: String?) -> String? {
        text?.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
    }

    @Test func powerAdviceSentencesCarryTheirValues() {
        #expect(plain(Formatting.watts(8, locale: english)) == "8 W")
        #expect(plain(L10n.powerWeakCharger(Formatting.watts(8, locale: english), Formatting.watts(30, locale: english)))
            == "Your charger supplies only 8 W. Warframe needs about 20–30 W, so the battery drains while you play and "
            + "the Mac slows down when it gets low. Use your Mac's own charger (30 W or more).")
        #expect(L10n.powerLowBattery(Formatting.percent(0.07, locale: english)).hasPrefix("The battery is at 7%."))
        // Kinds without values keep their sentences; the fanless one comes from the cap the advice carries.
        #expect(L10n.power(PowerAdvice(kind: .battery, frameRateCap: 30)) == L10n.powerBatteryFanless("30"))
        #expect(L10n.power(PowerAdvice(kind: .battery)) == L10n.powerBattery)
        #expect(L10n.power(PowerAdvice(kind: .lowPowerMode, frameRateCap: 30)) == L10n.powerLowPowerMode("30"))
        #expect(L10n.power(PowerAdvice(kind: .thermal, frameRateCap: 30, thermalState: .critical))
            == L10n.powerThermal("30"))
    }

    @Test func bytesUseDecimalUnitsLikeFinder() {
        #expect(plain(Formatting.bytes(23_400_000_000, locale: english)) == "23.4 GB")
        #expect(plain(Formatting.bytes(55_700_000_000, locale: english)) == "55.7 GB")
        #expect(plain(Formatting.bytes(118_000_000, locale: english)) == "118 MB")
        #expect(plain(Formatting.bytes(-5, locale: english)) == "Zero KB" || plain(Formatting.bytes(-5, locale: english)) == "0 bytes")
    }

    @Test func aGameDownloadLineHasAmountsSpeedAndTimeLeft() {
        var progress = ProgressSnapshot.bytes(23_400_000_000, of: 55_700_000_000, estimate: true,
                                              bytesPerSecond: 47_000_000)
        progress.secondsRemaining = RateEstimator.secondsRemaining(progress)
        #expect(plain(Formatting.progressLine(progress, locale: english))
            == "23.4 GB of about 55.7 GB · 47 MB/s · about 11 min left")
        #expect(plain(Formatting.accessibilityProgress(progress, locale: english))
            == "23.4 GB of about 55.7 GB, 47 MB/s, about 11 min left")
    }

    @Test func anExactTotalAndAFractionReadDifferently() {
        #expect(plain(Formatting.progressLine(.bytes(59_000_000, of: 118_000_000), locale: english)) == "59 MB of 118 MB")
        #expect(plain(Formatting.progressLine(ProgressSnapshot(fraction: 0.42), locale: english)) == "42%")
        #expect(Formatting.progressLine(ProgressSnapshot(), locale: english) == nil)
    }

    @Test func anEstimatedTotalNeverShowsAsFinished() {
        #expect(ProgressSnapshot.bytes(60_000_000_000, of: 55_700_000_000, estimate: true).displayFraction == 0.99)
        #expect(ProgressSnapshot.bytes(118, of: 118).displayFraction == 1)
        #expect(ProgressSnapshot.bytes(5, of: nil).displayFraction == nil)
    }

    @Test func durationsAndElapsedTime() {
        #expect(plain(Formatting.duration(660, locale: english)) == "11 min")
        #expect(plain(Formatting.duration(690, locale: english)) == "12 min")
        #expect(plain(Formatting.duration(40, locale: english)) == "40 sec")
        #expect(plain(Formatting.duration(3900, locale: english)) == "1 hr, 5 min")
        #expect(Formatting.elapsed(65) == "1:05")
        #expect(Formatting.elapsed(3725) == "1:02:05")
    }

    @Test func speedIsMeasuredWhenTheDownloadDoesNotSayIt() {
        var estimator = RateEstimator()
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(estimator.add(bytes: 0, at: start) == nil)
        #expect(estimator.add(bytes: 10_000_000, at: start.addingTimeInterval(1)) == 10_000_000)
        // Too soon for a new sample: the speed stays.
        #expect(estimator.add(bytes: 12_000_000, at: start.addingTimeInterval(1.2)) == 10_000_000)
        let smoothed = estimator.add(bytes: 30_000_000, at: start.addingTimeInterval(2))
        #expect(smoothed.map { $0 > 10_000_000 && $0 < 20_000_000 } == true)
        // A download that starts over forgets the old speed.
        #expect(estimator.add(bytes: 1_000, at: start.addingTimeInterval(3)) == nil)
    }

    @Test func gameKitContentStatesBecomeActivities() {
        let downloading = TrackActivity(.downloading(bytesThisRun: 1_000, bytesOnDisk: 1_000, expectedBytes: 55_700_000_000,
                                                      megabytesPerSecond: 44))
        #expect(downloading?.detail == .downloadingGame)
        #expect(downloading?.progress?.bytesPerSecond == 44_000_000)
        #expect(downloading?.progress?.totalIsEstimate == true)
        #expect(TrackActivity(.needsEULA)?.attention == .acceptEULAInDEWindow)
        // Only guessed (DE's launcher went quiet at its start): its own, softer card and line.
        #expect(TrackActivity(.mayNeedEULA) == TrackActivity(detail: .maybeWaitingForEULA,
                                                            attention: .maybeAcceptEULAInDEWindow))
        #expect(L10n.eulaGuessedBody != L10n.eulaLiveBody)
        #expect(TrackActivity(.preprocessing(fraction: 0.5))?.progress?.fraction == 0.5)
        #expect(TrackActivity(.restartingLauncher(attempt: 2, reason: .stalled))?.detail
            == .restartingLauncher(attempt: 2, stalled: true))
        #expect(TrackActivity(.downloadingInstaller(receivedBytes: 5, totalBytes: 10))?.progress == .bytes(5, of: 10))
        #expect(TrackActivity(.stuck(.stalled)) == nil)
        #expect(TrackActivity(.warning("wineserver -w passed its deadline")) == nil)
    }

    @Test func anUpdateShowsWhatThisRunAddedWithoutATotal() {
        // An update's size is unknown in advance: the library's growth since DE's launcher started, no total.
        let update = TrackActivity(.downloading(bytesThisRun: 300_000_000, bytesOnDisk: 55_000_000_000, expectedBytes: nil,
                                                megabytesPerSecond: 40))
        #expect(update?.progress?.completed == 300_000_000)
        #expect(update?.progress?.total == nil)
    }
}

struct SetupPresentationTests {
    @Test func stepsAreDoneActiveNeedYouFailedOrPending() {
        var state = SetupState()
        state.preflight = TrackState(step: .checkNetwork, status: .done)
        state.engine = TrackState(step: .createPrefix, status: .running)
        state.steam = TrackState(step: .waitForSignIn, status: .waitingForUser, action: .signInToSteam)
        state.game = TrackState(step: .extractGame, status: .failed, attempts: 4,
                                failure: SetupFailure(.permanent, "x"))
        #expect(SetupPresentation.status(of: .checkPlatform, in: state, activity: nil) == .done)
        #expect(SetupPresentation.status(of: .activateRuntime, in: state, activity: nil) == .done)
        #expect(SetupPresentation.status(of: .createPrefix, in: state, activity: nil) == .active)
        #expect(SetupPresentation.status(of: .waitForSignIn, in: state, activity: nil) == .needsYou)
        #expect(SetupPresentation.status(of: .checkLicense, in: state, activity: nil) == .pending)
        #expect(SetupPresentation.status(of: .extractGame, in: state, activity: nil) == .failed)
        #expect(SetupPresentation.status(of: .engine, in: state, activity: nil) == .active)
        #expect(SetupPresentation.status(of: .preflight, in: state, activity: nil) == .done)
        // A running step that waits on DE's window needs the player too.
        let eula = TrackActivity(detail: .waitingForEULA, attention: .acceptEULAInDEWindow)
        state.game = TrackState(step: .acceptEULA, status: .running)
        #expect(SetupPresentation.status(of: .acceptEULA, in: state, activity: eula) == .needsYou)
        #expect(SetupPresentation.attentionItems(in: state, activities: [.game: eula])
            == [.action(.steam, .signInToSteam), .live(.game, .acceptEULAInDEWindow)])
        let guessed = TrackActivity(detail: .maybeWaitingForEULA, attention: .maybeAcceptEULAInDEWindow)
        #expect(SetupPresentation.status(of: .acceptEULA, in: state, activity: guessed) == .needsYou)
        #expect(SetupPresentation.attentionItems(in: state, activities: [.game: guessed])
            == [.action(.steam, .signInToSteam), .live(.game, .maybeAcceptEULAInDEWindow)])
    }

    @Test func aSkippedSteamTrackKeepsWhatItFinished() {
        var state = SetupState(loginMode: .warframeAccount)
        state.steam = TrackState(step: .waitForSignIn, status: .skipped)
        #expect(SetupPresentation.status(of: .installSteam, in: state, activity: nil) == .done)
        #expect(SetupPresentation.status(of: .waitForSignIn, in: state, activity: nil) == .skipped)
        #expect(SetupPresentation.status(of: .steam, in: state, activity: nil) == .skipped)
    }

    @Test func overallProgressCountsTheStepsThatApply() {
        var state = SetupState()
        #expect(SetupPresentation.overallFraction(state) == 0)
        for track in SetupTrack.allCases { state[track] = TrackState(step: track.steps.last!, status: .done) }
        #expect(SetupPresentation.overallFraction(state) == 1)
        state.preflight = TrackState(step: .checkNetwork, status: .done)
        state.engine = TrackState(step: .fetchManifest)
        state.steam = TrackState(step: .installSteam)
        state.game = TrackState(step: .downloadInstaller)
        // 4 preflight steps of 19.
        #expect(abs(SetupPresentation.overallFraction(state) - 4.0 / 19.0) < 1e-9)
    }

    @Test func storageCountsAnInstalledGame() {
        #expect(StoragePolicy.requiredFreeBytes(libraryBytes: 0) == 80_000_000_000)
        #expect(StoragePolicy.requiredFreeBytes(libraryBytes: 52_600_000_000) == 27_400_000_000)
        #expect(StoragePolicy.requiredFreeBytes(libraryBytes: 90_000_000_000) == 10_000_000_000)
    }
}
