import Foundation

/// Does the work of one setup step. Implementations translate their errors into outcomes and must be idempotent:
/// after a crash or restart the interrupted step runs again from the top.
public protocol SetupStepPerforming: Sendable {
    func perform(_ step: SetupStep, in state: SetupState) async -> StepOutcome
}

/// The async driver around `SetupMachine`: runs every runnable step concurrently, feeds outcomes back through the
/// pure transition function, persists after every transition and schedules automatic retries.
///
/// Offline tracks wait for `.networkAvailable` (the app's network monitor) or a user retry; waiting-for-user
/// tracks wait for `.userResponded`.
public actor SetupOrchestrator {
    public private(set) var state: SetupState
    /// The last error writing setup.json. Setup carries on in memory and writes again on the next transition.
    public private(set) var lastSaveError: String?

    private let store: SetupStateStore
    private let performer: any SetupStepPerforming
    private let clock: any WallClock
    private var runningSteps: [SetupStep: Task<Void, Never>] = [:]
    private var retryTimers: [SetupTrack: RetryTimer] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var observers: [UUID: AsyncStream<SetupState>.Continuation] = [:]
    private var isShutDown = false

    private struct RetryTimer {
        let id: UUID
        let task: Task<Void, Never>
    }

    /// Loads setup.json (resuming whatever was interrupted) without starting any work.
    public init(store: SetupStateStore, performer: any SetupStepPerforming, clock: any WallClock = SystemClock()) {
        self.store = store
        self.performer = performer
        self.clock = clock
        state = SetupMachine.resumed(store.load() ?? .initial)
    }

    /// Starts every step that can run.
    public func start() {
        pump()
    }

    public func send(_ event: SetupEvent) {
        apply(event)
        pump()
    }

    /// Returns once no step is running and no automatic retry is pending: setup is finished, or waiting for the
    /// user, the network, or a manual retry.
    public func waitUntilIdle() async {
        guard !isIdle else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    /// The current state, then every change.
    public func updates() -> AsyncStream<SetupState> {
        let (stream, continuation) = AsyncStream<SetupState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        observers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    /// Stops scheduling work (app termination). Steps already running are cancelled and their results dropped.
    ///
    /// Returns the cancelled steps' tasks. A cancelled step still stops its process (SIGTERM, then SIGKILL) and runs
    /// its cleanup (`wineserver -k` after `msiexec /a`, detaching Steam's disk image), so a caller about to exit must
    /// await them.
    @discardableResult
    public func shutdown() -> [Task<Void, Never>] {
        isShutDown = true
        let cancelled = Array(runningSteps.values)
        cancelled.forEach { $0.cancel() }
        retryTimers.values.forEach { $0.task.cancel() }
        runningSteps.removeAll()
        retryTimers.removeAll()
        resumeIdleWaiters()
        return cancelled
    }

    private var isIdle: Bool { runningSteps.isEmpty && retryTimers.isEmpty }

    private func apply(_ event: SetupEvent) {
        var next = SetupMachine.reduce(state, event)
        guard next != state else { return }
        next.updatedAt = clock.now
        state = next
        do {
            try store.save(next)
            lastSaveError = nil
        } catch {
            lastSaveError = String(describing: error)
        }
        for observer in observers.values { observer.yield(next) }
    }

    private func pump() {
        guard !isShutDown else { return }
        for step in SetupMachine.runnableSteps(in: state) where runningSteps[step] == nil {
            apply(.stepStarted(step))
            guard state[step.track].status == .running else { continue }
            let snapshot = state
            let performer = performer
            runningSteps[step] = Task {
                let outcome = await performer.perform(step, in: snapshot)
                self.finish(step, with: outcome)
            }
        }
        scheduleAutomaticRetries()
        if isIdle { resumeIdleWaiters() }
    }

    private func finish(_ step: SetupStep, with outcome: StepOutcome) {
        guard !isShutDown else { return }
        runningSteps[step] = nil
        apply(.stepFinished(step, outcome))
        pump()
    }

    private func scheduleAutomaticRetries() {
        for trackID in SetupTrack.allCases {
            let track = state[trackID]
            if let timer = retryTimers[trackID], track.status != .failed {
                // Resolved some other way (a manual retry, a mode switch).
                timer.task.cancel()
                retryTimers[trackID] = nil
            }
            guard retryTimers[trackID] == nil, let delay = SetupMachine.automaticRetryDelay(for: track) else {
                continue
            }
            let id = UUID()
            let attempts = track.attempts
            let clock = clock
            retryTimers[trackID] = RetryTimer(id: id, task: Task {
                do { try await clock.sleep(for: delay) } catch { return }
                self.automaticRetryDue(trackID, timer: id, attempts: attempts)
            })
        }
    }

    private func automaticRetryDue(_ trackID: SetupTrack, timer id: UUID, attempts: Int) {
        guard !isShutDown, retryTimers[trackID]?.id == id else { return }
        retryTimers[trackID] = nil
        if state[trackID].status == .failed, state[trackID].attempts == attempts {
            apply(.retry(trackID))
        }
        pump()
    }

    private func resumeIdleWaiters() {
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }
}
