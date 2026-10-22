import Foundation
import Synchronization
import Testing
import WarzagTestSupport
@testable import WarzagCore

/// Plays back scripted outcomes per step (default: completed) and records every call.
actor ScriptedPerformer: SetupStepPerforming {
    private var scripts: [SetupStep: [StepOutcome]]
    private(set) var calls: [SetupStep] = []
    private var arrivals: Set<SetupStep> = []
    private var waiters: [(steps: Set<SetupStep>, continuation: CheckedContinuation<Void, Never>)] = []
    private let rendezvous: [SetupStep: Set<SetupStep>]

    /// `rendezvous[step]`: steps that must all have started before `step` may finish (proves they run together).
    init(_ scripts: [SetupStep: [StepOutcome]] = [:], rendezvous: [SetupStep: Set<SetupStep>] = [:]) {
        self.scripts = scripts
        self.rendezvous = rendezvous
    }

    func perform(_ step: SetupStep, in state: SetupState) async -> StepOutcome {
        calls.append(step)
        arrivals.insert(step)
        let ready = waiters.filter { $0.steps.isSubset(of: arrivals) }
        waiters.removeAll { $0.steps.isSubset(of: arrivals) }
        ready.forEach { $0.continuation.resume() }
        if let others = rendezvous[step], !others.isSubset(of: arrivals) {
            await withCheckedContinuation { waiters.append((others, $0)) }
        }
        guard var queue = scripts[step], !queue.isEmpty else { return .completed }
        let outcome = queue.removeFirst()
        scripts[step] = queue
        return outcome
    }

    func count(_ step: SetupStep) -> Int { calls.filter { $0 == step }.count }
}

@Suite(.timeLimit(.minutes(1)))
struct SetupOrchestratorTests {
    let fileSystem = InMemoryFileSystem()
    let clock = ManualClock()
    var store: SetupStateStore { SetupStateStore(url: URL(filePath: "/home/State/setup.json"), fileSystem: fileSystem) }

    func run(_ performer: ScriptedPerformer) async -> SetupOrchestrator {
        let orchestrator = SetupOrchestrator(store: store, performer: performer, clock: clock)
        await orchestrator.start()
        await orchestrator.waitUntilIdle()
        return orchestrator
    }

    @Test func runsEveryStepOnceAndPersistsTheResult() async throws {
        let performer = ScriptedPerformer()
        let orchestrator = await run(performer)
        let state = await orchestrator.state
        #expect(state.isReadyToPlay)
        #expect(await performer.calls.count == SetupStep.allCases.count)
        #expect(Set(await performer.calls) == Set(SetupStep.allCases))
        #expect(store.load() == state)
        #expect(state.updatedAt == clock.now)
    }

    @Test func engineSteamAndInstallerDownloadRunConcurrently() async {
        // fetchManifest only finishes once the other two tracks have started; a sequential driver would hang here.
        let performer = ScriptedPerformer(rendezvous: [.fetchManifest: [.installSteam, .downloadInstaller]])
        let orchestrator = await run(performer)
        #expect(await orchestrator.state.isReadyToPlay)
        let calls = await performer.calls
        #expect(calls.prefix(4) == [.checkPlatform, .checkLocation, .checkStorage, .checkNetwork])
    }

    @Test func waitsForTheUserThenContinues() async {
        let performer = ScriptedPerformer([.waitForSignIn: [.needsUser(.signInToSteam)]])
        let orchestrator = await run(performer)
        var state = await orchestrator.state
        #expect(state.steam == TrackState(step: .waitForSignIn, status: .waitingForUser, action: .signInToSteam))
        #expect(state.engine.status == .done)
        #expect(state.game.status == .done)
        #expect(!state.isReadyToPlay)

        await orchestrator.send(.userResponded(.signInToSteam))
        await orchestrator.waitUntilIdle()
        state = await orchestrator.state
        #expect(state.isReadyToPlay)
        #expect(await performer.count(.waitForSignIn) == 2)
    }

    @Test func transientFailuresAreRetriedAutomaticallyWithBackoff() async {
        let failure = StepOutcome.failed(SetupFailure(.transient, "reset"))
        let performer = ScriptedPerformer([.downloadRuntime: [failure, failure]])
        let orchestrator = await run(performer)
        #expect(await orchestrator.state.isReadyToPlay)
        #expect(await performer.count(.downloadRuntime) == 3)
        #expect(clock.sleeps == [.seconds(2), .seconds(8)])
    }

