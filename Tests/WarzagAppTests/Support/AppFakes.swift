import Foundation
import GameKit
import ProfileKit
import Synchronization
import WarzagCore
import WarzagTestSupport
@testable import WarzagApp

// Fakes for the app's service protocols: plain state behind a lock, every call recorded. No Wine, Steam, DE's launcher,
// network or AppKit side effect is ever reached from these.

/// A MacBook Air 15" M2 (T1, fanless).
let m2Air = HardwareProfile(chip: "Apple M2", modelIdentifier: "Mac14,15", productName: "MacBook Air (15-inch, M2, 2023)",
                            performanceCores: 4, efficiencyCores: 4, gpuCores: 10, memoryGB: 24, isAppleSilicon: true,
                            macOSVersion: "26.5.1")

final class FakeSystem: SystemServicing {
    struct State {
        var hardware = m2Air
        var lowPowerMode = false
        var battery = false
        var hot = false
        /// The adapter's watts (nil: none, or it does not say) and the battery's charge (nil: no battery).
        var adapterWatts: Int?
        var batteryPercent: Int?
        var location = ApplicationLocation(url: URL(filePath: "/Applications/Warzag.app"), inApplicationsFolder: true)
        var moveFails = false
        var storage = StorageCheck(volume: VolumeInfo(availableCapacity: 400_000_000_000, isCaseSensitive: false,
                                                      isLocal: true, format: "apfs"), libraryBytes: 0)
        var network = true
        var calls: [String] = []
        var opened: [URL] = []
        var badges: [String?] = []
        var keptAwake: [KeepAwakeReason?] = []
        /// What keepGameInFront reports before it waits for the session to end.
        var focusEvents: [GameFocusEvent] = []
        /// What keepGameInFront reports next while it waits (a test sets these during the session); taken once.
        var laterFocusEvents: [GameFocusEvent] = []
        /// Every change of Warzag's Dock presence, in order (Hide Warzag while playing).
        var dock: [DockPresence] = []
        var mainWindowShown = 0
    }

    let state = Mutex(State())

    func set(_ body: (inout State) -> Void) { state.withLock { body(&$0) } }
    var calls: [String] { state.withLock { $0.calls } }
    var badges: [String?] { state.withLock { $0.badges } }
    var keptAwake: [KeepAwakeReason?] { state.withLock { $0.keptAwake } }
    var opened: [URL] { state.withLock { $0.opened } }
    var dock: [DockPresence] { state.withLock { $0.dock } }
    var mainWindowShown: Int { state.withLock { $0.mainWindowShown } }

    func hardware() -> HardwareProfile {
        state.withLock { state in
            var hardware = state.hardware
            hardware.lowPowerMode = state.lowPowerMode
            hardware.powerSource = state.battery ? .battery : .ac
            hardware.thermalState = state.hot ? .serious : .nominal
            return hardware
        }
    }

    func powerAdvice(for tier: PerformanceTier) -> [PowerAdvice] {
        var info = FakeSystemInfo.mac(chip: "Apple M2", model: "Mac14,15", product: nil, performanceCores: 4,
                                      efficiencyCores: 4, gpuCores: 10, memoryGB: 24)
        state.withLock { state in
            info.isLowPowerModeEnabled = state.lowPowerMode
            info.powerSource = state.battery ? .battery : .ac
            info.thermalState = state.hot ? .serious : .nominal
            info.powerAdapterWatts = state.adapterWatts
            info.batteryPercent = state.batteryPercent
        }
        return PowerAdvisor(system: info).advice(for: tier)
    }

    func applicationLocation() -> ApplicationLocation { state.withLock { $0.location } }

    func moveToApplications() async throws {
        let fails = state.withLock { state in
            state.calls.append("moveToApplications")
            return state.moveFails
        }
        if fails { throw CocoaError(.fileWriteNoPermission) }
    }

    func storage(for library: URL) -> StorageCheck { state.withLock { $0.storage } }
    func networkIsAvailable() async -> Bool { state.withLock { $0.network } }
    func networkAvailability() -> AsyncStream<Bool> { AsyncStream { $0.finish() } }

