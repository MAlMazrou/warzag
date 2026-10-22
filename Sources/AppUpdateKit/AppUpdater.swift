import Foundation
import RuntimeKit
import WarzagCore

/// What a check of the app feed found.
public enum AppFeedCheck: Equatable, Sendable {
    /// This build names no app feed.
    case notConfigured
    /// The feed offers this build or an older one.
    case upToDate(AppManifest)
    case available(AppManifest)
}

/// The new Warzag `prepare` left, unpacked and checked, waiting in `AppUpdater.stagedApp` for `install`. Its record
/// (prepared.json) is a note in Warzag's caches, never trusted on its own: it counts only as long as the manifest the
/// last check kept, verified again, describes it exactly.
public struct PreparedApp: Codable, Equatable, Sendable {
    public var requirement: AppRequirement
    /// The archive's size.
    public var bytes: Int64
    public var releaseNotes: URL?

    public init(requirement: AppRequirement, bytes: Int64, releaseNotes: URL? = nil) {
        self.requirement = requirement
        self.bytes = bytes
        self.releaseNotes = releaseNotes
    }

    public var version: String { requirement.version }
    public var build: String { requirement.build }
}

/// Who swaps, and when.
public enum AppUpdateHandoff: Equatable, Sendable {
    /// The app: the new Warzag's own executable (`AppSwapCommand.appFlag`) first checks that the swap can be made
    /// (`AppSwap.probe`), then is started again on its own and waits for `pid` (the app) to exit before it swaps,
    /// records the outcome and opens the new Warzag. `HelperLaunching` starts both, each responsible for itself, so the
    /// probe meets macOS as the swap will. The caller quits.
    case afterExit(pid: Int32)
    /// warzagctl: the new Warzag's warzagctl swaps at once, and the caller waits for it; `reopen` opens the new Warzag
    /// afterwards.
    case now(reopen: Bool)
}

/// Warzag's own updates (docs/RELEASING.md), for the app (`LiveAppUpdateService`) and `warzagctl app`:
///
/// - check: the app feed's signed manifest, always from the server, verified (`AppManifestVerifier`); its serial
///   becomes the floor; only a higher build than the installed one is offered, and only to a macOS it supports.
/// - prepare: once the volume has room for it, the archive downloaded with resume into `WarzagPaths.appUpdates`
///   (`PackDownloading`: size and SHA-256), unpacked with ditto into `staging/`, which must then hold exactly
///   Warzag.app, and that app checked (`AppBundleVerifying`). Nothing installed is touched.
/// - install: the prepared copy, checked again against the kept manifest (itself verified again); the installed app
///   where it can be replaced (`AppLocationInspecting`), no game running; then the new Warzag's own code swaps
///   (`AppSwapCommand`, `AppSwap`). Once Warzag has quit, the helper records how the swap ended (`takeSwapFailure`).
public struct AppUpdater: Sendable {
    public var installed: InstalledApp
    /// The app feed; nil: the build names none.
    public var feed: URL?
    /// The manifest keys and certificates this build pins (EngineKit's `RuntimeTrust.pinned`).
    public var trust: ManifestTrust
    public var paths: WarzagPaths
    public var macOSVersion: String
    /// Development builds only (`AppFeed.allowsLoopbackHTTP`).
    public var allowsLoopbackHTTP: Bool
    public var http: any HTTPClient
    public var downloader: any PackDownloading
    public var extractor: any AppArchiveExtracting
    public var bundles: any AppBundleVerifying
    public var location: any AppLocationInspecting
    public var fileSystem: any FileSystem
    public var processes: any ProcessInspecting
    /// Runs warzagctl's helper for `.now`, as a child of the command that runs `warzagctl app update`.
    public var runner: any ProcessRunning
    /// Starts the app's helper for `.afterExit`: its probe, then its swap.
    public var launcher: any HelperLaunching
    public var clock: any WallClock

