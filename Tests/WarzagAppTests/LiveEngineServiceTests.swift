import CryptoKit
import EngineKit
import Foundation
import RuntimeKit
import SteamHostKit
import Synchronization
import Testing
import WarzagCore
import WarzagTestSupport
import WineKit
@testable import WarzagApp

/// `LiveEngineService` over a scratch home: EngineKit's own code on a host laid out like build/n/Warzag.app (real
/// files), with a recording runner instead of Wine and ad-hoc signatures.
struct LiveEngineServiceTests {
    /// Answers "ad hoc" for every bundle (as runtime/n/make-host.sh signs development builds) and counts the checks.
    final class AdHocSignatures: CodeSignatureInspecting {
        private let count = Mutex(0)
        var inspections: Int { count.withLock { $0 } }

        func signerFingerprint(of bundle: URL) throws -> String? {
            count.withLock { $0 += 1 }
            return nil
        }
    }

    struct Scratch {
        let root: URL
        let paths: WarzagPaths
        /// The development build use-local registers (cloned into Runtimes.noindex/n).
        let host: URL

        init() throws {
            root = try temporaryDirectory("live-engine")
            paths = WarzagPaths(home: root, userCacheDirectory: nil)
            host = root.appending(path: "build/n/Warzag.app", directoryHint: .isDirectory)
            let contents = host.appending(path: "Contents", directoryHint: .isDirectory)
            try Self.write("""
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0"><dict>
                <key>CFBundleExecutable</key><string>wine</string>
                <key>CFBundleIdentifier</key><string>com.warzag.gamehost</string>
                <key>CFBundleShortVersionString</key><string>0.2.0</string>
                <key>CFBundleVersion</key><string>1</string>
                <key>WarzagRuntimeChannel</key><string>n</string>
                </dict></plist>
                """, to: contents.appending(path: "Info.plist"))
            for program in ["MacOS/wine", "MacOS/wineserver"] {
                let url = contents.appending(path: program)
                try Self.write("#!/bin/sh\nexit 1\n", to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.plainPath)
            }
            for file in ["lib/wine/aarch64-windows/lsteamclient.dll", "renderers/dxmt/aarch64-windows/winemetal.dll",
                         "renderers/dxmt/aarch64-windows/nvapi64.dll", "renderers/dxmt/aarch64-windows/nvngx.dll",
                         "share/warzag/bridge/steam.exe", "share/warzag/bridge/steamclient64-forwarder.dll",
                         "share/warzag/bridge/wz-steamprobe.exe", "share/warzag/bridge/steam.reg"] {
                try Self.write(file, to: contents.appending(path: file))
            }
        }

