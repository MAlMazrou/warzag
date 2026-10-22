import ContentKit
import EngineKit
import Foundation
import WarzagCore
import WineKit

/// Tunables of the content flow.
public struct ContentConfiguration: Sendable, Equatable {
    public static let defaultInstallerURL = URL(string: "https://content.warframe.com/dl/Warframe.msi")!
    /// Size of Steam's single depot for app 230410. Only an estimate of a DirectX 11 install, so progress against it
    /// stays below 100% until DE's launcher says it is done.
    public static let defaultExpectedContentBytes: Int64 = 55_700_000_000

    public var installerURL: URL
    public var installer: InstallerExpectations
    public var expectedContentBytes: Int64
    /// No real progress for this long is a stall (`StallWatchdog` says what counts).
    public var stallTimeout: TimeInterval
    /// The same while DE's launcher defragments the caches after the applet: it rewrites files in place, so the
    /// library does not grow, and it logs nothing until the step ends.
    public var finishingStallTimeout: TimeInterval
    /// Restarts of DE's launcher after a stall or an unexpected exit, before reporting "stuck".
    public var maximumRestarts: Int
    public var pollInterval: Duration
    public var sizeSampleInterval: TimeInterval
    public var registryPollInterval: TimeInterval
    /// A launcher without an accepted EULA that writes its first lines and then goes quiet this long is assumed to
    /// show its EULA, even when its log does not say so.
    public var eulaPromptAfter: TimeInterval
    /// The most time one launcher attempt may spend on that assumption. It pauses the stall watchdog, so without a
    /// limit a launcher that hangs quietly at its start would never be restarted.
    public var eulaGuessLimit: TimeInterval
    /// With ReadEula already set, DE's EULA step passes at once; if it lingers this long, the EULA changed.
    public var eulaLingerBeforePrompt: TimeInterval
    /// How long DE's launcher gets to close by itself before `wineserver -k`.
    public var closeGracePeriod: TimeInterval
    /// After this long without a finished update, status says "needs update".
    public var updateStaleAfter: TimeInterval

    public init(installerURL: URL = ContentConfiguration.defaultInstallerURL,
                installer: InstallerExpectations = InstallerExpectations(),
                expectedContentBytes: Int64 = ContentConfiguration.defaultExpectedContentBytes,
                stallTimeout: TimeInterval = 180, finishingStallTimeout: TimeInterval = 900, maximumRestarts: Int = 2,
                pollInterval: Duration = .seconds(1),
                sizeSampleInterval: TimeInterval = 5, registryPollInterval: TimeInterval = 5,
                eulaPromptAfter: TimeInterval = 20, eulaGuessLimit: TimeInterval = 600,
                eulaLingerBeforePrompt: TimeInterval = 3,
                closeGracePeriod: TimeInterval = 15, updateStaleAfter: TimeInterval = 24 * 3600) {
        self.installerURL = installerURL
        self.installer = installer
        self.expectedContentBytes = expectedContentBytes
        self.stallTimeout = stallTimeout
        self.finishingStallTimeout = finishingStallTimeout
        self.maximumRestarts = maximumRestarts
        self.pollInterval = pollInterval
        self.sizeSampleInterval = sizeSampleInterval
        self.registryPollInterval = registryPollInterval
        self.eulaPromptAfter = eulaPromptAfter
        self.eulaGuessLimit = eulaGuessLimit
        self.eulaLingerBeforePrompt = eulaLingerBeforePrompt
        self.closeGracePeriod = closeGracePeriod
        self.updateStaleAfter = updateStaleAfter
    }
}

public enum LauncherRunMode: String, Sendable, Codable {
    /// First download after Warframe.msi was unpacked.
    case install
    /// Bring an installed game up to date (before every Play).
    case update
}

public enum LauncherRestartReason: String, Sendable, Codable, Equatable {
    /// No real progress for `stallTimeout` (`StallWatchdog`).
    case stalled
    /// DE's launcher ended before it finished (crash, or closed by hand).
    case exited
}

/// What the content flow is doing, for progress UI. Reported on every poll, so values can repeat.
public enum ContentRunState: Equatable, Sendable {
    case downloadingInstaller(receivedBytes: Int64, totalBytes: Int64?)
    case checkingInstaller
    case installerChecked(sha256: String, authenticode: AuthenticodeVerdict)
    case extractingInstaller
    case startingLauncher(attempt: Int)
    /// DE's window shows its EULA: the player has to read it and click I AGREE. Warzag never accepts it.
    case needsEULA
    /// DE's launcher went quiet at its start without its log naming the EULA step: it probably shows its EULA. Only a
    /// guess, reported for at most `ContentConfiguration.eulaGuessLimit` per attempt.
    case mayNeedEULA
    /// DE's launcher downloads. `bytesThisRun`: library growth since the launcher started; `bytesOnDisk`: the whole
    /// library; `expectedBytes`: a complete install's size for a first install, nil for an update (its size is not
    /// known in advance). The rate comes from "Downloading @ N MB/s".
    case downloading(bytesThisRun: Int64, bytesOnDisk: Int64, expectedBytes: Int64?, megabytesPerSecond: Double?)
    /// DE's ContentUpdate applet; the fraction comes from its byte counters.
    case preprocessing(fraction: Double?)
    case finishing
    case restartingLauncher(attempt: Int, reason: LauncherRestartReason)
    case closingLauncher
    case complete(seconds: Double?)
    case stuck(LauncherRestartReason)
    /// A problem that did not stop the run, such as a Wine tool stopped at its deadline.
    case warning(String)
}