    public init(installed: InstalledApp, feed: URL?, trust: ManifestTrust, paths: WarzagPaths, macOSVersion: String,
                allowsLoopbackHTTP: Bool = AppFeed.allowsLoopbackHTTP, http: any HTTPClient,
                downloader: any PackDownloading, extractor: any AppArchiveExtracting, bundles: any AppBundleVerifying,
                location: any AppLocationInspecting, fileSystem: any FileSystem, processes: any ProcessInspecting,
                runner: any ProcessRunning, launcher: any HelperLaunching, clock: any WallClock) {
        self.installed = installed
        self.feed = feed
        self.trust = trust
        self.paths = paths
        self.macOSVersion = macOSVersion
        self.allowsLoopbackHTTP = allowsLoopbackHTTP
        self.http = http
        self.downloader = downloader
        self.extractor = extractor
        self.bundles = bundles
        self.location = location
        self.fileSystem = fileSystem
        self.processes = processes
        self.runner = runner
        self.launcher = launcher
        self.clock = clock
    }

    /// `home` is the user's real home, whose Applications folder counts as one (whatever WARZAG_HOME says).
    public static func live(installed: InstalledApp, feed: URL?, trust: ManifestTrust, paths: WarzagPaths,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) -> AppUpdater {
        let runner = SystemProcessRunner()
        return AppUpdater(
            installed: installed, feed: feed, trust: trust, paths: paths,
            macOSVersion: VersionNumber(ProcessInfo.processInfo.operatingSystemVersion).description,
            http: URLSessionHTTPClient(session: URLSessionHTTPClient.uncachedSession),
            downloader: ResumablePackDownloader(),
            extractor: DittoArchiveExtractor(runner: runner), bundles: LiveAppBundleVerifier(),
            location: LiveAppLocationInspector(home: home), fileSystem: LocalFileSystem(),
            processes: DarwinProcessInspector(), runner: runner, launcher: PosixHelperLauncher(), clock: SystemClock())
    }

    var records: AppUpdateRecords { AppUpdateRecords(paths: paths, fileSystem: fileSystem) }

    /// Where the checked new Warzag waits: what the player drags into Applications when Warzag cannot replace itself.
    public var stagedApp: URL { records.stagedBundle }

    /// The highest app-manifest serial this Mac accepted.
    public func lastAcceptedSerial() -> UInt64? { records.lastSerial() }

    // MARK: Check

    public func check() async throws(AppUpdateFailure) -> AppFeedCheck {
        guard let feed else { return .notConfigured }
        guard AppManifestVerifier.isAllowed(feed, context: context(serial: nil)) else {
            throw .rejected("the app feed must be an https URL, not \(feed.absoluteString)")
        }
        let data: Data
        do {
            data = try await http.data(from: feed)
        } catch {
            throw .unreachable(Self.describe(error))
        }
        let manifest = try verify(data)
        do {
            try records.accept(manifest)
            try fileSystem.writeAtomically(data, to: records.manifestFile)
        } catch {
            throw Self.localFailure("could not record the app manifest", error)
        }
        removeLeftovers()
        guard AppManifest.isNewer(manifest.build, than: installed.build) else { return .upToDate(manifest) }
        try checkMacOS(manifest)
        return .available(manifest)
    }

    /// Signature, kind and every field, against this Mac's serial floor. An expired manifest is the release page's to
    /// renew, so it counts as "try again later"; every other refusal is a rejection.
    func verify(_ data: Data) throws(AppUpdateFailure) -> AppManifest {
        do {
            return try AppManifestVerifier.verify(data, trust: trust, context: context(serial: records.lastSerial()))
        } catch {
            if case .expired(let date) = error {
                throw .unreachable("the app manifest expired at \(date.formatted(.iso8601)) and the release page has "
                    + "not published a fresh one")
            }
            throw .rejected(error.description)
        }
    }

