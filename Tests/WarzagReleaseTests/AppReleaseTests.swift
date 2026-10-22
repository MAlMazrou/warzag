import AppUpdateKit
import CryptoKit
import Foundation
import RuntimeKit
import Testing
import WarzagCore
@testable import warzag_release

/// "Unpacks" an update archive by creating the app it should hold.
struct FakeAppArchive: AppArchiveExtracting {
    var identifier = "com.warzag.app"
    var version = "0.2.0"
    var build = "413"
    var minimumMacOS = "15.0"
    var extraEntry: String?

    func extract(_ archive: URL, into destination: URL) async throws {
        let contents = destination.appending(path: "Warzag.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>\(identifier)</string>
            <key>CFBundleShortVersionString</key><string>\(version)</string>
            <key>CFBundleVersion</key><string>\(build)</string>
            <key>LSMinimumSystemVersion</key><string>\(minimumMacOS)</string>
            </dict></plist>
            """.utf8).write(to: contents.appending(path: "Info.plist"))
        if let extraEntry {
            try FileManager.default.createDirectory(at: destination.appending(path: extraEntry),
                                                    withIntermediateDirectories: true)
        }
    }
}

/// Stands in for the code signature: the app is "signed" by `signer`, and its Info.plist must match.
struct SignedBy: AppBundleVerifying {
    var signer = projectSigner

    func verify(_ bundle: URL, against requirement: AppRequirement) throws(AppBundleRejection) {
        guard signer == requirement.signerFingerprint else {
            throw .signerMismatch(expected: requirement.signerFingerprint, actual: signer)
        }
        let app = InstalledApp.read(bundle)
        guard app.identifier == requirement.bundleIdentifier else {
            throw .identityMismatch(expected: requirement.bundleIdentifier, actual: app.identifier ?? "none")
        }
        guard app.version == requirement.version else {
            throw .versionMismatch(expected: requirement.version, actual: app.version)
        }
        guard app.build == requirement.build else { throw .buildMismatch(expected: requirement.build, actual: app.build) }
    }
}

func appTool(_ archive: FakeAppArchive = FakeAppArchive(), signer: String = projectSigner) -> ReleaseTool {
    var tool = tool()
    tool.appExtractor = archive
    tool.bundles = SignedBy(signer: signer)
    return tool
}

/// A key and an update archive, as a release has them.
struct AppReleaseFixture {
    let release: ReleaseFixture
    let archive: String

    init() throws {
        release = try ReleaseFixture()
        archive = release.scratch.path("Warzag-0.2.0.zip")
        try Data((0..<3000).map { UInt8(truncatingIfNeeded: $0 &* 13) }).write(to: URL(filePath: archive))
    }

    var manifestFile: String { release.scratch.path("Warzag-0.2.0.manifest.json") }

    func options(url: String = "https://releases.example.org/v0.2.0/Warzag-0.2.0.zip") -> AppManifestOptions {
        AppManifestOptions(archive: archive, serial: 11, expiresInDays: 30, url: URL(string: url)!,
                           keyFile: release.keyFile, signerFingerprint: projectSigner,
                           releaseNotes: URL(string: "https://releases.example.org/v0.2.0"), output: manifestFile)
    }

    func verifyOptions(signer: String? = projectSigner, runningBuild: String? = nil) -> AppVerifyOptions {
        AppVerifyOptions(manifest: manifestFile, archive: archive, publicKey: release.publicKey,
                         signerFingerprint: signer, runningBuild: runningBuild)
    }

    func cleanup() { release.scratch.cleanup() }
}

@Suite struct AppReleaseCommandLineTests {
    func parse(_ line: String) throws(ReleaseUsageError) -> ReleaseCommand {
        try ReleaseCommandLine.parse(line.split(separator: " ").map(String.init))
    }

    @Test func appManifestAndAppVerifyCommandLines() throws {
        let line = "app-manifest --archive /a.zip --serial 9 --expires 60 --url https://e.org/a.zip --key /k "
            + "--signer-sha256 \(projectSigner) --min-macos 15.4 --release-notes https://e.org/v --key-id k1 --out /m.json"
        #expect(try parse(line) == .appManifest(AppManifestOptions(
            archive: "/a.zip", serial: 9, expiresInDays: 60, url: URL(string: "https://e.org/a.zip")!, keyFile: "/k",
            signerFingerprint: projectSigner, keyID: "k1", minMacOS: "15.4",
            releaseNotes: URL(string: "https://e.org/v"), output: "/m.json")))
        #expect(try parse("app-verify --manifest /m --archive /a --pubkey AAAA --running-build 412 --macos 15.0")
            == .appVerify(AppVerifyOptions(manifest: "/m", archive: "/a", publicKey: "AAAA", runningBuild: "412",
                                           macOSVersion: "15.0")))
    }

    static let base = "app-manifest --archive /a --serial 1 --expires 1 --key /k --signer-sha256 \(projectSigner)"

    @Test(arguments: [
        ("\(base) --url http://e.org/a.zip", "--url must be an https URL (or http on 127.0.0.1 in a development build)"),
        ("\(base) --url https://e.org/a.zip --release-notes http://e.org/v",
         "--release-notes must be an https URL (or http on 127.0.0.1 in a development build)"),
        ("\(base) --url https://e.org/a.zip --serial 0", "--serial must be a positive integer"),
        ("app-verify --manifest /m --archive /a", "missing --pubkey"),
    ])
    func usageErrors(_ line: String, _ message: String) {
        #expect(throws: ReleaseUsageError(message: message)) { try parse(line) }
    }

    /// The tests are a development build: a rehearsal's loopback feed is accepted here, and never in a release build.
    @Test func loopbackHTTPOnlyInADevelopmentBuild() throws {
        #expect(try ReleaseCommandLine.appURL("http://127.0.0.1:8123/a.zip", option: "--url").port == 8123)
        #expect(throws: ReleaseUsageError(message: "--url must be an https URL")) {
            try ReleaseCommandLine.appURL("http://127.0.0.1:8123/a.zip", option: "--url", allowsLoopbackHTTP: false)
        }
    }
}

@Suite struct AppManifestSigningTests {
    @Test func theManifestDescribesTheArchiveAndItsApp() async throws {
        let fixture = try AppReleaseFixture()
        defer { fixture.cleanup() }
        let result = await appTool(FakeAppArchive(minimumMacOS: "15.2")).run(.appManifest(fixture.options()))
        #expect(result.exitCode == 0, "\(result.stderr)")
        #expect(result.stdout.contains("manifest  Warzag 0.2.0 (build 413), kind app, serial 11"))

        let data = try Data(contentsOf: URL(filePath: fixture.manifestFile))
        let trust = ManifestTrust(publicKeys: [ManifestTrust.keyID(for: fixture.release.key.publicKey):
                                                fixture.release.key.publicKey.rawRepresentation],
                                  signerFingerprints: [projectSigner])
        let manifest = try AppManifestVerifier.verify(data, trust: trust, context: AppManifestContext(
            now: issuedAt, lastAcceptedSerial: 11))
        let archive = try Data(contentsOf: URL(filePath: fixture.archive))
        #expect(manifest.kind == "app")
        #expect(manifest.version == "0.2.0" && manifest.build == "413")
        #expect(manifest.minMacOS == "15.2")
        #expect(manifest.size == Int64(archive.count))
        #expect(manifest.sha256 == SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined())
        #expect(manifest.expires == Date(timeIntervalSince1970: 1_792_000_000 + 30 * 86_400))
        #expect(manifest.releaseNotes == URL(string: "https://releases.example.org/v0.2.0"))
        // A runtime verifier refuses it outright.
        #expect(throws: ManifestRejection.wrongKind(expected: "runtime", found: "app")) {
            try ManifestVerifier.verify(data, trust: trust, context: ManifestContext(
                now: issuedAt, lastAcceptedSerial: nil, revoked: [], appVersion: "", macOSVersion: ""))
        }
    }

    @Test(arguments: [
        (FakeAppArchive(identifier: "com.example.other"), "the app is com.example.other, not com.warzag.app"),
        (FakeAppArchive(extraEntry: "__MACOSX"), "Warzag-0.2.0.zip must hold exactly Warzag.app, not Warzag.app, __MACOSX"),
        (FakeAppArchive(build: "413b"), "Warzag would reject this app manifest: manifest is malformed: build must be numbers "
            + "and dots, as CFBundleVersion"),
    ])
    func whatWarzagWouldRefuseIsNeverSigned(_ archive: FakeAppArchive, _ message: String) async throws {
        let fixture = try AppReleaseFixture()
        defer { fixture.cleanup() }
        let result = await appTool(archive).run(.appManifest(fixture.options()))
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains(message), "\(result.stderr)")
        #expect(!FileManager.default.fileExists(atPath: fixture.manifestFile))
    }

    @Test func anAppSignedByAnotherCertificateIsNeverSigned() async throws {
        let fixture = try AppReleaseFixture()
        defer { fixture.cleanup() }
        let other = String(repeating: "0", count: 64)
        let result = await appTool(signer: other).run(.appManifest(fixture.options()))
        #expect(result.stderr.contains("Warzag would refuse the app in Warzag-0.2.0.zip: the app is signed by \(other)"))
    }
}

@Suite struct AppVerifyTests {
    func signed(_ fixture: AppReleaseFixture) async throws {
        let result = await appTool().run(.appManifest(fixture.options()))
        #expect(result.exitCode == 0, "\(result.stderr)")
    }

    @Test func whatWarzagChecksPasses() async throws {
        let fixture = try AppReleaseFixture()
        defer { fixture.cleanup() }
        try await signed(fixture)
        let result = await appTool().run(.appVerify(fixture.verifyOptions(runningBuild: "412")))
        #expect(result.exitCode == 0, "\(result.stderr)")
        #expect(result.stdout.contains("manifest  ok: Warzag 0.2.0 (build 413) serial 11"))
        #expect(result.stdout.contains("archive   ok: 3000 bytes"))
        #expect(result.stdout.contains("app       ok: com.warzag.app 0.2.0 (build 413), arm64, strictly signed by"))
    }

    @Test func refusals() async throws {
        let fixture = try AppReleaseFixture()
        defer { fixture.cleanup() }
        try await signed(fixture)

        var stranger = fixture.verifyOptions()
        stranger.publicKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        #expect(await appTool().run(.appVerify(stranger)).stderr.contains("app manifest rejected: manifest signed with unknown key"))

        #expect(await appTool().run(.appVerify(fixture.verifyOptions(runningBuild: "413"))).stderr
            .contains("build 413 is not newer than the running build 413: Warzag would not offer it"))

        let otherSigner = String(repeating: "0", count: 64)
        #expect(await appTool().run(.appVerify(fixture.verifyOptions(signer: otherSigner))).stderr
            .contains("app manifest rejected: code signer \(projectSigner) is not trusted"))

        var older = fixture.verifyOptions()
        older.macOSVersion = "14.6"
        #expect(await appTool().run(.appVerify(older)).stderr.contains("needs macOS 15.0 or later, not 14.6"))

        #expect(await appTool(FakeAppArchive(build: "412")).run(.appVerify(fixture.verifyOptions())).stderr
            .contains("app: the app is build 412, not 413"))

        // The archive cut short.
        let archive = try Data(contentsOf: URL(filePath: fixture.archive))
        try archive.prefix(1000).write(to: URL(filePath: fixture.archive))
        #expect(await appTool().run(.appVerify(fixture.verifyOptions())).stderr
            .contains("size mismatch: expected 3000 bytes, got 1000"))
        try archive.write(to: URL(filePath: fixture.archive))

        // The manifest edited after signing.
        let text = try String(contentsOfFile: fixture.manifestFile, encoding: .utf8)
        var envelope = try WarzagJSON.decoder().decode(SignedManifest.self, from: Data(text.utf8))
        envelope.payload = Data(String(decoding: envelope.payload, as: UTF8.self)
            .replacingOccurrences(of: "\"serial\":11", with: "\"serial\":12").utf8)
        try envelope.encoded().write(to: URL(filePath: fixture.manifestFile))
        #expect(await appTool().run(.appVerify(fixture.verifyOptions())).stderr.contains("manifest signature does not verify"))
    }

    /// A runtime manifest is no app manifest, whatever it is signed with.
    @Test func aRuntimeManifestIsRefused() async throws {
        let fixture = try AppReleaseFixture()
        defer { fixture.cleanup() }
        var runtime = fixture.release.options()
        runtime.output = fixture.manifestFile
        #expect(await tool().run(.manifest(runtime)).exitCode == 0)
        #expect(await appTool().run(.appVerify(fixture.verifyOptions())).stderr
            .contains("manifest kind is runtime, not app"))
    }
}
