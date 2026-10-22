import Darwin
import Foundation
import WarzagCore

/// The file operations a swap makes, behind a protocol so tests can make any one of them fail.
public protocol BundleFileOperating: Sendable {
    /// Whether anything (a link included) is at `url`.
    func exists(_ url: URL) -> Bool
    /// A copy of `source` at `destination`, which must not exist yet (an APFS clone where the volume allows it).
    func copy(_ source: URL, to destination: URL) throws
    /// Exchanges the two paths in one step (renamex_np with RENAME_SWAP): at no moment is either of them missing.
    func exchange(_ first: URL, _ second: URL) throws
    func remove(_ url: URL) throws
    /// CFBundleIdentifier and CFBundleVersion as the bundle's Info.plist names them (nothing is verified).
    func info(of bundle: URL) -> (identifier: String?, build: String?)
}

public struct LocalBundleFiles: BundleFileOperating {
    public init() {}

    public func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.plainPath, &info) == 0
    }

    public func copy(_ source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }

    public func exchange(_ first: URL, _ second: URL) throws {
        guard renamex_np(first.plainPath, second.plainPath, UInt32(RENAME_SWAP)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    public func remove(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    public func info(of bundle: URL) -> (identifier: String?, build: String?) {
        let info = BundleInfo.read(bundle, fileSystem: LocalFileSystem())
        return (info?["CFBundleIdentifier"] as? String, info?["CFBundleVersion"] as? String)
    }
}

/// How `warzagctl app swap` exits, for the caller that started it.
public enum AppSwapExit {
    public static let replaced: Int32 = 0
    /// Nothing could be moved (or the app did not quit): the installed Warzag is as it was.
    public static let refused: Int32 = 1
    /// The new copy failed a check (EX_DATAERR from sysexits(3)): nothing was installed.
    public static let rejected: Int32 = 65
}

/// Why a probe failed.
public enum AppSwapFailure: Error, Equatable, Sendable, CustomStringConvertible {
    /// The new copy failed a check.
    case rejected(String)
    /// The installed Warzag cannot be replaced where it is.
    case cannotReplace(String)

    public var description: String {
        switch self {
        case .rejected(let reason), .cannotReplace(let reason): reason
        }
    }

    public var exitCode: Int32 {
        switch self {
        case .rejected: AppSwapExit.rejected
        case .cannotReplace: AppSwapExit.refused
        }
    }
}

/// What a swap ended with.
public enum AppSwapOutcome: Equatable, Sendable {
    /// The new Warzag is in place and checked. `leftover` is where the previous one stays when it could not be removed.
    case replaced(leftover: URL?)
    /// The new Warzag failed its check in place, or could not be moved; the previous one is in place again.
    case restored(String)
    /// Nothing was changed.
    case untouched(String)
    /// Nothing was changed: the new copy failed a check before anything was moved.
    case rejected(String)
    /// The previous Warzag could not be put back after a failed check: it waits at `previous`.
    case failed(String, previous: URL)
    /// The app that started the helper did not quit in time: nothing was changed or opened (it still runs).
    case stillRunning(String)

    public var exitCode: Int32 {
        switch self {
        case .replaced: AppSwapExit.replaced
        case .rejected: AppSwapExit.rejected
        case .restored, .untouched, .failed, .stillRunning: AppSwapExit.refused
        }
    }

    /// The reason, for anything but a replacement.
    public var reason: String? {
        switch self {
        case .replaced: nil
        case .restored(let reason), .untouched(let reason), .rejected(let reason), .stillRunning(let reason): reason
        case .failed(let reason, let previous): "\(reason); the previous Warzag is at \(previous.plainPath)"
        }
    }
}

/// What the helper's swap ended with, recorded (`AppUpdater`'s `swap-result.json`) before anything is opened: once
/// Warzag has quit, the Warzag that opens next, the new one or the previous one, learns it only from here
/// (`AppUpdater.takeSwapFailure`). Written by the new release's helper and read by the previous release's app, so it
/// is an interface between releases, like the helper's command line.
public struct AppSwapRecord: Codable, Equatable, Sendable {
    public enum Result: String, Codable, Sendable {
        /// The new Warzag is in place.
        case replaced
        /// The new copy failed a check after Warzag had quit: it is no copy to keep.
        case rejected
        /// Warzag could not be replaced where it is; the checked copy is the player's to drag into Applications, and
        /// the same build is not tried again by quitting.
        case refused
        /// Warzag did not quit in time: nothing was changed, and trying again may work.
        case stillRunning
    }

    public var schema = 1
    public var version: String
    public var build: String
    public var result: Result
    public var reason: String?
    public var date: Date
    /// The app has reported it (a failure is reported once).
    public var reported = false

    public init(version: String, build: String, result: Result, reason: String?, date: Date) {
        self.version = version
        self.build = build
        self.result = result
        self.reason = reason
        self.date = date
    }

    /// What `outcome` records for the Warzag `requirement` describes.
    public init(_ outcome: AppSwapOutcome, for requirement: AppRequirement, at date: Date) {
        let result: Result = switch outcome {
        case .replaced: .replaced
        case .rejected: .rejected
        case .restored, .untouched, .failed: .refused
        case .stillRunning: .stillRunning
        }
        self.init(version: requirement.version, build: requirement.build, result: result, reason: outcome.reason,
                  date: date)
    }
}

/// Replaces an installed Warzag with a checked new one; the new Warzag's own code does it (`AppSwapCommand`: its
/// executable for the app, its warzagctl for `warzagctl app update`), so the code that swaps is the verified new code.
///
/// The new copy is put next to the installed app as `.Warzag.app.swap-<build>` (hidden, and without the .app extension,
/// so neither Finder nor Launch Services takes it for another Warzag), then the two are exchanged in one step: the
/// installed path always holds a whole app, the old one or the new one. After the exchange the same name holds the
/// previous Warzag, which is removed once the new one has passed its check in place.
public struct AppSwap: Sendable {
    public var installed: URL
    /// The checked new Warzag (`WarzagPaths.appUpdates/staging/Warzag.app`); it stays there for the player whatever
    /// happens.
    public var staged: URL
    public var requirement: AppRequirement
    public var bundles: any AppBundleVerifying
    public var files: any BundleFileOperating
    public var processes: any ProcessInspecting
    /// Runs /usr/bin/open.
    public var runner: any ProcessRunning
    public var clock: any WallClock
    /// One line per step, for Warzag.log.
    public var log: @Sendable (String) -> Void
    /// Gets the outcome of `run` once, before anything is opened (`AppSwapCommand` records it for the Warzag that
    /// opens next).
    public var report: @Sendable (AppSwapOutcome) -> Void = { _ in }
    /// How long the app that started the helper has to quit.
    public var exitDeadline: TimeInterval = 120

    public init(installed: URL, staged: URL, requirement: AppRequirement, bundles: any AppBundleVerifying,
                files: any BundleFileOperating, processes: any ProcessInspecting, runner: any ProcessRunning,
                clock: any WallClock, log: @escaping @Sendable (String) -> Void) {
        self.installed = installed
        self.staged = staged
        self.requirement = requirement
        self.bundles = bundles
        self.files = files
        self.processes = processes
        self.runner = runner
        self.clock = clock
        self.log = log
    }

    public static func live(installed: URL, staged: URL, requirement: AppRequirement,
                            log: @escaping @Sendable (String) -> Void) -> AppSwap {
        AppSwap(installed: installed, staged: staged, requirement: requirement, bundles: LiveAppBundleVerifier(),
                files: LocalBundleFiles(), processes: DarwinProcessInspector(), runner: SystemProcessRunner(),
                clock: SystemClock(), log: log)
    }

    /// The prefix of every swap copy next to `installed` (`AppUpdater` removes what a failed swap left).
    public static func swapPrefix(for installed: URL) -> String { ".\(installed.lastPathComponent).swap-" }

    /// The new copy until the exchange, the previous Warzag after it.
    public var swapCopy: URL {
        installed.deletingLastPathComponent().appending(path: Self.swapPrefix(for: installed) + requirement.build,
                                                         directoryHint: .isDirectory)
    }

    private var name: String { "Warzag \(requirement.version) (build \(requirement.build))" }

    // MARK: Probe

    /// Before the app quits: puts the new copy next to the installed app and exchanges the two there and back, the move
    /// the swap makes, so a folder Warzag may not change is found while the player can still be told (and keeps the
    /// running app). Leaves the copy for `run`. The answer holds only for the process that runs it, so the app runs it
    /// the way it runs the swap (`HelperLaunching`).
    public func probe() throws(AppSwapFailure) {
        try checkInstalledIsWarzag()
        try placeSwapCopy()
        do {
            try files.exchange(swapCopy, installed)
        } catch {
            try? files.remove(swapCopy)
            throw .cannotReplace(refusal(error))
        }
        do {
            try files.exchange(swapCopy, installed)
        } catch {
            // Consistent either way: the checked new Warzag is in place already, the previous one at the swap copy.
            log("update: the new Warzag is in place early (\(Self.describe(error))); the previous one waits at "
                + swapCopy.plainPath)
            return
        }
        log("update: \(installed.plainPath) can be replaced; \(name) waits next to it")
    }

    // MARK: Swap

    /// Waits for `pid` (the app that started this helper) to exit, then exchanges the two copies, checks the new
    /// Warzag in place, removes the previous one and, with `reopen`, opens the new Warzag. Any failure puts the
    /// previous Warzag back (and opens it). The checked copy in `staged` is left as it is. `report` gets the outcome
    /// before anything is opened.
    public func run(waitingFor pid: Int32?, reopen: Bool) async -> AppSwapOutcome {
        if let pid {
            guard await waitForExit(of: pid) else {
                removeSwapCopyIfNew()
                return await finish(.stillRunning("Warzag did not quit within \(Int(exitDeadline)) s"), reopen: false)
            }
        }
        do {
            try checkInstalledIsWarzag()
        } catch {
            return await finish(.untouched(error.description), reopen: false)
        }
        // A probe whose second exchange failed, or a second run, finds the new Warzag in place already.
        if (try? bundles.verify(installed, against: requirement)) != nil {
            log("update: \(name) is in place already")
            return await finish(.replaced(leftover: removeSwapCopy()), reopen: reopen)
        }
        do {
            try placeSwapCopy(reusing: true)
        } catch {
            let outcome: AppSwapOutcome = if case .rejected = error { .rejected(error.description) }
                else { .untouched(error.description) }
            return await finish(outcome, reopen: reopen)
        }
        do {
            try files.exchange(swapCopy, installed)
        } catch {
            try? files.remove(swapCopy)
            return await finish(.untouched(refusal(error)), reopen: reopen)
        }
        do {
            try bundles.verify(installed, against: requirement)
        } catch {
            let reason = "the new Warzag failed its check in place: \(error)"
            do {
                try files.exchange(swapCopy, installed)
            } catch {
                log("update: \(reason); putting the previous Warzag back failed (\(Self.describe(error))), it waits at "
                    + swapCopy.plainPath)
                return await finish(.failed(reason, previous: swapCopy), reopen: reopen)
            }
            try? files.remove(swapCopy)
            return await finish(.restored(reason), reopen: reopen)
        }
        return await finish(.replaced(leftover: removeSwapCopy()), reopen: reopen)
    }

    private func finish(_ outcome: AppSwapOutcome, reopen: Bool) async -> AppSwapOutcome {
        switch outcome {
        case .replaced(let leftover):
            log("update: replaced \(installed.plainPath) with \(name)"
                + (leftover.map { "; the previous Warzag could not be removed from \($0.plainPath)" } ?? ""))
        case .restored(let reason):
            log("update: \(reason); the previous Warzag is back in \(installed.plainPath)")
        case .untouched(let reason), .rejected(let reason), .stillRunning(let reason):
            log("update: \(reason); nothing was replaced")
        case .failed:
            break
        }
        // First the record, then the app that reads it.
        report(outcome)
        if reopen { await open(installed) }
        return outcome
    }

    // MARK: Steps

    /// Why the exchange was refused. EPERM on a bundle that is not locked is App Management's answer (macOS 13+): the
    /// player can allow Warzag there, or drag the checked copy into Applications.
    private func refusal(_ error: any Error) -> String {
        let reason = "macOS did not let Warzag replace \(installed.plainPath): \(Self.describe(error))"
        guard Self.isNotPermitted(error), !Self.isLocked(installed) else { return reason }
        return reason + " (System Settings > Privacy & Security > App Management must allow Warzag)"
    }

    static func isNotPermitted(_ error: any Error) -> Bool {
        let nsError = error as NSError
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        return [nsError, underlying].contains { $0?.domain == NSPOSIXErrorDomain && $0?.code == Int(EPERM) }
    }

    /// The bundle or its folder carries a lock flag (chflags uchg, schg): EPERM then means the lock, not macOS.
    static func isLocked(_ bundle: URL) -> Bool {
        let locked = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)
        return [bundle, bundle.deletingLastPathComponent()].contains { item in
            var info = stat()
            return lstat(item.plainPath, &info) == 0 && info.st_flags & locked != 0
        }
    }

    /// Never replace anything but Warzag, whatever path the helper was given.
    private func checkInstalledIsWarzag() throws(AppSwapFailure) {
        let identifier = files.info(of: installed).identifier
        guard identifier == requirement.bundleIdentifier else {
            throw .cannotReplace("\(installed.plainPath) is \(identifier.map { "\($0)" } ?? "no app bundle"), "
                + "not \(requirement.bundleIdentifier)")
        }
    }

    /// The checked new copy at `swapCopy`. With `reusing`, one a probe left that still passes is kept; anything else
    /// there is a leftover of an earlier attempt and makes way.
    private func placeSwapCopy(reusing: Bool = false) throws(AppSwapFailure) {
        if files.exists(swapCopy) {
            if reusing, (try? bundles.verify(swapCopy, against: requirement)) != nil { return }
            do {
                try files.remove(swapCopy)
            } catch {
                throw .cannotReplace("could not clear \(swapCopy.plainPath): \(Self.describe(error))")
            }
        }
        do {
            try bundles.verify(staged, against: requirement)
        } catch {
            throw .rejected("the downloaded Warzag failed its check: \(error)")
        }
        do {
            try files.copy(staged, to: swapCopy)
        } catch {
            try? files.remove(swapCopy)
            throw .cannotReplace("could not copy the new Warzag next to \(installed.plainPath): \(Self.describe(error))")
        }
        do {
            try bundles.verify(swapCopy, against: requirement)
        } catch {
            try? files.remove(swapCopy)
            throw .rejected("the copy next to \(installed.plainPath) failed its check: \(error)")
        }
    }

    /// Removes the previous Warzag after a swap; returns where it stays when that fails.
    private func removeSwapCopy() -> URL? {
        guard files.exists(swapCopy) else { return nil }
        do {
            try files.remove(swapCopy)
            return nil
        } catch {
            return swapCopy
        }
    }

    /// Before anything was exchanged the swap copy is the new build, never the installed app: it can go.
    private func removeSwapCopyIfNew() {
        if files.exists(swapCopy), files.info(of: swapCopy).build == requirement.build { try? files.remove(swapCopy) }
    }

    /// Polls until `pid` has exited, or until the deadline. A pid that comes to name another program (reused) counts as
    /// exited.
    private func waitForExit(of pid: Int32) async -> Bool {
        let program = processes.executablePath(of: pid)
        let deadline = clock.now.addingTimeInterval(exitDeadline)
        while processes.isAlive(pid), processes.executablePath(of: pid) == program {
            guard clock.now < deadline else { return false }
            do {
                try await clock.sleep(for: .milliseconds(200))
            } catch {
                return false
            }
        }
        return true
    }

    /// `open <app>`: Launch Services starts it; `open` returns as soon as it has.
    private func open(_ app: URL) async {
        do {
            let result = try await runner.run(Command("/usr/bin/open", [app.plainPath], timeout: .seconds(30)))
            if !result.succeeded { log("update: open \(app.plainPath) failed: \(result.standardError)") }
        } catch {
            log("update: open \(app.plainPath) failed: \(error)")
        }
    }

    static func describe(_ error: any Error) -> String {
        if let error = error as? POSIXError { return String(cString: strerror(error.code.rawValue)) }
        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return String(cString: strerror(Int32(underlying.code)))
        }
        return nsError.localizedDescription
    }
}
