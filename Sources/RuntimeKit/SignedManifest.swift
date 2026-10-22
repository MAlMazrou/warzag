import CryptoKit
import Foundation
import WarzagCore

/// A signed manifest (runtime or app) with its detached Ed25519 signature. `payload` holds the manifest bytes exactly
/// as signed.
public struct SignedManifest: Codable, Equatable, Sendable {
    /// Which pinned key signed it (the app pins the current and the next key, for rotation).
    public var keyId: String
    public var payload: Data
    public var signature: Data

    public init(keyId: String, payload: Data, signature: Data) {
        self.keyId = keyId
        self.payload = payload
        self.signature = signature
    }

    /// Publisher side (warzag-release, and tests).
    public static func sign(_ manifest: RuntimeManifest, keyId: String,
                            with key: Curve25519.Signing.PrivateKey) throws -> SignedManifest {
        let payload = try manifest.canonicalBytes()
        return SignedManifest(keyId: keyId, payload: payload, signature: try key.signature(for: payload))
    }

    public func encoded() throws -> Data {
        try WarzagJSON.encoder(pretty: true).encode(self)
    }

    /// The payload of an envelope whose signature verifies with the key it names, which `trust` pins. Nothing in the
    /// payload has been read yet; the verifiers of both kinds of manifest start here.
    static func verifiedPayload(_ data: Data, trust: ManifestTrust) throws(ManifestRejection) -> Data {
        let envelope: SignedManifest
        do {
            envelope = try WarzagJSON.decoder().decode(SignedManifest.self, from: data)
        } catch {
            throw .malformedEnvelope
        }
        guard let keyData = trust.publicKeys[envelope.keyId],
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            throw .unknownKey(envelope.keyId)
        }
        guard key.isValidSignature(envelope.signature, for: envelope.payload) else { throw .badSignature }
        return envelope.payload
    }

    /// The `kind` a signed payload names: "app" for an app manifest, nil for a runtime manifest (they name none) and
    /// for a payload that is no JSON object.
    static func kind(of payload: Data) -> String? {
        struct Kind: Decodable {
            var kind: String?
        }
        return (try? WarzagJSON.decoder().decode(Kind.self, from: payload))?.kind
    }
}

extension RuntimeManifest {
    /// The kind a runtime manifest may name. Runtime manifests name none; `ManifestVerifier` refuses any other kind (an
    /// app manifest is "app").
    public static let kind = "runtime"
}

/// What the app trusts, compiled in: manifest-signing public keys and code-signing certificate fingerprints.
public struct ManifestTrust: Sendable {
    /// Raw 32-byte Ed25519 public keys by key id.
    public var publicKeys: [String: Data]
    /// Lowercase hex SHA-256 fingerprints of certificates allowed to sign runtime packs and Warzag.app.
    public var signerFingerprints: Set<String>

    public init(publicKeys: [String: Data], signerFingerprints: Set<String>) {
        self.publicKeys = publicKeys
        self.signerFingerprints = Set(signerFingerprints.map { $0.lowercased() })
    }