    func context(serial: UInt64?) -> AppManifestContext {
        AppManifestContext(now: clock.now, lastAcceptedSerial: serial, allowsLoopbackHTTP: allowsLoopbackHTTP)
    }

    func checkMacOS(_ manifest: AppManifest) throws(AppUpdateFailure) {
        if let required = VersionNumber(manifest.minMacOS), let running = VersionNumber(macOSVersion), running < required {
            throw .requiresNewerMacOS(manifest.minMacOS)
        }
    }

    // MARK: Prepare

    /// Downloads and checks `build`, which the last check offered. A copy already prepared and still passing is kept,
    /// and so is an archive a full disk kept from being unpacked.
    @discardableResult
    public func prepare(build: String, progress: @escaping @Sendable (_ received: Int64, _ total: Int64) -> Void = { _, _ in })
        async throws(AppUpdateFailure) -> PreparedApp {
        guard feed != nil else { throw .notConfigured }
        let manifest = try await manifest(offering: build)
        guard AppManifest.isNewer(manifest.build, than: installed.build) else {
            throw .rejected("build \(manifest.build) is not newer than the running build \(installed.build)")
        }
        try checkMacOS(manifest)
        let requirement = AppRequirement(manifest)
        let records = records
        if let prepared = records.prepared(), prepared.requirement == requirement,
           (try? bundles.verify(records.stagedBundle, against: requirement)) != nil {
            progress(manifest.size, manifest.size)
            return prepared
        }
        records.clearPrepared()

        let archive = records.archive(for: manifest)
        records.removeArchives(except: archive)
        let downloaded = (try? FileDigest.verify(archive, sha256: manifest.sha256, size: manifest.size,
                                                 fileSystem: fileSystem)) != nil
        try checkFreeSpace(for: manifest, downloaded: downloaded)
        if downloaded {
            progress(manifest.size, manifest.size)
        } else {
            do {
                try fileSystem.createDirectory(at: paths.appUpdates)
                try await downloader.download(manifest.url, to: archive, size: manifest.size, sha256: manifest.sha256) {
                    progress($0.receivedBytes, $0.totalBytes ?? manifest.size)
                }
            } catch {
                throw Self.downloadFailure(error)
            }
        }
        do {
            try fileSystem.createDirectory(at: records.stagingDirectory)
            try await extractor.extract(archive, into: records.stagingDirectory)
            let entries = try fileSystem.contentsOfDirectory(at: records.stagingDirectory).map(\.lastPathComponent).sorted()
            guard entries == [AppUpdateRecords.appName] else {
                throw AppArchiveError(reason: "it must hold exactly \(AppUpdateRecords.appName), not "
                    + (entries.isEmpty ? "nothing" : entries.joined(separator: ", ")))
            }
            try bundles.verify(records.stagedBundle, against: requirement)
        } catch {
            records.clearPrepared()
            // The archive passed its size and SHA-256. A full disk is no fault of it: it stays, so freeing space and
            // trying again needs no new download. An archive that does not unpack into the manifest's app goes.
            if Self.isOutOfSpace(error) { throw .unreachable(Self.notEnoughSpace(Self.describe(error))) }
            try? fileSystem.removeItem(at: archive)
            throw .rejected(Self.describe(error))
        }
        // Unpacked and checked: the archive is not needed again.
        try? fileSystem.removeItem(at: archive)
        let prepared = PreparedApp(requirement: requirement, bytes: manifest.size, releaseNotes: manifest.releaseNotes)
        do {
            try records.save(prepared)
        } catch {
            records.clearPrepared()
            throw Self.localFailure("could not record the prepared update", error)
        }
        return prepared
    }

