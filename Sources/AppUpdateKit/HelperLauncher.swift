import Darwin
import Foundation
import Synchronization
import WarzagCore

/// Starts the update helper, the new Warzag's own executable (`AppSwapCommand`): `run` for its probe while Warzag still
/// runs, `launch` for the swap it makes once Warzag has quit. Both start it the same way, so the probe meets macOS
/// exactly as the swap will.
public protocol HelperLaunching: Sendable {
    /// Starts `command` in a session of its own and returns its pid at once, without waiting for it: it outlives the
    /// process starting it.
    func launch(_ command: Command) throws -> Int32
    /// Starts `command` as `launch` does, in this process's session, and waits for it (at most `command.timeout`, then
    /// it is stopped and `ProcessTimedOut` thrown): its exit status and what it printed.
    func run(_ command: Command) async throws -> ProcessOutput
}

/// posix_spawn with every signal back to its default handling and none blocked (the app ignores SIGTERM to quit
/// cleanly on it, and an exec'd child would inherit that), inheriting no descriptor (POSIX_SPAWN_CLOEXEC_DEFAULT) but
/// stdin on /dev/null and stdout and stderr on /dev/null (`launch`: the helper writes its own log) or on files read
/// back (`run`), and responsible for itself (responsibility_spawnattrs_setdisclaim).
///
/// App Management (macOS 13+) is a TCC service, which answers for a process's responsible process: a plain child counts
/// as the app while the app runs and as itself once the app has quit, so the probe would ask for the old Warzag and the
/// swap for the helper. Disclaimed, both are the new Warzag's own executable (com.warzag.app, the project certificate),
/// so what macOS lets the probe do it lets the swap do, and what the player allows for Warzag covers both.
public struct PosixHelperLauncher: HelperLaunching {
    /// Between SIGTERM and SIGKILL for a run that passed its deadline, or whose task was cancelled.
    public var killGracePeriod: Duration = .seconds(3)

    public init() {}

    public func launch(_ command: Command) throws -> Int32 {
        try Self.spawn(command, newSession: true, output: nil)
    }

    public func run(_ command: Command) async throws -> ProcessOutput {
        try Task.checkCancellation()
        let base = FileManager.default.temporaryDirectory.appending(path: "warzag-helper-\(UUID().uuidString)").plainPath
        let output = (stdout: URL(filePath: base + ".out"), stderr: URL(filePath: base + ".err"))
        defer {
            try? FileManager.default.removeItem(at: output.stdout)
            try? FileManager.default.removeItem(at: output.stderr)
        }
        let child = Child(pid: try Self.spawn(command, newSession: false, output: output))
        let watchdog = command.timeout.map { timeout in
            Task.detached { [killGracePeriod] in
                do { try await Task.sleep(for: timeout) } catch { return }
                child.stop(signal: SIGTERM, reason: .deadline)
                do { try await Task.sleep(for: killGracePeriod) } catch { return }
                child.stop(signal: SIGKILL, reason: .deadline)
            }
        }
        let stopper = Mutex<Task<Void, Never>?>(nil)
        let status = await withTaskCancellationHandler {
            await child.exitStatus()
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
            throw CancellationError()
        case .deadline?:
            if let timeout = command.timeout { throw ProcessTimedOut(command: command.description, timeout: timeout) }
        case nil:
            break
        }
        return ProcessOutput(exitCode: status, stdout: (try? Data(contentsOf: output.stdout)) ?? Data(),
                             stderr: (try? Data(contentsOf: output.stderr)) ?? Data())
    }

    static func spawn(_ command: Command, newSession: Bool, output: (stdout: URL, stderr: URL)?) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        var flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        if newSession { flags |= POSIX_SPAWN_SETSID }
        posix_spawnattr_setflags(&attributes, Int16(flags))
        _ = setDisclaim?(&attributes, 1)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        for (descriptor, file) in [(Int32(1), output?.stdout), (2, output?.stderr)] {
            posix_spawn_file_actions_addopen(&actions, descriptor, file?.plainPath ?? "/dev/null",
                                             O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        }
        if let directory = command.workingDirectory {
            posix_spawn_file_actions_addchdir_np(&actions, directory.plainPath)
        }

        let environment = command.environment ?? ProcessInfo.processInfo.environment
        let argv = ([command.executable.plainPath] + command.arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, command.executable.plainPath, &actions, &attributes, argv, envp)
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO) }
        return pid
    }

    /// responsibility_spawnattrs_setdisclaim (libSystem; not in the SDK's headers, so looked up when first needed):
    /// LLDB and Chromium start programs with it that answer to TCC for themselves. Without it the helper would start as
    /// a plain child.
    private static let setDisclaim: (@convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else {
            return nil
        }
        return unsafeBitCast(symbol, to: (@convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32).self)
    }()

    /// Why Warzag stopped a child.
    private enum StopReason: Sendable {
        case deadline
        case cancelled
    }

    /// The running child, shared with the deadline and cancellation tasks.
    private final class Child: Sendable {
        let pid: pid_t
        private let state = Mutex<(exited: Bool, reason: StopReason?)>((false, nil))

        init(pid: pid_t) {
            self.pid = pid
        }

        var stopReason: StopReason? { state.withLock { $0.reason } }

        /// Waits off Swift's cooperative pool: first for the exit without reaping (waitid with WNOWAIT, so `stop` can
        /// never signal a pid that already belongs to another process), then reaps it.
        func exitStatus() async -> Int32 {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    var info = siginfo_t()
                    while waitid(P_PID, id_t(self.pid), &info, WEXITED | WNOWAIT) == -1, errno == EINTR {}
                    self.state.withLock { $0.exited = true }
                    var status: Int32 = 0
                    while waitpid(self.pid, &status, 0) == -1, errno == EINTR {}
                    // A signal's number shows as 128 plus it, as in a shell.
                    let signal = status & 0x7f
                    continuation.resume(returning: signal == 0 ? (status >> 8) & 0xff : 128 + signal)
                }
            }
        }

        func stop(signal: Int32, reason: StopReason) {
            state.withLock { state in
                guard !state.exited else { return }
                state.reason = state.reason ?? reason
                kill(pid, signal)
            }
        }
    }
}
