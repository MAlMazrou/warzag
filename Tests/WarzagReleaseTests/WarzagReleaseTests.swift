import CryptoKit
import Foundation
import RuntimeKit
import Testing
import WarzagCore
@testable import warzag_release

/// A fresh directory under the system temp dir, removed by `cleanup()`.
struct Scratch {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "warzag-release-tests-\(UUID().uuidString)",
                                                               directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func path(_ name: String) -> String { url.appending(path: name).path(percentEncoded: false) }
    func cleanup() { try? FileManager.default.removeItem(at: url) }
}

/// Unpacks a "pack" by creating the host the installer looks for, with its channel in Info.plist.
struct FakeExtractor: PackExtracting {
    var hostName = WarzagPaths.gameHostName
    var channel = "n"

    func extract(_ pack: URL, into destination: URL) async throws {
        let wine = destination.appending(path: "\(hostName)/Contents/MacOS")
        try FileManager.default.createDirectory(at: wine, withIntermediateDirectories: true)
        try Data("loader".utf8).write(to: wine.appending(path: "wine"))
        try Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>WarzagRuntimeChannel</key><string>\(channel)</string></dict></plist>
            """.utf8).write(to: wine.deletingLastPathComponent().appending(path: "Info.plist"))
    }
}

struct FixedSigner: CodeSignatureInspecting {
    var fingerprint: String?
    func signerFingerprint(of bundle: URL) throws -> String? { fingerprint }
}

let projectSigner = String(repeating: "f3", count: 32)
let issuedAt = Date(timeIntervalSince1970: 1_792_000_000.75)

func tool(signer: String? = projectSigner, now: Date = issuedAt, extractor: any PackExtracting = FakeExtractor()) -> ReleaseTool {
    ReleaseTool(fileSystem: LocalFileSystem(), now: { now }, extractor: extractor, signatures: FixedSigner(fingerprint: signer),
                temporaryDirectory: FileManager.default.temporaryDirectory, currentMacOS: "26.5.1")
}

/// A key pair on disk and a pack, as a release would have them.
struct ReleaseFixture {
    let scratch: Scratch
    let key: Curve25519.Signing.PrivateKey
    let keyFile: String
    let pack: String

    init() throws {
        scratch = try Scratch()
        key = Curve25519.Signing.PrivateKey()
        keyFile = try ManifestKeys.writeNewKeyPair(key, in: scratch.url.appending(path: "keys"), name: "dev")
            .privateKey.path(percentEncoded: false)
        pack = scratch.path("WarzagRuntime-n-0.1.0.aar")
        try Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 &* 7) }).write(to: URL(filePath: pack))
    }

    var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }
    var manifestFile: String { scratch.path("manifest.json") }

    func options(version: String = "0.1.0", url: String = "https://releases.example.org/WarzagRuntime-n-0.1.0.aar",
                 revoked: [String] = [], killSwitch: KillSwitch = .none) -> ManifestOptions {
        ManifestOptions(pack: pack, version: version, serial: 7, expiresInDays: 30,
                        url: URL(string: url)!, keyFile: keyFile, signerFingerprint: projectSigner,
                        revoked: revoked, killSwitch: killSwitch, output: manifestFile)
    }

    func verifyOptions(install: Bool = true, signer: String? = projectSigner) -> VerifyOptions {
        VerifyOptions(manifest: manifestFile, pack: pack, publicKey: publicKey, signerFingerprint: signer, install: install)
    }
}

@Suite struct ReleaseCommandLineTests {
    func parse(_ line: String) throws(ReleaseUsageError) -> ReleaseCommand {
        try ReleaseCommandLine.parse(line.split(separator: " ").map(String.init))
    }

    @Test func keygenAndPubkey() throws {
        #expect(try parse("keygen --out /k") == .keygen(KeygenOptions(directory: "/k")))
        #expect(try parse("keygen --out /k --name dev") == .keygen(KeygenOptions(directory: "/k", name: "dev")))
        #expect(try parse("pubkey --key /k/dev.ed25519") == .publicKey(keyFile: "/k/dev.ed25519"))
        #expect(try parse("help") == .help)
        #expect(try parse("manifest --help") == .help)
    }

    @Test func aFullManifestCommandLine() throws {
        let line = "manifest --pack /p.aar --version 0.1.0 --serial 42 --expires 30 "
            + "--url https://example.org/p.aar --key /k --signer-sha256 \(projectSigner.uppercased()) "
            + "--min-launcher 0.2.0 --min-macos 15.4 --revoke n-0.0.9 --revoke n-0.0.8 "
            + "--kill-switch blockInstall --message hello --key-id rt-2026a --out /m.json"
        var expected = ManifestOptions(
            pack: "/p.aar", version: "0.1.0", serial: 42, expiresInDays: 30,
            url: URL(string: "https://example.org/p.aar")!, keyFile: "/k", signerFingerprint: projectSigner,
            keyID: "rt-2026a", revoked: ["n-0.0.9", "n-0.0.8"],
            killSwitch: KillSwitch(level: .blockInstall, message: "hello"),
            output: "/m.json")
        expected.minLauncher = "0.2.0"
        expected.minMacOS = "15.4"
        #expect(try parse(line) == .manifest(expected))
    }

    @Test func verifyCommandLine() throws {
        #expect(try parse("verify --manifest /m --pack /p --pubkey AAAA --no-install")
            == .verify(VerifyOptions(manifest: "/m", pack: "/p", publicKey: "AAAA", install: false)))
        #expect(try parse("verify --manifest /m --pack /p --pubkey AAAA --signer-sha256 \(projectSigner) --macos 15.0")
            == .verify(VerifyOptions(manifest: "/m", pack: "/p", publicKey: "AAAA", signerFingerprint: projectSigner,
                                     macOSVersion: "15.0")))
    }

    static let base = "manifest --pack /p --version 1 --key /k --signer-sha256 \(projectSigner)"

    @Test(arguments: [
        ("", "missing command"),
        ("frobnicate", "unknown command: frobnicate"),
        ("keygen", "missing --out"),
        ("keygen --out /k --name ../x", "--name must be a plain file name"),
        ("keygen --out", "--out needs a value"),
        ("keygen --out /k --force", "unknown option: --force"),
        ("keygen --out /k extra", "unexpected argument: extra"),
        ("\(base) --serial 0 --expires 1 --url https://e.org/p", "--serial must be a positive integer"),
        ("\(base) --serial 1 --expires 0 --url https://e.org/p", "--expires must be a number of days from 1 to 3650"),
        ("\(base) --serial 1 --expires 1 --url http://e.org/p", "--url must be an https URL"),
        ("\(base) --serial 1 --expires 1 --url https://e.org/p --message hi", "--message needs --kill-switch"),
        ("\(base) --serial 1 --expires 1 --url https://e.org/p --kill-switch off", "unknown kill switch level: off"),
        ("manifest --pack /p --version 1 --serial 1 --expires 1 --url https://e.org/p --key /k --signer-sha256 abc",
         "--signer-sha256 must be a SHA-256 (64 hex digits)"),
        ("verify --manifest /m --pack /p", "missing --pubkey"),
    ])
    func usageErrors(_ line: String, _ message: String) {
        #expect(throws: ReleaseUsageError(message: message)) { try parse(line) }
    }
}

@Suite struct ManifestKeyTests {
    @Test func keygenWritesAPrivateKeyOnlyTheOwnerCanRead() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let directory = scratch.path("keys")
        let result = await tool().run(.keygen(KeygenOptions(directory: directory, name: "dev")))
        #expect(result.exitCode == 0)

        let privatePath = directory + "/dev.ed25519"
        let publicPath = directory + "/dev.ed25519.pub"
        let attributes = try FileManager.default.attributesOfItem(atPath: privatePath)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory)[.posixPermissions] as? NSNumber
        #expect(directoryMode?.intValue == 0o700)

        let key = try ManifestKeys.readPrivateKey(at: URL(filePath: privatePath))
        let publicText = try String(contentsOfFile: publicPath, encoding: .utf8)
        #expect(try ManifestKeys.publicKey(base64: publicText).rawRepresentation == key.publicKey.rawRepresentation)
        #expect(result.stdout.contains("key id       \(ManifestTrust.keyID(for: key.publicKey))"))
        #expect(result.stdout.contains(key.publicKey.rawRepresentation.base64EncodedString()))
        #expect(!result.stdout.contains(key.rawRepresentation.base64EncodedString()))

        let again = await tool().run(.keygen(KeygenOptions(directory: directory, name: "dev")))
        #expect(again.exitCode == 1)
        #expect(again.stderr.contains("already exists; keys are never replaced"))
        #expect(try ManifestKeys.readPrivateKey(at: URL(filePath: privatePath)).rawRepresentation == key.rawRepresentation)
    }

    @Test func keyIDIsSixteenHexDigitsOfThePublicKeysHash() {
        let key = Curve25519.Signing.PrivateKey()
        let id = ManifestTrust.keyID(for: key.publicKey)
        let digest = SHA256.hash(data: key.publicKey.rawRepresentation).map { String(format: "%02x", $0) }.joined()
        #expect(id.count == 16)
        #expect(digest.hasPrefix(id))
    }

    @Test func aPrivateKeyOthersCanReadIsRefused() throws {
        let fixture = try ReleaseFixture()
        defer { fixture.scratch.cleanup() }
        chmod(fixture.keyFile, 0o644)
        #expect(throws: ReleaseError(message: "\(fixture.keyFile) is readable by other users; run chmod 600 on it")) {
            try ManifestKeys.readPrivateKey(at: URL(filePath: fixture.keyFile))
        }
    }

    @Test func pubkeyPrintsThePublicKeyAndItsID() async throws {
        let fixture = try ReleaseFixture()
        defer { fixture.scratch.cleanup() }
        let result = await tool().run(.publicKey(keyFile: fixture.keyFile))
        #expect(result.stdout == fixture.publicKey + "\n")
        #expect(result.stderr == "key id: \(ManifestTrust.keyID(for: fixture.key.publicKey))\n")
    }
}

@Suite struct ManifestSigningTests {
    @Test func theManifestDescribesThePackAndTheAppAcceptsIt() async throws {
        let fixture = try ReleaseFixture()
        defer { fixture.scratch.cleanup() }
        let result = await tool().run(.manifest(fixture.options()))
        #expect(result.exitCode == 0, "\(result.stderr)")

        let data = try Data(contentsOf: URL(filePath: fixture.manifestFile))
        let keyID = ManifestTrust.keyID(for: fixture.key.publicKey)
        let trust = ManifestTrust(publicKeys: [keyID: fixture.key.publicKey.rawRepresentation],
                                  signerFingerprints: [projectSigner])
        let context = ManifestContext(now: issuedAt, lastAcceptedSerial: 6, revoked: [], appVersion: "0.1.0",
                                      macOSVersion: "15.0")
        let manifest = try ManifestVerifier.verify(data, trust: trust, context: context)
        let packData = try Data(contentsOf: URL(filePath: fixture.pack))
        #expect(manifest.id == "n-0.1.0")
        #expect(manifest.channel == .n)
        #expect(manifest.arch == "arm64")
        #expect(manifest.serial == 7)
        #expect(manifest.size == Int64(packData.count))
        #expect(manifest.sha256 == SHA256.hash(data: packData).map { String(format: "%02x", $0) }.joined())
        #expect(manifest.signerFingerprint == projectSigner)
        #expect(manifest.expires == Date(timeIntervalSince1970: 1_792_000_000 + 30 * 86_400))
        #expect(manifest.minLauncher == "0.1.0" && manifest.minMacOS == "15.0")
        let envelope = try WarzagJSON.decoder().decode(SignedManifest.self, from: data)
        #expect(envelope.keyId == keyID)
    }

    @Test func stdoutCarriesTheEnvelopeWhenThereIsNoOutputFile() async throws {
        let fixture = try ReleaseFixture()
        defer { fixture.scratch.cleanup() }
        var options = fixture.options()
        options.output = nil
        let result = await tool().run(.manifest(options))
        #expect(result.exitCode == 0)
        let envelope = try WarzagJSON.decoder().decode(SignedManifest.self, from: Data(result.stdout.utf8))
        #expect(envelope.keyId == ManifestTrust.keyID(for: fixture.key.publicKey))
        #expect(result.stderr.contains("manifest  n-0.1.0"))
    }

    @Test func aManifestTheAppWouldRejectIsNeverWritten() async throws {
        let fixture = try ReleaseFixture()
        defer { fixture.scratch.cleanup() }
        let badVersion = await tool().run(.manifest(fixture.options(version: "../0.1.0")))
        #expect(badVersion.exitCode == 1)
        #expect(badVersion.stderr.contains("the app would reject this manifest"))
        let revokesItself = await tool().run(.manifest(fixture.options(revoked: ["n-0.1.0"])))
        #expect(revokesItself.exitCode == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.manifestFile))
    }

    @Test func aMissingPackIsAnError() async throws {
        let fixture = try ReleaseFixture()
        defer { fixture.scratch.cleanup() }
        try FileManager.default.removeItem(atPath: fixture.pack)
        let result = await tool().run(.manifest(fixture.options()))
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("no pack at"))
    }
}

@Suite struct ManifestVerificationCommandTests {
    func signedFixture(_ options: ((ReleaseFixture) -> ManifestOptions)? = nil) async throws -> ReleaseFixture {
        let fixture = try ReleaseFixture()
        let result = await tool().run(.manifest(options?(fixture) ?? fixture.options()))
        #expect(result.exitCode == 0, "\(result.stderr)")
        return fixture
    }

    @Test func aGoodReleaseVerifiesAndInstalls() async throws {
        let fixture = try await signedFixture()
        defer { fixture.scratch.cleanup() }
        let result = await tool().run(.verify(fixture.verifyOptions()))
        #expect(result.exitCode == 0, "\(result.stderr)")
        #expect(result.stdout.contains("manifest  ok: n-0.1.0 serial 7"))
        #expect(result.stdout.contains("pack      ok: 5000 bytes"))
        #expect(result.stdout.contains("install   ok: RuntimeInstaller unpacked Warzag.app"))
        #expect(result.stdout.contains("activated as Runtimes.noindex/n/0.1.0"))
        #expect(!result.stdout.contains("note"))
    }

    @Test func withoutAPinnedSignerTheManifestsOwnIsUsedAndSaidSo() async throws {
        let fixture = try await signedFixture()
        defer { fixture.scratch.cleanup() }
        let result = await tool().run(.verify(fixture.verifyOptions(install: false, signer: nil)))
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("signer not pinned"))
    }

    @Test func aTamperedManifestIsRejected() async throws {
        let fixture = try await signedFixture()
        defer { fixture.scratch.cleanup() }
        var envelope = try WarzagJSON.decoder().decode(SignedManifest.self,
                                                       from: Data(contentsOf: URL(filePath: fixture.manifestFile)))
        let payload = String(decoding: envelope.payload, as: UTF8.self)
        envelope.payload = Data(payload.replacingOccurrences(of: "releases.example.org", with: "evil.example.org").utf8)
        try envelope.encoded().write(to: URL(filePath: fixture.manifestFile))
        let result = await tool().run(.verify(fixture.verifyOptions()))
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("manifest rejected: manifest signature does not verify"))
    }

    @Test func anotherKeyIsUnknown() async throws {
        let fixture = try await signedFixture()
        defer { fixture.scratch.cleanup() }
        var options = fixture.verifyOptions()
        options.publicKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let result = await tool().run(.verify(options))
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("manifest signed with unknown key \(ManifestTrust.keyID(for: fixture.key.publicKey))"))
    }

    @Test func aDifferentPinnedSignerIsUntrusted() async throws {
        let fixture = try await signedFixture()
        defer { fixture.scratch.cleanup() }
        let result = await tool().run(.verify(fixture.verifyOptions(signer: String(repeating: "0", count: 64))))
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("code signer \(projectSigner) is not trusted"))
    }

    @Test func aChangedPackIsRejected() async throws {
        let fixture = try await signedFixture()
        defer { fixture.scratch.cleanup() }
        let handle = try FileHandle(forUpdating: URL(filePath: fixture.pack))
        try handle.seek(toOffset: 100)
        try handle.write(contentsOf: Data([0xFF]))
        try handle.close()
        let result = await tool().run(.verify(fixture.verifyOptions()))
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("SHA-256 mismatch"))
    }

    @Test func anExpiredManifestIsRejected() async throws {
        let fixture = try await signedFixture()
        defer { fixture.scratch.cleanup() }
        let later = issuedAt.addingTimeInterval(31 * 86_400)
        let result = await tool(now: later).run(.verify(fixture.verifyOptions()))
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("manifest expired"))
    }

    @Test func aPackSignedByAnotherCertificateFailsTheInstall() async throws {
        let fixture = try await signedFixture()
        defer { fixture.scratch.cleanup() }
        let result = await tool(signer: String(repeating: "ab", count: 32)).run(.verify(fixture.verifyOptions()))
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("install: runtime signed by \(String(repeating: "ab", count: 32)), expected \(projectSigner)"))
        let adHoc = await tool(signer: nil).run(.verify(fixture.verifyOptions()))
        #expect(adHoc.stderr.contains("install: runtime signed by nobody"))
    }

    @Test func aPackHoldingAnotherChannelsHostFailsTheInstall() async throws {
        let fixture = try await signedFixture()
        defer { fixture.scratch.cleanup() }
        let result = await tool(extractor: FakeExtractor(channel: "x")).run(.verify(fixture.verifyOptions()))
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains(#"install: the pack is for channel n but holds Info.plist's WarzagRuntimeChannel is "x", not n"#))
    }

    @Test func aPackWithoutTheHostAtItsRootFailsTheInstall() async throws {
        let fixture = try await signedFixture()
        defer { fixture.scratch.cleanup() }
        let result = await tool(extractor: FakeExtractor(hostName: "Other.app")).run(.verify(fixture.verifyOptions()))
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("install: the staged runtime has no Warzag.app"))
    }

    @Test func aBlockInstallKillSwitchSkipsTheInstall() async throws {
        let fixture = try await signedFixture { $0.options(killSwitch: KillSwitch(level: .blockInstall, message: "bad")) }
        defer { fixture.scratch.cleanup() }
        let result = await tool().run(.verify(fixture.verifyOptions()))
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("install   skipped"))
    }

    @Test func aPackNamedDifferentlyFromTheURLGetsANote() async throws {
        let fixture = try await signedFixture { $0.options(url: "https://releases.example.org/elsewhere.aar") }
        defer { fixture.scratch.cleanup() }
        let result = await tool().run(.verify(fixture.verifyOptions(install: false)))
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("note      the manifest's URL names elsewhere.aar"))
    }
}
