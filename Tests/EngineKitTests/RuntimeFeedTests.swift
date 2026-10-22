import CryptoKit
import Foundation
import RuntimeKit
import Testing
import WarzagCore
import WarzagTestSupport
@testable import EngineKit

/// The engine from a signed runtime feed, step by step as setup runs it.
@Suite struct RuntimeFeedTests {
    let fixture = EngineFixture()
    var runtime: RuntimeService { fixture.engine.runtime }
    let feed = RuntimeFeed(url: URL(string: "https://releases.example.org/runtime/n/manifest.json")!,
                           appVersion: "0.1.0", macOSVersion: "26.5.1")
    /// The pins with the tests' key standing in for the release key.
    let trust = ManifestTrust(publicKeys: ["rt-test": EngineFixture.publicKey],
                              signerFingerprints: [RuntimeTrust.projectCertificate])

    /// A pack signed by the project certificate, its manifest on the feed and the pack at its URL.
    @discardableResult
    func publish(version: String, serial: UInt64 = 42, killSwitch: KillSwitch = .none,
                 key: Curve25519.Signing.PrivateKey = EngineFixture.key) throws -> RuntimeManifest {
        let published = try fixture.pack(version: version, serial: serial, signer: RuntimeTrust.projectCertificate)
        var manifest = published.manifest
        manifest.killSwitch = killSwitch
        fixture.http.respond(to: feed.url, with: try EngineFixture.signed(manifest, with: key))
        let bytes = try #require(fixture.fileSystem.data(at: published.pack.plainPath))
        fixture.http.respond(to: manifest.url, with: bytes)
        fixture.signatures.set(.certificate(RuntimeTrust.projectCertificate))
        return manifest
    }

