import AppKit
import Foundation
import GameKit
import ProfileKit
import Synchronization
import WarzagCore

/// Demo mode (`WARZAG_DEMO=1` or `--demo`): every service is simulated with believable timing and numbers, so the
/// whole first-run flow, Home, Play and Updates can be shown and smoke-tested. Nothing here starts Wine, Steam or DE's
/// launcher, downloads anything or writes outside WARZAG_HOME; the UI labels the run "Demo" everywhere. Warzag's own
/// simulated update ends as a real one does, with Warzag quitting (nothing was installed, so nothing opens again).
enum DemoServices {
    static func make(speed: Double) -> AppServices {
        let world = DemoWorld(speed: speed)
        return AppServices(system: DemoSystem(world: world), engine: DemoEngine(world: world),
                           steam: DemoSteam(world: world), game: DemoGame(world: world), clock: SystemClock(),
                           appUpdate: DemoAppUpdates(world: world), isDemo: true)
    }
}

/// The simulated state every demo service shares.
final class DemoWorld: Sendable {
    struct State {
        var runtime: RuntimeSummary?
        /// What the pretend release page offered last.
        var offeredEngine: EngineOffer?
        /// The engine the prefix was last set up for.
        var prefixRuntime: String?
        var steamStartedAt: Date?
        var installerDone = false
        var launcherExtracted = false
        var eulaAccepted = false
        var gameInstalled = false
        var lastUpdate: Date?
        /// Digital Extremes has an update out: the next run of the pretend launcher in Updates downloads it.
        var gameUpdatePending = true
        /// Updates' run of the pretend launcher was closed (Cancel, quitting).
        var contentRunCancelled = false
        var gameRunning = false
        var quitRequested = false
    }

    let speed: Double
    let state = Mutex(State())

    init(speed: Double) {
        self.speed = speed
    }

    /// Sleeps for a simulated duration (scaled by the demo speed).
    func pause(_ seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000 / speed)))
    }

    func read<T: Sendable>(_ body: (State) -> T) -> T { state.withLock { body($0) } }
    func change(_ body: (inout State) -> Void) { state.withLock { body(&$0) } }
}

struct DemoSystem: SystemServicing {
    let world: DemoWorld

    func hardware() -> HardwareProfile { HardwareProfile.detect() }
    func powerAdvice(for tier: PerformanceTier) -> [PowerAdvice] { PowerAdvisor().advice(for: tier) }
    func applicationLocation() -> ApplicationLocation {
        ApplicationLocation(url: Bundle.main.bundleURL, inApplicationsFolder: true)
    }
    func moveToApplications() async throws {}
    func storage(for library: URL) -> StorageCheck {
        StorageCheck(volume: VolumeInfo(availableCapacity: 412_000_000_000, isCaseSensitive: false, isLocal: true,
                                        format: "apfs"),
                     libraryBytes: world.read { $0.gameInstalled } ? 52_600_000_000 : 0)
    }
    func networkIsAvailable() async -> Bool { true }
    func networkAvailability() -> AsyncStream<Bool> { AsyncStream { $0.yield(true) } }

    // Nothing outside Warzag's own (temporary) data is opened in a demo.
    @MainActor func open(_ url: URL) { if url.isFileURL { NSWorkspace.shared.open(url) } }
    @MainActor func revealInFinder(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    @MainActor func showSteam() {}
    @MainActor func showGameHost(openedProcess: Int32?) {}
    func keepGameInFront(openedProcess: Int32, hidingSteam: Bool,
                         events: @escaping @Sendable (GameFocusEvent) -> Void) async {}
    @MainActor func setDockBadge(_ text: String?) { NSApp?.dockTile.badgeLabel = text }
    @MainActor func requestAttention() {}
    @MainActor func keepAwake(_ reason: KeepAwakeReason?) {}
    // The simulated game has no window to hand the front to, so a demo never hides Warzag.
    @MainActor func setDockPresence(_ presence: DockPresence) {}
    @MainActor func showMainWindow() {}
    @MainActor func quit() { AppTermination.request() }
}

/// The engine from a pretend release page, as a player's setup gets it: offered, downloaded, checked, installed.
struct DemoEngine: EngineServicing {
    let world: DemoWorld
    /// The page offers the first engine until setup has installed it, then a newer one, as if a release came out
    /// meanwhile (so Updates has one to install).
    static let firstVersion = "0.2.0-demo"
    static let newerVersion = "0.3.0-demo"
    static let packBytes: Int64 = 182_000_000

