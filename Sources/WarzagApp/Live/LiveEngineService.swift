import EngineKit
import Foundation
import ProfileKit
import RuntimeKit
import SteamHostKit
import WarzagCore
import WineKit

/// EngineKit for the app: the engine from the release page's signed feed, development runtimes (`use-local`), the
/// prefix and its doctor, and the Steam license probe.
struct LiveEngineService: EngineServicing {
    let paths: WarzagPaths
    let settings: SettingsBox
    let steam: SteamLocations
    let inheritedEnvironment: [String: String]
    let log: AppLog
    /// Runs Wine (and wineserver); tests record the commands instead.
    var runner: any ProcessRunning = SystemProcessRunner()
    /// Reads code signatures (use-local checks the clone); tests answer without Security.framework.
    var signatures: any CodeSignatureInspecting = SecurityCodeSignatureInspector()
    /// The signed runtime manifest's URL (`RuntimeFeedSource`), nil without one.
    var feed: URL?
    /// The manifest keys and pack signer this build pins (release builds: the release key only).
    var trust: ManifestTrust = RuntimeTrust.pinned
    /// Checked against a manifest's minLauncher.
    var appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    /// The feed's manifest and packs; tests serve them without a network.
    var http: any HTTPClient = URLSessionHTTPClient(session: URLSessionHTTPClient.uncachedSession)
    var packDownloader: any PackDownloading = ResumablePackDownloader()
    /// Unpacks runtime packs (`aa extract`); nil: Apple Archive with `runner`.
    var extractor: (any PackExtracting)?

    var engine: Engine {
        var engine = Engine.live(paths: paths, inheritedEnvironment: inheritedEnvironment)
        engine.runner = runner
        engine.signatures = signatures
        engine.http = http
        engine.packDownloader = packDownloader
        engine.extractor = extractor ?? AppleArchiveExtractor(runner: runner)
        return engine
    }

    func developmentRuntime() -> DevelopmentRuntime? {
        guard let bundle = settings.engine.developmentRuntime else { return nil }
        // The kit reads the channel from the loader's architecture (and the host's WarzagRuntimeChannel key).
        return DevelopmentRuntime(bundle: bundle,
                                  channel: try? RuntimeHostChannel.detect(bundle: bundle, fileSystem: LocalFileSystem()))
    }

    func activeRuntime() -> RuntimeSummary? {
        let engine = engine
        guard let active = try? engine.runtime.active(), let status = try? engine.runtime.status(),
              let current = status.current else { return nil }
        return RuntimeSummary(id: active.runtime.id, version: active.runtime.version, channel: active.runtime.channel,
                              development: current.development, hostPath: active.host.bundle.plainPath)
    }

    func registerDevelopmentRuntime(_ runtime: DevelopmentRuntime) async throws -> RuntimeSummary {
        guard runtime.channel != nil else {
            throw RuntimeServiceError.notAGameHost(runtime.bundle.plainPath)
        }
        let records = DevelopmentRuntimeRecord.Store(paths: paths)
        let stamp = DevelopmentRuntimeRecord.stamp(of: runtime.bundle)
        if let active = activeRuntime(), active.development, let record = records.load(),
           record.source == runtime.bundle.plainPath, record.stamp == stamp, record.runtimeID == active.id {
            return active
        }
        // Cloned (instant on the same APFS volume), signature checked, made current; the previous runtime is kept.
        try engine.runtime.useLocal(runtime.bundle)
        guard let active = activeRuntime() else { throw RuntimeServiceError.noRuntime }
        records.save(DevelopmentRuntimeRecord(source: runtime.bundle.plainPath, stamp: stamp, runtimeID: active.id))
        return active
    }

    // MARK: The engine from the release page

    func feedURL() -> URL? { feed }

    private func runtimeFeed() throws -> RuntimeFeed {
        guard let feed else { throw NoRuntimeFeed() }
        return RuntimeFeed(url: feed, appVersion: appVersion, macOSVersion: HardwareProfile.detect().macOSVersion)
    }

    func fetchEngineManifest() async throws -> EngineOffer {
        let runtime = engine.runtime
        return Self.offer(try await runtime.fetchManifest(from: try runtimeFeed(), trust: trust), runtime: runtime)
    }

    func checkEngineManifest() async throws -> EngineOffer {
        let runtime = engine.runtime
        return Self.offer(try await runtime.checkManifest(from: try runtimeFeed(), trust: trust), runtime: runtime)
    }

    private static func offer(_ manifest: RuntimeManifest, runtime: RuntimeService) -> EngineOffer {
        EngineOffer(id: manifest.id, version: manifest.version, bytes: manifest.size,
                    installed: runtime.isCurrent(manifest))
    }

    /// The manifest fetchManifest kept (verified again), or a fresh one: it may have expired since, or Warzag
    /// restarted on a later step after the cache was emptied.
    private func feedManifest(_ runtime: RuntimeService) async throws -> RuntimeManifest {
        let feed = try runtimeFeed()
        if let saved = runtime.savedManifest(for: feed, trust: trust) { return saved }
        return try await runtime.fetchManifest(from: feed, trust: trust)
    }

    func downloadEngine(progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let runtime = engine.runtime
        let manifest = try await feedManifest(runtime)
        guard !runtime.isCurrent(manifest) else { return }
        try await runtime.downloadPack(for: manifest) { progress($0.receivedBytes, $0.totalBytes ?? manifest.size) }
        log.write("setup: engine pack \(manifest.id) downloaded and its SHA-256 checked")
    }

