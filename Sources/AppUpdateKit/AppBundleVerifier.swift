import CryptoKit
import Darwin
import Foundation
import RuntimeKit
import Security
import WarzagCore

/// What a downloaded Warzag must be: the bundle an app manifest describes, signed by the certificate it names (which
/// the build pins).
public struct AppRequirement: Codable, Equatable, Sendable {
    public var bundleIdentifier: String
    public var version: String
    public var build: String
    /// Lowercase hex SHA-256 of the leaf certificate.
    public var signerFingerprint: String

    public init(bundleIdentifier: String = AppManifest.bundleIdentifier, version: String, build: String,
                signerFingerprint: String) {
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.build = build
        self.signerFingerprint = signerFingerprint.lowercased()
    }

    public init(_ manifest: AppManifest) {
        self.init(version: manifest.version, build: manifest.build, signerFingerprint: manifest.signerFingerprint)
    }

    /// Where every Warzag.app keeps warzagctl, which performs the swap (`AppSwap`).
    public static let helperPath = "Contents/Helpers/warzagctl"
}

/// Why a Warzag.app is not one an update may install.
public enum AppBundleRejection: Error, Equatable, Sendable, CustomStringConvertible {
    case notABundle(String)
    /// A symbolic link whose target is absolute or lies outside the bundle.
    case linkLeavesBundle(String)
    /// Something that is neither a folder, a file nor a link (a FIFO, a device).
    case unexpectedItem(String)
    case quarantined(String)
    /// The code signature does not validate: changed, added or missing files, nested code changed after signing.
    case badSignature(String)
    /// Signed ad hoc: no certificate to compare.
    case noCertificate
    case signerMismatch(expected: String, actual: String)
    case identityMismatch(expected: String, actual: String)
    case versionMismatch(expected: String, actual: String)
    case buildMismatch(expected: String, actual: String)
    case architecture(path: String, found: String)
    case missingCode(String)

    public var description: String {
        switch self {
        case .notABundle(let path): "\(path) is not an app bundle"
        case .linkLeavesBundle(let path): "the link \(path) leads out of the bundle"
        case .unexpectedItem(let path): "\(path) is neither a file, a folder nor a link"
        case .quarantined(let path): "\(path) carries a quarantine attribute"
        case .badSignature(let reason): "the code signature does not validate: \(reason)"
        case .noCertificate: "the app is signed ad hoc, not by the project certificate"
        case .signerMismatch(let expected, let actual): "the app is signed by \(actual), not by \(expected)"
        case .identityMismatch(let expected, let actual): "the app is \(actual), not \(expected)"
        case .versionMismatch(let expected, let actual): "the app is version \(actual), not \(expected)"
        case .buildMismatch(let expected, let actual): "the app is build \(actual), not \(expected)"
        case .architecture(let path, let found): "\(path) is \(found), not arm64"
        case .missingCode(let path): "\(path) is missing"
        }
    }
}

/// Checks a Warzag.app before anything installs it, and again in place after the swap.
public protocol AppBundleVerifying: Sendable {
    /// Throws unless `bundle` is exactly the Warzag `requirement` describes.
    func verify(_ bundle: URL, against requirement: AppRequirement) throws(AppBundleRejection)
}

/// The real checks, in this order: only folders, files and links that stay inside the bundle, and no quarantine
/// attribute (a quarantined copy would need another Open Anyway); a strict code signature
/// (`SecurityCodeSignatureInspector.validationFlags`) by the required certificate, with the required identifier; then,
/// from the Info.plist that signature seals, identity, version and build; last, an arm64 main executable and warzagctl.
public struct LiveAppBundleVerifier: AppBundleVerifying {
    /// What a code signature says once it validated: its leaf certificate's SHA-256 (nil for ad hoc) and identifier.
    public struct Signature: Equatable, Sendable {
        public var fingerprint: String?
        public var identifier: String?

        public init(fingerprint: String?, identifier: String?) {
            self.fingerprint = fingerprint
            self.identifier = identifier
        }
    }

    /// Validates a bundle's signature (Security.framework); tests stand in a certificate the test Mac cannot sign with.
    var signature: @Sendable (URL) throws(AppBundleRejection) -> Signature

    public init() {
        signature = { url throws(AppBundleRejection) in try Self.codeSignature(of: url) }
    }

    init(signature: @escaping @Sendable (URL) throws(AppBundleRejection) -> Signature) {
        self.signature = signature
    }

