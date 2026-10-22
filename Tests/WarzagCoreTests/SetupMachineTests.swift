import Foundation
import Testing
@testable import WarzagCore

/// Every transition of the first-run state machine, for every step.
@Suite struct SetupMachineTests {
    static let transient = SetupFailure(.transient, "connection reset")
    static let permanent = SetupFailure(.permanent, "disk full")

    /// A state where `step` is its track's current step with `status`, and everything `step` depends on is done.
    static func state(at step: SetupStep, _ status: TrackStatus, attempts: Int = 0,
                      action: UserAction? = nil, failure: SetupFailure? = nil) -> SetupState {
        var state = SetupState()
        if step.track != .preflight { state.preflight = TrackState(step: .checkNetwork, status: .done) }
        if (step.track == .game && step != .downloadInstaller) || step == .checkLicense {
            state.engine = TrackState(step: .createPrefix, status: .done)
        }
        state[step.track] = TrackState(step: step, status: status, attempts: attempts, action: action, failure: failure)
        return state
    }

    static func reduce(_ state: SetupState, _ events: SetupEvent...) -> SetupState {
        events.reduce(state, SetupMachine.reduce)
    }

    static func changing(_ state: SetupState, _ track: SetupTrack, to trackState: TrackState) -> SetupState {
        var expected = state
        expected[track] = trackState
        return expected
    }

    // MARK: Step edges

    @Test(arguments: SetupStep.allCases)
    func pendingStepStarts(_ step: SetupStep) {
        let before = Self.state(at: step, .pending, attempts: 1)
        let after = Self.reduce(before, .stepStarted(step))
        #expect(after == Self.changing(before, step.track, to: TrackState(step: step, status: .running, attempts: 1)))
    }

    @Test(arguments: SetupStep.allCases)
    func completionAdvancesToTheNextStepOrFinishesTheTrack(_ step: SetupStep) {
        let before = Self.state(at: step, .running, attempts: 2)
        let after = Self.reduce(before, .stepFinished(step, .completed))
        let expected = step.next.map { TrackState(step: $0) } ?? TrackState(step: step, status: .done)
        #expect(after == Self.changing(before, step.track, to: expected))
    }

