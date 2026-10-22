import Darwin
import EngineKit
import Foundation
import Synchronization
import WarzagCore
import WineKit

// Side effects GameKit needs beyond WarzagCore's, each behind a protocol so the content and play flows run against
// fakes in tests.

/// A program Warzag started and is watching: DE's launcher (a child process) or the game host (opened through
/// LaunchServices, so a child of launchd rather than of Warzag).
public protocol RunningProcess: AnyObject, Sendable {
    var processIdentifier: Int32 { get }
    var isRunning: Bool { get }
    /// Returns once the process has ended: its exit status for Warzag's own children, nil for a process
    /// LaunchServices started (only its parent, launchd, can collect that).
    func waitForExit() async -> Int32?
    /// Asks the process to quit (SIGTERM).
    func terminate()
}

/// Starts a long-running program without waiting for it.
public protocol ProcessLaunching: Sendable {
    /// stdout and stderr go to `command.logFile` (or nowhere). Wine programs must not get pipes: the wineserver
    /// they start inherits them and outlives them.
    func launch(_ command: Command) throws -> any RunningProcess
}

/// Opens an application bundle through LaunchServices, so the game is its own app (Game Mode, Dock identity,
/// privacy prompts) rather than a child of Warzag.
public protocol ApplicationOpening: Sendable {
    /// Always a new instance: the host bundle may already be running for another Wine process.
    func openNewInstance(of application: URL, arguments: [String], environment: [String: String],
                         activates: Bool) async throws -> any RunningProcess
}

/// File questions the content and play flows ask beyond `FileSystem`.
public protocol GameFiles: Sendable {
    /// Where the symbolic link at `url` points (absolute), or nil when `url` is not a symbolic link.
    func symbolicLinkDestination(of url: URL) -> URL?
    /// Whether two paths reach the same directory once symbolic links are followed (a prefix's `x:` drive and the
    /// library).
    func isSameDirectory(_ first: URL, _ second: URL) -> Bool
    /// Bytes allocated on disk for the files under `directory`; 0 when it does not exist.
    func diskUsage(of directory: URL) -> Int64
    /// Copies a file (an APFS clone when source and destination share a volume), replacing the destination.
    func copyItem(at source: URL, to destination: URL) throws
}

/// The check before Play that the runtime host is still the code that was installed.
public protocol HostSignatureChecking: Sendable {
    /// Throws unless `host`'s code signature verifies (strictly, nested code included) and, for the active
    /// runtime's host, is still by the signer it was installed with.
    func verify(_ host: GameHost) throws
}

/// Whether anything runs in a Wine prefix.
public protocol PrefixActivityProbing: Sendable {
    /// The process ID of the wineserver serving `prefix`, or nil when none runs. A wineserver lives while any program
    /// in the prefix runs (and a few seconds longer), so this is "is anything running in this prefix".
    func wineserver(for prefix: URL) -> Int32?
}

// MARK: - Live implementations

/// The live check, with EngineKit's `RuntimeService`: the same strict validation as at install
/// (`SecurityCodeSignatureInspector`); when `host` is the active runtime's, its signer must be the recorded one. A
/// development host passed with `--host` only has to verify.
public struct RuntimeSignatureCheck: HostSignatureChecking {
    public let engine: Engine

    public init(engine: Engine) {
        self.engine = engine
    }

    public func verify(_ host: GameHost) throws {
        let runtime = engine.runtime
        let active = try? runtime.active()
        let expected = active.flatMap {
            $0.host.bundle.standardized.plainPath == host.bundle.standardized.plainPath
                ? $0.runtime.signerFingerprint : nil
        }
        try runtime.verifySignature(of: host, expectedSigner: expected)
    }
}

/// Child processes through Foundation's `Process`.
public struct FoundationProcessLauncher: ProcessLaunching {
    public init() {}

    public func launch(_ command: Command) throws -> any RunningProcess {
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        if let environment = command.environment { process.environment = environment }
        if let directory = command.workingDirectory { process.currentDirectoryURL = directory }
        process.standardInput = FileHandle.nullDevice
        let log = try command.logFile.map(LogFile.openForAppending)
        process.standardOutput = log ?? FileHandle.nullDevice
        process.standardError = log ?? FileHandle.nullDevice

        let child = ChildProcess(process)
        // Weak: the child owns the Process, and the Process keeps its handler.
        process.terminationHandler = { [weak child] finished in
            try? log?.close()
            child?.exited(finished.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            try? log?.close()
            throw error
        }
        return child
    }
}

final class ChildProcess: RunningProcess, @unchecked Sendable {
    // `Process` is not Sendable; it is only read (pid) or told to terminate, both thread-safe.
    private let process: Process
    private let exit = ExitLatch()

    init(_ process: Process) {
        self.process = process
    }

    var processIdentifier: Int32 { process.processIdentifier }
    var isRunning: Bool { !exit.isSet }

    func exited(_ status: Int32) {
        exit.set(status)
    }

    func waitForExit() async -> Int32? {
        await exit.wait()
    }

