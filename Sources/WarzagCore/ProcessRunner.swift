import Darwin
import Foundation
import Synchronization

/// A program to run: absolute executable path, arguments, environment and working directory.
public struct Command: Sendable, Hashable, CustomStringConvertible {
    public var executable: URL
    public var arguments: [String]
    /// The complete environment for the child, or nil to inherit Warzag's own.
    public var environment: [String: String]?
    public var workingDirectory: URL?
    /// When set, stdout and stderr are appended to this file instead of being captured. Wine tools need this:
    /// the wineserver they start inherits the descriptors and outlives them, so a pipe would not reach end-of-file.
    public var logFile: URL?
    /// The deadline: a run still going after this long is stopped (SIGTERM, then SIGKILL) and reported as
    /// `ProcessTimedOut`. nil waits for as long as it takes.
    public var timeout: Duration?

    public init(
        _ executable: String,
        _ arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil,
        logFile: URL? = nil,
        timeout: Duration? = nil
    ) {
        self.init(executable: URL(filePath: executable), arguments: arguments,
                  environment: environment, workingDirectory: workingDirectory, logFile: logFile, timeout: timeout)
    }

    public init(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil,
        logFile: URL? = nil,
        timeout: Duration? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.logFile = logFile
        self.timeout = timeout
    }

    /// Shell-like rendering for logs and test failure messages (not for execution).
    public var description: String {
        ([executable.plainPath] + arguments).map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
    }
}

/// Exit status and captured output of a finished process.
public struct ProcessOutput: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data

    public init(exitCode: Int32, stdout: Data = Data(), stderr: Data = Data()) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { exitCode == 0 }
    public var standardOutput: String { String(decoding: stdout, as: UTF8.self) }
    public var standardError: String { String(decoding: stderr, as: UTF8.self) }
}

/// A run that passed its `Command.timeout`. The process was stopped before this was thrown.
public struct ProcessTimedOut: Error, Equatable, CustomStringConvertible {
    /// `Command.description` of the run.
    public var command: String
    public var timeout: Duration

    public init(command: String, timeout: Duration) {
        self.command = command
        self.timeout = timeout
    }

    public var seconds: Int { Int(timeout.components.seconds) }

    public var description: String { "\(command) did not finish within \(seconds) s and was stopped" }
}

/// Process side effects, behind a protocol so tests can record commands instead of running them.
public protocol ProcessRunning: Sendable {
    /// Runs `command` to completion. A run that passes its timeout, or whose task is cancelled, is stopped (SIGTERM,
    /// then SIGKILL after a grace period) and throws `ProcessTimedOut` or `CancellationError`; a cancelled task starts
    /// nothing. Cleanup that must follow a cancellation (`wineserver -k`, detaching an image) belongs in a task the
    /// cancellation does not reach.
    func run(_ command: Command) async throws -> ProcessOutput
}

/// Runs processes with Foundation's `Process`, capturing stdout and stderr (or appending them to a log file).
public struct SystemProcessRunner: ProcessRunning {
    /// Between SIGTERM and SIGKILL for a process that passed its deadline, or whose task was cancelled.
    public var killGracePeriod: Duration

    public init(killGracePeriod: Duration = .seconds(3)) {
        self.killGracePeriod = killGracePeriod
    }

