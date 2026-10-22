import Foundation
import Synchronization
import WarzagCore

/// The update helper's command line (docs/RELEASING.md). Two programs take it: the new Warzag's own executable with
/// `appFlag` first, for the app's hand-over (`AppUpdater.install(.afterExit)`, so macOS sees Warzag itself make the
/// swap), and warzagctl's `app swap`, for `warzagctl app update`. The Warzag being replaced starts the new release's
/// helper with it and reads the record that helper leaves (`AppSwapRecord`): both are interfaces every release keeps.
///
///     [--home <dir>] --installed <Warzag.app> --staged <Warzag.app> --version <v> --build <b> --signer <sha256>
///         [--log <Warzag.log>] (--probe | [--wait-pid <pid>] [--open])
public struct AppSwapCommand: Equatable, Sendable {
    /// What makes Warzag's executable the helper when it comes first: it probes or swaps and exits, and never starts
    /// the app.
    public static let appFlag = "--update-swap"

    /// Warzag's data (`WarzagPaths(home:)`), where the record goes; warzagctl takes it as its own `--home`.
    public var home: String?
    public var installed: String
    public var staged: String
    public var version: String
    public var build: String
    public var signer: String
    public var log: String?
    /// Checks that the swap can be made (`AppSwap.probe`) and changes nothing else.
    public var probe = false
    /// The app that started the helper: the swap waits for it to quit, and the outcome is recorded for the Warzag that
    /// opens next.
    public var waitPID: Int32?
    /// Opens the Warzag that is in place afterwards.
    public var open = false

    public init(home: String?, installed: String, staged: String, version: String, build: String, signer: String,
                log: String?) {
        self.home = home
        self.installed = installed
        self.staged = staged
        self.version = version
        self.build = build
        self.signer = signer
        self.log = log
    }

    /// The command line, after `appFlag` or `app swap`.
    public var arguments: [String] {
        var arguments = home.map { ["--home", $0] } ?? []
        arguments += ["--installed", installed, "--staged", staged, "--version", version, "--build", build,
                      "--signer", signer]
        if let log { arguments += ["--log", log] }
        if probe { arguments.append("--probe") }
        if let waitPID { arguments += ["--wait-pid", "\(waitPID)"] }
        if open { arguments.append("--open") }
        return arguments
    }

    public struct UsageError: Error, Equatable, CustomStringConvertible {
        public var message: String
        public var description: String { message }
    }

    static let valueOptions: Set<String> = ["--home", "--installed", "--staged", "--version", "--build", "--signer",
                                            "--log", "--wait-pid"]

    public static func parse(_ arguments: [String]) throws(UsageError) -> AppSwapCommand {
        var values: [String: String] = [:]
        var probe = false
        var open = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--probe": probe = true
            case "--open": open = true
            case _ where valueOptions.contains(argument):
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                    throw UsageError(message: "\(argument) needs a value")
                }
                index += 1
                values[argument] = arguments[index]
            default:
                throw UsageError(message: argument.hasPrefix("-")
                    ? "unknown option for app swap: \(argument)" : "unexpected argument for app swap: \(argument)")
            }
            index += 1
        }
        var waitPID: Int32?
        if let text = values["--wait-pid"] {
            guard let pid = Int32(text), pid > 0 else { throw UsageError(message: "--wait-pid needs a pid") }
            waitPID = pid
        }
        guard let installed = values["--installed"], let staged = values["--staged"], let version = values["--version"],
              let build = values["--build"], let signer = values["--signer"] else {
            throw UsageError(message: "app swap needs --installed, --staged, --version, --build and --signer")
        }
        var command = AppSwapCommand(home: values["--home"], installed: installed, staged: staged, version: version,
                                     build: build, signer: signer, log: values["--log"])
        command.probe = probe
        command.waitPID = waitPID
        command.open = open
        return command
    }

    /// How the helper ended: its exit status (`AppSwapExit`) and, unless it succeeded, why (one line).
    public struct Result: Equatable, Sendable {
        public var exitCode: Int32
        public var reason: String?

        public init(exitCode: Int32, reason: String? = nil) {
            self.exitCode = exitCode
            self.reason = reason
        }
    }

    /// Runs the helper. Only a certificate in `signers` (this build's pins) is installed: the new copy is checked
    /// against it before and after the swap. Every step goes to `--log` (Warzag.log) and to `output`. With `waitPID`,
    /// the outcome is recorded in `paths` (`AppUpdateRecords`) before anything is opened. Relative paths are taken
    /// from `currentDirectory`.
    public func run(signers: Set<String>, paths: WarzagPaths, currentDirectory: URL,
                    output: @escaping @Sendable (String) -> Void,
                    swap makeSwap: (_ installed: URL, _ staged: URL, _ requirement: AppRequirement,
                                    _ log: @escaping @Sendable (String) -> Void) -> AppSwap) async -> Result {
        guard signers.contains(signer.lowercased()) else {
            return Result(exitCode: AppSwapExit.rejected, reason: "\(signer) is not a certificate this build trusts")
        }
        let file = AppendingLog(url: log.map { Self.location($0, in: currentDirectory, directory: false) })
        let log: @Sendable (String) -> Void = { line in
            file.write(line)
            output(line + "\n")
        }
        let requirement = AppRequirement(version: version, build: build, signerFingerprint: signer)
        var swap = makeSwap(Self.location(installed, in: currentDirectory), Self.location(staged, in: currentDirectory),
                            requirement, log)
        if probe {
            do {
                try swap.probe()
                return Result(exitCode: AppSwapExit.replaced)
            } catch {
                log("update: \(error); nothing was replaced")
                return Result(exitCode: error.exitCode, reason: error.description)
            }
        }
        if waitPID != nil {
            let records = AppUpdateRecords(paths: paths, fileSystem: LocalFileSystem())
            let clock = swap.clock
            swap.report = { outcome in
                do {
                    try records.save(AppSwapRecord(outcome, for: requirement, at: clock.now))
                } catch {
                    log("update: could not record the outcome for the Warzag that opens next: \(error)")
                }
            }
        }
        let outcome = await swap.run(waitingFor: waitPID, reopen: open)
        return Result(exitCode: outcome.exitCode, reason: outcome.reason)
    }

    static func location(_ path: String, in directory: URL, directory isDirectory: Bool = true) -> URL {
        URL(filePath: path, directoryHint: isDirectory ? .isDirectory : .notDirectory, relativeTo: directory)
            .absoluteURL.standardized
    }

    /// `body` run to completion from synchronous code: Warzag's entry point, before anything of the app has started
    /// (warzagctl has its own). Only there: blocking a thread of Swift's cooperative pool this way could starve it.
    public static func blocking<Value: Sendable>(_ body: @escaping @Sendable () async -> Value) -> Value {
        let box = Box<Value>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let value = await body()
            box.value.withLock { $0 = value }
            done.signal()
        }
        done.wait()
        // The task set it before it signalled.
        return box.value.withLock { $0! }
    }

    private final class Box<Value: Sendable>: Sendable {
        let value = Mutex<Value?>(nil)
    }
}
