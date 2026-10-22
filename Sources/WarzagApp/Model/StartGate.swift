import Foundation
import Synchronization

/// Holds setup back until the player clicks Get Started on the Welcome screen. Only the read-only checks on this Mac
/// (the preflight track) run before that; the engine, Steam and the game wait here, so nothing is downloaded or started
/// without the click.
final class StartGate: Sendable {
    private struct State {
        var open = false
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    }

    private let state = Mutex(State())

    init(open: Bool = false) {
        state.withLock { $0.open = open }
    }

    var isOpen: Bool { state.withLock { $0.open } }

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.open = true
            defer { state.waiters.removeAll() }
            return Array(state.waiters.values)
        }
        waiters.forEach { $0.resume() }
    }

    /// Returns once the gate is open, or at once when the waiting task is cancelled.
    func wait() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { state -> Bool in
                    if state.open || Task.isCancelled { return true }
                    state.waiters[id] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume()
        }
    }
}