    public func run(_ command: Command) async throws -> ProcessOutput {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        if let environment = command.environment { process.environment = environment }
        if let directory = command.workingDirectory { process.currentDirectoryURL = directory }
        process.standardInput = FileHandle.nullDevice

        let stdout = Pipe()
        let stderr = Pipe()
        var log: FileHandle?
        if let logFile = command.logFile {
            let handle = try Self.openForAppending(logFile)
            process.standardOutput = handle
            process.standardError = handle
            log = handle
        } else {
            process.standardOutput = stdout
            process.standardError = stderr
        }
        defer { try? log?.close() }

        // The exit is awaited with a latch, not a stream: iterating an AsyncStream ends as soon as the task is
        // cancelled, while the child may still be running.
        let exitStatus = ExitStatusLatch()
        process.terminationHandler = { finished in exitStatus.set(finished.terminationStatus) }
        try process.run()
        let child = Child(process)

        // Drain both pipes while the child runs: output larger than a pipe buffer would otherwise stall it.
        let capture = command.logFile == nil
        let out = Task { await Self.readToEnd(capture ? stdout.fileHandleForReading : nil) }
        let err = Task { await Self.readToEnd(capture ? stderr.fileHandleForReading : nil) }

        let watchdog = command.timeout.map { timeout in
            Task.detached { [killGracePeriod] in
                do { try await Task.sleep(for: timeout) } catch { return }
                child.stop(signal: SIGTERM, reason: .deadline)
                do { try await Task.sleep(for: killGracePeriod) } catch { return }
                child.stop(signal: SIGKILL, reason: .deadline)
            }
        }
        // Cancelled while it runs: SIGTERM now, SIGKILL after the grace period, and the wait goes on until the child
        // has really exited.
        let stopper = Mutex<Task<Void, Never>?>(nil)
        let exitCode = await withTaskCancellationHandler {
            await exitStatus.wait()
        } onCancel: { [killGracePeriod] in
            let task = Task.detached {
                child.stop(signal: SIGTERM, reason: .cancelled)
                do { try await Task.sleep(for: killGracePeriod) } catch { return }
                child.stop(signal: SIGKILL, reason: .cancelled)
            }
            stopper.withLock { $0 = task }
        }
        watchdog?.cancel()
        stopper.withLock { $0?.cancel() }
        switch child.stopReason {
        case .cancelled?:
            // As after a deadline, a grandchild (a wineserver) may still hold the pipes open: no reader is waited for.
            throw CancellationError()
        case .deadline?:
            if let timeout = command.timeout { throw ProcessTimedOut(command: command.description, timeout: timeout) }
        case nil:
            break
        }
        return ProcessOutput(exitCode: exitCode, stdout: await out.value, stderr: await err.value)
    }

    /// Why Warzag stopped a child.
    private enum StopReason: Sendable {
        case deadline
        case cancelled
    }

    /// The running `Process`, shared with the deadline and cancellation tasks. `Process` is only asked whether it runs
    /// and for its pid here, both thread-safe.
    private final class Child: @unchecked Sendable {
        private let process: Process
        private let reason = Mutex<StopReason?>(nil)

        init(_ process: Process) {
            self.process = process
        }

        /// The first reason it was signalled for, if Warzag stopped it.
        var stopReason: StopReason? { reason.withLock { $0 } }

        func stop(signal: Int32, reason: StopReason) {
            // Only while it runs: once Foundation has reaped it, its pid may belong to someone else. A run that ended
            // on its own just before the deadline (or the cancellation) is neither a timeout nor stopped.
            guard process.isRunning else { return }
            self.reason.withLock { $0 = $0 ?? reason }
            kill(process.processIdentifier, signal)
        }
    }

    /// The child's exit status, set once by the termination handler and awaited without regard to cancellation.
    private final class ExitStatusLatch: Sendable {
        private struct State {
            var status: Int32?
            var waiters: [CheckedContinuation<Int32, Never>] = []
        }

        private let state = Mutex(State())

        func set(_ status: Int32) {
            let waiters = state.withLock { state -> [CheckedContinuation<Int32, Never>] in
                guard state.status == nil else { return [] }
                state.status = status
                defer { state.waiters.removeAll() }
                return state.waiters
            }
            waiters.forEach { $0.resume(returning: status) }
        }

        func wait() async -> Int32 {
            await withCheckedContinuation { continuation in
                let status = state.withLock { state -> Int32? in
                    if let status = state.status { return status }
                    state.waiters.append(continuation)
                    return nil
                }
                if let status { continuation.resume(returning: status) }
            }
        }
    }

    private static func readToEnd(_ handle: FileHandle?) async -> Data {
        guard let handle else { return Data() }
        return await withCheckedContinuation { continuation in
            // Blocking reads stay off Swift's cooperative thread pool.
            DispatchQueue.global(qos: .utility).async {
                let data = (try? handle.readToEnd()) ?? nil
                continuation.resume(returning: data ?? Data())
            }
        }
    }

    private static func openForAppending(_ url: URL) throws -> FileHandle {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.plainPath) {
            FileManager.default.createFile(atPath: url.plainPath, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }
}