    func developmentRuntime() -> DevelopmentRuntime? { nil }
    func activeRuntime() -> RuntimeSummary? { world.read { $0.runtime } }

    func registerDevelopmentRuntime(_ runtime: DevelopmentRuntime) async throws -> RuntimeSummary {
        try await world.pause(1.5)
        let summary = RuntimeSummary(id: "n-demo", version: "0.2.0-demo", channel: .n, development: true,
                                     hostPath: "/Demo/Warzag.app")
        world.change { $0.runtime = summary }
        return summary
    }

    // The .invalid host is never asked: nothing here touches the network.
    func feedURL() -> URL? { URL(string: "https://release.warzag-demo.invalid/runtime/n/manifest.json") }

    func fetchEngineManifest() async throws -> EngineOffer {
        try await world.pause(1)
        let offer = world.read { Self.offer(installed: $0.runtime) }
        world.change { $0.offeredEngine = offer }
        return offer
    }

    /// As the real check: the offer, with nothing kept for the steps (an update fetches it again).
    func checkEngineManifest() async throws -> EngineOffer {
        try await world.pause(1)
        return world.read { Self.offer(installed: $0.runtime) }
    }

    static func offer(installed runtime: RuntimeSummary?) -> EngineOffer {
        let version = runtime == nil ? firstVersion : newerVersion
        return EngineOffer(id: "n-\(version)", version: version, bytes: packBytes, installed: runtime?.version == version)
    }

    /// About 20 MB/s, shown faster than real time.
    func downloadEngine(progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let offer = world.read { $0.offeredEngine ?? Self.offer(installed: $0.runtime) }
        guard !offer.installed else { return }
        let steps = 30
        for step in 0...steps {
            progress(offer.bytes * Int64(step) / Int64(steps), offer.bytes)
            try await world.pause(0.3)
        }
    }

    func verifyEngine() async throws {
        try await world.pause(1.5)
    }

    func activateEngine() async throws -> RuntimeSummary {
        try await world.pause(1)
        let summary = world.read { state in
            let offer = state.offeredEngine ?? Self.offer(installed: state.runtime)
            return RuntimeSummary(id: offer.id, version: offer.version, channel: .n, development: false,
                                  hostPath: "/Demo/Runtimes.noindex/n/\(offer.version)/Warzag.app")
        }
        world.change { $0.runtime = summary }
        return summary
    }

    func setUpPrefix() async throws -> PrefixSummary {
        try await world.pause(4)
        world.change { $0.prefixRuntime = $0.runtime?.id }
        return PrefixSummary(created: true, library: "/Demo/Library/Warframe.noindex", log: "/Demo/prefix-n.log")
    }

    func repairPrefix() async throws -> PrefixSummary {
        try await world.pause(2)
        world.change { $0.prefixRuntime = $0.runtime?.id }
        return PrefixSummary(created: false, library: "/Demo/Library/Warframe.noindex", log: "/Demo/prefix-n.log")
    }

    func prefixRuntimeID() -> String? { world.read { $0.prefixRuntime } }

    func doctor() async -> [HealthCheck] {
        try? await world.pause(1)
        let detail = L10n.demoCheckDetail
        return ["runtime", "prefix", "manifest", "library", "dxmt", "lsteamclient", "bridge", "registry", "steam",
                "folders", "identity"].map {
            HealthCheck(id: "engine.\($0)", title: L10n.doctorTitle($0), passed: true, detail: detail)
        }
    }

    func probeSteamLicense() async -> LicenseProbeResult {
        try? await world.pause(2)
        return .owned
    }
}

struct DemoSteam: SteamServicing {
    let world: DemoWorld
    /// The pretend player signs in this long after Steam started: long enough for the sign-in card to show.
    static let signInAfter = 20.0

    func status() -> SteamSnapshot {
        let started = world.read { $0.steamStartedAt }
        let signedIn = started.map { Date().timeIntervalSince($0) * world.speed >= Self.signInAfter } ?? false
        return SteamSnapshot(installed: true, running: started != nil, signedIn: signedIn)
    }

    func install() async throws {}