    @Test func aFeedInstallsItsRuntimeStepByStep() async throws {
        // A development engine was in use: it stays as the previous runtime.
        let development = try #require(try fixture.registerDevelopmentRuntime().current)
        let published = try publish(version: "0.3.0")

        let manifest = try await runtime.fetchManifest(from: feed, trust: trust)
        #expect(manifest == published)
        #expect(try runtime.store.load().lastSerial == 42)
        #expect(runtime.savedManifest(for: feed, trust: trust) == published)
        #expect(!runtime.isCurrent(manifest))

        let progress = Recorder<DownloadProgress>()
        try await runtime.downloadPack(for: manifest) { progress.append($0) }
        #expect(progress.all.last == DownloadProgress(receivedBytes: manifest.size, totalBytes: manifest.size))
        try FileDigest.verify(runtime.packFile(for: manifest), sha256: manifest.sha256, size: manifest.size,
                              fileSystem: fixture.fileSystem)

        try await runtime.stagePack(for: manifest)
        #expect(try runtime.store.load().current?.id == development.id, "staged is not installed")
        // Unpacked inside the store, out of Spotlight, while it waits for activatePack (setup may quit in between).
        let staged = fixture.paths.runtimeStaging.appending(path: "n-0.3.0/Warzag.app")
        #expect(fixture.fileSystem.text(at: staged.plainPath + "/Contents/MacOS/wine") == "wine loader 0.3.0")

        let state = try runtime.activatePack(for: manifest)
        #expect(state.current?.id == "n-0.3.0")
        #expect(state.current?.channel == .n)
        #expect(state.current?.signerFingerprint == RuntimeTrust.projectCertificate)
        #expect(state.previous?.id == development.id)
        #expect(runtime.isCurrent(manifest))
        #expect(fixture.fileSystem.text(at: fixture.paths.gameHost(.n, version: "0.3.0").plainPath
            + "/Contents/MacOS/wine") == "wine loader 0.3.0")
        #expect(try fixture.fileSystem.contentsOfDirectory(at: runtime.workDirectory).map(\.lastPathComponent)
            == ["feed-manifest.json"])
        #expect(try fixture.fileSystem.contentsOfDirectory(at: fixture.paths.runtimeStaging).isEmpty)
        #expect(fixture.http.requests == [feed.url, manifest.url])
    }

    /// A manifest naming another engine channel is no manifest Warzag can read.
    @Test func aFeedManifestOfAnotherChannelIsRefused() async throws {
        let manifest = try publish(version: "0.3.0")
        let text = String(decoding: try manifest.canonicalBytes(), as: UTF8.self)
        let payload = Data(text.replacingOccurrences(of: #""channel":"n""#, with: #""channel":"x""#).utf8)
        let envelope = SignedManifest(keyId: "rt-test", payload: payload,
                                      signature: try EngineFixture.key.signature(for: payload))
        fixture.http.respond(to: feed.url, with: try envelope.encoded())
        do {
            _ = try await runtime.fetchManifest(from: feed, trust: trust)
            Issue.record("a manifest of another channel was accepted")
        } catch RuntimeServiceError.manifestRejected(.malformedManifest) {
        }
        // Refused before anything was recorded or kept.
        #expect(try runtime.store.load().lastSerial == nil)
        #expect(!fixture.fileSystem.fileExists(at: runtime.feedManifestFile))
        #expect(fixture.http.requests == [feed.url])
    }

    @Test func onlyAPinnedKeyAndAnHTTPSFeedAreAccepted() async throws {
        try publish(version: "0.3.0", key: EngineFixture.strangerKey)
        await #expect(throws: RuntimeServiceError.manifestRejected(.badSignature)) {
            _ = try await runtime.fetchManifest(from: feed, trust: trust)
        }
        // This build's real pins do not know the tests' key at all.
        try publish(version: "0.3.0")
        await #expect(throws: RuntimeServiceError.manifestRejected(.unknownKey("rt-test"))) {
            _ = try await runtime.fetchManifest(from: feed, trust: RuntimeTrust.pinned)
        }
        var plain = feed
        plain.url = URL(string: "http://releases.example.org/runtime/n/manifest.json")!
        await #expect(throws: RuntimeServiceError.insecureFeed("http://releases.example.org/runtime/n/manifest.json")) {
            _ = try await runtime.fetchManifest(from: plain, trust: trust)
        }
        #expect(try runtime.store.load().lastSerial == nil)
    }

    @Test func anOlderManifestCannotTakeTheEngineBack() async throws {
        try publish(version: "0.3.0", serial: 42)
        _ = try await runtime.fetchManifest(from: feed, trust: trust)
        try publish(version: "0.2.0", serial: 41)
        await #expect(throws: RuntimeServiceError.manifestRejected(.olderSerial(received: 41, accepted: 42))) {
            _ = try await runtime.fetchManifest(from: feed, trust: trust)
        }
        #expect(runtime.savedManifest(for: feed, trust: trust)?.version == "0.3.0")
    }

    /// A check (the app's Check for Updates) verifies as fetchManifest does and records nothing: no serial floor, no
    /// revocations (which would roll the current runtime back under a game that runs on it), no kept manifest. It
    /// refuses what fetchManifest refuses.
    @Test func aCheckVerifiesTheManifestAndRecordsNothing() async throws {
        let first = try publish(version: "0.3.0")
        _ = try await runtime.fetchManifest(from: feed, trust: trust)
        try await runtime.downloadPack(for: first)
        try await runtime.stagePack(for: first)
        try runtime.activatePack(for: first)
        let state = try runtime.store.load()

        var revoking = try fixture.pack(version: "0.4.0", serial: 43, signer: RuntimeTrust.projectCertificate).manifest
        revoking.revoked = ["n-0.3.0"]
        fixture.http.respond(to: feed.url, with: try EngineFixture.signed(revoking))
        #expect(try await runtime.checkManifest(from: feed, trust: trust) == revoking)
        #expect(try runtime.store.load() == state)
        #expect(runtime.savedManifest(for: feed, trust: trust) == first)
        #expect(runtime.isCurrent(first))

        try publish(version: "0.2.0", serial: 41)
        await #expect(throws: RuntimeServiceError.manifestRejected(.olderSerial(received: 41, accepted: 42))) {
            _ = try await runtime.checkManifest(from: feed, trust: trust)
        }
        #expect(try runtime.store.load() == state)
    }

    @Test func theKeptManifestIsVerifiedAgainOnEveryRead() async throws {
        try publish(version: "0.3.0")
        _ = try await runtime.fetchManifest(from: feed, trust: trust)
        #expect(runtime.savedManifest(for: feed, trust: trust) != nil)
        // Another key (a release build reading what a development build kept): not trusted.
        #expect(runtime.savedManifest(for: feed, trust: RuntimeTrust.release) == nil)
        // Expired since it was fetched: the steps fetch a fresh one.
        fixture.clock.advance(by: 31 * 86_400)
        #expect(runtime.savedManifest(for: feed, trust: trust) == nil)
    }

    @Test func aDamagedDownloadIsDeletedAndFetchedAgain() async throws {
        let manifest = try publish(version: "0.3.0")
        _ = try await runtime.fetchManifest(from: feed, trust: trust)
        fixture.http.respond(to: manifest.url, with: Data("warzag-pack 0.3.X".utf8))
        await #expect(throws: DigestMismatch.self) { try await runtime.downloadPack(for: manifest) }
        #expect(!fixture.fileSystem.fileExists(at: runtime.packFile(for: manifest)))
        fixture.http.respond(to: manifest.url, with: Data("warzag-pack 0.3.0".utf8))
        try await runtime.downloadPack(for: manifest)
        // An intact pack is not fetched a third time.
        let requests = fixture.http.requests.count
        try await runtime.downloadPack(for: manifest)
        #expect(fixture.http.requests.count == requests)
    }

    @Test func activationChecksTheStagedHostAgain() async throws {
        let manifest = try publish(version: "0.3.0")
        _ = try await runtime.fetchManifest(from: feed, trust: trust)
        // Nothing staged yet (a crash before the unpack finished): nothing to activate.
        #expect(throws: RuntimeStoreError.stagedHostMissing) { try runtime.activatePack(for: manifest) }
        try await runtime.downloadPack(for: manifest)
        try await runtime.stagePack(for: manifest)
        // Signed by someone else by now: never the engine.
        fixture.signatures.set(.certificate(String(repeating: "cd", count: 32)))
        #expect(throws: RuntimeInstallError.self) { try runtime.activatePack(for: manifest) }
        #expect(try runtime.store.load().current == nil)
    }

    /// What is in Runtimes.noindex/staging, by name.
    var staged: [String] {
        ((try? fixture.fileSystem.contentsOfDirectory(at: fixture.paths.runtimeStaging)) ?? [])
            .map(\.lastPathComponent).sorted()
    }

    /// Setup's verify step staged one manifest's engine and its install step activates another (the kept one expired or
    /// was replaced): the first copy must not stay in Application Support, which macOS never purges and backups copy.
    @Test func aManifestChangeBetweenStagingAndActivationLeavesNothingStaged() async throws {
        let first = try publish(version: "0.3.0")
        _ = try await runtime.fetchManifest(from: feed, trust: trust)
        try await runtime.downloadPack(for: first)
        try await runtime.stagePack(for: first)
        #expect(staged == ["n-0.3.0"])

        let second = try publish(version: "0.3.1", serial: 43)
        #expect(try await runtime.fetchManifest(from: feed, trust: trust) == second)
        #expect(throws: RuntimeStoreError.stagedHostMissing) { try runtime.activatePack(for: second) }
        try await runtime.downloadPack(for: second)
        try await runtime.stagePack(for: second)
        #expect(staged == ["n-0.3.1"])
        #expect(try runtime.activatePack(for: second).current?.id == "n-0.3.1")
        #expect(staged.isEmpty)
        #expect(try fixture.fileSystem.contentsOfDirectory(at: fixture.paths.runtimeDirectory(.n))
            .map(\.lastPathComponent) == ["0.3.1"])
    }

    /// A copy a crash cut short goes with the next staging; a use-local clone another process is making stays (its own
    /// install removes it). Choosing a development engine clears a feed pack that waited for its activation, which the
    /// feed's install step stages again if the feed's engine is chosen again.
    @Test func stagingKeepsOnlyWhatIsStillWanted() async throws {
        let manifest = try publish(version: "0.3.0")
        _ = try await runtime.fetchManifest(from: feed, trust: trust)
        try await runtime.downloadPack(for: manifest)
        let staging = fixture.paths.runtimeStaging.plainPath
        fixture.fileSystem.addFile(staging + "/n-0.2.9/Warzag.app/Contents/MacOS/wine", "cut short by a crash")
        fixture.fileSystem.addFile(staging + "/n-dev-20261016-200000/Warzag.app/Contents/MacOS/wine", "being cloned")
        try await runtime.stagePack(for: manifest)
        #expect(staged == ["n-0.3.0", "n-dev-20261016-200000"])

        fixture.signatures.set(.adHoc)
        let development = try #require(try fixture.registerDevelopmentRuntime().current)
        #expect(development.id.hasPrefix("n-dev-"))
        #expect(staged == ["n-dev-20261016-200000"])

        fixture.signatures.set(.certificate(RuntimeTrust.projectCertificate))
        #expect(throws: RuntimeStoreError.stagedHostMissing) { try runtime.activatePack(for: manifest) }
        try await runtime.stagePack(for: manifest)
        #expect(try runtime.activatePack(for: manifest).previous?.id == development.id)
        #expect(staged == ["n-dev-20261016-200000"])
    }

    @Test func aPackSignedByAnotherCertificateIsNeverStaged() async throws {
        let manifest = try publish(version: "0.3.0")
        _ = try await runtime.fetchManifest(from: feed, trust: trust)
        try await runtime.downloadPack(for: manifest)
        fixture.signatures.set(.adHoc)
        await #expect(throws: RuntimeInstallError.signerMismatch(expected: RuntimeTrust.projectCertificate,
                                                                 actual: RuntimeSigner.adHoc)) {
            try await runtime.stagePack(for: manifest)
        }
        #expect(throws: RuntimeStoreError.stagedHostMissing) { try runtime.activatePack(for: manifest) }
    }

    @Test func aPausedRuntimeIsRefusedBeforeAnyOfItsPackIsFetched() async throws {
        let manifest = try publish(version: "0.3.0",
                                   killSwitch: KillSwitch(level: .blockInstall, message: "crashes on M1 Macs"))
        // The manifest itself is fine (it may carry revocations): it is accepted and kept.
        #expect(try await runtime.fetchManifest(from: feed, trust: trust) == manifest)
        await #expect(throws: RuntimeInstallError.blocked("crashes on M1 Macs")) {
            try await runtime.downloadPack(for: manifest)
        }
        #expect(fixture.http.requests == [feed.url], "no pack request")
        #expect(!fixture.fileSystem.fileExists(at: runtime.packFile(for: manifest)))
        // The steps after it refuse it the same way.
        await #expect(throws: RuntimeInstallError.blocked("crashes on M1 Macs")) {
            try await runtime.stagePack(for: manifest)
        }
        #expect(fixture.http.requests == [feed.url])
    }

    @Test func aRuntimeThisMacRolledBackIsNotFetchedAgainUnlessAskedFor() async throws {
        try fixture.registerDevelopmentRuntime()
        let manifest = try publish(version: "0.3.0")
        _ = try await runtime.fetchManifest(from: feed, trust: trust)
        try await runtime.downloadPack(for: manifest)
        try await runtime.stagePack(for: manifest)
        try runtime.activatePack(for: manifest)
        #expect(try runtime.rollback().rolledBack == ["n-0.3.0"])

        // The feed keeps offering it; its pack (deleted after the install) is not downloaded again.
        let requests = fixture.http.requests
        await #expect(throws: RuntimeInstallError.rolledBack("n-0.3.0")) {
            try await runtime.downloadPack(for: manifest)
        }
        #expect(fixture.http.requests == requests)
        // An explicit reinstall fetches it.
        try await runtime.downloadPack(for: manifest, allowRolledBack: true)
        #expect(fixture.http.requests == requests + [manifest.url])
    }
}

