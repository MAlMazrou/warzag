import Foundation
import Security

public struct CodeSignatureError: Error, Equatable, CustomStringConvertible {
    public var status: OSStatus
    public var stage: String
    public var description: String { "code signature \(stage) failed (OSStatus \(status))" }
}

/// Who signed a bundle, behind a protocol so tests do not need signed bundles.
public protocol CodeSignatureInspecting: Sendable {
    /// Validates the bundle's signature and returns the lowercase hex SHA-256 of its leaf certificate, or nil for
    /// ad-hoc signed code (which has no certificate). Throws if the signature is broken.
    func signerFingerprint(of bundle: URL) throws -> String?
}

public struct SecurityCodeSignatureInspector: CodeSignatureInspecting {
    /// What `codesign --verify --deep --strict` checks. With default flags, nested code (a host's
    /// Contents/MacOS/wineserver) is matched only by its code-directory hash, never by its pages, so a modified binary
    /// that kept its old signature would pass. AppUpdateKit checks a downloaded Warzag.app with the same flags.
    public static let validationFlags = SecCSFlags(rawValue: kSecCSCheckNestedCode | kSecCSStrictValidate
        | kSecCSCheckAllArchitectures)

    public init() {}

    public func signerFingerprint(of bundle: URL) throws -> String? {
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(bundle as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw CodeSignatureError(status: status, stage: "open") }
        status = SecStaticCodeCheckValidity(code, Self.validationFlags, nil)
        guard status == errSecSuccess else { throw CodeSignatureError(status: status, stage: "validation") }
        var information: CFDictionary?
        status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard status == errSecSuccess, let info = information as? [String: Any] else {
            throw CodeSignatureError(status: status, stage: "signing information")
        }
        guard let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        return (SecCertificateCopyData(leaf) as Data).sha256Hex
    }
}