    func start() async throws {
        try await world.pause(2)
        world.change { $0.steamStartedAt = $0.steamStartedAt ?? Date() }
    }

    func card() async -> SteamCard {
        let status = status()
        if !status.running { return SteamCard(state: .off) }
        return status.signedIn ? SteamCard(state: .signedIn, name: "Demo Tenno") : SteamCard(state: .signingIn)
    }

    func logIn() async -> Bool {
        try? await start()
        return true
    }

    func logOut() async {
        world.change { $0.steamStartedAt = nil }
    }

    func hideSteam() async {}

    func allowHiding(_ allowed: Bool) {}
}

struct DemoGame: GameServicing {
    let world: DemoWorld
    static let installerBytes: Int64 = 118_000_000
    static let contentBytes: Int64 = ContentConfiguration.defaultExpectedContentBytes

    func launcherExtracted() -> Bool { world.read { $0.launcherExtracted } }

    func downloadInstaller(progress: @escaping @Sendable (ContentRunState) -> Void) async throws {
        let steps = 16
        for step in 0...steps {
            progress(.downloadingInstaller(receivedBytes: Self.installerBytes * Int64(step) / Int64(steps),
                                           totalBytes: Self.installerBytes))
            try await world.pause(0.25)
        }
        progress(.checkingInstaller)
        try await world.pause(0.5)
        world.change { $0.installerDone = true }
    }

    func extractInstaller(progress: @escaping @Sendable (ContentRunState) -> Void) async throws {
        progress(.extractingInstaller)
        try await world.pause(3)
        world.change { $0.launcherExtracted = true }
    }

    func seedProfile() throws -> Bool { true }

    /// As Warzag's seed leaves it.
    func motionBlur() -> MotionBlurSetting { .off }

    func eulaAccepted() -> Bool { world.read { $0.eulaAccepted } }

    func waitForEULA(progress: @escaping @Sendable (ContentRunState) -> Void) async throws -> EULAOutcome {
        progress(.startingLauncher(attempt: 0))
        try await world.pause(2)
        // The pretend player reads DE's EULA and clicks I AGREE.
        for _ in 0..<12 {
            progress(.needsEULA)
            try await world.pause(0.5)
        }
        world.change { $0.eulaAccepted = true }
        return .accepted
    }

    func pinDirectX11() async throws {
        try await world.pause(0.3)
    }

    func downloadContent(progress: @escaping @Sendable (ContentRunState) -> Void) async throws -> ContentRunOutcome {
        // The expected size at a believable 44-49 MB/s, shown about thirty times faster than real time at demo speed 1.
        let steps = 120
        for step in 0...steps {
            let bytes = Self.contentBytes * Int64(step) / Int64(steps) * 94 / 100
            progress(.downloading(bytesThisRun: bytes, bytesOnDisk: bytes, expectedBytes: Self.contentBytes,
                                  megabytesPerSecond: Double(44 + (step * 7) % 6)))
            try await world.pause(0.25)
        }
        for step in 0...10 {
            progress(.preprocessing(fraction: Double(step) / 10))
            try await world.pause(0.3)
        }
        progress(.finishing)
        try await world.pause(1.5)
        world.change {
            $0.gameInstalled = true
            $0.lastUpdate = Date()
        }
        return .completed
    }

    /// Closes Updates' run of the pretend launcher (setup's runs here are not cancelled from outside).
    func cancelContentRun() async {
        world.change { $0.contentRunCancelled = true }
    }

    /// The pretend launcher's update run: the first one after setup downloads a hotfix (about 1.4 GB at 45 MB/s, shown
    /// thirty times faster than real time at demo speed 1), later ones find nothing new.
    func updateGame(progress: @escaping @Sendable (ContentRunState) -> Void) async throws -> GameUpdateOutcome {
        world.change { $0.contentRunCancelled = false }
        try await step(.startingLauncher(attempt: 0), progress, then: 1.5)
        let pending = world.read { $0.gameUpdatePending }
        if pending {
            let bytes: Int64 = 1_380_000_000
            let steps = 24
            for step in 0...steps {
                let done = bytes * Int64(step) / Int64(steps)
                try await self.step(.downloading(bytesThisRun: done, bytesOnDisk: 52_600_000_000 + done, expectedBytes: nil,
                                                 megabytesPerSecond: Double(43 + step % 5)), progress, then: 0.25)
            }
        }
        for step in 0...8 {
            try await self.step(.preprocessing(fraction: Double(step) / 8), progress, then: 0.3)
        }
        try await step(.finishing, progress, then: 1)
        world.change {
            $0.lastUpdate = Date()
            $0.gameUpdatePending = false
        }
        return pending ? .updated : .upToDate
    }