    /// The manifest the last check kept (verified again), or a fresh one; either must offer `build`.
    func manifest(offering build: String) async throws(AppUpdateFailure) -> AppManifest {
        if let data = try? fileSystem.contents(of: records.manifestFile), let saved = try? verify(data), saved.build == build {
            return saved
        }
        switch try await check() {
        case .available(let manifest) where manifest.build == build:
            return manifest
        case .available(let manifest):
            throw .rejected("the release page now offers build \(manifest.build), not \(build); check again")
        case .upToDate:
            throw .rejected("the release page no longer offers build \(build)")
        case .notConfigured:
            throw .notConfigured
        }
    }

    /// Room on the caches' volume for the archive (unless it is there already), about three times its size unpacked,
    /// and a margin: a full disk is found before the download, not half-way through unpacking. A volume that does not
    /// say is not held up.
    func checkFreeSpace(for manifest: AppManifest, downloaded: Bool) throws(AppUpdateFailure) {
        let needed = (downloaded ? 0 : manifest.size) + 3 * manifest.size + Self.freeSpaceMargin
        guard let free = (try? fileSystem.volumeInfo(for: paths.appUpdates))?.availableCapacity, free < needed else {
            return
        }
        throw .unreachable(Self.notEnoughSpace("the update needs about \(Self.megabytes(needed)) on the volume holding "
            + "\(paths.appUpdates.plainPath), and \(Self.megabytes(free)) are free"))
    }

    /// Never fill the disk to the last byte.
    static let freeSpaceMargin: Int64 = 100_000_000

    /// The update `prepare` left, if its copy is still there and the manifest the last check kept, verified again,
    /// describes it (it is checked again before anything installs it).
    public func prepared() -> PreparedApp? {
        let records = records
        guard let prepared = records.prepared(), fileSystem.directoryExists(at: records.stagedBundle),
              (try? checkKeptManifest(describes: prepared)) != nil else { return nil }
        return prepared
    }

    /// Throws unless the manifest the last check kept, verified again with this build's pins (a pinned key, kind,
    /// serial floor, expiry, a pinned signer), names exactly `prepared`'s identity, version, build and signer.
    func checkKeptManifest(describes prepared: PreparedApp) throws(AppUpdateFailure) {
        guard let data = try? fileSystem.contents(of: records.manifestFile) else {
            throw .rejected("no app manifest describes the prepared update; check again")
        }
        let manifest = try verify(data)
        guard AppRequirement(manifest) == prepared.requirement else {
            throw .rejected("the prepared update is not the one the app manifest describes; check again")
        }
    }

    /// What `install` acts on: prepared.json is a note in Warzag's caches, which anything running as this user can
    /// write, so the requirement the copy is checked against, and whose helper then runs, must be the signed
    /// manifest's. A note no verified manifest describes goes, with its copy; one whose manifest has expired stays
    /// until a check brings a fresh one.
    func trustedPrepared() throws(AppUpdateFailure) -> PreparedApp {
        let records = records
        guard let prepared = records.prepared(), fileSystem.directoryExists(at: records.stagedBundle) else {
            throw .rejected("no update is prepared (check and download it first)")
        }
        do {
            try checkKeptManifest(describes: prepared)
        } catch {
            if case .unreachable = error { throw error }
            records.clearPrepared()
            throw error
        }
        return prepared
    }

    // MARK: Install

