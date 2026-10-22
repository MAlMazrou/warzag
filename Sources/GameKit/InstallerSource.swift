import Foundation
import WarzagCore

/// A Warframe.msi that passed `InstallerChecks` and the Authenticode check.
public struct VerifiedInstaller: Equatable, Sendable {
    public var url: URL
    public var bytes: Int64
    public var sha256: String
    /// `.unavailable` only from `NoAuthenticodeVerifier` (tests); callers then say that the signature was not checked.
    public var authenticode: AuthenticodeVerdict
}

/// Supplies a checked Warframe.msi to `ContentService.install`.
public protocol InstallerProviding: Sendable {
    func installer(progress: @escaping @Sendable (ContentRunState) -> Void) async throws -> VerifiedInstaller
}

/// Warframe.msi from DE's server (resumable) or from a file the user already has, checked either way.
public struct InstallerSource: InstallerProviding {
    public enum Origin: Sendable, Equatable {
        /// Download `url` to `destination` (an existing file that passes the checks is reused).
        case download(URL, to: URL)
        case file(URL)
    }

    public var origin: Origin
    public var expectations: InstallerExpectations
    public var downloader: ResumableDownloader
    public var authenticode: any AuthenticodeVerifying
    public var fileSystem: any FileSystem

    public init(origin: Origin, expectations: InstallerExpectations = InstallerExpectations(),
                downloader: ResumableDownloader = ResumableDownloader(),
                authenticode: any AuthenticodeVerifying = NativeAuthenticodeVerifier(),
                fileSystem: any FileSystem = LocalFileSystem()) {
        self.origin = origin
        self.expectations = expectations
        self.downloader = downloader
        self.authenticode = authenticode
        self.fileSystem = fileSystem
    }

    public func installer(progress: @escaping @Sendable (ContentRunState) -> Void) async throws -> VerifiedInstaller {
        let url: URL
        switch origin {
        case .file(let file):
            url = file
        case .download(let source, let destination):
            url = destination
            let reusable = (try? InstallerChecks.check(destination, expectations: expectations,
                                                       fileSystem: fileSystem)) != nil
            if !reusable {
                if fileSystem.fileExists(at: destination) { try fileSystem.removeItem(at: destination) }
                let expectations = expectations
                let fileSystem = fileSystem
                try await downloader.download(
                    source, to: destination,
                    validate: { try InstallerChecks.check($0, expectations: expectations, fileSystem: fileSystem) },
                    progress: { progress(.downloadingInstaller(receivedBytes: $0.receivedBytes, totalBytes: $0.totalBytes)) })
            }
        }
        progress(.checkingInstaller)
        let (bytes, sha256) = try InstallerChecks.check(url, expectations: expectations, fileSystem: fileSystem)
        let verdict = await authenticode.verify(url, expectedSigner: InstallerExpectations.signer)
        if case .rejected(let reason) = verdict { throw InstallerCheckError.signatureRejected(reason) }
        progress(.installerChecked(sha256: sha256, authenticode: verdict))
        return VerifiedInstaller(url: url, bytes: bytes, sha256: sha256, authenticode: verdict)
    }
}
