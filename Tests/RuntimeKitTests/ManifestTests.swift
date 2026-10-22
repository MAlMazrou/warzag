import CryptoKit
import Foundation
import Testing
import WarzagCore
@testable import RuntimeKit

/// Keys and a manifest shared by the runtime tests.
enum Fixture {
    static let key = Curve25519.Signing.PrivateKey()
    static let nextKey = Curve25519.Signing.PrivateKey()
    static let strangerKey = Curve25519.Signing.PrivateKey()
    static let signer = String(repeating: "ab", count: 32)
    static let now = Date(timeIntervalSince1970: 1_792_000_000)

    static let trust = ManifestTrust(
        publicKeys: ["rt-2026a": key.publicKey.rawRepresentation, "rt-2026b": nextKey.publicKey.rawRepresentation],
        signerFingerprints: [signer]
    )

    static func context(serial: UInt64? = 41, revoked: Set<String> = [], app: String = "1.0.0",
                        macOS: String = "26.5.1") -> ManifestContext {
        ManifestContext(now: now, lastAcceptedSerial: serial, revoked: revoked, appVersion: app, macOSVersion: macOS)
    }

    static func manifest(id: String = "n-0.1.0", version: String = "0.1.0", serial: UInt64 = 42,
                         sha256: String = String(repeating: "0", count: 64), size: Int64 = 1234) -> RuntimeManifest {
        RuntimeManifest(
            serial: serial, expires: now.addingTimeInterval(30 * 86_400), id: id, version: version, channel: .n,
            arch: "arm64", minLauncher: "1.0.0", minMacOS: "15.0",
            url: URL(string: "https://runtime.example.org/stable/WarzagRuntime-\(id).aar")!,
            size: size, sha256: sha256, signerFingerprint: signer
        )
    }

    static func signed(_ manifest: RuntimeManifest, keyId: String = "rt-2026a",
                       with key: Curve25519.Signing.PrivateKey = key) throws -> Data {
        try SignedManifest.sign(manifest, keyId: keyId, with: key).encoded()
    }
}

@Suite struct ManifestVerificationTests {
    func verify(_ data: Data, context: ManifestContext = Fixture.context()) throws(ManifestRejection) -> RuntimeManifest {
        try ManifestVerifier.verify(data, trust: Fixture.trust, context: context)
    }

    @Test func aProperlySignedManifestVerifies() throws {
        let manifest = Fixture.manifest()
        #expect(try verify(try Fixture.signed(manifest)) == manifest)
    }

    @Test func eitherPinnedKeyIsAccepted() throws {
        let manifest = Fixture.manifest()
        #expect(try verify(try Fixture.signed(manifest, keyId: "rt-2026b", with: Fixture.nextKey)) == manifest)
    }

    @Test func aTamperedPayloadIsRejected() throws {
        var envelope = try SignedManifest.sign(Fixture.manifest(), keyId: "rt-2026a", with: Fixture.key)
        let text = String(decoding: envelope.payload, as: UTF8.self)
        envelope.payload = Data(text.replacingOccurrences(of: "runtime.example.org", with: "evil.example.org").utf8)
        #expect(throws: ManifestRejection.badSignature) { try verify(try envelope.encoded()) }
    }

    @Test func aSingleFlippedBitIsRejected() throws {
        var envelope = try SignedManifest.sign(Fixture.manifest(), keyId: "rt-2026a", with: Fixture.key)
        envelope.payload[envelope.payload.startIndex + 10] ^= 0x01
        #expect(throws: ManifestRejection.badSignature) { try verify(try envelope.encoded()) }
        var badSignature = try SignedManifest.sign(Fixture.manifest(), keyId: "rt-2026a", with: Fixture.key)
        badSignature.signature[badSignature.signature.startIndex] ^= 0x80
        #expect(throws: ManifestRejection.badSignature) { try verify(try badSignature.encoded()) }
    }

    @Test func aSignatureFromAnUnpinnedKeyIsRejected() throws {
        let forged = try Fixture.signed(Fixture.manifest(), keyId: "rt-2026a", with: Fixture.strangerKey)
        #expect(throws: ManifestRejection.badSignature) { try verify(forged) }
        let unknown = try Fixture.signed(Fixture.manifest(), keyId: "rt-1999", with: Fixture.strangerKey)
        #expect(throws: ManifestRejection.unknownKey("rt-1999")) { try verify(unknown) }
    }

    @Test func garbageIsAMalformedEnvelope() {
        #expect(throws: ManifestRejection.malformedEnvelope) { try verify(Data("not json".utf8)) }
        #expect(throws: ManifestRejection.malformedEnvelope) { try verify(Data(#"{"keyId":"rt-2026a"}"#.utf8)) }
    }

    @Test func aSignedPayloadThatIsNotAManifestIsMalformed() throws {
        let payload = Data(#"{"hello":"world"}"#.utf8)
        let envelope = SignedManifest(keyId: "rt-2026a", payload: payload, signature: try Fixture.key.signature(for: payload))
        #expect {
            try verify(try envelope.encoded())
        } throws: { error in
            if case .malformedManifest = error as? ManifestRejection { true } else { false }
        }
    }