        static func write(_ text: String, to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        func service(runner: any ProcessRunning, signatures: any CodeSignatureInspecting) -> LiveEngineService {
            var service = LiveEngineService(paths: paths, settings: SettingsBox(AppSettings()),
                                            steam: SteamLocations(home: root),
                                            inheritedEnvironment: ["HOME": root.plainPath, "USER": "tenno"],
                                            log: .disabled)
            service.runner = runner
            service.signatures = signatures
            return service
        }

        /// What wineboot leaves behind, as far as `PrefixService.isBooted` looks.
        func bootPrefix() throws {
            let prefix = paths.prefix(for: .n)
            try Self.write("WINE REGISTRY Version 2\n", to: prefix.appending(path: "system.reg"))
            try Self.write("WINE REGISTRY Version 2\n", to: prefix.appending(path: "user.reg"))
            try FileManager.default.createDirectory(at: prefix.appending(path: "drive_c/windows/system32"),
                                                    withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func theLicenseProbeIsOneWineRunThatNeverWaitsForTheRestOfThePrefix() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        // wz-steamprobe.exe exits 24 when the account does not own the app (bridge/steamprobe/steamprobe.c).
        let runner = RecordingProcessRunner { command in
            ProcessOutput(exitCode: command.arguments.first?.hasSuffix(#"\wz-steamprobe.exe"#) == true ? 24 : 0)
        }
        let service = scratch.service(runner: runner, signatures: AdHocSignatures())
        let runtime = try await service.registerDevelopmentRuntime(DevelopmentRuntime(bundle: scratch.host, channel: .n))
        #expect(runtime.channel == .n)
        #expect(runtime.development)
        try scratch.bootPrefix()

        #expect(await service.probeSteamLicense() == .notOwned)
        // Exactly the probe: no `wineserver -w`, which returns only once everything in the prefix has exited, and DE's
        // launcher may be downloading there for an hour (the license card would wait for it).
        #expect(runner.commandLines == [#"wine C:\Program Files (x86)\Steam\wz-steamprobe.exe --appid 230410 --timeout 30"#])
        let probe = try #require(runner.commands.first)
        #expect(probe.executable.plainPath == runtime.hostPath + "/Contents/MacOS/wine")
        // Wine runs from the clone inside the .noindex store, never from the build tree or a folder Spotlight lists.
        #expect(runtime.hostPath.hasPrefix(scratch.paths.runtimes.plainPath + "/n/"))
        #expect(scratch.paths.runtimes.lastPathComponent == "Runtimes.noindex")
        let environment = probe.environment ?? [:]
        #expect(environment["WINEPREFIX"] == scratch.paths.prefix(for: .n).plainPath)
        #expect(environment["SteamAppId"] == "230410")
        #expect(environment["WINEDLLOVERRIDES"] == WineEnvironment.steamDLLOverrides)
        #expect(environment["STEAM_COMPAT_CLIENT_INSTALL_PATH"]
            == SteamLocations(home: scratch.root).clientDirectory.plainPath)
        #expect(environment["WINEDLLPATH_PREPEND"] == nil)
    }

    /// Signed by one certificate, whatever the bundle.
    struct CertificateSignatures: CodeSignatureInspecting {
        let fingerprint: String
        func signerFingerprint(of bundle: URL) throws -> String? { fingerprint }
    }

    /// "Unpacks" a pack by copying the scratch host into the staging folder (the pack's bytes stand in for it).
    struct CopyHostExtractor: PackExtracting {
        let host: URL
        func extract(_ pack: URL, into destination: URL) async throws {
            try FileManager.default.copyItem(at: host, to: destination.appending(path: WarzagPaths.gameHostName))
        }
    }

    @Test func theEngineFromAFeedIsDownloadedCheckedAndInstalled() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let pack = Data("a runtime pack".utf8)
        let key = Curve25519.Signing.PrivateKey()
        let manifest = RuntimeManifest(
            serial: 7, expires: Date().addingTimeInterval(86_400), id: "n-0.3.0", version: "0.3.0", channel: .n,
            arch: "arm64", minLauncher: "0.1.0", minMacOS: "15.0",
            url: URL(string: "https://releases.example.org/WarzagRuntime-n-0.3.0.aar")!, size: Int64(pack.count),
            sha256: SHA256.hash(data: pack).map { String(format: "%02x", $0) }.joined(),
            signerFingerprint: RuntimeTrust.projectCertificate)
        let http = FakeHTTPClient()
        http.respond(to: FakeEngine.feedURL, with: try SignedManifest.sign(manifest, keyId: "test", with: key).encoded())
        let transport = FakeRangeTransport(body: pack)
        var service = scratch.service(runner: RecordingProcessRunner(),
                                      signatures: CertificateSignatures(fingerprint: RuntimeTrust.projectCertificate))
        service.feed = FakeEngine.feedURL
        service.trust = ManifestTrust(publicKeys: ["test": key.publicKey.rawRepresentation],
                                      signerFingerprints: [RuntimeTrust.projectCertificate])
        service.appVersion = "0.1.0"
        service.http = http
        service.packDownloader = ResumablePackDownloader(downloader: ResumableDownloader(transport: transport,
                                                                                         clock: ManualClock()))
        service.extractor = CopyHostExtractor(host: scratch.host)

        #expect(service.feedURL() == FakeEngine.feedURL)
        #expect(try await service.fetchEngineManifest()
            == EngineOffer(id: "n-0.3.0", version: "0.3.0", bytes: Int64(pack.count), installed: false))
        let received = Recorder<Int64>()
        try await service.downloadEngine { bytes, total in
            #expect(total == Int64(pack.count))
            received.append(bytes)
        }
        #expect(received.all.last == Int64(pack.count))
        try await service.verifyEngine()
        #expect(service.activeRuntime() == nil, "checked, not installed yet")
        // Unpacked inside the .noindex store while it waits; the download cache holds the pack, never an app bundle.
        let staged = scratch.paths.runtimeStaging.appending(path: "n-0.3.0/Warzag.app/Contents/MacOS/wine")
        #expect(FileManager.default.fileExists(atPath: staged.plainPath))
        #expect(!(FileManager.default.subpaths(atPath: scratch.paths.caches.plainPath) ?? [])
            .contains { $0.hasSuffix(".app") })
        let active = try await service.activateEngine()
        #expect(active.id == "n-0.3.0")
        #expect(active.channel == .n)
        #expect(!active.development)
        #expect(FileManager.default.fileExists(atPath: active.hostPath + "/Contents/MacOS/wine"))
        #expect(active.hostPath == scratch.paths.runtimes.plainPath + "/n/0.3.0/Warzag.app")
        #expect(!FileManager.default.fileExists(atPath: staged.plainPath))
        // Current now: the feed offers nothing new, and the steps have nothing left to do.
        #expect(try await service.fetchEngineManifest().installed)
        try await service.downloadEngine { _, _ in }
        #expect(transport.requests.count == 1)
    }

