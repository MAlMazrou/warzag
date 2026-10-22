import EngineKit
import Foundation
import GameKit
import ProfileKit
import SteamHostKit
import Synchronization
import WarzagCore
import WineKit

/// GameKit for the app: Warframe.msi, DE's launcher (EULA, download, updates), the EE.cfg seed, Play.
final class LiveGameService: GameServicing {
    let paths: WarzagPaths
    let engine: LiveEngineService
    let steam: LiveSteamService
    let inheritedEnvironment: [String: String]
    let log: AppLog
    private let runs = ContentRunCoordinator()

    init(paths: WarzagPaths, engine: LiveEngineService, steam: LiveSteamService, inheritedEnvironment: [String: String],
         log: AppLog) {
        self.paths = paths
        self.engine = engine
        self.steam = steam
        self.inheritedEnvironment = inheritedEnvironment
        self.log = log
    }

    // MARK: Wiring

    var context: GameContext {
        GameContext.live(paths: paths, inheritedEnvironment: inheritedEnvironment)
    }

    /// The active runtime's host, the prefix, and the library X: points at.
    func installation() throws -> GameInstallation {
        let active = try engine.engine.runtime.active()
        let prefix = paths.prefix(for: active.runtime.channel)
        let user = GameInstallation.windowsUserName(inPrefix: prefix, fileSystem: LocalFileSystem(),
                                                    fallback: NSUserName())
        return GameInstallation.resolve(host: active.host, prefix: prefix, library: nil, paths: paths,
                                        files: LocalGameFiles(), windowsUserName: user)
    }

    func content() throws -> ContentService {
        ContentService(installation: try installation(), context: context)
    }

    var installerURL: URL { paths.caches.appending(path: "downloads/Warframe.msi") }

    var installerSource: InstallerSource {
        InstallerSource(origin: .download(ContentConfiguration.defaultInstallerURL, to: installerURL),
                        authenticode: NativeAuthenticodeVerifier())
    }

    // MARK: Setup

    func launcherExtracted() -> Bool {
        let library = (try? installation().library) ?? paths.warframeLibrary
        return FileManager.default.fileExists(atPath: library.appending(path: "Tools/Launcher.exe").plainPath)
    }

    func downloadInstaller(progress: @escaping @Sendable (ContentRunState) -> Void) async throws {
        let verified = try await installerSource.installer(progress: progress)
        log.write("game: Warframe.msi \(verified.bytes) bytes, sha256 \(verified.sha256), \(verified.authenticode)")
    }

    func extractInstaller(progress: @escaping @Sendable (ContentRunState) -> Void) async throws {
        // Reuses the checked file from downloadInstaller (downloads it again only if it went missing).
        let verified = try await installerSource.installer(progress: progress)
        let content = try content()
        // msiexec refuses a busy prefix; the license probe may still be finishing.
        _ = await content.waitUntilPrefixIsIdle(timeout: 60)
        progress(.extractingInstaller)
        try await content.extractInstaller(verified)
    }

    func seedProfile() throws -> Bool {
        let installation = try installation()
        // The player's preset (or the one recommended for this Mac) names the upscaler a new EE.cfg starts with.
        let hardware = HardwareProfile.detect()
        let choice = engine.settings.settings.graphics(for: hardware.tierClassification.tier)
        return try EEConfigSeed.seedIfAbsent(at: installation.prefix.eeConfig,
                                             preset: GraphicsTuning.seedPreset(choice, hardware: hardware),
                                             fileSystem: LocalFileSystem())
    }

    func motionBlur() -> MotionBlurSetting {
        guard let installation = try? installation() else { return .unknown }
        return EEConfigReader.motionBlur(at: installation.prefix.eeConfig, fileSystem: LocalFileSystem())
    }

    func eulaAccepted() -> Bool {
        (try? content().eulaAcceptedInRegistry()) ?? false
    }