/// `downloadPack` on the real disk with WarzagCore's resumable downloader behind a scripted server: a pack whose
/// download breaks off resumes from the bytes it has, guarded by If-Range, and lands only once its SHA-256 is right.
@Suite struct RuntimeFeedLiveDownloadTests {
    @Test func anInterruptedPackDownloadResumes() async throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let body = Data((0..<250_000).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 5) })
        let manifest = RuntimeManifest(
            serial: 1, expires: Date().addingTimeInterval(86_400), id: "n-0.3.0", version: "0.3.0", channel: .n,
            arch: "arm64", minLauncher: "0.1.0", minMacOS: "15.0",
            url: URL(string: "https://releases.example.org/WarzagRuntime-n-0.3.0.aar")!, size: Int64(body.count),
            sha256: SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined(),
            signerFingerprint: RuntimeTrust.projectCertificate)
        let transport = FakeRangeTransport(body: body, behaviors: [.dropAfter(100_000)])
        let downloader = ResumablePackDownloader(downloader: ResumableDownloader(transport: transport, clock: ManualClock()))
        let engine = Engine(
            paths: WarzagPaths(home: home, userCacheDirectory: nil), fileSystem: LocalEngineFileSystem(),
            runner: RecordingProcessRunner(), http: FakeHTTPClient(), signatures: FakeSignatures(),
            extractor: AppleArchiveExtractor(runner: RecordingProcessRunner()), clock: ManualClock(),
            windowsUserName: "tenno", inheritedEnvironment: [:], packDownloader: downloader)
        let progress = Recorder<DownloadProgress>()
        try await engine.runtime.downloadPack(for: manifest) { progress.append($0) }
        #expect(try Data(contentsOf: engine.runtime.packFile(for: manifest)) == body)
        #expect(transport.requests == [FakeRangeTransport.Request(offset: 0, validator: nil),
                                       FakeRangeTransport.Request(offset: 100_000, validator: #""v1""#)])
        #expect(progress.all.last?.receivedBytes == Int64(body.count))
        #expect(progress.all.map(\.receivedBytes) == progress.all.map(\.receivedBytes).sorted())

        // A server now serving other bytes under the same URL: refused, and nothing is left to splice onto.
        let other = FakeRangeTransport(body: Data(repeating: 7, count: body.count), etag: #""v2""#)
        try FileManager.default.removeItem(at: engine.runtime.packFile(for: manifest))
        var replaced = engine
        replaced.packDownloader = ResumablePackDownloader(downloader: ResumableDownloader(transport: other,
                                                                                          clock: ManualClock()))
        await #expect(throws: DigestMismatch.self) { try await replaced.runtime.downloadPack(for: manifest) }
        #expect(!FileManager.default.fileExists(atPath: engine.runtime.packFile(for: manifest).plainPath))
        #expect(!FileManager.default.fileExists(
            atPath: ResumableDownloader.partURL(for: engine.runtime.packFile(for: manifest)).plainPath))
    }
}