    /// Hands the prepared Warzag to its own helper. Refuses, changing nothing, when no verified manifest describes the
    /// prepared copy or the copy no longer passes, when the installed app cannot be replaced where it is
    /// (`cannotReplace`; the checked copy stays in `stagedApp`), when the helper could not replace this very copy after
    /// Warzag had quit before, and while Warframe or DE's launcher runs. Returns what the helper printed (`.now`).
    @discardableResult
    public func install(_ handoff: AppUpdateHandoff, log: URL?) async throws(AppUpdateFailure) -> String {
        let records = records
        let prepared = try trustedPrepared()
        guard AppManifest.isNewer(prepared.build, than: installed.build) else {
            records.clearPrepared()
            throw .rejected("build \(prepared.build) is not newer than the running build \(installed.build)")
        }
        do {
            try bundles.verify(records.stagedBundle, against: prepared.requirement)
        } catch {
            records.clearPrepared()
            throw .rejected("the prepared copy no longer passes its check: \(error)")
        }
        if let obstacle = location.obstacle(replacing: installed.bundle) { throw .cannotReplace(obstacle) }
        if processes.processRunning(inside: paths.runtimes) != nil { throw .gameRunning }

        var command = AppSwapCommand(home: paths.home.plainPath, installed: installed.bundle.plainPath,
                                     staged: records.stagedBundle.plainPath, version: prepared.version,
                                     build: prepared.build, signer: prepared.requirement.signerFingerprint,
                                     log: log?.plainPath)
        switch handoff {
        case .afterExit(let pid):
            try checkLastSwap(of: prepared)
            let executable = try appExecutable()
            command.probe = true
            let probe = Command(executable: executable, arguments: [AppSwapCommand.appFlag] + command.arguments,
                                timeout: .seconds(120))
            let launcher = launcher
            try await runHelper { try await launcher.run(probe) }
            command.probe = false
            command.waitPID = pid
            command.open = true
            do {
                _ = try launcher.launch(Command(executable: executable,
                                                arguments: [AppSwapCommand.appFlag] + command.arguments))
            } catch {
                throw .cannotReplace("could not start Warzag's update helper: \(Self.describe(error))")
            }
            return ""
        case .now(let reopen):
            if let pid = processes.processRunning(inside: installed.bundle.appending(path: "Contents/MacOS")) {
                throw .cannotReplace("Warzag is running from \(installed.bundle.plainPath) (pid \(pid)); quit it first")
            }
            command.open = reopen
            let swap = Command(executable: records.stagedBundle.appending(path: AppRequirement.helperPath),
                               arguments: ["app", "swap"] + command.arguments, timeout: .seconds(600))
            let runner = runner
            let output = try await runHelper { try await runner.run(swap) }
            records.clearPrepared()
            return output
        }
    }

    /// The checked copy's own executable (CFBundleExecutable in Contents/MacOS, which the bundle check found arm64).
    func appExecutable() throws(AppUpdateFailure) -> URL {
        let bundle = records.stagedBundle
        guard let name = BundleInfo.read(bundle, fileSystem: fileSystem)?["CFBundleExecutable"] as? String,
              !name.isEmpty, !name.contains("/") else {
            throw .rejected("the prepared copy names no executable")
        }
        return bundle.appending(path: "Contents/MacOS/\(name)")
    }

    /// A swap of this very copy that the helper could not make after Warzag had quit (`AppSwapRecord.Result.refused`)
    /// would fail the same way again, after another quit: it is thrown at once instead, and the checked copy stays for
    /// the player. A copy the helper refused (`rejected`) goes, so the next prepare downloads it again. Any other
    /// record makes way for the new try's.
    func checkLastSwap(of prepared: PreparedApp) throws(AppUpdateFailure) {
        let records = records
        guard var record = records.swapRecord() else { return }
        guard record.build == prepared.build else {
            records.clearSwapRecord()
            return
        }
        switch record.result {
        case .refused:
            record.reported = true
            try? records.save(record)
            throw .cannotReplace(record.reason ?? "the last try could not replace Warzag")
        case .rejected:
            records.clearPrepared()
            throw .rejected(record.reason ?? "the update helper refused the prepared copy")
        case .replaced, .stillRunning:
            records.clearSwapRecord()
        }
    }