    @MainActor func open(_ url: URL) { state.withLock { $0.opened.append(url) } }
    @MainActor func revealInFinder(_ url: URL) { state.withLock { $0.calls.append("reveal") } }
    @MainActor func showSteam() { state.withLock { $0.calls.append("showSteam") } }
    @MainActor func showGameHost(openedProcess: Int32?) {
        state.withLock { $0.calls.append("showGameHost(\(openedProcess.map(String.init) ?? "nil"))") }
    }
    func keepGameInFront(openedProcess: Int32, hidingSteam: Bool,
                         events: @escaping @Sendable (GameFocusEvent) -> Void) async {
        let scripted = state.withLock { state -> [GameFocusEvent] in
            state.calls.append("keepGameInFront(\(openedProcess))")
            return state.focusEvents
        }
        scripted.forEach(events)
        // Like the real one it keeps going until the session ends, when the model cancels it.
        while !Task.isCancelled {
            let later = state.withLock { state in
                defer { state.laterFocusEvents = [] }
                return state.laterFocusEvents
            }
            later.forEach(events)
            try? await Task.sleep(for: .milliseconds(5))
        }
        state.withLock { $0.calls.append("keepGameInFront ended") }
    }
    @MainActor func setDockBadge(_ text: String?) { state.withLock { $0.badges.append(text) } }
    @MainActor func requestAttention() { state.withLock { $0.calls.append("requestAttention") } }
    @MainActor func keepAwake(_ reason: KeepAwakeReason?) { state.withLock { $0.keptAwake.append(reason) } }
    @MainActor func setDockPresence(_ presence: DockPresence) { state.withLock { $0.dock.append(presence) } }
    @MainActor func showMainWindow() { state.withLock { $0.mainWindowShown += 1 } }
    @MainActor func quit() { state.withLock { $0.calls.append("quit") } }
}

final class FakeEngine: EngineServicing {
    struct State {
        var development: DevelopmentRuntime?
        var active: RuntimeSummary?
        var prefixError: (any Error)?
        var probe = LicenseProbeResult.owned
        /// The release page's feed, and what each feed step throws (by step name: check, fetch, download, verify,
        /// activate).
        var feed: URL?
        var offer = EngineOffer(id: "n-0.3.0", version: "0.3.0", bytes: 180_000_000, installed: false)
        var feedErrors: [String: any Error] = [:]
        /// The feed revokes the current engine: `fetchEngineManifest` makes this one (the previous engine) current, as
        /// RuntimeStore's `accept` does; `checkEngineManifest` changes nothing.
        var revocationRollsBackTo: RuntimeSummary?
        /// Steps that wait while they are named here: check, fetch, download (after half its bytes), verify,
        /// setUpPrefix, repairPrefix.
        var holdFeedSteps: Set<String> = []
        /// The runtime the prefix was last set up for (`setUpPrefix` and `repairPrefix` record the active one).
        var prefixRuntime: String?
        var calls: [String] = []
    }

    static let feedURL = URL(string: "https://releases.example.org/runtime/n/manifest.json")!

    let settings: SettingsBox
    let state = Mutex(State())

    init(settings: SettingsBox) {
        self.settings = settings
    }

    func set(_ body: (inout State) -> Void) { state.withLock { body(&$0) } }
    var calls: [String] { state.withLock { $0.calls } }

    /// A development engine for `channel` (nil: a bundle that is not a Warzag engine).
    func useDevelopmentEngine(_ channel: RuntimeChannel?) {
        set { $0.development = DevelopmentRuntime(bundle: URL(filePath: "/build/Warzag.app"), channel: channel) }
    }

    static func runtime(_ channel: RuntimeChannel, development: Bool = true) -> RuntimeSummary {
        RuntimeSummary(id: "\(channel.rawValue)-dev-20261017", version: "0.2.0-dev", channel: channel,
                       development: development, hostPath: "/home/Runtimes.noindex/\(channel.rawValue)/0.2.0/Warzag.app")
    }

    func developmentRuntime() -> DevelopmentRuntime? { state.withLock { $0.development } }

    func activeRuntime() -> RuntimeSummary? { state.withLock { $0.active } }

    func registerDevelopmentRuntime(_ runtime: DevelopmentRuntime) async throws -> RuntimeSummary {
        try state.withLock { state in
            state.calls.append("register")
            guard let channel = runtime.channel else { throw CocoaError(.fileReadCorruptFile) }
            let summary = Self.runtime(channel)
            state.active = summary
            return summary
        }
    }

    func feedURL() -> URL? { state.withLock { $0.feed } }

    private func feedStep(_ name: String) throws {
        let error = state.withLock { state -> (any Error)? in
            state.calls.append(name)
            return state.feedErrors[name]
        }
        if let error { throw error }
    }