    @Test func automaticRetriesGiveUpAndAManualRetryRunsAgain() async {
        let failure = StepOutcome.failed(SetupFailure(.transient, "reset"))
        let performer = ScriptedPerformer([.downloadContent: Array(repeating: failure, count: 5)])
        let orchestrator = await run(performer)
        var state = await orchestrator.state
        #expect(state.game.status == .failed)
        #expect(state.game.attempts == 4)
        #expect(await performer.count(.downloadContent) == 4)
        #expect(clock.sleeps == [.seconds(2), .seconds(8), .seconds(32)])

        await orchestrator.send(.retry(.game))
        await orchestrator.waitUntilIdle()
        state = await orchestrator.state
        #expect(state.game.attempts == 5)
        #expect(await performer.count(.downloadContent) == 5)
        await orchestrator.send(.retry(.game))
        await orchestrator.waitUntilIdle()
        #expect(await orchestrator.state.isReadyToPlay)
    }

    @Test func permanentFailuresWaitForTheUser() async {
        let performer = ScriptedPerformer([.extractGame: [.failed(SetupFailure(.permanent, "msiexec failed"))]])
        let orchestrator = await run(performer)
        #expect(await orchestrator.state.game.status == .failed)
        #expect(clock.sleeps.isEmpty)
        await orchestrator.send(.retry(.game))
        await orchestrator.waitUntilIdle()
        #expect(await orchestrator.state.isReadyToPlay)
    }

    @Test func offlineStepsResumeWhenTheNetworkReturns() async {
        let performer = ScriptedPerformer([.fetchManifest: [.offline], .downloadInstaller: [.offline]])
        let orchestrator = await run(performer)
        var state = await orchestrator.state
        #expect(state.engine.status == .offline)
        #expect(state.game.status == .offline)
        // Steam got as far as it can without the engine: the license check waits for the prefix.
        #expect(state.steam == TrackState(step: .checkLicense))

        await orchestrator.send(.networkAvailable)
        await orchestrator.waitUntilIdle()
        state = await orchestrator.state
        #expect(state.isReadyToPlay)
    }

    @Test func resumesAfterARestartWithoutRedoingCompletedSteps() async {
        // The app died while downloading the runtime; Steam was waiting for a sign-in.
        var saved = SetupState.initial
        saved.preflight = TrackState(step: .checkNetwork, status: .done)
        saved.engine = TrackState(step: .downloadRuntime, status: .running, attempts: 1)
        saved.steam = TrackState(step: .waitForSignIn, status: .waitingForUser, action: .signInToSteam)
        saved.game = TrackState(step: .downloadInstaller, status: .failed, attempts: 2,
                                failure: SetupFailure(.transient, "reset"))
        try? store.save(saved)

        let performer = ScriptedPerformer()
        let orchestrator = SetupOrchestrator(store: store, performer: performer, clock: clock)
        let resumed = await orchestrator.state
        #expect(resumed.engine == TrackState(step: .downloadRuntime))
        #expect(resumed.steam == TrackState(step: .waitForSignIn))
        #expect(resumed.game == TrackState(step: .downloadInstaller))

        await orchestrator.start()
        await orchestrator.waitUntilIdle()
        #expect(await orchestrator.state.isReadyToPlay)
        let calls = await performer.calls
        let redone: Set<SetupStep> = [.checkPlatform, .checkLocation, .checkStorage, .checkNetwork, .fetchManifest,
                                      .installSteam, .startSteam]
        #expect(redone.isDisjoint(with: calls))
        #expect(calls.filter { $0.track == .engine }.first == .downloadRuntime)
        #expect(Set(calls) == Set(SetupStep.allCases).subtracting(redone))
    }

    @Test func aRestartedOrchestratorPicksUpWhereTheLastOneStopped() async {
        let first = ScriptedPerformer([.acceptEULA: [.needsUser(.acceptEULA)]])
        _ = await run(first)
        // A second launch: the EULA is re-checked (the user may have agreed while Warzag was closed).
        let second = ScriptedPerformer()
        let orchestrator = await run(second)
        #expect(await orchestrator.state.isReadyToPlay)
        #expect(await second.calls == [.acceptEULA, .downloadContent])
    }

    @Test func choosingAWarframeAccountFinishesSetupWithoutSteam() async {
        let performer = ScriptedPerformer([.checkLicense: [.needsUser(.addWarframeToLibrary)]])
        let orchestrator = await run(performer)
        #expect(await !orchestrator.state.isReadyToPlay)
        await orchestrator.send(.setLoginMode(.warframeAccount))
        await orchestrator.waitUntilIdle()
        let state = await orchestrator.state
        #expect(state.isReadyToPlay)
        #expect(state.steam.status == .skipped)
        #expect(store.load()?.loginMode == .warframeAccount)
    }