public enum LauncherRunOutcome: Equatable, Sendable {
    /// "Total time:" was logged; DE's launcher has been closed.
    case completed(seconds: Double?)
    /// DE's launcher was closed while its EULA was showing.
    case eulaDeclined
    /// Still stalled (or ending early) after `maximumRestarts` restarts.
    case stuck(LauncherRestartReason)
}

public enum ContentError: Error, Equatable, CustomStringConvertible {
    case prefixNotReady([PrefixIssue])
    case notInstalled
    case extractionFailed(String)
    case launcherDidNotStart(String)
    /// The copy of Warframe.msi handed to msiexec is not the file that was verified.
    case stagedInstallerChanged(expected: String, actual: String)
    /// DE's launcher could not be kept on DirectX 11 (its registry setting).
    case directX11NotPinned(String)

    public var description: String {
        switch self {
        case .prefixNotReady(let issues): "the prefix is not ready: " + issues.map(\.description).joined(separator: "; ")
        case .notInstalled: "Warframe is not installed yet"
        case .extractionFailed(let reason): "could not unpack Warframe.msi: \(reason)"
        case .launcherDidNotStart(let reason): "could not start DE's launcher: \(reason)"
        case .stagedInstallerChanged(let expected, let actual):
            "the copy of Warframe.msi for msiexec has SHA-256 \(actual), not the verified \(expected)"
        case .directX11NotPinned(let reason): "could not keep DE's launcher on DirectX 11: \(reason)"
        }
    }
}

/// Why the prefix's process list could not be read (`ContentService.runningImages()`): the tool's problem as
/// `runTool` reports it, or that it listed nothing.
struct ProcessListUnavailable: Error, Equatable, CustomStringConvertible {
    var description: String
}

/// Installed / needs update / not installed, from the files and logs on disk (no network, nothing started).
public struct ContentStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case installed
        case needsUpdate
        case notInstalled
    }

    public var state: State
    /// One sentence for the UI.
    public var reason: String
    public var library: String
    public var launcherPresent: Bool
    public var gamePresent: Bool
    /// Warframe.x64.exe's modification time (DE's launcher replaces it on updates).
    public var gameModified: Date?
    public var lastUpdate: Date?
    /// "warzag" (Warzag ran the update) or "Launcher.log" (DE's log says a run finished).
    public var lastUpdateSource: String?
    public var libraryBytes: Int64?
    /// The build Warframe reported when it last started (EE.log's "Build Label"); nil before its first start.
    public var build: String?
}

/// When an update last finished, written by Warzag next to setup.json.
struct ContentRecord: Codable, Equatable {
    static let schemaVersion = 1
    var schema = ContentRecord.schemaVersion
    var library: String
    var lastUpdate: Date
    var mode: LauncherRunMode
    var launcherSeconds: Double?
}

/// The stall watchdog of one launcher attempt. Only real progress resets it: the library growing past its largest
/// size so far, a download rate above zero, the applet's counters moving, or DE's step list moving on. Other lines
/// (hashing, HTTP requests, retries) are not progress: a launcher that keeps talking without getting anywhere has
/// stalled. It is paused while the EULA waits for the player.
struct StallWatchdog: Equatable, Sendable {
    private(set) var lastProgress: Date
    private(set) var largestLibrary: Int64
    private(set) var isPaused = false
    private var appletCounter: (done: Int64, total: Int64)?
    private var preprocessCounter: (done: Int64, total: Int64)?

    init(start: Date, librarySize: Int64) {
        lastProgress = start
        largestLibrary = librarySize
    }

    static func == (lhs: StallWatchdog, rhs: StallWatchdog) -> Bool {
        lhs.lastProgress == rhs.lastProgress && lhs.largestLibrary == rhs.largestLibrary && lhs.isPaused == rhs.isPaused
            && lhs.appletCounter?.done == rhs.appletCounter?.done && lhs.appletCounter?.total == rhs.appletCounter?.total
            && lhs.preprocessCounter?.done == rhs.preprocessCounter?.done
            && lhs.preprocessCounter?.total == rhs.preprocessCounter?.total
    }

    /// A new measurement of the library's size on disk.
    mutating func library(_ bytes: Int64, at now: Date) {
        guard bytes > largestLibrary else { return }
        largestLibrary = bytes
        progressed(at: now)
    }

    /// An event from Launcher.log.
    mutating func observe(_ event: LauncherEvent, at now: Date) {
        switch event {
        case .rate(let megabytesPerSecond):
            if megabytesPerSecond > 0 { progressed(at: now) }
        case .runStarted, .phaseFinished, .bytesTotal, .appletStarted, .appletExited, .totalTime:
            progressed(at: now)
        case .content(let event):
            observeApplet(event, at: now)
        }
    }

    /// An event from Preprocess.log (or one ContentKit's rules found in Launcher.log).
    mutating func observeApplet(_ event: ContentEvent, at now: Date) {
        switch event {
        case .launcherDownloaded(let done, let total):
            // A new counter (another phase of the applet) or a higher count.
            if appletCounter.map({ $0.total != total || done > $0.done }) ?? true { progressed(at: now) }
            appletCounter = (done, total)
        case .launcherPreprocess(let done, let total):
            if preprocessCounter.map({ $0.total != total || done > $0.done }) ?? true { progressed(at: now) }
            preprocessCounter = (done, total)
        case .assetsToDownload, .preprocessDone, .logRestarted, .updateRestarting:
            progressed(at: now)
        default:
            break
        }
    }