    private func held(_ name: String) async throws {
        while state.withLock({ $0.holdFeedSteps.contains(name) }) { try await Task.sleep(for: .milliseconds(5)) }
    }

    func fetchEngineManifest() async throws -> EngineOffer {
        try feedStep("fetch")
        try await held("fetch")
        return state.withLock { state in
            if let previous = state.revocationRollsBackTo {
                state.active = previous
                state.revocationRollsBackTo = nil
            }
            return state.offer
        }
    }

    func checkEngineManifest() async throws -> EngineOffer {
        try feedStep("check")
        try await held("check")
        return state.withLock { $0.offer }
    }

    func downloadEngine(progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try feedStep("download")
        let bytes = state.withLock { $0.offer.bytes }
        progress(bytes / 2, bytes)
        try await held("download")
        progress(bytes, bytes)
    }

    func verifyEngine() async throws {
        try feedStep("verify")
        try await held("verify")
    }

    func activateEngine() async throws -> RuntimeSummary {
        try feedStep("activate")
        return state.withLock { state in
            let summary = RuntimeSummary(id: state.offer.id, version: state.offer.version, channel: .n,
                                         development: false,
                                         hostPath: "/home/Runtimes.noindex/n/\(state.offer.version)/Warzag.app")
            state.active = summary
            return summary
        }
    }

    func setUpPrefix() async throws -> PrefixSummary {
        let error = state.withLock { state in
            state.calls.append("setUpPrefix")
            return state.prefixError
        }
        if let error { throw error }
        try await held("setUpPrefix")
        set { $0.prefixRuntime = $0.active?.id }
        return PrefixSummary(created: true, library: "/home/Library/Warframe.noindex", log: "/home/prefix.log")
    }

    func repairPrefix() async throws -> PrefixSummary {
        let error = state.withLock { state in
            state.calls.append("repairPrefix")
            return state.prefixError
        }
        if let error { throw error }
        try await held("repairPrefix")
        set { $0.prefixRuntime = $0.active?.id }
        return PrefixSummary(created: false, library: "/home/Library/Warframe.noindex", log: "/home/prefix.log")
    }

    func prefixRuntimeID() -> String? { state.withLock { $0.prefixRuntime } }

    func doctor() async -> [HealthCheck] {
        state.withLock { $0.calls.append("doctor") }
        return [HealthCheck(id: "engine.runtime", title: "Engine", passed: true, detail: "n-dev"),
                HealthCheck(id: "engine.dxmt", title: "Graphics (DXMT)", passed: false, detail: "missing")]
    }

    func probeSteamLicense() async -> LicenseProbeResult {
        state.withLock { state in
            state.calls.append("probe")
            return state.probe
        }
    }
}

final class FakeSteam: SteamServicing {
    struct State {
        var installed = true
        var running = true
        var signedIn = true
        var installFails = false
        var startMakesRunning = true
        var card = SteamCard(state: .signedIn, name: "Test Tenno")
        var logInSignsIn = true
        var hidingAllowed = false
        var calls: [String] = []
    }

    let state = Mutex(State())

    func set(_ body: (inout State) -> Void) { state.withLock { body(&$0) } }
    var calls: [String] { state.withLock { $0.calls } }

    func status() -> SteamSnapshot {
        state.withLock { SteamSnapshot(installed: $0.installed, running: $0.running, signedIn: $0.signedIn) }
    }

    func install() async throws {
        let fails = state.withLock { state in
            state.calls.append("install")
            if !state.installFails { state.installed = true }
            return state.installFails
        }
        if fails { throw URLError(.cannotConnectToHost) }
    }

    func start() async throws {
        state.withLock { state in
            state.calls.append("start")
            if state.startMakesRunning { state.running = true }
        }
    }

    func card() async -> SteamCard {
        state.withLock { $0.card }
    }

    func logIn() async -> Bool {
        state.withLock { state in
            state.calls.append("logIn")
            guard state.installed else { return false }
            if state.logInSignsIn {
                state.running = true
                state.signedIn = true
                state.card = SteamCard(state: .signedIn, name: "Test Tenno")
            }
            return true
        }
    }

    func logOut() async {
        state.withLock { state in
            state.calls.append("logOut")
            state.signedIn = false
            state.card = SteamCard(state: .signedOut)
        }
    }

    func hideSteam() async {
        state.withLock { state in
            if state.hidingAllowed { state.calls.append("hideSteam") }
        }
    }

    func allowHiding(_ allowed: Bool) {
        state.withLock { $0.hidingAllowed = allowed }
    }
}

