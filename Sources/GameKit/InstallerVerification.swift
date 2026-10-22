import CryptoKit
import Foundation
import WarzagCore

/// What a downloaded Warframe.msi must look like before Warzag hands it to `msiexec`.
public struct InstallerExpectations: Equatable, Sendable {
    /// DE's installer is about 100 MB; anything under 10 MB is an error page or a truncated file.
    public static let defaultMinimumBytes: Int64 = 10_000_000
    /// OLE/CFB ("compound file") signature every MSI starts with.
    public static let compoundFileSignature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    /// The Authenticode signer of DE's installer (CN of the leaf certificate).
    public static let signer = "Digital Extremes Ltd."

    public var minimumBytes: Int64

    public init(minimumBytes: Int64 = InstallerExpectations.defaultMinimumBytes) {
        self.minimumBytes = minimumBytes
    }
}

public enum InstallerCheckError: Error, Equatable, CustomStringConvertible {
    case missing(String)
    case tooSmall(bytes: Int64, minimum: Int64)
    case notAnInstaller
    case signatureRejected(String)

    public var description: String {
        switch self {
        case .missing(let path): "no installer at \(path)"
        case .tooSmall(let bytes, let minimum): "Warframe.msi is only \(bytes) bytes (expected more than \(minimum))"
        case .notAnInstaller: "Warframe.msi is not a Windows Installer package (no compound-file signature)"
        case .signatureRejected(let reason): "Warframe.msi's Authenticode signature was rejected: \(reason)"
        }
    }
}

/// Size and signature bytes. These catch truncated downloads and HTML error pages; they do not prove who made the
/// file (that is `AuthenticodeVerifying`).
public enum InstallerChecks {
    /// Returns the installer's size and SHA-256.
    @discardableResult
    public static func check(_ url: URL, expectations: InstallerExpectations,
                             fileSystem: any FileSystem) throws -> (bytes: Int64, sha256: String) {
        guard fileSystem.fileExists(at: url) else { throw InstallerCheckError.missing(url.plainPath) }
        let bytes = Int64(try fileSystem.attributes(of: url).size)
        guard bytes > expectations.minimumBytes else {
            throw InstallerCheckError.tooSmall(bytes: bytes, minimum: expectations.minimumBytes)
        }
        let head = try fileSystem.read(url, offset: 0, maxLength: InstallerExpectations.compoundFileSignature.count)
        guard Array(head) == InstallerExpectations.compoundFileSignature else { throw InstallerCheckError.notAnInstaller }
        return (bytes, try sha256(of: url, fileSystem: fileSystem))
    }

    /// The file's SHA-256 as lowercase hex, read in 1 MB chunks.
    public static func sha256(of url: URL, fileSystem: any FileSystem) throws -> String {
        var hasher = SHA256()
        try fileSystem.forEachChunk(of: url, chunkSize: 1 << 20) { hasher.update(data: $0) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// The outcome of checking an installer's Authenticode signature.
public enum AuthenticodeVerdict: Equatable, Sendable, CustomStringConvertible {
    /// The signature verifies and the leaf certificate's CN is the expected signer.
    case trusted(signer: String)
    /// Do not use the file.
    case rejected(String)
    /// Nothing was checked (only `NoAuthenticodeVerifier` says this). Not a pass; callers say so.
    case unavailable(String)

    public var description: String {
        switch self {
        case .trusted(let signer): "signed by \(signer)"
        case .rejected(let reason): "rejected: \(reason)"
        case .unavailable(let reason): "not checked: \(reason)"
        }
    }
}

/// Checks the Authenticode signature of a Windows file and its signer. Players' Macs use `NativeAuthenticodeVerifier`.
public protocol AuthenticodeVerifying: Sendable {
    func verify(_ file: URL, expectedSigner: String) async -> AuthenticodeVerdict
}

/// Authenticode of a Windows Installer package, with nothing but macOS (`MSIAuthenticode`).
public struct NativeAuthenticodeVerifier: AuthenticodeVerifying {
    public init() {}

    public func verify(_ file: URL, expectedSigner: String) async -> AuthenticodeVerdict {
        let package: Data
        do {
            // Mapped, not read: the package is about 100 MB and is only hashed once.
            package = try Data(contentsOf: file, options: .alwaysMapped)
        } catch {
            return .rejected("cannot read \(file.lastPathComponent): \(error.localizedDescription)")
        }
        do {
            return .trusted(signer: try MSIAuthenticode.verify(package, expectedSigner: expectedSigner).signerCommonName)
        } catch {
            return .rejected(error.description)
        }
    }
}

/// Reports that nothing was checked. Never a pass; for tests.
public struct NoAuthenticodeVerifier: AuthenticodeVerifying {
    public init() {}

    public func verify(_ file: URL, expectedSigner: String) async -> AuthenticodeVerdict {
        .unavailable("no verifier")
    }
}