    /// The player has DE's EULA in front of them: waiting is not a stall.
    mutating func pause() {
        isPaused = true
    }

    /// The EULA has gone away: a fresh window from now.
    mutating func resume(at now: Date) {
        guard isPaused else { return }
        isPaused = false
        lastProgress = now
    }

    func isStalled(at now: Date, timeout: TimeInterval) -> Bool {
        !isPaused && now.timeIntervalSince(lastProgress) >= timeout
    }

    private mutating func progressed(at now: Date) {
        if now > lastProgress { lastProgress = now }
    }
}

/// Installs and updates Warframe with DE's own tools: Warframe.msi unpacked with `msiexec /a` into X:\, then
/// `X:\Tools\Launcher.exe -cluster:public -registry:Steam` on DXMT, watched through Launcher.log, the library's size
/// and the prefix's registry, and closed once it logs "Total time:". The launcher gets no Steam variables, so Steam
/// never shows "Playing" during downloads.
///
/// Every Wine tool run has a deadline (`WineTool.timeout`); one that passes it is stopped, written to the tool log and
/// reported (`ContentRunState.warning`, or an error when the step cannot go on).
public struct ContentService: Sendable {
    public let installation: GameInstallation
    public let context: GameContext
    public let configuration: ContentConfiguration

    public init(installation: GameInstallation, context: GameContext,
                configuration: ContentConfiguration = ContentConfiguration()) {
        self.installation = installation
        self.context = context
        self.configuration = configuration
    }

    public var inspector: PrefixInspector {
        PrefixInspector(installation: installation, fileSystem: context.fileSystem, files: context.files,
                        probe: context.probe)
    }

    static let eulaKey = #"Software\Digital Extremes\Warframe\SteamLauncher"#

    /// `ReadEula` is set (DE stores the MD5 of the accepted EULA). Read from user.reg, which wineserver saves up to 30
    /// seconds after a change and when it exits.
    public func eulaAcceptedInRegistry() -> Bool {
        let registry = WineRegistryHive.load(installation.userRegistry, fileSystem: context.fileSystem)
        return !(registry?.string(Self.eulaKey, "ReadEula") ?? "").isEmpty
    }

    // MARK: - Install and update

    /// Unpacks the installer when the library has no launcher yet, then runs DE's launcher for the first download.
    public func install(installer: any InstallerProviding,
                        progress: @escaping @Sendable (ContentRunState) -> Void) async throws -> LauncherRunOutcome {
        if !context.fileSystem.fileExists(at: installation.launcherExecutable) {
            let verified = try await installer.installer(progress: progress)
            // Cancelled while the installer was fetched or checked: start nothing in the prefix.
            try Task.checkCancellation()
            progress(.extractingInstaller)
            try await extractInstaller(verified)
        }
        return try await runLauncher(.install, progress: progress)
    }

    /// Runs DE's launcher once to bring an installed game up to date.
    public func update(progress: @escaping @Sendable (ContentRunState) -> Void) async throws -> LauncherRunOutcome {
        guard context.fileSystem.fileExists(at: installation.gameExecutable) else { throw ContentError.notInstalled }
        return try await runLauncher(.update, progress: progress)
    }

    // MARK: - Warframe.msi

    /// The name the installer gets inside the prefix (`C:\windows\temp`), so `msiexec` never depends on a Z: drive.
    static let stagedInstallerName = "warzag-Warframe.msi"