final class FakeGame: GameServicing {
    struct State {
        var launcherExtracted = false
        var eulaAccepted = false
        var eulaOutcome = EULAOutcome.accepted
        /// waitForEULA keeps reporting DE's EULA window while this is set.
        var holdEULA = false
        var downloadOutcome = ContentRunOutcome.completed
        var downloadError: (any Error)?
        var installerError: (any Error)?
        /// extractInstaller waits while this is set (msiexec /a runs). Cancelled, it cleans up first, in a task of its
        /// own that takes a moment, as ContentService runs `wineserver -k` after a cancelled msiexec.
        var holdExtract = false
        /// downloadContent reports these, then waits while `holdDownload` is set.
        var downloadProgress: [ContentRunState] = []
        var holdDownload = false
        /// downloadContent waits for DE's launcher run instead, as LiveGameService does: the run is a task of its own,
        /// which the step's cancellation does not reach and only `cancelContentRun` ends.
        var downloadWaitsForTheRun = false
        var contentRun: Task<Void, Never>?
        var content: ContentSummary?
        /// contentStatus blocks (it reads the disk off the main actor) while this is set.
        var holdContentStatus = false
        /// What EE.cfg says about motion blur.
        var motionBlur = MotionBlurSetting.unknown
        var playUpdates: [PlayUpdate] = [.game(.opening), .game(.started(processIdentifier: 42))]
        var playFailure: PlayFailure?
        /// play reports `playUpdates`, then waits while this is set (e.g. DE's launcher still updating the game).
        var holdPlayAfterUpdates = false
        var holdPlayUntilQuit = false
        /// What play throws once it stops waiting, instead of reporting Warframe's exit (a session that breaks off).
        var errorAfterUpdates: (any Error)?
        var quitRequested = false
        /// updateGame reports these, then waits while `holdUpdate` is set in a run of DE's launcher that only
        /// `cancelContentRun` (or the caller's cancellation) ends, as in LiveGameService.
        var updateProgress: [ContentRunState] = []
        var holdUpdate = false
        var updateOutcome = GameUpdateOutcome.upToDate
        var updateFailure: PlayFailure?
        /// Something runs in the prefix: a game an earlier run of Warzag left running.
        var prefixBusy = false
        var calls: [String] = []
    }

    let state = Mutex(State())

    func set(_ body: (inout State) -> Void) { state.withLock { body(&$0) } }
    var calls: [String] { state.withLock { $0.calls } }

    private func record(_ call: String) { state.withLock { $0.calls.append(call) } }

    func launcherExtracted() -> Bool { state.withLock { $0.launcherExtracted } }

    func downloadInstaller(progress: @escaping @Sendable (ContentRunState) -> Void) async throws {
        record("downloadInstaller")
        progress(.downloadingInstaller(receivedBytes: 59_000_000, totalBytes: 118_000_000))
        if let error = state.withLock({ $0.installerError }) { throw error }
    }

    func extractInstaller(progress: @escaping @Sendable (ContentRunState) -> Void) async throws {
        record("extractInstaller")
        progress(.extractingInstaller)
        do {
            while state.withLock({ $0.holdExtract }) { try await Task.sleep(for: .milliseconds(5)) }
        } catch {
            await Task.detached {
                try? await Task.sleep(for: .milliseconds(100))
                self.record("extractInstaller.cleanedUp")
            }.value
            throw error
        }
        set { $0.launcherExtracted = true }
    }

    func seedProfile() throws -> Bool {
        record("seedProfile")
        return true
    }

    func motionBlur() -> MotionBlurSetting { state.withLock { $0.motionBlur } }

    func eulaAccepted() -> Bool { state.withLock { $0.eulaAccepted } }

    func waitForEULA(progress: @escaping @Sendable (ContentRunState) -> Void) async throws -> EULAOutcome {
        record("waitForEULA")
        progress(.needsEULA)
        while state.withLock({ $0.holdEULA }) {
            try await Task.sleep(for: .milliseconds(5))
            progress(.needsEULA)
        }
        let outcome = state.withLock { $0.eulaOutcome }
        if outcome == .accepted { set { $0.eulaAccepted = true } }
        return outcome
    }

    func pinDirectX11() async throws { record("pinDirectX11") }