    @Test func olderSerialsAreRefusedButTheSameSerialIsFine() throws {
        let manifest = Fixture.manifest(serial: 42)
        let data = try Fixture.signed(manifest)
        #expect(throws: ManifestRejection.olderSerial(received: 42, accepted: 43)) {
            try verify(data, context: Fixture.context(serial: 43))
        }
        #expect(try verify(data, context: Fixture.context(serial: 42)) == manifest)
        #expect(try verify(data, context: Fixture.context(serial: nil)) == manifest)
    }

    @Test func expiredManifestsAreRefused() throws {
        var manifest = Fixture.manifest()
        manifest.expires = Fixture.now
        #expect(throws: ManifestRejection.expired(Fixture.now)) { try verify(try Fixture.signed(manifest)) }
        manifest.expires = Fixture.now.addingTimeInterval(1)
        #expect(try verify(try Fixture.signed(manifest)) == manifest)
    }

    @Test func revokedRuntimesAreRefused() throws {
        let data = try Fixture.signed(Fixture.manifest(id: "n-0.1.0"))
        #expect(throws: ManifestRejection.revoked("n-0.1.0")) {
            try verify(data, context: Fixture.context(revoked: ["n-0.1.0"]))
        }
        var selfRevoking = Fixture.manifest(id: "n-0.1.0")
        selfRevoking.revoked = ["n-0.0.9", "n-0.1.0"]
        #expect(throws: ManifestRejection.revoked("n-0.1.0")) { try verify(try Fixture.signed(selfRevoking)) }
    }

    @Test func onlyPinnedCodeSigningCertificatesAreTrusted() throws {
        var manifest = Fixture.manifest()
        manifest.signerFingerprint = String(repeating: "cd", count: 32)
        #expect(throws: ManifestRejection.untrustedSigner(manifest.signerFingerprint)) {
            try verify(try Fixture.signed(manifest))
        }
        manifest.signerFingerprint = Fixture.signer.uppercased()
        #expect(try verify(try Fixture.signed(manifest)).id == "n-0.1.0")
    }

    @Test func channelAndArchitectureMustAgree() throws {
        var manifest = Fixture.manifest()
        manifest.arch = "x86_64"
        #expect(throws: ManifestRejection.architectureMismatch(channel: .n, arch: "x86_64")) {
            try verify(try Fixture.signed(manifest))
        }
    }

    /// A manifest for any channel but n is no manifest Warzag can read.
    @Test func aManifestOfAnotherChannelIsMalformed() throws {
        let text = String(decoding: try Fixture.manifest().canonicalBytes(), as: UTF8.self)
        let payload = Data(text.replacingOccurrences(of: #""channel":"n""#, with: #""channel":"x""#).utf8)
        let envelope = SignedManifest(keyId: "rt-2026a", payload: payload, signature: try Fixture.key.signature(for: payload))
        #expect {
            try verify(try envelope.encoded())
        } throws: { error in
            if case .malformedManifest = error as? ManifestRejection { true } else { false }
        }
    }

    @Test func compatibilityWithThisAppAndMacOS() throws {
        var manifest = Fixture.manifest()
        manifest.minLauncher = "1.2.0"
        manifest.minMacOS = "27.0"
        let data = try Fixture.signed(manifest)
        #expect(throws: ManifestRejection.requiresNewerApp("1.2.0")) { try verify(data) }
        #expect(throws: ManifestRejection.requiresNewerMacOS("27.0")) { try verify(data, context: Fixture.context(app: "1.2.0")) }
        #expect(try verify(data, context: Fixture.context(app: "1.10.0", macOS: "27.0.1")) == manifest)
    }

    @Test(arguments: [
        { (m: inout RuntimeManifest) in m.id = "../../etc" },
        { (m: inout RuntimeManifest) in m.version = "0.1/0" },
        { (m: inout RuntimeManifest) in m.url = URL(string: "http://runtime.example.org/pack.aar")! },
        { (m: inout RuntimeManifest) in m.sha256 = "XYZ" },
        { (m: inout RuntimeManifest) in m.sha256 = String(repeating: "A", count: 64) },
        { (m: inout RuntimeManifest) in m.size = 0 },
        { (m: inout RuntimeManifest) in m.minMacOS = "fifteen" },
    ] as [@Sendable (inout RuntimeManifest) -> Void])
    func malformedFieldsAreRejected(_ corrupt: @Sendable (inout RuntimeManifest) -> Void) throws {
        var manifest = Fixture.manifest()
        corrupt(&manifest)
        let data = try Fixture.signed(manifest)
        #expect {
            try verify(data)
        } throws: { error in
            if case .malformedManifest = error as? ManifestRejection { true } else { false }
        }
    }

    @Test func unsupportedSchemasAreRejected() throws {
        var manifest = Fixture.manifest()
        manifest.schema = 2
        #expect(throws: ManifestRejection.unsupportedSchema(2)) { try verify(try Fixture.signed(manifest)) }
    }

    @Test func canonicalBytesAreStableAndSorted() throws {
        let manifest = Fixture.manifest()
        let bytes = try manifest.canonicalBytes()
        #expect(bytes == (try manifest.canonicalBytes()))
        let text = String(decoding: bytes, as: UTF8.self)
        let keys = ["arch", "channel", "expires", "id", "killSwitch", "minLauncher", "minMacOS", "revoked", "schema",
                    "serial", "sha256", "signerFingerprint", "size", "url", "version"]
        let offsets = keys.map { text.range(of: "\"\($0)\":")?.lowerBound }
        #expect(!offsets.contains(nil))
        #expect(offsets.compactMap { $0 } == offsets.compactMap { $0 }.sorted())
        #expect(text.hasPrefix(#"{"arch":"arm64","channel":"n","expires":"2026-11-13T17:46:40Z","id":"n-0.1.0","killSwitch":{"level":"none"}"#))
        #expect(text.contains(#""url":"https://runtime.example.org/stable/WarzagRuntime-n-0.1.0.aar""#))
        #expect(!text.contains("\n"))
        #expect(try WarzagJSON.decoder().decode(RuntimeManifest.self, from: bytes) == manifest)
    }
}
