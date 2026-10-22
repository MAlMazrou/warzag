import CryptoKit
import Foundation
import Testing
import WarzagCore
@testable import RuntimeKit

/// App manifests, signed with the runtime manifests' keys (`Fixture`).
enum AppFixture {
    static func manifest(version: String = "0.2.0", build: String = "413", serial: UInt64 = 42,
                         url: String = "https://releases.example.org/v0.2.0/Warzag-0.2.0.zip") -> AppManifest {
        AppManifest(serial: serial, expires: Fixture.now.addingTimeInterval(30 * 86_400), version: version, build: build,
                    minMacOS: "15.0", url: URL(string: url)!, size: 12_345_678,
                    sha256: String(repeating: "c", count: 64), signerFingerprint: Fixture.signer,
                    releaseNotes: URL(string: "https://releases.example.org/v0.2.0"))
    }

    static func signed(_ manifest: AppManifest, keyId: String = "rt-2026a",
                       with key: Curve25519.Signing.PrivateKey = Fixture.key) throws -> Data {
        try SignedManifest.sign(manifest, keyId: keyId, with: key).encoded()
    }

    static func context(serial: UInt64? = 41, loopback: Bool = false) -> AppManifestContext {
        AppManifestContext(now: Fixture.now, lastAcceptedSerial: serial, allowsLoopbackHTTP: loopback)
    }

    /// A payload signed as it is, whatever it says.
    static func signedPayload(_ json: String) throws -> Data {
        let payload = Data(json.utf8)
        return try SignedManifest(keyId: "rt-2026a", payload: payload, signature: try Fixture.key.signature(for: payload))
            .encoded()
    }
}

@Suite struct AppManifestVerificationTests {
    func verify(_ data: Data, context: AppManifestContext = AppFixture.context()) throws(ManifestRejection) -> AppManifest {
        try AppManifestVerifier.verify(data, trust: Fixture.trust, context: context)
    }

    @Test func aProperlySignedAppManifestVerifies() throws {
        let manifest = AppFixture.manifest()
        #expect(try verify(try AppFixture.signed(manifest)) == manifest)
        #expect(manifest.kind == "app")
        #expect(try verify(try AppFixture.signed(manifest, keyId: "rt-2026b", with: Fixture.nextKey)) == manifest)
    }

    @Test func tamperingAndForeignKeysAreRejected() throws {
        var envelope = try SignedManifest.sign(AppFixture.manifest(), keyId: "rt-2026a", with: Fixture.key)
        envelope.payload = Data(String(decoding: envelope.payload, as: UTF8.self)
            .replacingOccurrences(of: "releases.example.org", with: "evil.example.org").utf8)
        #expect(throws: ManifestRejection.badSignature) { try verify(try envelope.encoded()) }
        let forged = try AppFixture.signed(AppFixture.manifest(), with: Fixture.strangerKey)
        #expect(throws: ManifestRejection.badSignature) { try verify(forged) }
        let unknown = try AppFixture.signed(AppFixture.manifest(), keyId: "rt-1999", with: Fixture.strangerKey)
        #expect(throws: ManifestRejection.unknownKey("rt-1999")) { try verify(unknown) }
        #expect(throws: ManifestRejection.malformedEnvelope) { try verify(Data("{}".utf8)) }
    }

    /// The two kinds share keys and envelope; neither verifier ever reads the other's manifest.
    @Test func aRuntimeManifestIsNeverAnAppManifestAndTheOtherWayRound() throws {
        let runtime = try Fixture.signed(Fixture.manifest())
        #expect(throws: ManifestRejection.wrongKind(expected: "app", found: "runtime")) { try verify(runtime) }
        let app = try AppFixture.signed(AppFixture.manifest())
        #expect(throws: ManifestRejection.wrongKind(expected: "runtime", found: "app")) {
            try ManifestVerifier.verify(app, trust: Fixture.trust, context: Fixture.context())
        }
        // A runtime manifest that names its kind still verifies as one; any other kind is refused by both.
        var runtimeJSON = String(decoding: try Fixture.manifest().canonicalBytes(), as: UTF8.self)
        runtimeJSON.removeFirst()
        let named = try AppFixture.signedPayload(#"{"kind":"runtime","# + runtimeJSON)
        #expect(try ManifestVerifier.verify(named, trust: Fixture.trust, context: Fixture.context()) == Fixture.manifest())
        #expect(throws: ManifestRejection.wrongKind(expected: "app", found: "runtime")) { try verify(named) }
        let other = try AppFixture.signedPayload(#"{"kind":"engine","# + runtimeJSON)
        #expect(throws: ManifestRejection.wrongKind(expected: "runtime", found: "engine")) {
            try ManifestVerifier.verify(other, trust: Fixture.trust, context: Fixture.context())
        }
        #expect(throws: ManifestRejection.wrongKind(expected: "app", found: "engine")) { try verify(other) }
    }

    @Test func aPayloadOfKindAppThatIsNoAppManifestIsMalformed() throws {
        let data = try AppFixture.signedPayload(#"{"kind":"app","hello":"world"}"#)
        #expect {
            try verify(data)
        } throws: { error in
            if case .malformedManifest = error as? ManifestRejection { true } else { false }
        }
    }