    func downloadContent(progress: @escaping @Sendable (ContentRunState) -> Void) async throws -> ContentRunOutcome {
        record("downloadContent")
        for value in state.withLock({ $0.downloadProgress }) { progress(value) }
        let run = state.withLock { state -> Task<Void, Never>? in
            guard state.downloadWaitsForTheRun else { return nil }
            let run = state.contentRun ?? Task {
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            }
            state.contentRun = run
            state.calls.append("downloadContent.waitingForTheRun")
            return run
        }
        if let run {
            await run.value
            record("downloadContent.runEnded")
            throw CancellationError()
        }
        do {
            while state.withLock({ $0.holdDownload }) { try await Task.sleep(for: .milliseconds(5)) }
        } catch {
            record("downloadContent.cancelled")
            throw error
        }
        if let error = state.withLock({ $0.downloadError }) { throw error }
        return state.withLock { $0.downloadOutcome }
    }

    func cancelContentRun() async {
        let run = state.withLock { state -> Task<Void, Never>? in
            state.calls.append("cancelContentRun")
            defer { state.contentRun = nil }
            return state.contentRun
        }
        run?.cancel()
        await run?.value
    }

    func contentStatus() -> ContentSummary? {
        while state.withLock({ $0.holdContentStatus }) { usleep(1_000) }
        return state.withLock { $0.content }
    }

    func updateGame(progress: @escaping @Sendable (ContentRunState) -> Void) async throws -> GameUpdateOutcome {
        record("updateGame")
        if let failure = state.withLock({ $0.updateFailure }) { throw failure }
        for value in state.withLock({ $0.updateProgress }) { progress(value) }
        let run = state.withLock { state -> Task<Void, Never> in
            let run = Task {
                while !Task.isCancelled, self.state.withLock({ $0.holdUpdate }) {
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }
            state.contentRun = run
            return run
        }
        await withTaskCancellationHandler {
            await run.value
        } onCancel: {
            run.cancel()
        }
        guard !run.isCancelled else {
            record("updateGame.closed")
            throw CancellationError()
        }
        return state.withLock { state in
            if state.contentRun == run { state.contentRun = nil }
            return state.updateOutcome
        }
    }

    func prefixIsBusy() -> Bool { state.withLock { $0.prefixBusy } }

    func play(_ request: PlayRequest, updates: @escaping @Sendable (PlayUpdate) -> Void) async throws -> PlaySummary {
        record("play(\(request.steam ? "steam" : "account"),\(request.graphics.rawValue))")
        if let failure = state.withLock({ $0.playFailure }) { throw failure }
        for update in state.withLock({ $0.playUpdates }) { updates(update) }
        do {
            while state.withLock({ $0.holdPlayAfterUpdates || ($0.holdPlayUntilQuit && !$0.quitRequested) }) {
                try await Task.sleep(for: .milliseconds(5))
            }
        } catch {
            record("play.cancelled")
            throw error
        }
        if let error = state.withLock({ $0.errorAfterUpdates }) { throw error }
        updates(.game(.exited(seconds: 600)))
        updates(.game(.cleanedUp(forced: false)))
        return PlaySummary(seconds: 600, signals: [.steamActive, .loggedIn], forcedCleanup: false)
    }

    func quitGame() async {
        record("quitGame")
        set { $0.quitRequested = true }
    }

    func forceQuitGame() async {
        record("forceQuitGame")
        set { $0.quitRequested = true }
    }
}

/// Warzag's own updates: what the app feed answers and what each step throws, every call recorded.
final class FakeAppUpdates: AppUpdateServicing {
    struct State {
        var version = AppVersion(version: "0.1.0", build: "100")
        var check = Result<AppUpdateCheck, AppUpdateError>.success(.upToDate)
        var prepareError: AppUpdateError?
        var installError: AppUpdateError?
        /// prepare reports half the download, then waits while this is set, then reports the rest.
        var holdPrepare = false
        /// After the download, prepare's checks (digest, code signature) run while this is set. Like the real ones they
        /// go on when the update is cancelled (quitting); "prepare.cancelled" records that it was.
        var holdChecks = false
        /// installPreparedUpdate waits while this is set.
        var holdInstall = false
        /// What preparedCopy() returns: the checked copy kept after a cannotReplace.
        var copy: URL?
        /// What lastInstallResult() returns once: an install that failed after the previous Warzag quit.
        var lastInstall: AppUpdateError?
        /// The CHANGELOG.md the running build carries; nil for none, as under `swift test`.
        var changelog: String?
        var calls: [String] = []
    }

    static let offer = AppUpdateOffer(version: "0.2.0", build: "124", bytes: 48_000_000,
                                      releaseNotes: URL(string: "https://releases.example.org/warzag/0.2.0"))