    /// The release page revokes the current engine. Check for Updates' read (`checkEngineManifest`) changes nothing on
    /// disk, since a game may be running on that engine; the update's fetch then applies it: the previous engine is
    /// current again and the revoked copy is deleted.
    @Test func aCheckLeavesARevocationToTheUpdate() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let pack = Data("a runtime pack".utf8)
        let digest = SHA256.hash(data: pack).map { String(format: "%02x", $0) }.joined()
        let key = Curve25519.Signing.PrivateKey()
        func manifest(serial: UInt64, version: String, revoked: [String] = []) -> RuntimeManifest {
            RuntimeManifest(
                serial: serial, expires: Date().addingTimeInterval(86_400), id: "n-\(version)", version: version,
                channel: .n, arch: "arm64", minLauncher: "0.1.0", minMacOS: "15.0",
                url: URL(string: "https://releases.example.org/WarzagRuntime-n-\(version).aar")!,
                size: Int64(pack.count), sha256: digest, signerFingerprint: RuntimeTrust.projectCertificate,
                revoked: revoked)
        }
        let http = FakeHTTPClient()
        func publish(_ manifest: RuntimeManifest) throws {
            let signed = try SignedManifest.sign(manifest, keyId: "test", with: key).encoded()
            http.respond(to: FakeEngine.feedURL, with: signed)
        }
        var service = scratch.service(runner: RecordingProcessRunner(),
                                      signatures: CertificateSignatures(fingerprint: RuntimeTrust.projectCertificate))
        service.feed = FakeEngine.feedURL
        service.trust = ManifestTrust(publicKeys: ["test": key.publicKey.rawRepresentation],
                                      signerFingerprints: [RuntimeTrust.projectCertificate])
        service.appVersion = "0.1.0"
        service.http = http
        service.packDownloader = ResumablePackDownloader(downloader: ResumableDownloader(
            transport: FakeRangeTransport(body: pack), clock: ManualClock()))
        service.extractor = CopyHostExtractor(host: scratch.host)
        // Setup installed 0.3.0, then an update 0.4.0: 0.3.0 stays as the previous engine.
        for (serial, version) in [(UInt64(7), "0.3.0"), (UInt64(8), "0.4.0")] {
            try publish(manifest(serial: serial, version: version))
            _ = try await service.fetchEngineManifest()
            try await service.downloadEngine { _, _ in }
            try await service.verifyEngine()
            _ = try await service.activateEngine()
        }
        let current = try #require(service.activeRuntime())
        #expect(current.id == "n-0.4.0")
        let runtime = service.engine.runtime
        let state = try runtime.store.load()
        let kept = try Data(contentsOf: runtime.feedManifestFile)

        try publish(manifest(serial: 9, version: "0.5.0", revoked: ["n-0.4.0"]))
        #expect(try await service.checkEngineManifest()
            == EngineOffer(id: "n-0.5.0", version: "0.5.0", bytes: Int64(pack.count), installed: false))
        #expect(service.activeRuntime() == current)
        #expect(FileManager.default.fileExists(atPath: current.hostPath + "/Contents/MacOS/wine"))
        #expect(try runtime.store.load() == state, "no serial floor, no revocation recorded")
        #expect(try Data(contentsOf: runtime.feedManifestFile) == kept, "nothing kept for the steps")

