import Darwin
import Foundation
import Synchronization

/// SIGINT (Ctrl-C) and SIGTERM while a long command (`content install|update`, `play`) runs.
///
/// The first signal cancels the command's work, which unwinds through its close sequence (DE's launcher gets WM_CLOSE,
/// a grace period and `wineserver -k`; `play` then also closes the game); warzagctl then exits with 128 + the signal.
/// A second signal ends warzagctl at once.
final class Interrupter: Sendable {
    private struct State {
        var received: Int32?
        var handlers: [UUID: @Sendable (Int32) -> Void] = [:]
    }

    private let state = Mutex(State())
    private let onRepeat: @Sendable (Int32) -> Void
    private let sources = Mutex<[any DispatchSourceSignal]>([])

    /// `onRepeat` runs for every signal after the first.
    init(onRepeat: @escaping @Sendable (Int32) -> Void = { _ in }) {
        self.onRepeat = onRepeat
    }

    /// The real signals. Their default action (ending the process on the spot, leaving Wine behind) is turned off for
    /// as long as the process lives; a second signal still ends it, through `onRepeat`.
    static func live() -> Interrupter {
        let interrupter = Interrupter { signal in
            FileHandle.standardError.write(Data("warzagctl: stopped without waiting\n".utf8))
            exit(128 + signal)
        }
        for number in [SIGINT, SIGTERM] {
            Darwin.signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
            source.setEventHandler { interrupter.trigger(number) }
            source.resume()
            interrupter.sources.withLock { $0.append(source) }
        }
        return interrupter
    }

    /// The first signal received, if any.
    var received: Int32? { state.withLock { $0.received } }

    /// Delivers a signal (from a dispatch source, or a test).
    func trigger(_ signal: Int32) {
        let handlers = state.withLock { state -> [@Sendable (Int32) -> Void]? in
            guard state.received == nil else { return nil }
            state.received = signal
            return Array(state.handlers.values)
        }
        guard let handlers else {
            onRepeat(signal)
            return
        }
        handlers.forEach { $0(signal) }
    }

    /// Runs `work` in a task of its own and cancels it when a signal arrives (or arrived already). Returns its result
    /// and the signal, if one came.
    func run<Value: Sendable>(_ work: @escaping @Sendable () async throws -> Value) async
        -> (result: Result<Value, any Error>, signal: Int32?) {
        let task = Task { try await work() }
        let id = UUID()
        let alreadySignalled = state.withLock { state -> Bool in
            guard state.received == nil else { return true }
            state.handlers[id] = { _ in task.cancel() }
            return false
        }
        if alreadySignalled { task.cancel() }
        let result = await task.result
        state.withLock { _ = $0.handlers.removeValue(forKey: id) }
        return (result, received)
    }

    /// The exit status after a signal, as shells report it.
    static func exitCode(for signal: Int32) -> Int32 { 128 + signal }

    static func name(of signal: Int32) -> String {
        switch signal {
        case SIGINT: "SIGINT"
        case SIGTERM: "SIGTERM"
        default: "signal \(signal)"
        }
    }
}