    let state = Mutex(State())

    func set(_ body: (inout State) -> Void) { state.withLock { body(&$0) } }
    var calls: [String] { state.withLock { $0.calls } }

    private func record(_ call: String) { state.withLock { $0.calls.append(call) } }

    func currentVersion() -> AppVersion { state.withLock { $0.version } }

    func check() async throws -> AppUpdateCheck {
        record("check")
        return try state.withLock { $0.check }.get()
    }

    func prepare(_ offer: AppUpdateOffer,
                 progress: @escaping @Sendable (_ received: Int64, _ total: Int64) -> Void) async throws {
        record("prepare(\(offer.version))")
        progress(offer.bytes / 2, offer.bytes)
        while state.withLock({ $0.holdPrepare }) { try await Task.sleep(for: .milliseconds(5)) }
        if let error = state.withLock({ $0.prepareError }) { throw error }
        progress(offer.bytes, offer.bytes)
        var noticed = false
        while state.withLock({ $0.holdChecks }) {
            if Task.isCancelled, !noticed {
                noticed = true
                record("prepare.cancelled")
            }
            usleep(1_000)
        }
    }

    func installPreparedUpdate() async throws {
        record("install")
        while state.withLock({ $0.holdInstall }) { try await Task.sleep(for: .milliseconds(5)) }
        if let error = state.withLock({ $0.installError }) { throw error }
    }

    func preparedCopy() -> URL? { state.withLock { $0.copy } }

    func lastInstallResult() -> AppUpdateError? {
        state.withLock { state in
            defer { state.lastInstall = nil }
            return state.lastInstall
        }
    }

    func changelog() -> String? {
        state.withLock { state in
            state.calls.append("changelog")
            return state.changelog
        }
    }
}

/// Fakes, an in-memory file system and a manual clock, wired into an `AppModel` the way `AppModel.make` does it.
@MainActor
final class AppFixture {
    let fileSystem = InMemoryFileSystem()
    let clock = ManualClock()
    let settings: SettingsBox
    let system = FakeSystem()
    let engine: FakeEngine
    let steam = FakeSteam()
    let game = FakeGame()
    let appUpdate = FakeAppUpdates()
    /// Set before `makeModel()` (e.g. a development engine from the launch).
    var options = LaunchOptions(home: URL(filePath: "/home", directoryHint: .isDirectory))
    /// Warzag.log for `makeModel()`; set a real one before it to check what the model writes.
    var log = AppLog.disabled

    /// `welcomed`: Get Started was clicked on an earlier launch (most tests); false shows the Welcome screen first.
    init(welcomed: Bool = true, settings: AppSettings = AppSettings()) {
        var settings = settings
        settings.welcomed = welcomed
        self.settings = SettingsBox(settings)
        engine = FakeEngine(settings: self.settings)
    }

    var paths: WarzagPaths { WarzagPaths(home: options.home, userCacheDirectory: nil) }
    var store: SetupStateStore { SetupStateStore(paths: paths, fileSystem: fileSystem) }
    var services: AppServices {
        AppServices(system: system, engine: engine, steam: steam, game: game, clock: clock, appUpdate: appUpdate,
                    isDemo: false)
    }

    func makeModel() -> AppModel {
        let model = AppModel(options: options, services: services, settings: settings, fileSystem: fileSystem,
                             log: log)
        model.heartbeatInterval = nil
        return model
    }

    func performer() -> AppStepPerformer {
        var performer = AppStepPerformer(services: services, paths: paths, activity: ActivitySink(), log: .disabled)
        performer.steamStartTimeout = 3
        performer.signInGrace = 2
        return performer
    }

    /// setup.json for a Mac that finished setup.
    func saveReadyState(loginMode: LoginMode = .steam) throws {
        var state = SetupState(loginMode: loginMode)
        for track in SetupTrack.allCases {
            state[track] = TrackState(step: track.steps.last!, status: .done)
        }
        try store.save(state)
        engine.set { $0.active = FakeEngine.runtime(.n) }
        game.set {
            $0.launcherExtracted = true
            $0.eulaAccepted = true
            $0.content = ContentSummary(state: .installed, lastUpdate: Date(timeIntervalSince1970: 1_792_000_000),
                                        libraryBytes: 52_600_000_000, build: "2026.10.15.13.08")
        }
    }
}

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() {
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return true
}

/// Set once from any task, read from the test.
final class Flag: Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}

func temporaryDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "warzag-app-tests-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