        #expect(try await service.fetchEngineManifest().id == "n-0.5.0")
        #expect(service.activeRuntime()?.id == "n-0.3.0")
        #expect(!FileManager.default.fileExists(atPath: current.hostPath))
    }

    @Test func aFeedManifestOfAnotherChannelIsNeverInstalled() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let key = Curve25519.Signing.PrivateKey()
        let manifest = RuntimeManifest(
            serial: 7, expires: Date().addingTimeInterval(86_400), id: "n-0.3.0", version: "0.3.0", channel: .n,
            arch: "arm64", minLauncher: "0.1.0", minMacOS: "15.0",
            url: URL(string: "https://releases.example.org/WarzagRuntime-n-0.3.0.aar")!, size: 10,
            sha256: String(repeating: "0", count: 64), signerFingerprint: RuntimeTrust.projectCertificate)
        let text = String(decoding: try manifest.canonicalBytes(), as: UTF8.self)
        let payload = Data(text.replacingOccurrences(of: #""channel":"n""#, with: #""channel":"x""#).utf8)
        let envelope = SignedManifest(keyId: "test", payload: payload, signature: try key.signature(for: payload))
        let http = FakeHTTPClient()
        http.respond(to: FakeEngine.feedURL, with: try envelope.encoded())
        var service = scratch.service(runner: RecordingProcessRunner(), signatures: AdHocSignatures())
        service.feed = FakeEngine.feedURL
        service.trust = ManifestTrust(publicKeys: ["test": key.publicKey.rawRepresentation],
                                      signerFingerprints: [RuntimeTrust.projectCertificate])
        service.appVersion = "0.1.0"
        service.http = http
        for step in ["fetch", "download"] {
            do {
                if step == "fetch" {
                    _ = try await service.fetchEngineManifest()
                } else {
                    try await service.downloadEngine { _, _ in }
                }
                Issue.record("\(step) accepted a manifest of another channel")
            } catch RuntimeServiceError.manifestRejected(.malformedManifest) {
            }
        }
        #expect(http.requests == [FakeEngine.feedURL, FakeEngine.feedURL])
        #expect(service.activeRuntime() == nil)
    }

    /// A version paused on the release page (kill switch `blockInstall`): a new player reads "paused" at once, without
    /// downloading a few hundred MB of an engine that would be refused after the download.
    @Test func aPausedEngineIsRefusedBeforeItsPackIsDownloaded() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let key = Curve25519.Signing.PrivateKey()
        let manifest = RuntimeManifest(
            serial: 7, expires: Date().addingTimeInterval(86_400), id: "n-0.3.0", version: "0.3.0", channel: .n,
            arch: "arm64", minLauncher: "0.1.0", minMacOS: "15.0",
            url: URL(string: "https://releases.example.org/WarzagRuntime-n-0.3.0.aar")!, size: 24,
            sha256: String(repeating: "0", count: 64), signerFingerprint: RuntimeTrust.projectCertificate,
            killSwitch: KillSwitch(level: .blockInstall, message: "crashes at start"))
        let http = FakeHTTPClient()
        http.respond(to: FakeEngine.feedURL, with: try SignedManifest.sign(manifest, keyId: "test", with: key).encoded())
        let transport = FakeRangeTransport(body: Data(count: 24))
        var service = scratch.service(runner: RecordingProcessRunner(),
                                      signatures: CertificateSignatures(fingerprint: RuntimeTrust.projectCertificate))
        service.feed = FakeEngine.feedURL
        service.trust = ManifestTrust(publicKeys: ["test": key.publicKey.rawRepresentation],
                                      signerFingerprints: [RuntimeTrust.projectCertificate])
        service.appVersion = "0.1.0"
        service.http = http
        service.packDownloader = ResumablePackDownloader(downloader: ResumableDownloader(transport: transport,
                                                                                         clock: ManualClock()))

        _ = try await service.fetchEngineManifest()
        do {
            try await service.downloadEngine { _, _ in }
            Issue.record("the paused engine's pack was downloaded")
        } catch {
            #expect(error as? RuntimeInstallError == .blocked("crashes at start"))
            #expect(EngineFeedFailure.failure(for: error) == SetupFailure(.permanent, L10n.failureEnginePaused))
        }
        #expect(transport.requests.isEmpty)
        #expect(http.requests == [FakeEngine.feedURL])
    }

    /// What the prefix was last set up for, from its warzag-prefix.json: an engine update whose prefix set-up was cut
    /// short shows as another runtime than the active one.
    @Test func thePrefixSaysWhichEngineItWasSetUpFor() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let service = scratch.service(runner: RecordingProcessRunner(), signatures: AdHocSignatures())
        #expect(service.prefixRuntimeID() == nil, "no engine")
        let runtime = try await service.registerDevelopmentRuntime(DevelopmentRuntime(bundle: scratch.host, channel: .n))
        try scratch.bootPrefix()
        #expect(service.prefixRuntimeID() == nil, "no record yet")
        let layout = service.engine.prefix.layout
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        try PrefixManifest(channel: .n, runtimeID: "n-0.1.0", runtimeVersion: "0.1.0",
                           library: scratch.paths.warframeLibrary.plainPath,
                           macDriver: MacDriverOptions(MacDriverSettings(retinaMode: false)), createdAt: now,
                           configuredAt: now).save(in: layout, fileSystem: LocalFileSystem())
        #expect(service.prefixRuntimeID() == "n-0.1.0")
        #expect(service.prefixRuntimeID() != runtime.id)
        try Data("not json".utf8).write(to: PrefixManifest.url(in: layout))
        #expect(service.prefixRuntimeID() == nil, "an unreadable record says nothing")
    }

    @Test func anUnchangedDevelopmentBuildIsNotClonedAgain() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let signatures = AdHocSignatures()
        let service = scratch.service(runner: RecordingProcessRunner(), signatures: signatures)
        let engine = DevelopmentRuntime(bundle: scratch.host, channel: .n)
        let first = try await service.registerDevelopmentRuntime(engine)
        #expect(service.activeRuntime() == first)
        #expect(try await service.registerDevelopmentRuntime(engine) == first)
        #expect(signatures.inspections == 1)
    }
}