    /// A public key's id: the first 16 hex digits of the SHA-256 of its 32 raw bytes, derivable by anyone holding it.
    public static func keyID(for key: Curve25519.Signing.PublicKey) -> String {
        SHA256.hash(data: key.rawRepresentation).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// Facts about this install that a manifest is checked against.
public struct ManifestContext: Sendable {
    public var now: Date
    /// Highest serial accepted so far (Runtimes.noindex/active.json).
    public var lastAcceptedSerial: UInt64?
    /// Revocations learned from earlier manifests.
    public var revoked: Set<String>
    public var appVersion: String
    public var macOSVersion: String

    public init(now: Date, lastAcceptedSerial: UInt64?, revoked: Set<String>, appVersion: String, macOSVersion: String) {
        self.now = now
        self.lastAcceptedSerial = lastAcceptedSerial
        self.revoked = revoked
        self.appVersion = appVersion
        self.macOSVersion = macOSVersion
    }
}

public enum ManifestRejection: Error, Equatable, CustomStringConvertible {
    case malformedEnvelope
    case unknownKey(String)
    /// The signature does not match the payload: tampered, truncated or signed with another key.
    case badSignature
    case malformedManifest(String)
    case unsupportedSchema(Int)
    case olderSerial(received: UInt64, accepted: UInt64)
    case expired(Date)
    case revoked(String)
    case untrustedSigner(String)
    case architectureMismatch(channel: RuntimeChannel, arch: String)
    case requiresNewerApp(String)
    case requiresNewerMacOS(String)
    /// A manifest of another kind: an app manifest offered as a runtime manifest, or the other way round.
    case wrongKind(expected: String, found: String)

    public var description: String {
        switch self {
        case .malformedEnvelope: "manifest envelope is not valid JSON"
        case .unknownKey(let id): "manifest signed with unknown key \(id)"
        case .badSignature: "manifest signature does not verify"
        case .malformedManifest(let reason): "manifest is malformed: \(reason)"
        case .unsupportedSchema(let schema): "manifest schema \(schema) is not supported"
        case .olderSerial(let received, let accepted): "manifest serial \(received) is older than \(accepted)"
        case .expired(let date): "manifest expired at \(date.formatted(.iso8601))"
        case .revoked(let id): "runtime \(id) has been revoked"
        case .untrustedSigner(let fingerprint): "code signer \(fingerprint) is not trusted"
        case .architectureMismatch(let channel, let arch): "channel \(channel.rawValue) cannot be \(arch)"
        case .requiresNewerApp(let version): "runtime needs Warzag \(version) or later"
        case .requiresNewerMacOS(let version): "runtime needs macOS \(version) or later"
        case .wrongKind(let expected, let found): "manifest kind is \(found), not \(expected)"
        }
    }
}

/// Decides whether a fetched manifest may be acted on. Order matters: nothing in the payload is trusted until the
/// signature over its exact bytes has verified, and a payload of another kind (an app manifest, signed with the same
/// keys) is refused before it is read as a runtime manifest.
public enum ManifestVerifier {
    public static func verify(_ data: Data, trust: ManifestTrust,
                              context: ManifestContext) throws(ManifestRejection) -> RuntimeManifest {
        let payload = try SignedManifest.verifiedPayload(data, trust: trust)
        if let kind = SignedManifest.kind(of: payload), kind != RuntimeManifest.kind {
            throw .wrongKind(expected: RuntimeManifest.kind, found: kind)
        }
        let manifest: RuntimeManifest
        do {
            manifest = try WarzagJSON.decoder().decode(RuntimeManifest.self, from: payload)
        } catch {
            throw .malformedManifest(String(describing: error))
        }
        try check(manifest, trust: trust, context: context)
        return manifest
    }

    static func check(_ manifest: RuntimeManifest, trust: ManifestTrust,
                      context: ManifestContext) throws(ManifestRejection) {
        guard manifest.schema == RuntimeManifest.schemaVersion else { throw .unsupportedSchema(manifest.schema) }
        if let accepted = context.lastAcceptedSerial, manifest.serial < accepted {
            throw .olderSerial(received: manifest.serial, accepted: accepted)
        }
        guard context.now < manifest.expires else { throw .expired(manifest.expires) }
        guard !context.revoked.contains(manifest.id), !manifest.revoked.contains(manifest.id) else {
            throw .revoked(manifest.id)
        }
        guard trust.signerFingerprints.contains(manifest.signerFingerprint.lowercased()) else {
            throw .untrustedSigner(manifest.signerFingerprint)
        }
        guard manifest.channel.architecture == manifest.arch else {
            throw .architectureMismatch(channel: manifest.channel, arch: manifest.arch)
        }
        guard isSafePathComponent(manifest.id), isSafePathComponent(manifest.version) else {
            throw .malformedManifest("id and version must be plain names")
        }
        guard manifest.url.scheme == "https" else { throw .malformedManifest("pack URL must be https") }
        guard manifest.size > 0, manifest.sha256.count == 64,
              manifest.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw .malformedManifest("size and sha256 must describe the pack")
        }
        guard let minLauncher = VersionNumber(manifest.minLauncher), let minMacOS = VersionNumber(manifest.minMacOS)
        else { throw .malformedManifest("minLauncher and minMacOS must be versions") }
        if let app = VersionNumber(context.appVersion), app < minLauncher {
            throw .requiresNewerApp(manifest.minLauncher)
        }
        if let os = VersionNumber(context.macOSVersion), os < minMacOS {
            throw .requiresNewerMacOS(manifest.minMacOS)
        }
    }
}