    /// `msiexec /a <msi> /qn TARGETDIR=X:\`, then `X:\LocalAppDataFolder\Warframe\Downloaded\Public\*` moved to the
    /// library root, which gives the Steam layout (`X:\Tools\Launcher.exe`). The copy msiexec reads is hashed again
    /// and must be the file that was verified.
    public func extractInstaller(_ installer: VerifiedInstaller) async throws {
        let fileSystem = context.fileSystem
        // X: must reach an existing folder before anything can be written through it.
        try fileSystem.createDirectory(at: installation.library)
        let issues = inspector.issues(for: .extractInstaller)
        guard issues.isEmpty else { throw ContentError.prefixNotReady(issues) }

        let staged = installation.prefix.windowsTemp.appending(path: Self.stagedInstallerName)
        try context.files.copyItem(at: installer.url, to: staged)
        defer { try? fileSystem.removeItem(at: staged) }
        let stagedDigest = try InstallerChecks.sha256(of: staged, fileSystem: fileSystem)
        guard stagedDigest == installer.sha256.lowercased() else {
            throw ContentError.stagedInstallerChanged(expected: installer.sha256.lowercased(), actual: stagedDigest)
        }
        let command = WineTool.msiexecAdministrative(
            package: #"C:\windows\temp\"# + Self.stagedInstallerName, targetDirectory: GameInstallation.libraryRoot
        ).command(host: installation.host, prefix: installation.prefix.root, inherited: context.inheritedEnvironment,
                  logFile: context.toolLog)
        let output: ProcessOutput
        do {
            output = try await context.runner.run(command)
        } catch let timeout as ProcessTimedOut {
            note("msiexec /a did not finish within \(timeout.seconds) s and was stopped; stopping the prefix")
            _ = await runTool(.wineserverKill)
            throw ContentError.extractionFailed("msiexec did not finish within \(timeout.seconds) s and was stopped")
        } catch is CancellationError {
            // The runner stopped msiexec itself; what it started (its custom actions, the wineserver) may still write
            // into the library.
            await stopPrefixAfterCancelledExtraction()
            throw CancellationError()
        }
        if Task.isCancelled {
            // A runner that returned anyway (cancelled just as msiexec ended): never carry on into the library.
            await stopPrefixAfterCancelledExtraction()
            throw CancellationError()
        }
        // Like `wineserver -w`: everything msiexec started has finished writing.
        _ = await waitUntilPrefixIsIdle(timeout: 120)
        guard output.succeeded else { throw ContentError.extractionFailed("msiexec exited with status \(output.exitCode)") }

        // An administrative install also leaves a copy of the package in TARGETDIR.
        let packageCopy = installation.library.appending(path: Self.stagedInstallerName)
        if fileSystem.fileExists(at: packageCopy) { try? fileSystem.removeItem(at: packageCopy) }
        try moveDownloadedTree()
        guard fileSystem.fileExists(at: installation.launcherExecutable) else {
            throw ContentError.extractionFailed(#"the package did not contain Tools\Launcher.exe"#)
        }
    }

    /// After a cancelled `msiexec /a`: `wineserver -k` for the rest of the prefix, in a task the cancellation does not
    /// reach, before giving up.
    private func stopPrefixAfterCancelledExtraction() async {
        note("cancelled while msiexec /a ran; stopping the prefix")
        let service = self
        await Task.detached {
            _ = await service.runTool(.wineserverKill)
            _ = await service.waitUntilPrefixIsIdle(timeout: 10)
        }.value
    }

    /// Where the administrative install puts DE's files, relative to TARGETDIR.
    static let extractedTree = ["LocalAppDataFolder", "Warframe", "Downloaded", "Public"]

    func moveDownloadedTree() throws {
        let fileSystem = context.fileSystem
        var directory = installation.library
        for name in Self.extractedTree {
            guard let next = try fileSystem.contentsOfDirectory(at: directory).first(where: {
                $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame && fileSystem.directoryExists(at: $0)
            }) else { return }
            directory = next
        }
        for item in try fileSystem.contentsOfDirectory(at: directory) {
            try merge(item, into: installation.library.appending(path: item.lastPathComponent))
        }
        // Remove the emptied chain, deepest first, never anything that still holds files.
        while directory.standardized.plainPath != installation.library.plainPath {
            guard (try? fileSystem.contentsOfDirectory(at: directory))?.isEmpty == true else { break }
            try? fileSystem.removeItem(at: directory)
            directory = directory.deletingLastPathComponent()
        }
    }

    private func merge(_ source: URL, into destination: URL) throws {
        let fileSystem = context.fileSystem
        guard fileSystem.fileExists(at: destination) else {
            try fileSystem.moveItem(at: source, to: destination)
            return
        }
        if fileSystem.directoryExists(at: source), fileSystem.directoryExists(at: destination) {
            for child in try fileSystem.contentsOfDirectory(at: source) {
                try merge(child, into: destination.appending(path: child.lastPathComponent))
            }
            try? fileSystem.removeItem(at: source)
        } else {
            // A file from the package replaces the old one (repairing a damaged Tools folder).
            try fileSystem.removeItem(at: destination)
            try fileSystem.moveItem(at: source, to: destination)
        }
    }

    // MARK: - DirectX 11

    /// Where DE's launcher keeps its settings: `GraphicsAPI` lives under `Launcher` (0 = DirectX 11, DE's default);
    /// `-registry:Steam` adds `SteamLauncher`.
    static let launcherSettingsKey = #"Software\Digital Extremes\Warframe\Launcher"#
    static let steamLauncherSettingsKey = #"Software\Digital Extremes\Warframe\SteamLauncher"#
    static let directX11RegistryName = "warzag-directx11.reg"

    /// Keeps DE's launcher on DirectX 11 before its bulk download fetches the chosen API's caches. Sets `GraphicsAPI`
    /// to 0 under `Launcher` when it is missing or names another API, and under `SteamLauncher` only when it names
    /// another API. Reads user.reg, so it is meant for a prefix where nothing runs. Returns whether it wrote anything.
    @discardableResult
    public func pinDirectX11() async throws -> Bool {
        let registry = WineRegistryHive.load(installation.userRegistry, fileSystem: context.fileSystem)
        var file = RegistryFile()
        if registry?.value(Self.launcherSettingsKey, "GraphicsAPI") != .dword(0) {
            file.set(.currentUser, Self.launcherSettingsKey, "GraphicsAPI", .dword(0))
        }
        if case .dword(let api)? = registry?.value(Self.steamLauncherSettingsKey, "GraphicsAPI"), api != 0 {
            file.set(.currentUser, Self.steamLauncherSettingsKey, "GraphicsAPI", .dword(0))
        }
        guard !file.keys.isEmpty else { return false }
        try Task.checkCancellation()
        let staged = installation.prefix.windowsTemp.appending(path: Self.directX11RegistryName)
        try context.fileSystem.writeAtomically(try file.data(), to: staged)
        defer { try? context.fileSystem.removeItem(at: staged) }
        let command = WineTool.regImport(windowsPath: #"C:\windows\temp\"# + Self.directX11RegistryName)
            .command(host: installation.host, prefix: installation.prefix.root,
                     inherited: context.inheritedEnvironment, logFile: context.toolLog)
        let output: ProcessOutput
        do {
            output = try await context.runner.run(command)
        } catch let timeout as ProcessTimedOut {
            note("reg import \(Self.directX11RegistryName) did not finish within \(timeout.seconds) s and was stopped; "
                + "stopping the prefix")
            _ = await runTool(.wineserverKill)
            throw ContentError.directX11NotPinned("reg import did not finish within \(timeout.seconds) s")
        }
        guard output.succeeded else {
            throw ContentError.directX11NotPinned("reg import exited with status \(output.exitCode)")
        }
        return true
    }

    // MARK: - DE's launcher

    /// `X:\Tools\Launcher.exe -cluster:public -registry:Steam` from `X:\Tools`, on DXMT, without Steam variables.
    /// `hidden`: no window and no Dock icon (WARZAG_HIDE_WINDOWS=1, engine patch wz-n-0010), for runs where the
    /// player has nothing to do in DE's window.
    public func launcherCommand(hidden: Bool = false) -> Command {
        var environment = WineEnvironment.gameSession(
            prefix: installation.prefix.root, host: installation.host, renderer: RendererOptions(renderer: .dxmt),
            steam: nil, inherited: context.inheritedEnvironment)
        if hidden { environment["WARZAG_HIDE_WINDOWS"] = "1" }
        // Wine maps the Unix working directory to the deepest drive that holds it, so the library's Tools folder
        // becomes X:\Tools.
        return Command(executable: installation.host.wine,
                       arguments: [GameInstallation.launcherWindowsPath] + GameInstallation.launcherArguments,
                       environment: environment, workingDirectory: installation.toolsDirectory,
                       logFile: context.launcherOutputLog)
    }

    /// Runs DE's launcher until it reports "Total time:", restarting it after a stall or an unexpected exit, then
    /// closes it so Warzag can start the game itself. Cancelling the task closes the launcher the same way.
    public func runLauncher(_ mode: LauncherRunMode,
                            progress: @escaping @Sendable (ContentRunState) -> Void) async throws -> LauncherRunOutcome {
        let issues = inspector.issues(for: .runLauncher)
        guard issues.isEmpty else { throw ContentError.prefixNotReady(issues) }
        // Before DE's launcher reads its settings. A failure is only reported: DirectX 11 is DE's default.
        do {
            try await pinDirectX11()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            progress(.warning(String(describing: error)))
        }

        // Progress counts from here, so an update shows its own size, not the whole library.
        let libraryAtLaunch = context.files.diskUsage(of: installation.library)
        var restarts = 0
        while true {
            let attempt = try await superviseLauncher(mode: mode, attempt: restarts, libraryAtLaunch: libraryAtLaunch,
                                                      progress: progress)
            switch attempt.result {
            case .complete(let seconds):
                progress(.closingLauncher)
                for problem in await closeLauncher(attempt.process) { progress(.warning(problem)) }
                recordUpdate(mode: mode, seconds: seconds)
                progress(.complete(seconds: seconds))
                return .completed(seconds: seconds)
            case .eulaDeclined:
                return .eulaDeclined
            case .needsRestart(let reason):
                if reason == .stalled {
                    progress(.closingLauncher)
                    for problem in await closeLauncher(attempt.process) { progress(.warning(problem)) }
                }
                guard restarts < configuration.maximumRestarts else {
                    progress(.stuck(reason))
                    return .stuck(reason)
                }
                restarts += 1
                progress(.restartingLauncher(attempt: restarts, reason: reason))
            }
        }
    }

    private struct Attempt {
        enum Result {
            case complete(Double?)
            case eulaDeclined
            case needsRestart(LauncherRestartReason)
        }

        var result: Result
        var process: any RunningProcess
    }

    private func superviseLauncher(mode: LauncherRunMode, attempt: Int, libraryAtLaunch: Int64,
                                   progress: @escaping @Sendable (ContentRunState) -> Void) async throws -> Attempt {
        let fileSystem = context.fileSystem
        let clock = context.clock
        let prefix = installation.prefix
        var launcherLog = LogTailer(url: prefix.launcherLog)
        var preprocessLog = LogTailer(url: prefix.preprocessLog)
        let launcherParser = LogParser(kind: .launcher, rules: LauncherLog.ruleSet)
        let preprocessParser = LogParser(kind: .preprocess)
        // Only this run counts: the previous run's "Total time:" is still in the file.
        try launcherLog.seekToEnd(fileSystem)
        try preprocessLog.seekToEnd(fileSystem)
        var registryAccepted = eulaAcceptedInRegistry()
        // Hidden once DE's EULA is accepted. A restart shows the window again, in case the launcher waits for the
        // player.
        let hidden = registryAccepted && attempt == 0

        // A run cancelled during the previous attempt's close (which waits without throwing) starts nothing new.
        try Task.checkCancellation()
        progress(.startingLauncher(attempt: attempt))
        let process: any RunningProcess
        do {
            process = try context.launcher.launch(launcherCommand(hidden: hidden))
        } catch {
            throw ContentError.launcherDidNotStart(String(describing: error))
        }

        let started = clock.now
        var state = LauncherLogState()
        var librarySize = context.files.diskUsage(of: installation.library)
        var watchdog = StallWatchdog(start: started, librarySize: librarySize)
        // Any line of Launcher.log: a launcher that writes is not waiting for the player.
        var lastLauncherLine = started
        var launcherLines = 0
        var nextSizeSample = started.addingTimeInterval(configuration.sizeSampleInterval)
        var nextRegistryRead = started.addingTimeInterval(configuration.registryPollInterval)
        var eulaStepSince: Date?
        // Time this attempt has spent assuming a quiet launcher shows its EULA (capped by `eulaGuessLimit`).
        var eulaGuessed: TimeInterval = 0
        var lastPoll = started

        func readLogs(at now: Date) {
            if let chunk = try? launcherLog.poll(fileSystem) {
                if chunk.restarted {
                    state.apply(.content(.logRestarted))
                    watchdog.observeApplet(.logRestarted, at: now)
                }
                for line in chunk.lines {
                    if !line.allSatisfy(\.isWhitespace) {
                        lastLauncherLine = now
                        launcherLines += 1
                    }
                    guard let event = launcherParser.event(for: line).map(LauncherEvent.init) else { continue }
                    state.apply(event)
                    watchdog.observe(event, at: now)
                }
            }
            if let chunk = try? preprocessLog.poll(fileSystem) {
                if chunk.restarted {
                    state.applyApplet(.logRestarted)
                    watchdog.observeApplet(.logRestarted, at: now)
                }
                for line in chunk.lines {
                    guard let event = preprocessParser.event(for: line) else { continue }
                    state.applyApplet(event)
                    watchdog.observeApplet(event, at: now)
                }
            }
        }

        do {
            while true {
                try await clock.sleep(for: configuration.pollInterval)
                let now = clock.now
                readLogs(at: now)
                if now >= nextSizeSample {
                    librarySize = context.files.diskUsage(of: installation.library)
                    watchdog.library(librarySize, at: now)
                    nextSizeSample = now.addingTimeInterval(configuration.sizeSampleInterval)
                }
                if !registryAccepted, now >= nextRegistryRead {
                    registryAccepted = eulaAcceptedInRegistry()
                    nextRegistryRead = now.addingTimeInterval(configuration.registryPollInterval)
                }
                if state.isComplete { return Attempt(result: .complete(state.totalSeconds), process: process) }

                if state.atEULAStep {
                    if eulaStepSince == nil { eulaStepSince = now }
                } else {
                    eulaStepSince = nil
                }
                // The log shows the launcher waiting at its EULA step. With ReadEula already set the step passes at
                // once, so a lingering step means DE changed its EULA and shows it again.
                let eulaShowing = eulaStepSince.map {
                    !registryAccepted || now.timeIntervalSince($0) >= configuration.eulaLingerBeforePrompt
                } ?? false
                // The log does not name the EULA step (DE may reword it): no EULA accepted yet, and the launcher wrote
                // its first lines and then went quiet. A guess that pauses the watchdog, so at most `eulaGuessLimit`
                // per attempt.
                let quietAtStart = !registryAccepted && state.phase == .starting && launcherLines > 0
                    && now.timeIntervalSince(lastLauncherLine) >= configuration.eulaPromptAfter
                    && now.timeIntervalSince(started) >= configuration.eulaPromptAfter
                let eulaLikely = quietAtStart && !eulaShowing && eulaGuessed < configuration.eulaGuessLimit
                if eulaLikely { eulaGuessed += now.timeIntervalSince(lastPoll) }
                lastPoll = now

                // A self-updating launcher replaces its own process, so the prefix being busy also counts.
                let alive = process.isRunning || context.probe.wineserver(for: prefix.root) != nil
                if !alive {
                    readLogs(at: now)
                    if state.isComplete { return Attempt(result: .complete(state.totalSeconds), process: process) }
                    if state.atEULAStep { return Attempt(result: .eulaDeclined, process: process) }
                    return Attempt(result: .needsRestart(.exited), process: process)
                }

                // Waiting for the player is not a stall; the window starts over once the EULA is gone.
                if eulaShowing || eulaLikely {
                    watchdog.pause()
                } else {
                    watchdog.resume(at: now)
                }
                let stallTimeout = state.phase == .finishing
                    ? configuration.finishingStallTimeout : configuration.stallTimeout
                if watchdog.isStalled(at: now, timeout: stallTimeout) {
                    return Attempt(result: .needsRestart(.stalled), process: process)
                }
                progress(runState(state, mode: mode, eula: eulaShowing ? .showing : eulaLikely ? .guessed : nil,
                                  librarySize: librarySize, libraryAtLaunch: libraryAtLaunch, attempt: attempt))
            }
        } catch {
            // Cancelled: close DE's launcher as for a finished run. closeLauncher runs detached, so the cancellation
            // does not cut the grace period short.
            _ = await closeLauncher(process)
            throw error
        }
    }

    /// How sure the run is that DE's window shows its EULA.
    private enum EULAPrompt {
        /// The log shows the EULA step (or it lingers although ReadEula is set: DE changed its EULA).
        case showing
        /// The launcher went quiet at its start (`ContentRunState.mayNeedEULA`).
        case guessed
    }

    private func runState(_ state: LauncherLogState, mode: LauncherRunMode, eula: EULAPrompt?, librarySize: Int64,
                          libraryAtLaunch: Int64, attempt: Int) -> ContentRunState {
        switch eula {
        case .showing: return .needsEULA
        case .guessed: return .mayNeedEULA
        case nil: break
        }
        switch state.phase {
        case .starting, .eula: return .startingLauncher(attempt: attempt)
        case .downloading:
            return .downloading(bytesThisRun: max(0, librarySize - libraryAtLaunch), bytesOnDisk: librarySize,
                                expectedBytes: mode == .install ? configuration.expectedContentBytes : nil,
                                megabytesPerSecond: state.megabytesPerSecond)
        case .preprocessing: return .preprocessing(fraction: state.applet.fraction)
        case .finishing: return .finishing
        case .complete: return .complete(seconds: state.totalSeconds)
        }
    }

    /// Closes DE's launcher: WM_CLOSE (`taskkill` without /F), up to `closeGracePeriod` for the prefix to go idle (a
    /// launcher that updated itself runs on as a successor Warzag never started), then `wineserver -k`. Runs detached
    /// so a cancellation cannot skip the tools. Returns the problems to report (a tool that passed its deadline).
    @discardableResult
    public func closeLauncher(_ process: (any RunningProcess)?, waiting: Bool = true) async -> [String] {
        let service = self
        return await Task.detached { await service.closeLauncherNow(process, waiting: waiting) }.value
    }

    private func closeLauncherNow(_ process: (any RunningProcess)?, waiting: Bool) async -> [String] {
        let prefix = installation.prefix.root
        var problems: [String] = []
        if let problem = await runTool(.taskkill(imageName: GameInstallation.launcherImageName)) {
            problems.append(problem)
        }
        if waiting {
            await waitUntil(timeout: configuration.closeGracePeriod) {
                !(process?.isRunning ?? false) && context.probe.wineserver(for: prefix) == nil
            }
        }
        if let problem = await runTool(.wineserverKill) { problems.append(problem) }
        if waiting {
            await waitUntil(timeout: 10) {
                !(process?.isRunning ?? false) && context.probe.wineserver(for: prefix) == nil
            }
        }
        if let process, process.isRunning { process.terminate() }
        return problems
    }

    /// Runs a short Wine tool in the prefix with its deadline. Returns nil when it ran (whatever its exit status: a
    /// `taskkill` that finds nothing to close is fine), else what happened, also written to the tool log.
    func runTool(_ tool: WineTool) async -> String? {
        let command = tool.command(host: installation.host, prefix: installation.prefix.root,
                                   inherited: context.inheritedEnvironment, logFile: context.toolLog)
        do {
            _ = try await context.runner.run(command)
            return nil
        } catch let timeout as ProcessTimedOut {
            let problem = "\(tool.name) did not finish within \(timeout.seconds) s and was stopped"
            note(problem)
            return problem
        } catch {
            let problem = "\(tool.name) could not run: \(error)"
            note(problem)
            return problem
        }
    }

    /// Where `runningImages()` has cmd write tasklist's answer, in `C:\windows\temp`.
    static let processListName = "warzag-tasklist.txt"

    /// The lowercased image names of the processes running in the prefix: `tasklist /nh /fo csv`, written by cmd
    /// itself into C:\windows\temp so Wine's own messages cannot mix in. Fails (also in the tool log) when the tool did
    /// not run or listed nothing.
    func runningImages() async -> Result<Set<String>, ProcessListUnavailable> {
        let file = installation.prefix.windowsTemp.appending(path: Self.processListName)
        // Never an answer left from an earlier run.
        try? context.fileSystem.removeItem(at: file)
        defer { try? context.fileSystem.removeItem(at: file) }
        let tool = WineTool.cmd(["tasklist", "/nh", "/fo", "csv", ">", #"C:\windows\temp\"# + Self.processListName])
        if let problem = await runTool(tool) { return .failure(ProcessListUnavailable(description: problem)) }
        guard let data = try? context.fileSystem.contents(of: file),
              let images = Self.imageNames(tasklistCSV: String(decoding: data, as: UTF8.self)) else {
            let problem = "\(tool.name) listed no processes"
            note(problem)
            return .failure(ProcessListUnavailable(description: problem))
        }
        return .success(images)
    }

    /// The image names in `tasklist /nh /fo csv` output (`"Warframe.x64.exe","288","Console","1","0 K"`, one process
    /// a line), lowercased; nil when no line has that shape. tasklist itself is always listed, so a real answer is
    /// never empty.
    static func imageNames(tasklistCSV text: String) -> Set<String>? {
        var names = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            let row = line.trimmingCharacters(in: .whitespaces)
            guard row.count >= 2, row.hasPrefix("\""), row.hasSuffix("\"") else { continue }
            // Windows file names cannot hold a double quote, so `","` only ever separates fields.
            let fields = row.dropFirst().dropLast().components(separatedBy: "\",\"")
            // The second field is the process ID.
            guard fields.count >= 2, !fields[0].isEmpty, UInt32(fields[1]) != nil else { continue }
            names.insert(fields[0].lowercased())
        }
        return names.isEmpty ? nil : names
    }

    /// A line of Warzag's own in the tool log.
    func note(_ text: String) {
        try? context.fileSystem.append(Data("warzag: \(text)\n".utf8), to: context.toolLog)
    }

    /// Waits (up to `timeout`) until no wineserver runs for the prefix; returns whether it is idle.
    public func waitUntilPrefixIsIdle(timeout: TimeInterval) async -> Bool {
        let prefix = installation.prefix.root
        await waitUntil(timeout: timeout) { context.probe.wineserver(for: prefix) == nil }
        return context.probe.wineserver(for: prefix) == nil
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async {
        let deadline = context.clock.now.addingTimeInterval(timeout)
        while !condition(), context.clock.now < deadline {
            do { try await context.clock.sleep(for: .milliseconds(500)) } catch { return }
        }
    }

    // MARK: - Status

    var recordURL: URL { context.stateDirectory.appending(path: "content.json") }

    func loadRecord() -> ContentRecord? {
        guard let data = try? context.fileSystem.contents(of: recordURL),
              let record = try? WarzagJSON.decoder().decode(ContentRecord.self, from: data),
              record.schema == ContentRecord.schemaVersion,
              record.library == installation.library.plainPath else { return nil }
        return record
    }

    func recordUpdate(mode: LauncherRunMode, seconds: Double?) {
        let record = ContentRecord(library: installation.library.plainPath, lastUpdate: context.clock.now, mode: mode,
                                   launcherSeconds: seconds)
        guard let data = try? WarzagJSON.encoder(pretty: true).encode(record) else { return }
        try? context.fileSystem.writeAtomically(data, to: recordURL)
    }

    struct LauncherLogSummary: Equatable {
        /// The last run in the log reached "Total time:".
        var completed: Bool
        var modified: Date?
    }

    /// Reads Launcher.log's last run (from its last "Current time:" line).
    func launcherLogSummary() -> LauncherLogSummary? {
        let fileSystem = context.fileSystem
        let url = installation.prefix.launcherLog
        guard fileSystem.fileExists(at: url), let attributes = try? fileSystem.attributes(of: url) else { return nil }
        let window = min(attributes.size, 8 << 20)
        let data = (try? fileSystem.read(url, offset: attributes.size - window, maxLength: Int(window))) ?? Data()
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        let lastRun = lines.lastIndex { $0.hasPrefix("Current time:") } ?? lines.startIndex
        let completed = lines[lastRun...].contains { $0.hasPrefix("Total time:") }
        return LauncherLogSummary(completed: completed, modified: attributes.modificationDate)
    }

    /// Warframe's build from the top of EE.log, which every start rewrites; nil when the log is missing or does not
    /// say.
    func warframeBuild() -> String? {
        guard let data = try? context.fileSystem.read(installation.prefix.eeLog, offset: 0, maxLength: 64 * 1024) else {
            return nil
        }
        return Self.buildLabel(in: String(decoding: data, as: UTF8.self))
    }

    /// "2026.10.15.13.08" from "Sys [Diag]: Build Label: 2026.10.15.13.08 Retail Windows x64 [Stripped]".
    static func buildLabel(in text: String) -> String? {
        guard let found = text.range(of: "Build Label: ") else { return nil }
        let label = text[found.upperBound...].prefix { !$0.isWhitespace }
        guard label.contains("."), label.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else { return nil }
        return String(label)
    }

    public func status() -> ContentStatus {
        let fileSystem = context.fileSystem
        let launcherPresent = fileSystem.fileExists(at: installation.launcherExecutable)
        let gamePresent = fileSystem.fileExists(at: installation.gameExecutable)
        let gameModified = gamePresent ? (try? fileSystem.attributes(of: installation.gameExecutable))?.modificationDate : nil
        let record = loadRecord()
        let log = launcherLogSummary()

        var lastUpdate = record?.lastUpdate
        var source: String? = record == nil ? nil : "warzag"
        if let log, log.completed, let modified = log.modified, lastUpdate.map({ modified > $0 }) ?? true {
            lastUpdate = modified
            source = "Launcher.log"
        }
        var status = ContentStatus(
            state: .installed, reason: "", library: installation.library.plainPath, launcherPresent: launcherPresent,
            gamePresent: gamePresent, gameModified: gameModified, lastUpdate: lastUpdate, lastUpdateSource: source,
            libraryBytes: fileSystem.directoryExists(at: installation.library)
                ? context.files.diskUsage(of: installation.library) : nil,
            build: gamePresent ? warframeBuild() : nil)

        if !gamePresent {
            status.state = .notInstalled
            status.reason = launcherPresent
                ? "DE's launcher has not downloaded the game yet"
                : "Warframe.msi has not been unpacked into the library yet"
        } else if let log, !log.completed {
            status.state = .needsUpdate
            status.reason = "the last run of DE's launcher did not finish"
        } else if let lastUpdate {
            let age = max(0, context.clock.now.timeIntervalSince(lastUpdate))
            if age > configuration.updateStaleAfter {
                status.state = .needsUpdate
                status.reason = "the last update finished \(Self.ageText(age)) ago; DE may have released one since"
            } else {
                status.reason = "the last update finished \(Self.ageText(age)) ago"
            }
        } else if log?.completed == true {
            status.reason = "DE's launcher finished its last run"
        } else {
            status.state = .needsUpdate
            status.reason = "no finished update is recorded"
        }
        return status
    }

    /// "less than an hour", "5 hours", "3 days".
    static func ageText(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds / 3600)
        if hours < 1 { return "less than an hour" }
        if hours < 48 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        return "\(hours / 24) days"
    }
}