    @discardableResult
    func runHelper(_ run: () async throws -> ProcessOutput) async throws(AppUpdateFailure) -> String {
        let result: ProcessOutput
        do {
            result = try await run()
        } catch {
            throw .cannotReplace("Warzag's update helper did not finish: \(Self.describe(error))")
        }
        // Its last line says why: the app's helper writes the reason, warzagctl's prefixes it.
        let reason = result.standardError.split(whereSeparator: \.isNewline).last
            .map { String($0).replacingOccurrences(of: "warzagctl app swap: ", with: "") }
            ?? "the update helper exited with status \(result.exitCode)"
        switch result.exitCode {
        case AppSwapExit.replaced: return result.standardOutput
        case AppSwapExit.rejected: throw .rejected(reason)
        default: throw .cannotReplace(reason)
        }
    }

    // MARK: After the swap

    /// Why the swap the new Warzag's helper made once Warzag had quit did not replace Warzag, once: the Warzag that
    /// opens then is the previous one, and learns it only here. nil when it replaced Warzag, when there was none, or
    /// once said. A copy the helper refused (`rejected`) goes; after any other failure the checked copy stays for the
    /// player to drag into Applications, and `install` does not try that build again by quitting.
    public func takeSwapFailure() -> AppUpdateFailure? {
        let records = records
        guard var record = records.swapRecord() else { return nil }
        let reason = record.reason ?? "the update helper did not say why"
        switch record.result {
        case .replaced:
            records.clearSwapRecord()
            removeLeftovers()
            return nil
        case .rejected:
            records.clearPrepared()
            return .rejected(reason)
        case .refused, .stillRunning:
            guard !record.reported else { return nil }
            record.reported = true
            try? records.save(record)
            return .cannotReplace(reason)
        }
    }

    // MARK: Housekeeping

    /// After a check: a prepared copy that is not newer than the installed app (it has been installed, or the player
    /// installed a newer one by hand) and swap copies a failed swap left next to the installed app go.
    func removeLeftovers() {
        let records = records
        if let prepared = records.prepared(), !AppManifest.isNewer(prepared.build, than: installed.build) {
            records.clearPrepared()
        }
        let folder = installed.bundle.deletingLastPathComponent()
        let prefix = AppSwap.swapPrefix(for: installed.bundle)
        for entry in (try? fileSystem.contentsOfDirectory(at: folder)) ?? [] where entry.lastPathComponent.hasPrefix(prefix) {
            try? fileSystem.removeItem(at: entry)
        }
    }

    static func downloadFailure(_ error: any Error) -> AppUpdateFailure {
        switch error {
        case is DigestMismatch, is SizeMismatch: .rejected("the download is not the published archive: \(error)")
        case _ where isOutOfSpace(error): .unreachable(notEnoughSpace(describe(error)))
        default: .unreachable(describe(error))
        }
    }

    /// A step on this Mac that failed: worth trying again later, and said plainly when the disk is full.
    static func localFailure(_ step: String, _ error: any Error) -> AppUpdateFailure {
        let detail = "\(step): \(describe(error))"
        return .unreachable(isOutOfSpace(error) ? notEnoughSpace(detail) : detail)
    }

    static func notEnoughSpace(_ detail: String) -> String { "not enough free disk space: \(detail)" }

    /// The disk or the user's quota ran out (ENOSPC, EDQUOT), however the error carries it: POSIX, Cocoa's "out of
    /// space", an underlying error of either, or ditto's message.
    static func isOutOfSpace(_ error: any Error) -> Bool {
        if let error = error as? AppArchiveError { return error.isOutOfSpace }
        var current: NSError? = error as NSError
        while let error = current {
            if error.domain == NSPOSIXErrorDomain, [Int(ENOSPC), Int(EDQUOT)].contains(error.code) { return true }
            if error.domain == NSCocoaErrorDomain, error.code == CocoaError.fileWriteOutOfSpace.rawValue { return true }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// Whole megabytes, to the nearest.
    static func megabytes(_ bytes: Int64) -> String { "\((bytes + 500_000) / 1_000_000) MB" }

    /// One readable line: Foundation's errors by their localized text, Warzag's by their description.
    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as URLError: error.localizedDescription
        case let error as CocoaError: error.localizedDescription
        case let error as POSIXError: error.localizedDescription
        default: String(describing: error)
        }
    }
}

