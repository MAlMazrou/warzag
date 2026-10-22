import Foundation
import WarzagCore

/// Fetches a runtime pack to a local file and checks it against the size and SHA-256 its signed manifest names.
public protocol PackDownloading: Sendable {
    /// Downloads `url` to `destination`, resuming an earlier partial download of the same URL, then checks the file's
    /// size and SHA-256. A file that fails the check is deleted (the next try starts over) and the error thrown.
    func download(_ url: URL, to destination: URL, size: Int64, sha256: String,
                  progress: @escaping @Sendable (DownloadProgress) -> Void) async throws
}

/// `PackDownloading` with WarzagCore's `ResumableDownloader`, on the local disk.
public struct ResumablePackDownloader: PackDownloading {
    public var downloader: ResumableDownloader

    public init(downloader: ResumableDownloader = ResumableDownloader()) {
        self.downloader = downloader
    }

    public func download(_ url: URL, to destination: URL, size: Int64, sha256: String,
                         progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        try await downloader.download(url, to: destination, validate: { part in
            try FileDigest.verify(part, sha256: sha256, size: size, fileSystem: LocalFileSystem())
        }, progress: progress)
    }
}