    public func verify(_ bundle: URL, against requirement: AppRequirement) throws(AppBundleRejection) {
        try Self.checkTree(bundle)
        let signature = try signature(bundle)
        guard let fingerprint = signature.fingerprint else { throw .noCertificate }
        guard fingerprint == requirement.signerFingerprint else {
            throw .signerMismatch(expected: requirement.signerFingerprint, actual: fingerprint)
        }
        guard signature.identifier == requirement.bundleIdentifier else {
            throw .identityMismatch(expected: requirement.bundleIdentifier, actual: signature.identifier ?? "unnamed code")
        }
        let info = BundleInfo.read(bundle, fileSystem: LocalFileSystem()) ?? [:]
        let identifier = info["CFBundleIdentifier"] as? String ?? "none"
        guard identifier == requirement.bundleIdentifier else {
            throw .identityMismatch(expected: requirement.bundleIdentifier, actual: identifier)
        }
        let version = info["CFBundleShortVersionString"] as? String ?? "none"
        guard version == requirement.version else { throw .versionMismatch(expected: requirement.version, actual: version) }
        let build = info["CFBundleVersion"] as? String ?? "none"
        guard build == requirement.build else { throw .buildMismatch(expected: requirement.build, actual: build) }
        guard let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty, !executable.contains("/") else {
            throw .missingCode("CFBundleExecutable")
        }
        for program in ["Contents/MacOS/\(executable)", AppRequirement.helperPath] {
            let url = bundle.appending(path: program)
            guard let header = try? LocalFileSystem().read(url, offset: 0, maxLength: MachO.headerReadLength) else {
                throw .missingCode(program)
            }
            let architectures = MachO.architectures(header: header)
            guard architectures == [.arm64] else {
                throw .architecture(path: program,
                                    found: architectures?.map(\.description).joined(separator: "+") ?? "not a Mach-O file")
            }
        }
    }

    /// The bundle is a folder (not a link to one); everything in it a folder, a file or a relative link that stays
    /// inside it; nothing carries com.apple.quarantine.
    static func checkTree(_ bundle: URL) throws(AppBundleRejection) {
        let root = bundle.plainPath
        var info = stat()
        guard lstat(root, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw .notABundle(bundle.lastPathComponent) }
        if isQuarantined(root) { throw .quarantined(bundle.lastPathComponent) }
        guard let entries = FileManager.default.enumerator(atPath: root) else { throw .notABundle(bundle.lastPathComponent) }
        for case let relative as String in entries {
            let path = root + "/" + relative
            guard lstat(path, &info) == 0 else { throw .unexpectedItem(relative) }
            switch info.st_mode & S_IFMT {
            case S_IFDIR, S_IFREG:
                break
            case S_IFLNK:
                let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? "/"
                guard staysInside(link: relative, target: target) else { throw .linkLeavesBundle(relative) }
            default:
                throw .unexpectedItem(relative)
            }
            if isQuarantined(path) { throw .quarantined(relative) }
        }
    }

    /// Whether a link at `link` (relative to the bundle) pointing at `target` resolves inside the bundle.
    static func staysInside(link: String, target: String) -> Bool {
        guard !target.isEmpty, !target.hasPrefix("/") else { return false }
        var components = link.split(separator: "/").dropLast().map(String.init)
        for component in target.split(separator: "/") {
            switch component {
            case ".": continue
            case "..":
                guard !components.isEmpty else { return false }
                components.removeLast()
            default: components.append(String(component))
            }
        }
        return true
    }

    static func isQuarantined(_ path: String) -> Bool {
        getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// Validates the signature strictly and reads its identifier and leaf certificate.
    static func codeSignature(of bundle: URL) throws(AppBundleRejection) -> Signature {
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(bundle as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw .badSignature(message(status)) }
        status = SecStaticCodeCheckValidity(code, SecurityCodeSignatureInspector.validationFlags, nil)
        guard status == errSecSuccess else { throw .badSignature(message(status)) }
        var information: CFDictionary?
        status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard status == errSecSuccess, let info = information as? [String: Any] else {
            throw .badSignature(message(status))
        }
        let leaf = (info[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first
        return Signature(
            fingerprint: leaf.map { SHA256.hash(data: SecCertificateCopyData($0) as Data).map { String(format: "%02x", $0) }
                .joined() },
            identifier: info[kSecCodeInfoIdentifier as String] as? String)
    }

    static func message(_ status: OSStatus) -> String {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "error"
        return "\(text) (OSStatus \(status))"
    }
}