    @Test(arguments: SetupStep.allCases)
    func needingTheUserWaitsWithTheAction(_ step: SetupStep) {
        let before = Self.state(at: step, .running)
        let after = Self.reduce(before, .stepFinished(step, .needsUser(.signInToSteam)))
        #expect(after == Self.changing(before, step.track,
                                       to: TrackState(step: step, status: .waitingForUser, action: .signInToSteam)))
    }

    @Test(arguments: SetupStep.allCases)
    func goingOfflinePauses(_ step: SetupStep) {
        let before = Self.state(at: step, .running, attempts: 1)
        let after = Self.reduce(before, .stepFinished(step, .offline))
        #expect(after == Self.changing(before, step.track, to: TrackState(step: step, status: .offline, attempts: 1)))
    }

    @Test(arguments: SetupStep.allCases)
    func failuresAreCounted(_ step: SetupStep) {
        let once = Self.reduce(Self.state(at: step, .running), .stepFinished(step, .failed(Self.transient)))
        #expect(once[step.track] == TrackState(step: step, status: .failed, attempts: 1, failure: Self.transient))
        let twice = Self.reduce(once, .retry(step.track), .stepStarted(step), .stepFinished(step, .failed(Self.permanent)))
        #expect(twice[step.track] == TrackState(step: step, status: .failed, attempts: 2, failure: Self.permanent))
    }

    @Test(arguments: SetupStep.allCases)
    func theUsersResponseRearmsTheWaitingStep(_ step: SetupStep) {
        let before = Self.state(at: step, .waitingForUser, attempts: 1, action: .acceptEULA)
        #expect(Self.reduce(before, .userResponded(.acceptEULA))[step.track] == TrackState(step: step, attempts: 1))
        // A response to some other request leaves this step waiting.
        #expect(Self.reduce(before, .userResponded(.signInToSteam))[step.track] == before[step.track])
    }

    @Test(arguments: SetupStep.allCases)
    func retryRearmsFailedOfflineAndWaitingSteps(_ step: SetupStep) {
        let failed = Self.state(at: step, .failed, attempts: 3, failure: Self.permanent)
        #expect(Self.reduce(failed, .retry(step.track))[step.track] == TrackState(step: step, attempts: 3))
        let offline = Self.state(at: step, .offline)
        #expect(Self.reduce(offline, .retry(step.track))[step.track] == TrackState(step: step))
        let waiting = Self.state(at: step, .waitingForUser, action: .installSteam)
        #expect(Self.reduce(waiting, .retry(step.track))[step.track] == TrackState(step: step))
    }

    @Test(arguments: SetupStep.allCases)
    func theNetworkComingBackResumesOfflineSteps(_ step: SetupStep) {
        let offline = Self.state(at: step, .offline, attempts: 2)
        #expect(Self.reduce(offline, .networkAvailable)[step.track] == TrackState(step: step, attempts: 2))
        let failed = Self.state(at: step, .failed, attempts: 1, failure: Self.transient)
        #expect(Self.reduce(failed, .networkAvailable) == failed)
    }

    @Test(arguments: SetupStep.allCases)
    func staleOrMisdirectedResultsAreIgnored(_ step: SetupStep) {
        for status in [TrackStatus.pending, .waitingForUser, .offline, .failed, .done, .skipped] {
            let before = Self.state(at: step, status)
            #expect(Self.reduce(before, .stepFinished(step, .completed)) == before, "\(status)")
        }
        let running = Self.state(at: step, .running)
        let other = step.track.steps.first { $0 != step }!
        #expect(Self.reduce(running, .stepFinished(other, .completed)) == running)
        #expect(Self.reduce(running, .stepStarted(step)) == running)
    }

    @Test(arguments: SetupStep.allCases)
    func retryWithNothingToRetryChangesNothing(_ step: SetupStep) {
        for status in [TrackStatus.pending, .running, .done, .skipped] {
            let before = Self.state(at: step, status)
            #expect(Self.reduce(before, .retry(step.track)) == before, "\(status)")
        }
    }

    @Test(arguments: SetupStep.allCases)
    func restartChecksAgainWhateverWasInFlightOrWaiting(_ step: SetupStep) {
        for status in [TrackStatus.running, .waitingForUser, .offline, .failed] {
            let before = Self.state(at: step, status, attempts: 2, action: .chooseStorage, failure: Self.transient)
            #expect(SetupMachine.resumed(before) == Self.changing(before, step.track, to: TrackState(step: step)),
                    "\(status)")
        }
        for status in [TrackStatus.pending, .done, .skipped] {
            let before = Self.state(at: step, status)
            #expect(SetupMachine.resumed(before) == before, "\(status)")
        }
    }

    // MARK: Dependencies and parallel tracks

    @Test func onlyPreflightCanStartAtFirst() {
        #expect(SetupMachine.runnableSteps(in: .initial) == [.checkPlatform])
        for step in SetupStep.allCases where step.track != .preflight {
            var state = SetupState.initial
            state[step.track] = TrackState(step: step)
            #expect(Self.reduce(state, .stepStarted(step)) == state, "\(step)")
        }
    }

    @Test func afterPreflightTheEngineSteamAndInstallerDownloadRunInParallel() {
        var state = SetupState.initial
        state.preflight = TrackState(step: .checkNetwork, status: .done)
        #expect(SetupMachine.runnableSteps(in: state) == [.fetchManifest, .installSteam, .downloadInstaller])
    }

    @Test func gameStepsAfterTheInstallerWaitForTheEnginesPrefix() {
        var state = Self.state(at: .extractGame, .pending)
        state.engine = TrackState(step: .createPrefix, status: .running)
        #expect(!SetupMachine.runnableSteps(in: state).contains(.extractGame))
        #expect(Self.reduce(state, .stepStarted(.extractGame)) == state)
        state = Self.reduce(state, .stepFinished(.createPrefix, .completed))
        #expect(SetupMachine.runnableSteps(in: state).contains(.extractGame))
    }

    @Test func theLicenseCheckWaitsForTheEnginesPrefix() {
        // wz-steamprobe.exe runs inside the prefix, so a signed-in Steam still waits for the engine.
        var state = Self.state(at: .checkLicense, .pending)
        state.engine = TrackState(step: .createPrefix, status: .running)
        #expect(!SetupMachine.runnableSteps(in: state).contains(.checkLicense))
        #expect(Self.reduce(state, .stepStarted(.checkLicense)) == state)
        // The steps before it do not wait.
        var earlier = Self.state(at: .waitForSignIn, .pending)
        earlier.engine = TrackState(step: .downloadRuntime, status: .running)
        #expect(SetupMachine.runnableSteps(in: earlier).contains(.waitForSignIn))

        state = Self.reduce(state, .stepFinished(.createPrefix, .completed))
        #expect(SetupMachine.runnableSteps(in: state).contains(.checkLicense))
    }

    @Test func eeConfigIsSeededBeforeDEsLauncherFirstRuns() {
        // DE's ContentUpdate applet (spawned by the launcher at the end of the download) creates EE.cfg, and the seed
        // only ever writes an absent file, so it must come before every step that runs DE's code.
        let steps = SetupTrack.game.steps
        let seed = steps.firstIndex(of: .applyProfile)!
        for step in [SetupStep.acceptEULA, .pinDirectX11, .downloadContent] {
            #expect(seed < steps.firstIndex(of: step)!, "\(step)")
        }
        #expect(steps.firstIndex(of: .extractGame)! < seed)
    }

    @Test func directX11IsPinnedBeforeDEsLauncherFirstRuns() {
        // acceptEULA starts DE's launcher, and the same run goes on from the EULA into the bulk download, which
        // fetches the chosen graphics API's caches.
        let steps = SetupTrack.game.steps
        let pin = steps.firstIndex(of: .pinDirectX11)!
        #expect(pin < steps.firstIndex(of: .acceptEULA)!)
        #expect(pin < steps.firstIndex(of: .downloadContent)!)
        // It writes into the prefix, so after the installer is unpacked there.
        #expect(steps.firstIndex(of: .extractGame)! < pin)
        #expect(SetupStep.applyProfile.next == .pinDirectX11)
        #expect(SetupStep.pinDirectX11.next == .acceptEULA)
    }

    @Test func completingEveryStepOpensThePlayGate() {
        var state = SetupState.initial
        var completed: [SetupStep] = []
        while true {
            let runnable = SetupMachine.runnableSteps(in: state)
            if runnable.isEmpty { break }
            #expect(!state.isReadyToPlay)
            for step in runnable {
                state = Self.reduce(state, .stepStarted(step), .stepFinished(step, .completed))
                completed.append(step)
            }
        }
        #expect(state.isReadyToPlay)
        #expect(Set(completed) == Set(SetupStep.allCases))
        #expect(completed.count == SetupStep.allCases.count)
        #expect(SetupStep.allCases.allSatisfy(state.isCompleted))
    }

    // MARK: Engine channel

    @Test func setupPreparesTheEngine() {
        #expect(SetupState.initial.channel == .n)
        #expect(SetupTrack.engine.steps
            == [.fetchManifest, .downloadRuntime, .verifyRuntime, .activateRuntime, .createPrefix])
        var state = Self.state(at: .activateRuntime, .running)
        state = Self.reduce(state, .stepFinished(.activateRuntime, .completed))
        #expect(state.engine == TrackState(step: .createPrefix))
    }

    /// A setup.json without the engine channel, or with an unknown one, does not decode: setup starts over.
    @Test func aSetupFileWithoutTheEngineChannelDoesNotDecode() throws {
        let data = try WarzagJSON.encoder().encode(Self.state(at: .createPrefix, .pending))
        #expect(try WarzagJSON.decoder().decode(SetupState.self, from: data).channel == .n)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["channel"] = "x"
        let other = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try WarzagJSON.decoder().decode(SetupState.self, from: other) }
        object.removeValue(forKey: "channel")
        let none = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try WarzagJSON.decoder().decode(SetupState.self, from: none) }
    }

    // MARK: User choices

    @Test func aWarframeAccountSkipsSteamAndStillOpensTheGate() {
        var state = Self.state(at: .waitForSignIn, .waitingForUser, action: .signInToSteam)
        state.engine = TrackState(step: .createPrefix, status: .done)
        state.game = TrackState(step: .downloadContent, status: .done)
        #expect(!state.isReadyToPlay)

        let skipped = Self.reduce(state, .setLoginMode(.warframeAccount))
        #expect(skipped.loginMode == .warframeAccount)
        #expect(skipped.steam == TrackState(step: .waitForSignIn, status: .skipped))
        #expect(skipped.isReadyToPlay)
        #expect(skipped.isCompleted(.startSteam))
        #expect(!skipped.isCompleted(.waitForSignIn))

        let back = Self.reduce(skipped, .setLoginMode(.steam))
        #expect(back.loginMode == .steam)
        #expect(back.steam == TrackState(step: .waitForSignIn))
        #expect(!back.isReadyToPlay)
    }

    @Test func aFinishedSteamTrackStaysFinishedWhenTheModeChanges() {
        let state = Self.state(at: .checkLicense, .done)
        #expect(Self.reduce(state, .setLoginMode(.warframeAccount)).steam.status == .done)
    }

    @Test func notNowSkipsOnlyTheRelocationStep() {
        for status in [TrackStatus.pending, .waitingForUser, .failed] {
            let state = Self.state(at: .checkLocation, status, action: .moveToApplications)
            #expect(Self.reduce(state, .skipRelocation).preflight == TrackState(step: .checkStorage), "\(status)")
        }
        let running = Self.state(at: .checkLocation, .running)
        #expect(Self.reduce(running, .skipRelocation) == running)
        let elsewhere = Self.state(at: .checkStorage, .waitingForUser, action: .chooseStorage)
        #expect(Self.reduce(elsewhere, .skipRelocation) == elsewhere)
    }

    @Test func approvalsAreRememberedOnceAndSorted() {
        let state = Self.reduce(.initial, .userResponded(.moveToApplications), .userResponded(.installSteam),
                                .userResponded(.moveToApplications), .userResponded(.signInToSteam))
        #expect(state.approvals == [.installSteam, .moveToApplications])
        #expect(state.isApproved(.installSteam))
        #expect(!state.isApproved(.signInToSteam))
    }

    @Test func oneResponseRearmsEveryTrackWaitingForIt() {
        var state = Self.state(at: .createPrefix, .waitingForUser, action: .chooseStorage)
        state.game = TrackState(step: .downloadInstaller, status: .waitingForUser, action: .chooseStorage)
        let after = Self.reduce(state, .userResponded(.chooseStorage))
        #expect(after.engine.status == .pending)
        #expect(after.game.status == .pending)
    }

    // MARK: Automatic retries

    @Test func transientFailuresRetryWithBackoffThenStop() {
        func delay(_ attempts: Int, _ failure: SetupFailure = Self.transient) -> Duration? {
            SetupMachine.automaticRetryDelay(for: TrackState(step: .downloadRuntime, status: .failed,
                                                             attempts: attempts, failure: failure))
        }
        #expect(delay(1) == .seconds(2))
        #expect(delay(2) == .seconds(8))
        #expect(delay(3) == .seconds(32))
        #expect(delay(4) == nil)
        #expect(delay(1, Self.permanent) == nil)
        #expect(delay(1, SetupFailure(.unsupported, "Intel")) == nil)
        #expect(SetupMachine.automaticRetryDelay(for: TrackState(step: .downloadRuntime, status: .offline)) == nil)
    }

    // MARK: Persistence shape

    @Test func stateRoundTripsThroughSchemaVersionedJSON() throws {
        var state = Self.state(at: .downloadRuntime, .failed, attempts: 2, failure: Self.transient)
        state.approvals = [.installSteam]
        state.updatedAt = Date(timeIntervalSince1970: 1_792_000_000)
        let data = try WarzagJSON.encoder(pretty: true).encode(state)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schema"] as? Int == 1)
        #expect(Set(object.keys)
            == ["schema", "channel", "loginMode", "approvals", "preflight", "engine", "steam", "game", "updatedAt"])
        #expect(object["channel"] as? String == "n")
        let engine = try #require(object["engine"] as? [String: Any])
        #expect(engine["step"] as? String == "downloadRuntime")
        #expect(engine["status"] as? String == "failed")
        #expect(try WarzagJSON.decoder().decode(SetupState.self, from: data) == state)
    }

    @Test func everyStepBelongsToExactlyOneTrackInOrder() {
        #expect(SetupTrack.allCases.flatMap(\.steps) == SetupStep.allCases)
        for track in SetupTrack.allCases {
            for step in track.steps { #expect(step.track == track) }
            #expect(track.steps.last?.next == nil)
        }
    }
}