    func verifyEngine() async throws {
        let runtime = engine.runtime
        let manifest = try await feedManifest(runtime)
        guard !runtime.isCurrent(manifest) else { return }
        // Nothing is fetched when the pack is still there; the cache may have been emptied since the download.
        try await runtime.downloadPack(for: manifest)
        try await runtime.stagePack(for: manifest)
    }

    func activateEngine() async throws -> RuntimeSummary {
        let runtime = engine.runtime
        let manifest = try await feedManifest(runtime)
        if !runtime.isCurrent(manifest) {
            do {
                try runtime.activatePack(for: manifest)
            } catch RuntimeStoreError.stagedHostMissing {
                // Warzag restarted between verifying and installing: check it again, then switch.
                try await runtime.downloadPack(for: manifest)
                try await runtime.stagePack(for: manifest)
                try runtime.activatePack(for: manifest)
            }
        }
        guard let active = activeRuntime() else { throw RuntimeServiceError.noRuntime }
        return active
    }

    func setUpPrefix() async throws -> PrefixSummary {
        let engine = engine
        let report = try await engine.prefix.create(macDriver: macDriver(engine))
        return PrefixSummary(created: report.created, library: report.library, log: report.log)
    }

    func repairPrefix() async throws -> PrefixSummary {
        let engine = engine
        let report = try await engine.prefix.repair(macDriver: macDriver(engine))
        return PrefixSummary(created: report.created, library: report.library, log: report.log)
    }

    /// What create or repair last recorded in the prefix, while a runtime is active.
    func prefixRuntimeID() -> String? {
        let engine = engine
        guard (try? engine.runtime.active()) != nil else { return nil }
        return (try? PrefixManifest.load(from: engine.prefix.layout, fileSystem: engine.fileSystem))?.runtimeID
    }

    /// The settings the prefix was set up with (a repair keeps the player's), else the tier preset's RetinaMode, as
    /// `warzagctl prefix create` does.
    private func macDriver(_ engine: Engine) -> MacDriverSettings {
        engine.prefix.recordedMacDriver()
            ?? MacDriverSettings(retinaMode: PresetCatalog.preset(for: HardwareProfile.detect()).retinaMode)
    }

    func doctor() async -> [HealthCheck] {
        let report = await engine.prefix.doctor()
        let home = FileManager.default.homeDirectoryForCurrentUser.plainPath
        return report.checks.map { check in
            // Passed checks in plain words; a failed one keeps the engine's detail, with the home folder as "~".
            let detail = check.passed ? (L10n.doctorPassed(check.name) ?? check.detail)
                : check.detail.replacingOccurrences(of: home, with: "~")
            return HealthCheck(id: "engine.\(check.name)", title: L10n.doctorTitle(check.name), passed: check.passed,
                               detail: detail)
        }
    }

    /// wz-steamprobe.exe through the bridge, with the Steam variables (it registers as Warframe for a moment, so it
    /// runs only for this check). Its stdout goes to the prefix log; its exit status is the answer, given after it
    /// released its Steam connection. It does not wait for the prefix to go quiet (`wineserver -w`): DE's launcher
    /// shares the prefix and may be downloading for an hour, which would hold back the license card.
    func probeSteamLicense() async -> LicenseProbeResult {
        let engine = engine
        do {
            // DE's launcher may be unpacking or downloading in the same prefix; Wine copes. The invocation is
            // EngineKit's, shared with `warzagctl steam probe`.
            let output = try await engine.prefix.runSteamProbe(steamClientDirectory: steam.clientDirectory)
            return LicenseProbeResult(exitCode: output.exitCode)
        } catch {
            log.write("probe: \(error)")
            return .failed(String(describing: error))
        }
    }
}

/// What `use-local` registered last, so an unchanged development build is not cloned again on every setup run.
struct DevelopmentRuntimeRecord: Codable, Equatable, Sendable {
    var source: String
    /// Bundle version and modification times of the loader and the code signature: a rebuild changes them.
    var stamp: String
    var runtimeID: String

    static func stamp(of bundle: URL) -> String {
        let manager = FileManager.default
        func modified(_ relative: String) -> String {
            let path = bundle.appending(path: relative).plainPath
            let date = (try? manager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            return date.map { String(Int($0.timeIntervalSince1970)) } ?? "-"
        }
        let info = NSDictionary(contentsOf: bundle.appending(path: "Contents/Info.plist"))
        let version = info?["CFBundleVersion"] as? String ?? "-"
        return [version, modified("Contents/MacOS/wine"), modified("Contents/_CodeSignature/CodeResources")]
            .joined(separator: "/")
    }

    struct Store: Sendable {
        let url: URL

        init(paths: WarzagPaths) {
            url = paths.state.appending(path: "development-runtime.json")
        }

        func load() -> DevelopmentRuntimeRecord? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? WarzagJSON.decoder().decode(DevelopmentRuntimeRecord.self, from: data)
        }

        func save(_ record: DevelopmentRuntimeRecord) {
            guard let data = try? WarzagJSON.encoder(pretty: true).encode(record) else { return }
            try? LocalFileSystem().writeAtomically(data, to: url)
        }
    }
}
