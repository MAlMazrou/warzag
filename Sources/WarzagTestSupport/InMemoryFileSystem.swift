import Foundation
import Synchronization
import WarzagCore

/// A complete in-memory `FileSystem` for tests: files, directories, inode numbers (so log rotation can be
/// simulated), read-only directories and a configurable volume.
public final class InMemoryFileSystem: FileSystem {
    private struct Storage {
        var files: [String: Data] = [:]
        var directories: Set<String> = ["/"]
        var fileNumbers: [String: UInt64] = [:]
        var nextFileNumber: UInt64 = 100
        var readOnly: Set<String> = []
        var volume = VolumeInfo(availableCapacity: 500_000_000_000, isCaseSensitive: false, isLocal: true, format: "apfs")
        var failingWrites = false

        mutating func newFileNumber() -> UInt64 {
            nextFileNumber += 1
            return nextFileNumber
        }

        mutating func addDirectory(_ path: String) {
            var current = path
            while current != "/", !current.isEmpty {
                directories.insert(current)
                current = (current as NSString).deletingLastPathComponent
            }
        }

        func exists(_ path: String) -> Bool { files[path] != nil || directories.contains(path) }

        func descendants(of path: String) -> (files: [String], directories: [String]) {
            let prefix = path == "/" ? "/" : path + "/"
            return (files.keys.filter { $0.hasPrefix(prefix) }, directories.filter { $0.hasPrefix(prefix) })
        }
    }

    private let storage = Mutex(Storage())

    public init() {}

    // MARK: Test helpers

    public func addFile(_ path: String, _ contents: String) {
        addFile(path, Data(contents.utf8))
    }

    /// Creates or replaces a file (as a new inode, like an atomic replace).
    public func addFile(_ path: String, _ data: Data) {
        let path = Self.normalize(path)
        storage.withLock {
            $0.addDirectory((path as NSString).deletingLastPathComponent)
            $0.files[path] = data
            $0.fileNumbers[path] = $0.newFileNumber()
        }
    }

    /// Appends in place, keeping the inode (how a log grows).
    public func append(_ path: String, _ contents: String) {
        append(path, Data(contents.utf8))
    }

    public func append(_ path: String, _ data: Data) {
        let path = Self.normalize(path)
        storage.withLock {
            if $0.files[path] == nil {
                $0.addDirectory((path as NSString).deletingLastPathComponent)
                $0.files[path] = Data()
                $0.fileNumbers[path] = $0.newFileNumber()
            }
            $0.files[path]?.append(data)
        }
    }

    /// Truncates in place, keeping the inode.
    public func truncate(_ path: String, to contents: String = "") {
        let path = Self.normalize(path)
        storage.withLock { $0.files[path] = Data(contents.utf8) }
    }

    public func addDirectory(_ path: String) {
        let path = Self.normalize(path)
        storage.withLock { $0.addDirectory(path) }
    }

    public func makeReadOnly(_ path: String) {
        let path = Self.normalize(path)
        storage.withLock { _ = $0.readOnly.insert(path) }
    }

    public func setVolume(_ volume: VolumeInfo) {
        storage.withLock { $0.volume = volume }
    }

    /// Makes every write fail, as on a full disk.
    public func setFailingWrites(_ failing: Bool) {
        storage.withLock { $0.failingWrites = failing }
    }

    public func data(at path: String) -> Data? {
        let path = Self.normalize(path)
        return storage.withLock { $0.files[path] }
    }

    public func text(at path: String) -> String? {
        data(at: path).map { String(decoding: $0, as: UTF8.self) }
    }

    public var allFiles: [String] { storage.withLock { $0.files.keys.sorted() } }
    public var allDirectories: [String] { storage.withLock { $0.directories.sorted() } }

    // MARK: FileSystem

    public func fileExists(at url: URL) -> Bool {
        let path = Self.normalize(url)
        return storage.withLock { $0.exists(path) }
    }

    public func directoryExists(at url: URL) -> Bool {
        let path = Self.normalize(url)
        return storage.withLock { $0.directories.contains(path) }
    }

    public func contents(of url: URL) throws -> Data {
        let path = Self.normalize(url)
        guard let data = storage.withLock({ $0.files[path] }) else { throw Self.missing(path) }
        return data
    }

    public func read(_ url: URL, offset: UInt64, maxLength: Int) throws -> Data {
        let data = try contents(of: url)
        guard offset < UInt64(data.count) else { return Data() }
        let start = data.startIndex + Int(offset)
        return Data(data[start..<min(data.endIndex, start + maxLength)])
    }

    public func forEachChunk(of url: URL, chunkSize: Int, _ body: (Data) throws -> Void) throws {
        let data = try contents(of: url)
        var start = data.startIndex
        while start < data.endIndex {
            let end = min(data.endIndex, start + chunkSize)
            try body(Data(data[start..<end]))
            start = end
        }
    }