    /// Reports `state` and waits; a closed run (Cancel, quitting) stops here, as DE's launcher would.
    private func step(_ state: ContentRunState, _ progress: @Sendable (ContentRunState) -> Void,
                      then seconds: Double) async throws {
        if world.read({ $0.contentRunCancelled }) { throw CancellationError() }
        progress(state)
        try await world.pause(seconds)
    }

    func prefixIsBusy() -> Bool { world.read { $0.gameRunning } }

    func contentStatus() -> ContentSummary? {
        world.read { state in
            state.launcherExtracted || state.gameInstalled
                ? ContentSummary(state: state.gameInstalled ? .installed : .notInstalled, lastUpdate: state.lastUpdate,
                                 libraryBytes: state.gameInstalled ? 52_600_000_000 : 1_400_000_000,
                                 build: state.gameInstalled ? "2026.10.15.13.08" : nil)
                : nil
        }
    }

    func play(_ request: PlayRequest, updates: @escaping @Sendable (PlayUpdate) -> Void) async throws -> PlaySummary {
        for step in 0...8 {
            updates(.game(.updating(.preprocessing(fraction: Double(step) / 8))))
            try await world.pause(0.4)
        }
        updates(.game(.opening))
        try await world.pause(1)
        world.change {
            $0.gameRunning = true
            $0.quitRequested = false
        }
        updates(.game(.started(processIdentifier: 0)))
        let started = Date()
        let signals: [GameSignal] = request.steam ? [.steamActive, .steamLogin, .loggedIn] : [.loggedIn]
        for signal in signals {
            try await world.pause(1.5)
            updates(.game(.signal(signal)))
        }
        while !world.read({ $0.quitRequested }) {
            try await world.pause(0.5)
        }
        world.change { $0.gameRunning = false }
        let seconds = Date().timeIntervalSince(started) * world.speed
        updates(.game(.exited(seconds: seconds)))
        try await world.pause(1)
        updates(.game(.cleanedUp(forced: false)))
        world.change { $0.lastUpdate = Date() }
        return PlaySummary(seconds: seconds, signals: signals, forcedCleanup: false)
    }

    func quitGame() async {
        try? await world.pause(1)
        world.change { $0.quitRequested = true }
    }

    func forceQuitGame() async {
        world.change { $0.quitRequested = true }
    }
}

/// Warzag's own updates from a pretend release page: it offers the next version, which downloads with believable
/// timing; installing it installs nothing (Warzag then quits, as after a real update).
struct DemoAppUpdates: AppUpdateServicing {
    let world: DemoWorld
    static let bytes: Int64 = 46_000_000

    func currentVersion() -> AppVersion { AppVersion(bundle: .main) }

    func check() async throws -> AppUpdateCheck {
        try await world.pause(1.2)
        return .available(Self.offer(after: currentVersion()))
    }

    func prepare(_ offer: AppUpdateOffer,
                 progress: @escaping @Sendable (_ received: Int64, _ total: Int64) -> Void) async throws {
        let steps = 20
        for step in 0...steps {
            progress(offer.bytes * Int64(step) / Int64(steps), offer.bytes)
            try await world.pause(0.2)
        }
        // The checks: size, digest, bundle identity, code signature.
        try await world.pause(0.8)
    }

    func installPreparedUpdate() async throws {
        try await world.pause(1)
    }

    /// The next version: its last number one higher (0.1.0 offers 0.1.1), and the next build.
    static func offer(after current: AppVersion) -> AppUpdateOffer {
        var numbers = current.version.split(separator: ".").map(String.init)
        if let last = numbers.last, let number = Int(last) {
            numbers[numbers.count - 1] = String(number + 1)
        } else {
            numbers.append("1")
        }
        let build = Int(current.build).map { String($0 + 1) } ?? current.build + ".1"
        return AppUpdateOffer(version: numbers.joined(separator: "."), build: build, bytes: bytes, releaseNotes: nil)
    }
}