    func waitForEULA(progress: @escaping @Sendable (ContentRunState) -> Void) async throws -> EULAOutcome {
        let content = try content()
        if content.eulaAcceptedInRegistry() { return .accepted }
        let job = try await runs.job { content }
        job.relay.listen(progress)
        var nextRegistryRead = Date().addingTimeInterval(5)
        while true {
            if job.relay.passedEULA { return .accepted }
            if !job.relay.isRunning {
                switch try await job.task.value {
                case .completed: return .accepted
                case .eulaDeclined: return .declined
                case .stuck(let reason): return .stuck(reason)
                }
            }
            if Date() >= nextRegistryRead {
                // wineserver saves user.reg up to 30 s after DE writes ReadEula.
                if content.eulaAcceptedInRegistry() { return .accepted }
                nextRegistryRead = Date().addingTimeInterval(5)
            }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    /// GameKit's `ContentService.pinDirectX11`: GraphicsAPI 0 (DirectX 11, DE's default) before DE's launcher first
    /// runs; GameKit pins it again before every launcher run.
    func pinDirectX11() async throws {
        let content = try content()
        // msiexec or the license probe may still be finishing in the prefix; user.reg is read once it is idle.
        _ = await content.waitUntilPrefixIsIdle(timeout: 60)
        if try await content.pinDirectX11() { log.write("game: launcher pinned to DirectX 11") }
    }

    func downloadContent(progress: @escaping @Sendable (ContentRunState) -> Void) async throws -> ContentRunOutcome {
        let content = try content()
        let job = try await runs.job { content }
        job.relay.listen(progress)
        switch try await job.task.value {
        case .completed: return .completed
        case .eulaDeclined: return .eulaDeclined
        case .stuck(let reason): return .stuck(reason)
        }
    }

    func cancelContentRun() async {
        await runs.cancel()
    }

    func contentStatus() -> ContentSummary? {
        guard let status = try? content().status() else { return nil }
        return ContentSummary(state: status.state, lastUpdate: status.lastUpdate, libraryBytes: status.libraryBytes,
                              build: status.build)
    }

    // MARK: Updates

    func updateGame(progress: @escaping @Sendable (ContentRunState) -> Void) async throws -> GameUpdateOutcome {
        let content: ContentService
        do {
            content = try self.content()
        } catch {
            throw PlayFailure.needsRepair(String(describing: error))
        }
        // As before Play: DE's launcher runs on the host, so the host's signature must still verify, and still be the
        // signer's it was installed with, before any of its code runs.
        do {
            try content.context.hostSignatures.verify(content.installation.host)
        } catch {
            throw PlayFailure.needsRepair(String(describing: error))
        }
        let before = GameFilesStamp(content.status())
        let growth = LibraryGrowth()
        let outcome: LauncherRunOutcome
        do {
            outcome = try await runs.update(content) { state in
                growth.note(state)
                progress(state)
            }
        } catch let error as ContentError {
            switch error {
            case .notInstalled: throw PlayFailure.notInstalled
            case .prefixNotReady(let issues): throw Self.failure(.notReady(issues))
            default: throw PlayFailure.other(error.description)
            }
        }
        switch outcome {
        case .completed:
            let result = GameFilesStamp.outcome(before: before, after: GameFilesStamp(content.status()),
                                                grewDuringRun: growth.seen)
            log.write("game: DE's launcher finished an update run (" + (result == .updated ? "it updated Warframe"
                : "nothing shows it changed anything") + ")")
            return result
        case .eulaDeclined:
            return .eulaDeclined
        case .stuck:
            return .stuck
        }
    }

    func prefixIsBusy() -> Bool {
        guard let installation = try? installation() else { return false }
        return context.probe.wineserver(for: installation.prefix.root) != nil
    }

    // MARK: Play

    func play(_ request: PlayRequest, updates: @escaping @Sendable (PlayUpdate) -> Void) async throws -> PlaySummary {
        if request.steam { try await prepareSteam(updates) }
        let content: ContentService
        do {
            content = try self.content()
        } catch {
            throw PlayFailure.needsRepair(String(describing: error))
        }
        let hardware = HardwareProfile.detect()
        var launch = GameLaunchBuilder.launch(
            installation: content.installation, options: GraphicsTuning.playOptions(steam: request.steam, hud: request.hud),
            hardware: hardware, steamClientDirectory: steam.locations.clientDirectory, inherited: inheritedEnvironment)
        launch = GraphicsTuning.apply(request.graphics, hardware: hardware, to: launch)
        log.write("play: frame cap \(launch.renderer.frameRateCap.map(String.init) ?? "none"), NVEXT "
            + "\(launch.renderer.enableNVEXT ? "on" : "off")")
        do {
            // LaunchServices would hand the front to the process it opens, the steam.exe shim, which shows no window:
            // Warzag keeps it while the game starts and hands it to the game's window when that appears
            // (AppModel, SystemServicing.keepGameInFront).
            let session = PlaySession(content: content, configuration: PlayConfiguration(activates: false))
            let result = try await session.run(launch, update: true) { updates(.game($0)) }
            return PlaySummary(seconds: result.seconds, signals: result.signals, forcedCleanup: result.forcedCleanup)
        } catch let error as PlayError {
            throw Self.failure(error)
        } catch let error as ContentError {
            switch error {
            case .notInstalled: throw PlayFailure.notInstalled
            case .prefixNotReady(let issues): throw Self.failure(.notReady(issues))
            default: throw PlayFailure.other(error.description)
            }
        }
    }

    /// Steam must run and be signed in for Steam login: start it silently, wait up to a minute for each.
    private func prepareSteam(_ updates: @escaping @Sendable (PlayUpdate) -> Void) async throws {
        if !steam.status().running {
            updates(.startingSteam)
            try? await steam.start()
            for _ in 0..<60 where !steam.status().running {
                try await Task.sleep(for: .seconds(1))
            }
        }
        if !steam.status().signedIn {
            updates(.waitingForSteamSignIn)
            for _ in 0..<60 where !steam.status().signedIn {
                try await Task.sleep(for: .seconds(1))
            }
            guard steam.status().signedIn else { throw PlayFailure.steamNotSignedIn }
        }
    }

    static func failure(_ error: PlayError) -> PlayFailure {
        switch error {
        case .notReady(let issues):
            if issues.contains(where: { if case .prefixBusy = $0 { true } else { false } }) { return .busy }
            if issues.contains(.gameNotDownloaded) || issues.contains(.launcherNotExtracted) { return .notInstalled }
            return .needsRepair(issues.map(\.description).joined(separator: "; "))
        case .updateDidNotComplete(.eulaDeclined): return .updateDeclinedEULA
        case .updateDidNotComplete: return .updateStuck
        case .hostSignatureInvalid(let reason): return .needsRepair(reason)
        case .openFailed(let reason): return .other(reason)
        }
    }

    func quitGame() async {
        guard let installation = try? installation() else { return }
        // WM_CLOSE to Warframe's windows, as Windows' own taskkill without /F.
        let environment = WineEnvironment.toolRun(prefix: installation.prefix.root, inherited: inheritedEnvironment)
        _ = try? await SystemProcessRunner().run(Command(
            executable: installation.host.wine, arguments: ["taskkill", "/IM", "Warframe.x64.exe"],
            environment: environment, logFile: context.toolLog))
    }

    func forceQuitGame() async {
        guard let installation = try? installation() else { return }
        _ = try? await SystemProcessRunner().run(WineTool.wineserverKill.command(
            host: installation.host, prefix: installation.prefix.root, inherited: inheritedEnvironment,
            logFile: context.toolLog))
        log.write("play: force quit (wineserver -k)")
    }
}

/// What tells whether a finished run of DE's launcher changed the game: Warframe.x64.exe's modification time (DE's
/// launcher replaces it with an update) and the library's size on disk.
struct GameFilesStamp: Equatable, Sendable {
    var gameModified: Date?
    var libraryBytes: Int64?

    init(gameModified: Date?, libraryBytes: Int64?) {
        self.gameModified = gameModified
        self.libraryBytes = libraryBytes
    }

    init(_ status: ContentStatus) {
        self.init(gameModified: status.gameModified, libraryBytes: status.libraryBytes)
    }

    /// Updated when the library grew (while the run downloaded, as GameKit's progress measured it, or from before the
    /// run to after it) or Warframe.x64.exe was replaced; otherwise nothing shows the run changed anything.
    static func outcome(before: GameFilesStamp, after: GameFilesStamp, grewDuringRun: Bool) -> GameUpdateOutcome {
        var grew = grewDuringRun
        if let old = before.libraryBytes, let new = after.libraryBytes, new > old { grew = true }
        let replaced = before.gameModified != nil && after.gameModified != before.gameModified
        return grew || replaced ? .updated : .upToDate
    }
}

/// Whether an update run's progress ever showed the library growing (`ContentRunState.downloading`: the bytes this run
/// added so far).
final class LibraryGrowth: Sendable {
    private let grew = Mutex(false)

    var seen: Bool { grew.withLock { $0 } }

    func note(_ state: ContentRunState) {
        guard case .downloading(let bytesThisRun, _, _, _) = state, bytesThisRun > 0 else { return }
        grew.withLock { $0 = true }
    }
}

/// One run of DE's launcher shared by setup's EULA and download steps: accepting the EULA does not end the run, the
/// download goes on in the same launcher. Updates › Warframe runs separately (`update`); `cancel()` closes both.
actor ContentRunCoordinator {
    struct Job: Sendable {
        let relay: ContentRunRelay
        let task: Task<LauncherRunOutcome, any Error>
    }

    private var current: Job?
    /// Updates › Warframe's run, while it lasts.
    private var update: Task<LauncherRunOutcome, any Error>?

    /// The running job, or the last one if it completed; otherwise a new run of DE's launcher. A cancelled caller gets
    /// CancellationError instead: its step was cancelled before `cancel()` was called (quitting, a setup restart), so a
    /// run it started now would outlive that `cancel()`, and the quit would wait for it.
    func job(_ content: @Sendable () -> ContentService) throws -> Job {
        try Task.checkCancellation()
        if let current, current.relay.isRunning || current.relay.completed { return current }
        let service = content()
        let relay = ContentRunRelay()
        let task = Task<LauncherRunOutcome, any Error> {
            do {
                // GameKit refuses to start DE's launcher in a busy prefix; let a probe or msiexec finish first.
                _ = await service.waitUntilPrefixIsIdle(timeout: 60)
                let outcome = try await service.runLauncher(.install) { relay.report($0) }
                relay.finish(outcome)
                return outcome
            } catch {
                relay.finish(nil)
                throw error
            }
        }
        let job = Job(relay: relay, task: task)
        current = job
        return job
    }

    /// Runs DE's launcher once to bring the installed game up to date (`ContentService.update`) and returns how the run
    /// ended. Always a run of its own, never setup's (whose completed run `job` hands out again); `cancel()` closes it,
    /// and so does cancelling the caller. A caller cancelled before it began starts nothing; while another run is under
    /// way it is `PlayFailure.busy`.
    func update(_ content: ContentService,
                progress: @escaping @Sendable (ContentRunState) -> Void) async throws -> LauncherRunOutcome {
        try Task.checkCancellation()
        guard update == nil, current?.relay.isRunning != true else { throw PlayFailure.busy }
        let task = Task<LauncherRunOutcome, any Error> { try await content.update(progress: progress) }
        update = task
        defer { if update == task { update = nil } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Cancels the runs (GameKit closes DE's launcher) and waits for them to end.
    func cancel() async {
        let runs = [current?.task, update].compactMap { $0 }
        current = nil
        update = nil
        for run in runs { run.cancel() }
        for run in runs { _ = try? await run.value }
    }
}

/// Progress of a launcher run, fanned out to whichever setup step listens now.
final class ContentRunRelay: Sendable {
    private struct State {
        var listener: (@Sendable (ContentRunState) -> Void)?
        var passedEULA = false
        var running = true
        var completed = false
    }

    private let state = Mutex(State())

    var isRunning: Bool { state.withLock { $0.running } }
    var completed: Bool { state.withLock { $0.completed } }
    /// The launcher went past its EULA step (it downloads, prepares files or finishes).
    var passedEULA: Bool { state.withLock { $0.passedEULA } }

    func listen(_ listener: @escaping @Sendable (ContentRunState) -> Void) {
        state.withLock { $0.listener = listener }
    }

    func report(_ value: ContentRunState) {
        let listener = state.withLock { state -> (@Sendable (ContentRunState) -> Void)? in
            switch value {
            case .downloading, .preprocessing, .finishing, .complete: state.passedEULA = true
            default: break
            }
            return state.listener
        }
        listener?(value)
    }

    func finish(_ outcome: LauncherRunOutcome?) {
        state.withLock {
            $0.running = false
            if case .completed? = outcome {
                $0.completed = true
                $0.passedEULA = true
            }
        }
    }
}
