import Foundation
import WarzagCore

/// Remote brake on a runtime.
public struct KillSwitch: Codable, Equatable, Sendable {
    public enum Level: String, Codable, Sendable {
        case none
        /// Do not install or activate this runtime.
        case blockInstall
    }

    public var level: Level
    public var message: String?

    public init(level: Level, message: String? = nil) {
        self.level = level
        self.message = message
    }

    public static let none = KillSwitch(level: .none)
}

/// One runtime release ("Warzag.app" pack) as published in a signed manifest.
///
/// The manifest is signed as bytes: the signer encodes it once (`canonicalBytes`: sorted keys, ISO 8601 dates
/// without fractional seconds) and the envelope carries exactly those bytes, so verification never depends on
/// re-encoding.
public struct RuntimeManifest: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public var schema: Int
    /// Increases with every published manifest; older serials are refused (anti-rollback).
    public var serial: UInt64
    /// After this, the manifest no longer authorises installs. Installed runtimes keep working offline.
    public var expires: Date
    /// Unique runtime id, e.g. "n-0.2.0".
    public var id: String
    public var version: String
    public var channel: RuntimeChannel
    /// The loader's architecture, "arm64".
    public var arch: String
    /// Oldest Warzag.app that can drive this runtime.
    public var minLauncher: String
    public var minMacOS: String
    public var url: URL
    public var size: Int64
    /// Lowercase hex SHA-256 of the pack file.
    public var sha256: String
    /// Lowercase hex SHA-256 of the certificate that code-signs the pack; must be one the app pins.
    public var signerFingerprint: String
    /// Runtime ids that must never run again.
    public var revoked: [String]
    public var killSwitch: KillSwitch

    public init(
        serial: UInt64, expires: Date, id: String, version: String, channel: RuntimeChannel, arch: String,
        minLauncher: String, minMacOS: String, url: URL, size: Int64, sha256: String, signerFingerprint: String,
        revoked: [String] = [], killSwitch: KillSwitch = .none
    ) {
        schema = Self.schemaVersion
        self.serial = serial
        self.expires = expires
        self.id = id
        self.version = version
        self.channel = channel
        self.arch = arch
        self.minLauncher = minLauncher
        self.minMacOS = minMacOS
        self.url = url
        self.size = size
        self.sha256 = sha256
        self.signerFingerprint = signerFingerprint
        self.revoked = revoked
        self.killSwitch = killSwitch
    }

    /// The bytes a publisher signs.
    public func canonicalBytes() throws -> Data {
        try WarzagJSON.encoder().encode(self)
    }
}

/// A file or directory name that cannot escape its parent (runtime ids and versions become path components).
func isSafePathComponent(_ text: String) -> Bool {
    !text.isEmpty && text.count <= 64 && text != "." && text != ".."
        && text.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._-+".unicodeScalars.contains(scalar))
        }
}