    @Test func updatesStreamTheCurrentStateAndEveryChange() async {
        let orchestrator = SetupOrchestrator(store: store, performer: ScriptedPerformer(), clock: clock)
        let updates = await orchestrator.updates()
        await orchestrator.start()
        var seen: [SetupState] = []
        for await state in updates {
            seen.append(state)
            if state.isReadyToPlay { break }
        }
        #expect(seen.first?.preflight.status != .done)
        #expect(seen.last?.isReadyToPlay == true)
    }

    @Test func aFullDiskDoesNotStopSetup() async {
        fileSystem.setFailingWrites(true)
        let orchestrator = await run(ScriptedPerformer())
        #expect(await orchestrator.state.isReadyToPlay)
        #expect(await orchestrator.lastSaveError != nil)
        #expect(store.load() == nil)
    }

    @Test func shutdownStopsScheduling() async {
        let performer = ScriptedPerformer([.checkPlatform: [.failed(SetupFailure(.transient, "x"))]])
        let orchestrator = SetupOrchestrator(store: store, performer: performer, clock: clock)
        await orchestrator.shutdown()
        await orchestrator.start()
        await orchestrator.waitUntilIdle()
        #expect(await performer.calls.isEmpty)
    }

    /// Holds every step until it is cancelled, then cleans up in a task of its own that takes a moment, as GameKit
    /// runs `wineserver -k` after a cancelled `msiexec /a`.
    final class CleaningUpPerformer: SetupStepPerforming {
        private let cleaned = Mutex<[SetupStep]>([])
        var cleanedUp: [SetupStep] { cleaned.withLock { $0 } }

        func perform(_ step: SetupStep, in state: SetupState) async -> StepOutcome {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            await Task.detached {
                try? await Task.sleep(for: .milliseconds(50))
                self.cleaned.withLock { $0.append(step) }
            }.value
            return .completed
        }
    }

    @Test func shutdownHandsBackTheCancelledStepsSoTheirCleanupCanBeAwaited() async {
        let performer = CleaningUpPerformer()
        let orchestrator = SetupOrchestrator(store: store, performer: performer, clock: clock)
        await orchestrator.start()
        // Only the first check on this Mac runs before the others.
        let steps = await orchestrator.shutdown()
        #expect(steps.count == 1)
        for step in steps { await step.value }
        #expect(performer.cleanedUp == [.checkPlatform])
        // Its result was dropped: setup.json still says it was running, so the next launch runs it again.
        #expect(store.load()?.preflight == TrackState(step: .checkPlatform, status: .running))
        #expect(await orchestrator.state.preflight.status == .running)
    }
}

@Suite struct SetupStateStoreTests {
    let fileSystem = InMemoryFileSystem()
    var store: SetupStateStore { SetupStateStore(url: URL(filePath: "/home/State/setup.json"), fileSystem: fileSystem) }

    @Test func missingFileMeansAFreshStart() {
        #expect(store.inspect() == .missing)
        #expect(store.load() == nil)
    }

    @Test func roundTrip() throws {
        var state = SetupState.initial
        state.engine = TrackState(step: .verifyRuntime, status: .failed, attempts: 1, failure: SetupFailure(.permanent, "bad"))
        try store.save(state)
        #expect(store.load() == state)
        let text = try #require(fileSystem.text(at: "/home/State/setup.json"))
        #expect(text.contains(#""schema" : 1"#))
    }

    @Test func corruptFilesAreSetAsideAndSetupStartsOver() {
        fileSystem.addFile("/home/State/setup.json", "{ not json")
        #expect(store.inspect() == .unreadable)
        #expect(fileSystem.fileExists(at: store.url))
        #expect(store.load() == nil)
        #expect(!fileSystem.fileExists(at: store.url))
        #expect(fileSystem.text(at: "/home/State/setup.unreadable.json") == "{ not json")
    }

    @Test func newerSchemasAreSetAside() {
        fileSystem.addFile("/home/State/setup.json", #"{"schema": 2, "future": true}"#)
        #expect(store.load() == nil)
        #expect(fileSystem.fileExists(at: store.unreadableCopy))
    }

    @Test func unknownStepsInAnOldFileAreUnreadable() {
        fileSystem.addFile("/home/State/setup.json", """
            {"schema":1,"loginMode":"steam","approvals":[],
             "preflight":{"step":"teleport","status":"pending","attempts":0},
             "engine":{"step":"fetchManifest","status":"pending","attempts":0},
             "steam":{"step":"installSteam","status":"pending","attempts":0},
             "game":{"step":"downloadInstaller","status":"pending","attempts":0}}
            """)
        #expect(store.load() == nil)
    }
}
