import Darwin
import Foundation

/// Size and identity of a file, enough to notice that a log was truncated or replaced.
public struct FileAttributes: Sendable, Equatable {
    public var size: UInt64
    /// Inode number; changes when a file is replaced rather than appended to.
    public var fileNumber: UInt64
    public var modificationDate: Date?

    public init(size: UInt64, fileNumber: UInt64, modificationDate: Date? = nil) {
        self.size = size
        self.fileNumber = fileNumber
        self.modificationDate = modificationDate
    }
}

/// Free space and naming rules of the volume that holds a path.
public struct VolumeInfo: Sendable, Equatable, Codable {
    /// Bytes available for important data (what Finder shows, including purgeable space).
    public var availableCapacity: Int64?
    /// Wine prefixes and DE's caches need a case-insensitive volume.
    public var isCaseSensitive: Bool
    public var isLocal: Bool
    /// File-system type, for example "apfs".
    public var format: String?

    public init(availableCapacity: Int64?, isCaseSensitive: Bool, isLocal: Bool, format: String?) {
        self.availableCapacity = availableCapacity
        self.isCaseSensitive = isCaseSensitive
        self.isLocal = isLocal
        self.format = format
    }
}

/// File-system side effects, behind a protocol so every component can be pointed at a scratch tree or a fake.
public protocol FileSystem: Sendable {
    func fileExists(at url: URL) -> Bool
    func directoryExists(at url: URL) -> Bool
    func contents(of url: URL) throws -> Data
    /// Reads at most `maxLength` bytes starting at `offset` (fewer at the end of the file).
    func read(_ url: URL, offset: UInt64, maxLength: Int) throws -> Data
    /// Calls `body` with consecutive chunks of the file, so large files are never held in memory.
    func forEachChunk(of url: URL, chunkSize: Int, _ body: (Data) throws -> Void) throws
    func attributes(of url: URL) throws -> FileAttributes
    func contentsOfDirectory(at url: URL) throws -> [URL]
    /// Creates the directory and any missing parents.
    func createDirectory(at url: URL) throws
    /// Replaces `url` in one rename, so readers see the old or the new contents and never a torn file.
    func writeAtomically(_ data: Data, to url: URL) throws
    /// Creates a new file in one rename. Returns false, changing nothing, if anything already exists at `url`.
    func createExclusively(_ data: Data, at url: URL) throws -> Bool
    /// Adds `data` at the end of the file, creating it (and its folder) if needed. The file is never replaced, so a
    /// process that holds it open (a Wine tool writing its log) keeps writing to the same file.
    func append(_ data: Data, to url: URL) throws
    func moveItem(at source: URL, to destination: URL) throws
    func removeItem(at url: URL) throws
    func isWritableDirectory(at url: URL) -> Bool
    /// The volume holding `url`, or holding its nearest existing ancestor if `url` does not exist yet.
    func volumeInfo(for url: URL) throws -> VolumeInfo
}

public struct LocalFileSystem: FileSystem {
    public init() {}

    public func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.plainPath)
    }

    public func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.plainPath, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public func contents(of url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    public func read(_ url: URL, offset: UInt64, maxLength: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: maxLength) ?? Data()
    }

    public func forEachChunk(of url: URL, chunkSize: Int, _ body: (Data) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            try body(chunk)
        }
    }

    public func attributes(of url: URL) throws -> FileAttributes {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.plainPath)
        return FileAttributes(
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            modificationDate: attributes[.modificationDate] as? Date
        )
    }

    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
    }

    public func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func writeAtomically(_ data: Data, to url: URL) throws {
        try createDirectory(at: url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
    }

    public func createExclusively(_ data: Data, at url: URL) throws -> Bool {
        let directory = url.deletingLastPathComponent()
        try createDirectory(at: directory)
        let temporary = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary)
        // RENAME_EXCL makes "only if absent" and "never half-written" a single atomic step.
        let result = renamex_np(temporary.plainPath, url.plainPath, UInt32(RENAME_EXCL))
        let error = errno
        if result == 0 { return true }
        try? FileManager.default.removeItem(at: temporary)
        if error == EEXIST { return false }
        throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
    }

    public func append(_ data: Data, to url: URL) throws {
        try createDirectory(at: url.deletingLastPathComponent())
        // O_APPEND: every write lands at the end, even next to a child process appending to the same file.
        let descriptor = open(url.plainPath, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
    }

    public func moveItem(at source: URL, to destination: URL) throws {
        try createDirectory(at: destination.deletingLastPathComponent())
        try FileManager.default.moveItem(at: source, to: destination)
    }

    public func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    public func isWritableDirectory(at url: URL) -> Bool {
        directoryExists(at: url) && FileManager.default.isWritableFile(atPath: url.plainPath)
    }

    public func volumeInfo(for url: URL) throws -> VolumeInfo {
        // A library folder may be chosen before it exists.
        var probe = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.plainPath), probe.plainPath != "/" {
            probe = probe.deletingLastPathComponent()
        }
        let values = try probe.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
            .volumeSupportsCaseSensitiveNamesKey, .volumeIsLocalKey, .volumeTypeNameKey,
        ])
        return VolumeInfo(
            availableCapacity: Self.availableCapacity(important: values.volumeAvailableCapacityForImportantUsage,
                                                      plain: values.volumeAvailableCapacity.map(Int64.init)),
            isCaseSensitive: values.volumeSupportsCaseSensitiveNames ?? false,
            isLocal: values.volumeIsLocal ?? false,
            format: values.volumeTypeName
        )
    }

    /// What Finder shows as free: the space for important data (purgeable space included) where the volume counts it
    /// (APFS), else its plain free space. HFS+ and other volumes answer 0 for important usage however much is free.
    static func availableCapacity(important: Int64?, plain: Int64?) -> Int64? {
        if let important, important > 0 { return important }
        return plain ?? important
    }
}
