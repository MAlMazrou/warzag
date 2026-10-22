import Foundation
import WarzagCore

/// Follows a growing log file, returning only complete new lines on each poll. It tracks its byte offset and the
/// file's inode, so a log DE replaces or truncates (each run starts a fresh EE.log) is read again from the start.
public struct LogTailer: Equatable, Sendable {
    public struct Chunk: Equatable, Sendable {
        public var lines: [String]
        /// The file was replaced or truncated since the last poll; reading restarted from its first byte.
        public var restarted: Bool
    }

    /// Bytes read per file access.
    public static let readSize = 256 * 1024
    /// A "line" longer than this without a newline is delivered as is, so memory stays bounded.
    public static let maximumLineLength = 64 * 1024

    public let url: URL
    public private(set) var offset: UInt64 = 0
    public private(set) var fileNumber: UInt64?
    private var partial = Data()

    public init(url: URL) {
        self.url = url
    }

    /// Skips what the file already holds, so the next polls return only new lines. Call it just before starting the
    /// program that writes the log (EE.log and Launcher.log stay on disk between runs). A file replaced or truncated
    /// later, or one that does not exist yet, is read from its first byte.
    public mutating func seekToEnd(_ fileSystem: any FileSystem) throws {
        partial.removeAll()
        guard fileSystem.fileExists(at: url) else {
            offset = 0
            fileNumber = nil
            return
        }
        let attributes = try fileSystem.attributes(of: url)
        offset = attributes.size
        fileNumber = attributes.fileNumber
    }

    /// Reads up to `maxBytes` of new data. A missing file is not an error: DE creates its logs lazily.
    public mutating func poll(_ fileSystem: any FileSystem, maxBytes: Int = 4 << 20) throws -> Chunk {
        guard fileSystem.fileExists(at: url) else { return Chunk(lines: [], restarted: false) }
        let attributes = try fileSystem.attributes(of: url)
        var restarted = false
        if let known = fileNumber, known != attributes.fileNumber || attributes.size < offset {
            offset = 0
            partial.removeAll()
            restarted = true
        }
        fileNumber = attributes.fileNumber

        var lines: [String] = []
        var budget = maxBytes
        while offset < attributes.size, budget > 0 {
            let length = Int(min(UInt64(min(Self.readSize, budget)), attributes.size - offset))
            let data = try fileSystem.read(url, offset: offset, maxLength: length)
            guard !data.isEmpty else { break }
            offset += UInt64(data.count)
            budget -= data.count
            partial.append(data)
            lines += completeLines()
        }
        return Chunk(lines: lines, restarted: restarted)
    }

    private mutating func completeLines() -> [String] {
        var lines: [String] = []
        var start = partial.startIndex
        while let newline = partial[start...].firstIndex(of: 0x0A) {
            var end = newline
            if end > start, partial[end - 1] == 0x0D { end -= 1 }
            lines.append(String(decoding: partial[start..<end], as: UTF8.self))
            start = newline + 1
        }
        partial = Data(partial[start...])
        if partial.count > Self.maximumLineLength {
            lines.append(String(decoding: partial, as: UTF8.self))
            partial.removeAll()
        }
        return lines
    }
}