    public func attributes(of url: URL) throws -> FileAttributes {
        let path = Self.normalize(url)
        return try storage.withLock {
            if let data = $0.files[path] {
                return FileAttributes(size: UInt64(data.count), fileNumber: $0.fileNumbers[path] ?? 0)
            }
            if $0.directories.contains(path) { return FileAttributes(size: 0, fileNumber: 0) }
            throw Self.missing(path)
        }
    }

    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        let path = Self.normalize(url)
        return try storage.withLock { storage in
            guard storage.directories.contains(path) else { throw Self.missing(path) }
            let prefix = path == "/" ? "/" : path + "/"
            let children = Set((Array(storage.files.keys) + Array(storage.directories))
                .filter { $0.hasPrefix(prefix) && $0 != path }
                .map { prefix + $0.dropFirst(prefix.count).split(separator: "/")[0] })
            return children.sorted().map {
                URL(filePath: $0, directoryHint: storage.directories.contains($0) ? .isDirectory : .notDirectory)
            }
        }
    }

    public func createDirectory(at url: URL) throws {
        let path = Self.normalize(url)
        try storage.withLock {
            guard $0.files[path] == nil else { throw CocoaError(.fileWriteFileExists) }
            guard !$0.failingWrites else { throw CocoaError(.fileWriteOutOfSpace) }
            $0.addDirectory(path)
        }
    }

    public func writeAtomically(_ data: Data, to url: URL) throws {
        let path = Self.normalize(url)
        try storage.withLock {
            guard !$0.failingWrites else { throw CocoaError(.fileWriteOutOfSpace) }
            guard !$0.directories.contains(path) else { throw CocoaError(.fileWriteFileExists) }
            $0.addDirectory((path as NSString).deletingLastPathComponent)
            $0.files[path] = data
            $0.fileNumbers[path] = $0.newFileNumber()
        }
    }

    public func createExclusively(_ data: Data, at url: URL) throws -> Bool {
        let path = Self.normalize(url)
        return try storage.withLock {
            guard !$0.failingWrites else { throw CocoaError(.fileWriteOutOfSpace) }
            if $0.exists(path) { return false }
            $0.addDirectory((path as NSString).deletingLastPathComponent)
            $0.files[path] = data
            $0.fileNumbers[path] = $0.newFileNumber()
            return true
        }
    }

    public func append(_ data: Data, to url: URL) throws {
        let path = Self.normalize(url)
        try storage.withLock {
            guard !$0.failingWrites else { throw CocoaError(.fileWriteOutOfSpace) }
            guard !$0.directories.contains(path) else { throw CocoaError(.fileWriteFileExists) }
        }
        append(path, data)
    }

    public func moveItem(at source: URL, to destination: URL) throws {
        let from = Self.normalize(source)
        let to = Self.normalize(destination)
        try storage.withLock { storage in
            guard storage.exists(from) else { throw Self.missing(from) }
            guard !storage.exists(to) else { throw CocoaError(.fileWriteFileExists) }
            storage.addDirectory((to as NSString).deletingLastPathComponent)
            if let data = storage.files.removeValue(forKey: from) {
                storage.files[to] = data
                storage.fileNumbers[to] = storage.fileNumbers.removeValue(forKey: from)
                return
            }
            let (files, directories) = storage.descendants(of: from)
            storage.directories.remove(from)
            storage.directories.insert(to)
            for directory in directories {
                storage.directories.remove(directory)
                storage.directories.insert(to + directory.dropFirst(from.count))
            }
            for file in files {
                let moved = to + file.dropFirst(from.count)
                storage.files[moved] = storage.files.removeValue(forKey: file)
                storage.fileNumbers[moved] = storage.fileNumbers.removeValue(forKey: file)
            }
        }
    }

    public func removeItem(at url: URL) throws {
        let path = Self.normalize(url)
        try storage.withLock { storage in
            guard storage.exists(path) else { throw Self.missing(path) }
            if storage.files.removeValue(forKey: path) != nil {
                storage.fileNumbers[path] = nil
                return
            }
            let (files, directories) = storage.descendants(of: path)
            files.forEach { storage.files[$0] = nil; storage.fileNumbers[$0] = nil }
            directories.forEach { storage.directories.remove($0) }
            storage.directories.remove(path)
        }
    }

    public func isWritableDirectory(at url: URL) -> Bool {
        let path = Self.normalize(url)
        return storage.withLock { $0.directories.contains(path) && !$0.readOnly.contains(path) }
    }

    public func volumeInfo(for url: URL) throws -> VolumeInfo {
        storage.withLock { $0.volume }
    }

    // MARK: Helpers

    static func normalize(_ url: URL) -> String { url.standardizedFileURL.plainPath }

    static func normalize(_ path: String) -> String { normalize(URL(filePath: path)) }

    private static func missing(_ path: String) -> CocoaError {
        CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: path])
    }
}