/// What Warzag keeps about its own updates: the highest accepted app-manifest serial
/// (`WarzagPaths.appUpdateStateFile`) and, in `WarzagPaths.appUpdates`, the manifest the last check accepted, the
/// archive until it has been unpacked, the checked copy (`staging/Warzag.app`), what was prepared (`prepared.json`)
/// and how the helper's last swap ended (`swap-result.json`, `AppSwapRecord`).
struct AppUpdateRecords {
    static let appName = AppManifest.bundleName

    let paths: WarzagPaths
    let fileSystem: any FileSystem

    var manifestFile: URL { paths.appUpdates.appending(path: "manifest.json") }
    var preparedFile: URL { paths.appUpdates.appending(path: "prepared.json") }
    var swapRecordFile: URL { paths.appUpdates.appending(path: "swap-result.json") }
    var stagingDirectory: URL { paths.appUpdates.appending(path: "staging", directoryHint: .isDirectory) }
    var stagedBundle: URL { stagingDirectory.appending(path: Self.appName, directoryHint: .isDirectory) }

    /// Version and build are plain numbers by now (`AppManifestVerifier`).
    func archive(for manifest: AppManifest) -> URL {
        paths.appUpdates.appending(path: "Warzag-\(manifest.version)-\(manifest.build).zip")
    }

    /// Other builds' archives, and what their downloads left, go.
    func removeArchives(except archive: URL) {
        let name = archive.lastPathComponent
        for entry in (try? fileSystem.contentsOfDirectory(at: paths.appUpdates)) ?? []
        where entry.lastPathComponent.hasPrefix("Warzag-") && !entry.lastPathComponent.hasPrefix(name) {
            try? fileSystem.removeItem(at: entry)
        }
    }

    struct State: Codable, Equatable {
        var schema = 1
        var lastSerial: UInt64?
    }

    func lastSerial() -> UInt64? {
        guard let data = try? fileSystem.contents(of: paths.appUpdateStateFile),
              let state = try? WarzagJSON.decoder().decode(State.self, from: data), state.schema == 1 else { return nil }
        return state.lastSerial
    }

    /// Raises the serial floor to `manifest`'s (never lowers it).
    func accept(_ manifest: AppManifest) throws {
        let floor = max(lastSerial() ?? 0, manifest.serial)
        guard floor != lastSerial() else { return }
        try fileSystem.writeAtomically(try WarzagJSON.encoder(pretty: true).encode(State(lastSerial: floor)),
                                       to: paths.appUpdateStateFile)
    }

    func prepared() -> PreparedApp? {
        guard let data = try? fileSystem.contents(of: preparedFile) else { return nil }
        return try? WarzagJSON.decoder().decode(PreparedApp.self, from: data)
    }

    func save(_ prepared: PreparedApp) throws {
        try fileSystem.writeAtomically(try WarzagJSON.encoder(pretty: true).encode(prepared), to: preparedFile)
    }

    func swapRecord() -> AppSwapRecord? {
        guard let data = try? fileSystem.contents(of: swapRecordFile),
              let record = try? WarzagJSON.decoder().decode(AppSwapRecord.self, from: data), record.schema == 1 else {
            return nil
        }
        return record
    }

    func save(_ record: AppSwapRecord) throws {
        try fileSystem.writeAtomically(try WarzagJSON.encoder(pretty: true).encode(record), to: swapRecordFile)
    }

    func clearSwapRecord() {
        try? fileSystem.removeItem(at: swapRecordFile)
    }

    /// No prepared update: its record, its copy and what the helper said about it go.
    func clearPrepared() {
        try? fileSystem.removeItem(at: preparedFile)
        try? fileSystem.removeItem(at: stagingDirectory)
        clearSwapRecord()
    }
}
