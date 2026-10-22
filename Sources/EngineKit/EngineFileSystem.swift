import Darwin
import Foundation
import WarzagCore

/// File operations the engine needs beyond `FileSystem`: symbolic links (the X: drive, the user folders Wine links
/// into the Mac home), whole-tree copies (registering a local runtime build) and replacing a file with a copy of
/// another (DLL placeholders and Steam bridge files inside the prefix).
///
/// Nothing here follows a symbolic link when removing: a prefix holds `dosdevices/z: -> /`.
public protocol EngineFileSystem: FileSystem {
    /// True for a symbolic link itself, whether or not its destination exists.
    func isSymbolicLink(at url: URL) -> Bool
    /// The destination exactly as stored in the link (absolute or relative).
    func destinationOfSymbolicLink(at url: URL) throws -> String
    /// Creates a symbolic link; fails if anything already exists at `url`.
    func createSymbolicLink(at url: URL, destination: String) throws
    /// Copies a file or a whole directory tree to `destination`, which must not exist yet. Cloned (no extra space,
    /// near-instant) when both are on the same APFS volume.
    func copyItem(at source: URL, to destination: URL) throws
    /// Replaces whatever file is at `destination` with a copy of `source`, in one rename.
    func replaceFile(at destination: URL, withCopyOf source: URL) throws
    func isExecutableFile(at url: URL) -> Bool
}

public struct LocalEngineFileSystem: EngineFileSystem {
    private let base = LocalFileSystem()

    public init() {}

    // MARK: EngineFileSystem

    public func isSymbolicLink(at url: URL) -> Bool {
        var info = stat()
        return lstat(url.plainPath, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    public func destinationOfSymbolicLink(at url: URL) throws -> String {
        try FileManager.default.destinationOfSymbolicLink(atPath: url.plainPath)
    }

    public func createSymbolicLink(at url: URL, destination: String) throws {
        try base.createDirectory(at: url.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(atPath: url.plainPath, withDestinationPath: destination)
    }

    public func copyItem(at source: URL, to destination: URL) throws {
        try base.createDirectory(at: destination.deletingLastPathComponent())
        // clonefile(2) clones a whole directory tree in one call; it fails across volumes or on non-APFS volumes,
        // where a plain copy takes over.
        if clonefile(source.plainPath, destination.plainPath, UInt32(CLONE_NOFOLLOW)) == 0 { return }
        let error = errno
        guard error == EXDEV || error == ENOTSUP || error == EPERM else {
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    public func replaceFile(at destination: URL, withCopyOf source: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try base.createDirectory(at: directory)
        let temporary = directory.appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        try FileManager.default.copyItem(at: source, to: temporary)
        // rename(2) replaces the old file atomically; a reader sees the old or the new file, never a mix.
        guard rename(temporary.plainPath, destination.plainPath) == 0 else {
            let error = errno
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
    }

    public func isExecutableFile(at url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.plainPath)
    }

    // MARK: FileSystem

    public func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }
    public func directoryExists(at url: URL) -> Bool { base.directoryExists(at: url) }
    public func contents(of url: URL) throws -> Data { try base.contents(of: url) }
    public func read(_ url: URL, offset: UInt64, maxLength: Int) throws -> Data {
        try base.read(url, offset: offset, maxLength: maxLength)
    }
    public func forEachChunk(of url: URL, chunkSize: Int, _ body: (Data) throws -> Void) throws {
        try base.forEachChunk(of: url, chunkSize: chunkSize, body)
    }
    public func attributes(of url: URL) throws -> FileAttributes { try base.attributes(of: url) }
    public func contentsOfDirectory(at url: URL) throws -> [URL] { try base.contentsOfDirectory(at: url) }
    public func createDirectory(at url: URL) throws { try base.createDirectory(at: url) }
    public func writeAtomically(_ data: Data, to url: URL) throws { try base.writeAtomically(data, to: url) }
    public func createExclusively(_ data: Data, at url: URL) throws -> Bool { try base.createExclusively(data, at: url) }
    public func append(_ data: Data, to url: URL) throws { try base.append(data, to: url) }
    public func moveItem(at source: URL, to destination: URL) throws { try base.moveItem(at: source, to: destination) }
    /// Removes a file, a directory tree or a symbolic link (never its destination).
    public func removeItem(at url: URL) throws { try base.removeItem(at: url) }
    public func isWritableDirectory(at url: URL) -> Bool { base.isWritableDirectory(at: url) }
    public func volumeInfo(for url: URL) throws -> VolumeInfo { try base.volumeInfo(for: url) }
}