    func terminate() {
        guard isRunning else { return }
        process.terminate()
    }
}

/// A process Warzag did not start itself (an app LaunchServices opened), watched with a kqueue exit event.
public final class WatchedProcess: RunningProcess, @unchecked Sendable {
    public let processIdentifier: Int32
    private let exit = ExitLatch()
    private let source: DispatchSourceProcess

    public init(processIdentifier: Int32, inspector: any ProcessInspecting = DarwinProcessInspector()) {
        self.processIdentifier = processIdentifier
        let source = DispatchSource.makeProcessSource(identifier: processIdentifier, eventMask: .exit,
                                                      queue: .global(qos: .utility))
        self.source = source
        let exit = exit
        source.setEventHandler {
            exit.set(nil)
            source.cancel()
        }
        source.resume()
        // It may have ended before the source was armed.
        if !inspector.isAlive(processIdentifier) {
            exit.set(nil)
            source.cancel()
        }
    }

    public var isRunning: Bool { !exit.isSet }

    public func waitForExit() async -> Int32? {
        await exit.wait()
    }

    public func terminate() {
        guard isRunning else { return }
        kill(processIdentifier, SIGTERM)
    }
}

/// A one-time "it ended" signal for any number of waiters.
final class ExitLatch: Sendable {
    private struct State {
        var finished = false
        var status: Int32?
        var waiters: [CheckedContinuation<Int32?, Never>] = []
    }

    private let state = Mutex(State())

    var isSet: Bool { state.withLock { $0.finished } }

    func set(_ status: Int32?) {
        let waiters = state.withLock { state -> [CheckedContinuation<Int32?, Never>] in
            guard !state.finished else { return [] }
            state.finished = true
            state.status = status
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        waiters.forEach { $0.resume(returning: status) }
    }

    func wait() async -> Int32? {
        await withCheckedContinuation { continuation in
            let finished = state.withLock { state -> (Bool, Int32?) in
                if state.finished { return (true, state.status) }
                state.waiters.append(continuation)
                return (false, nil)
            }
            if finished.0 { continuation.resume(returning: finished.1) }
        }
    }
}

enum LogFile {
    static func openForAppending(_ url: URL) throws -> FileHandle {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.plainPath) {
            manager.createFile(atPath: url.plainPath, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }
}

public struct LocalGameFiles: GameFiles {
    public init() {}

    public func symbolicLinkDestination(of url: URL) -> URL? {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.plainPath) else { return nil }
        let resolved = target.hasPrefix("/")
            ? URL(filePath: target, directoryHint: .isDirectory)
            : url.deletingLastPathComponent().appending(path: target, directoryHint: .isDirectory)
        return resolved.standardized
    }

    public func isSameDirectory(_ first: URL, _ second: URL) -> Bool {
        var a = stat()
        var b = stat()
        guard stat(first.plainPath, &a) == 0, stat(second.plainPath, &b) == 0 else { return false }
        return a.st_dev == b.st_dev && a.st_ino == b.st_ino && (a.st_mode & S_IFMT) == S_IFDIR
    }

    public func diskUsage(of directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    public func copyItem(at source: URL, to destination: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: destination.plainPath) {
            try manager.removeItem(at: destination)
        }
        try manager.copyItem(at: source, to: destination)
    }
}

/// Asks the kernel whether a wineserver holds the prefix's lock, exactly as Wine itself finds a running server:
/// `/tmp/.wine-<uid>/server-<dev>-<inode>/lock` (device and inode of the prefix directory, in hex), write-locked by
/// the server for its whole life. Reading the lock with F_GETLK changes nothing and starts nothing.
public struct WineserverLockProbe: PrefixActivityProbing {
    public let serverRoot: URL

    public init(serverRoot: URL = URL(filePath: "/tmp/.wine-\(getuid())", directoryHint: .isDirectory)) {
        self.serverRoot = serverRoot
    }

    /// The server directory Wine derives for `prefix`, or nil if the prefix does not exist.
    public func serverDirectory(for prefix: URL) -> URL? {
        var info = stat()
        guard stat(prefix.plainPath, &info) == 0 else { return nil }
        return serverRoot.appending(path: Self.serverDirectoryName(device: info.st_dev, inode: info.st_ino),
                                    directoryHint: .isDirectory)
    }

    /// `server-<dev>-<ino>` exactly as wineserver's `create_server_dir` prints it: `%llx` of
    /// `(unsigned long long)st.st_dev`, so macOS's signed 32-bit `dev_t` is sign-extended when its top bit is set.
    static func serverDirectoryName(device: dev_t, inode: ino_t) -> String {
        "server-" + String(UInt64(bitPattern: Int64(device)), radix: 16) + "-" + String(UInt64(inode), radix: 16)
    }

    public func wineserver(for prefix: URL) -> Int32? {
        guard let directory = serverDirectory(for: prefix) else { return nil }
        let descriptor = open(directory.appending(path: "lock").plainPath, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 1
        guard fcntl(descriptor, F_GETLK, &lock) == 0, lock.l_type != Int16(F_UNLCK) else { return nil }
        return lock.l_pid
    }
}