    /// The serial floor refuses a replayed older manifest; the same one (checked again by prepare) still passes.
    @Test func olderSerialsAreRefusedButTheSameSerialIsFine() throws {
        let data = try AppFixture.signed(AppFixture.manifest(serial: 42))
        #expect(throws: ManifestRejection.olderSerial(received: 42, accepted: 43)) {
            try verify(data, context: AppFixture.context(serial: 43))
        }
        #expect(try verify(data, context: AppFixture.context(serial: 42)).serial == 42)
        #expect(try verify(data, context: AppFixture.context(serial: nil)).serial == 42)
    }

    @Test func expiredManifestsAreRefused() throws {
        var manifest = AppFixture.manifest()
        manifest.expires = Fixture.now
        #expect(throws: ManifestRejection.expired(Fixture.now)) { try verify(try AppFixture.signed(manifest)) }
    }

    @Test func onlyPinnedCertificatesAreTrusted() throws {
        var manifest = AppFixture.manifest()
        manifest.signerFingerprint = String(repeating: "cd", count: 32)
        #expect(throws: ManifestRejection.untrustedSigner(manifest.signerFingerprint)) {
            try verify(try AppFixture.signed(manifest))
        }
        manifest.signerFingerprint = Fixture.signer.uppercased()
        #expect(try verify(try AppFixture.signed(manifest)).build == "413")
    }

    @Test func unsupportedSchemasAreRejected() throws {
        var manifest = AppFixture.manifest()
        manifest.schema = 2
        #expect(throws: ManifestRejection.unsupportedSchema(2)) { try verify(try AppFixture.signed(manifest)) }
    }

    @Test(arguments: [
        { (m: inout AppManifest) in m.version = "0.2.0 beta" },
        { (m: inout AppManifest) in m.version = "1" },
        { (m: inout AppManifest) in m.version = "1.2.3.4.5" },
        { (m: inout AppManifest) in m.version = "../0.2" },
        { (m: inout AppManifest) in m.build = "413b" },
        { (m: inout AppManifest) in m.build = "" },
        { (m: inout AppManifest) in m.build = "4/13" },
        { (m: inout AppManifest) in m.minMacOS = "fifteen" },
        { (m: inout AppManifest) in m.url = URL(string: "http://releases.example.org/Warzag.zip")! },
        { (m: inout AppManifest) in m.url = URL(string: "file:///tmp/Warzag.zip")! },
        { (m: inout AppManifest) in m.url = URL(string: "http://127.0.0.1:8123/Warzag.zip")! },
        { (m: inout AppManifest) in m.releaseNotes = URL(string: "http://releases.example.org/notes")! },
        { (m: inout AppManifest) in m.sha256 = String(repeating: "C", count: 64) },
        { (m: inout AppManifest) in m.sha256 = "abc" },
        { (m: inout AppManifest) in m.size = 0 },
    ] as [@Sendable (inout AppManifest) -> Void])
    func malformedFieldsAreRejected(_ corrupt: @Sendable (inout AppManifest) -> Void) throws {
        var manifest = AppFixture.manifest()
        corrupt(&manifest)
        let data = try AppFixture.signed(manifest)
        #expect {
            try verify(data)
        } throws: { error in
            if case .malformedManifest = error as? ManifestRejection { true } else { false }
        }
    }

    /// A rehearsal's local feed: plain http on the loopback address, only where a development build allows it.
    @Test func loopbackHTTPOnlyWhenAllowed() throws {
        let data = try AppFixture.signed(AppFixture.manifest(url: "http://127.0.0.1:8123/Warzag-0.2.0.zip"))
        #expect(try verify(data, context: AppFixture.context(loopback: true)).url.port == 8123)
        #expect(throws: ManifestRejection.malformedManifest("archive URL must be https")) { try verify(data) }
        let remote = try AppFixture.signed(AppFixture.manifest(url: "http://releases.example.org/Warzag-0.2.0.zip"))
        #expect(throws: ManifestRejection.malformedManifest("archive URL must be https")) {
            try verify(remote, context: AppFixture.context(loopback: true))
        }
    }

    @Test func canonicalBytesAreStableSortedAndNameTheKind() throws {
        let manifest = AppFixture.manifest()
        let bytes = try manifest.canonicalBytes()
        #expect(bytes == (try manifest.canonicalBytes()))
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.hasPrefix(#"{"build":"413","expires":"2026-11-13T17:46:40Z","kind":"app","minMacOS":"15.0","#))
        let keys = ["build", "expires", "kind", "minMacOS", "releaseNotes", "schema", "serial", "sha256",
                    "signerFingerprint", "size", "url", "version"]
        let offsets = keys.map { text.range(of: "\"\($0)\":")?.lowerBound }
        #expect(!offsets.contains(nil))
        #expect(offsets.compactMap { $0 } == offsets.compactMap { $0 }.sorted())
        var plain = manifest
        plain.releaseNotes = nil
        #expect(!String(decoding: try plain.canonicalBytes(), as: UTF8.self).contains("releaseNotes"))
    }
}

@Suite struct AppBuildOrderTests {
    @Test(arguments: [
        ("124", "1000", true), ("1000", "124", false), ("413", "413", false), ("413", "412", false),
        ("1.10", "1.9", false), ("1.9", "1.10", true), ("2", "1.9", false), ("0", "1", true),
        // A running build that is no number (a development run) is older than any.
        ("dev", "1", true), ("", "1", true),
        // An offered build that is no number is never newer.
        ("1", "413b", false), ("1", "", false),
    ])
    func buildsCompareNumerically(_ running: String, _ offered: String, _ newer: Bool) {
        #expect(AppManifest.isNewer(offered, than: running) == newer)
    }

    @Test func buildNumbersAreDottedDigitsOnly() {
        #expect(AppManifest.buildNumber("413") != nil)
        #expect(AppManifest.buildNumber("1.2.3") != nil)
        #expect(AppManifest.buildNumber("413-rc1") == nil)
        #expect(AppManifest.buildNumber("٤١٣") == nil)
        #expect(AppManifest.buildNumber("") == nil)
    }
}
