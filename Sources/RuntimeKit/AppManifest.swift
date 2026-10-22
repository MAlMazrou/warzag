import CryptoKit
import Foundation
import WarzagCore

/// One Warzag.app release, as its signed app manifest publishes it (docs/RELEASING.md).
///
/// It uses the runtime manifests' envelope (`SignedManifest`) and trust (`ManifestTrust`). `kind` keeps the two apart:
/// `AppManifestVerifier` accepts only kind "app", and `ManifestVerifier` refuses any kind but "runtime", so a manifest
/// signed for one is never acted on as the other.
public struct AppManifest: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    /// The `kind` of every app manifest.
    public static let kind = "app"
    /// The only bundle an app manifest describes, and the one name it has in an update archive.
    public static let bundleIdentifier = "com.warzag.app"
    public static let bundleName = "Warzag.app"

    public var kind: String
    public var schema: Int
    /// Increases with every published app manifest; one older than this Mac has accepted is refused (a replay).
    public var serial: UInt64
    /// After this, the manifest offers nothing: an old manifest served again later cannot hold players back for ever.
    public var expires: Date
    /// The new Warzag's CFBundleShortVersionString, for example "0.2.0": what the player reads.
    public var version: String
    /// The new Warzag's CFBundleVersion, for example "412": the number that orders releases (only a higher one than
    /// the running app's is ever offered).
    public var build: String
    public var minMacOS: String
    /// The update archive (Warzag-<version>.zip, as `DittoArchiveExtractor` describes it).
    public var url: URL
    public var size: Int64
    /// Lowercase hex SHA-256 of the archive.
    public var sha256: String
    /// Lowercase hex SHA-256 of the certificate that code-signs Warzag.app; must be one the app pins.
    public var signerFingerprint: String
    /// The release's page, where the player reads what changed.
    public var releaseNotes: URL?

    public init(serial: UInt64, expires: Date, version: String, build: String, minMacOS: String, url: URL, size: Int64,
                sha256: String, signerFingerprint: String, releaseNotes: URL? = nil) {
        kind = Self.kind
        schema = Self.schemaVersion
        self.serial = serial
        self.expires = expires
        self.version = version
        self.build = build
        self.minMacOS = minMacOS
        self.url = url
        self.size = size
        self.sha256 = sha256
        self.signerFingerprint = signerFingerprint
        self.releaseNotes = releaseNotes
    }

    /// The bytes a publisher signs.
    public func canonicalBytes() throws -> Data {
        try WarzagJSON.encoder().encode(self)
    }

    /// A build number as releases order them: dotted digits ("412", "1.7"), compared numerically; nil for anything
    /// else (a suffix such as "412b" orders nothing).
    public static func buildNumber(_ text: String) -> VersionNumber? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else { return nil }
        return VersionNumber(text)
    }

    /// Whether `build` comes after `running`. A running build that is no number (a development run's "0" is one) is
    /// older than any; an offered build that is none is never newer.
    public static func isNewer(_ build: String, than running: String) -> Bool {
        guard let offered = buildNumber(build) else { return false }
        guard let current = buildNumber(running) else { return true }
        return current < offered
    }
}

extension SignedManifest {
    /// Publisher side for an app manifest (warzag-release, and tests).
    public static func sign(_ manifest: AppManifest, keyId: String,
                            with key: Curve25519.Signing.PrivateKey) throws -> SignedManifest {
        let payload = try manifest.canonicalBytes()
        return SignedManifest(keyId: keyId, payload: payload, signature: try key.signature(for: payload))
    }
}

/// Facts about this install an app manifest is checked against.
public struct AppManifestContext: Sendable {
    public var now: Date
    /// Highest app-manifest serial this Mac accepted (State/app-update.json); runtime manifests count their own.
    public var lastAcceptedSerial: UInt64?
    /// Development builds only: the archive and the release notes may also be plain http on this Mac's loopback
    /// address, for a local feed. Release builds never set it.
    public var allowsLoopbackHTTP: Bool

    public init(now: Date, lastAcceptedSerial: UInt64?, allowsLoopbackHTTP: Bool = false) {
        self.now = now
        self.lastAcceptedSerial = lastAcceptedSerial
        self.allowsLoopbackHTTP = allowsLoopbackHTTP
    }
}

/// Decides whether a fetched app manifest may be acted on. As for runtime manifests, nothing in the payload is trusted
/// until the signature over its exact bytes has verified; then its kind, before it is read as an app manifest at all.
public enum AppManifestVerifier {
    public static func verify(_ data: Data, trust: ManifestTrust,
                              context: AppManifestContext) throws(ManifestRejection) -> AppManifest {
        let payload = try SignedManifest.verifiedPayload(data, trust: trust)
        let kind = SignedManifest.kind(of: payload)
        guard kind == AppManifest.kind else {
            throw .wrongKind(expected: AppManifest.kind, found: kind ?? RuntimeManifest.kind)
        }
        let manifest: AppManifest
        do {
            manifest = try WarzagJSON.decoder().decode(AppManifest.self, from: payload)
        } catch {
            throw .malformedManifest(String(describing: error))
        }
        try check(manifest, trust: trust, context: context)
        return manifest
    }

    static func check(_ manifest: AppManifest, trust: ManifestTrust,
                      context: AppManifestContext) throws(ManifestRejection) {
        guard manifest.schema == AppManifest.schemaVersion else { throw .unsupportedSchema(manifest.schema) }
        if let accepted = context.lastAcceptedSerial, manifest.serial < accepted {
            throw .olderSerial(received: manifest.serial, accepted: accepted)
        }
        guard context.now < manifest.expires else { throw .expired(manifest.expires) }
        guard trust.signerFingerprints.contains(manifest.signerFingerprint.lowercased()) else {
            throw .untrustedSigner(manifest.signerFingerprint)
        }
        guard isPublishedVersion(manifest.version) else {
            throw .malformedManifest("version must be numbers and dots, as CFBundleShortVersionString")
        }
        guard AppManifest.buildNumber(manifest.build) != nil, manifest.build.count <= 32 else {
            throw .malformedManifest("build must be numbers and dots, as CFBundleVersion")
        }
        guard VersionNumber(manifest.minMacOS) != nil else { throw .malformedManifest("minMacOS must be a version") }
        guard isAllowed(manifest.url, context: context) else { throw .malformedManifest("archive URL must be https") }
        if let notes = manifest.releaseNotes, !isAllowed(notes, context: context) {
            throw .malformedManifest("release notes URL must be https")
        }
        guard manifest.size > 0, manifest.sha256.count == 64,
              manifest.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw .malformedManifest("size and sha256 must describe the archive")
        }
    }

    /// "0.2.0": what make-app.sh writes into CFBundleShortVersionString (2 to 4 numbers).
    static func isPublishedVersion(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return (2...4).contains(parts.count)
            && parts.allSatisfy { !$0.isEmpty && $0.count <= 9 && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    /// https with a host; with `allowsLoopbackHTTP` (development builds) also http to this Mac's loopback address.
    public static func isAllowed(_ url: URL, context: AppManifestContext) -> Bool {
        guard let host = url.host(), !host.isEmpty else { return false }
        if url.scheme == "https" { return true }
        return context.allowsLoopbackHTTP && url.scheme == "http" && isLoopback(host)
    }

    /// 127.0.0.1, ::1 or localhost.
    public static func isLoopback(_ host: String) -> Bool {
        ["127.0.0.1", "::1", "[::1]", "localhost"].contains(host.lowercased())
    }
}
