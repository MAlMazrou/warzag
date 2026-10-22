import Foundation
import WarzagCore

/// Line access to Steam's logs, which grow to megabytes: read from the end in chunks (the latest state is near the
/// end), or forward from a remembered offset (`warzagctl steam timeline --follow`). Lines are bytes without the line
/// feed or a carriage return before it.
enum LogLines {
    /// A line longer than this is not one of Steam's log lines; it is dropped rather than kept growing in memory.
    static let longestLine = 1 << 20

    /// Calls `body` with each line of `url`, newest first, until it returns false, the file's start is reached, or
    /// `byteLimit` bytes have been read. `skipUnterminatedLastLine`: a last line without a line feed is being written
    /// (a later read sees it whole), so it is left out. `endingAt`: the lines before this offset only (where a
    /// `forward` reader stands), when the file is still `position`'s.
    static func backward(
        in url: URL, fileSystem: any FileSystem, chunkSize: Int = 64 * 1024, byteLimit: UInt64? = nil,
        endingAt position: Position? = nil, skipUnterminatedLastLine: Bool = false,
        _ body: (ArraySlice<UInt8>) throws -> Bool
    ) throws {
        let attributes = try fileSystem.attributes(of: url)
        let chunk = UInt64(max(chunkSize, 1))
        var end = attributes.size
        if let position, position.fileNumber == attributes.fileNumber { end = min(end, position.offset) }
        if skipUnterminatedLastLine, end > 0, try fileSystem.read(url, offset: end - 1, maxLength: 1).first != 0x0A {
            end = try endOfLastCompleteLine(in: url, size: end, fileSystem: fileSystem, chunk: chunk)
        }
        let top = end
        var carry: [UInt8] = []
        while end > 0 {
            var length = min(chunk, end)
            if let byteLimit {
                guard top - end < byteLimit else { return }
                length = min(length, byteLimit - (top - end))
            }
            let start = end - length
            var buffer = [UInt8](try fileSystem.read(url, offset: start, maxLength: Int(end - start)))
            buffer.append(contentsOf: carry)
            var lines = buffer.split(separator: 0x0A, omittingEmptySubsequences: false)
            // The first piece may be the tail of a line that started in the previous chunk.
            carry = start > 0 && !lines.isEmpty ? Array(lines.removeFirst()) : []
            if carry.count > longestLine { carry = [] }
            for line in lines.reversed() where !(try body(trimmed(line))) {
                return
            }
            end = start
        }
    }

    /// Where a `forward` reader that should see only what is written from now on starts: the end of the file's last
    /// complete line.
    static func endPosition(in url: URL, fileSystem: any FileSystem) throws -> Position {
        let attributes = try fileSystem.attributes(of: url)
        var offset = attributes.size
        if offset > 0, try fileSystem.read(url, offset: offset - 1, maxLength: 1).first != 0x0A {
            offset = try endOfLastCompleteLine(in: url, size: offset, fileSystem: fileSystem, chunk: 64 * 1024)
        }
        return Position(offset: offset, fileNumber: attributes.fileNumber)
    }

    /// The offset just after the file's last line feed (0 if there is none within `longestLine` of the end).
    private static func endOfLastCompleteLine(in url: URL, size: UInt64, fileSystem: any FileSystem,
                                              chunk: UInt64) throws -> UInt64 {
        var end = size
        while end > 0, size - end < UInt64(longestLine) {
            let start = end > chunk ? end - chunk : 0
            let bytes = [UInt8](try fileSystem.read(url, offset: start, maxLength: Int(end - start)))
            if let feed = bytes.lastIndex(of: 0x0A) { return start + UInt64(feed) + 1 }
            end = start
        }
        return 0
    }

    /// The complete lines between `offset` and the end of the file, and the offset after the last of them (a line
    /// still being written is left for the next call). From 0 when the file was replaced or truncated since: a
    /// different `fileNumber`, or a size below `offset`.
    static func forward(
        in url: URL, from position: Position?, fileSystem: any FileSystem, maximumBytes: Int = 4 << 20
    ) throws -> (lines: [ArraySlice<UInt8>], position: Position) {
        let attributes = try fileSystem.attributes(of: url)
        var offset = position?.offset ?? 0
        if let position, position.fileNumber != attributes.fileNumber || attributes.size < position.offset {
            offset = 0
        }
        guard attributes.size > offset else {
            return ([], Position(offset: offset, fileNumber: attributes.fileNumber))
        }
        // Far behind (a burst, or the first look at a big file): only the newest bytes, starting at a line.
        var skippedToLineStart = false
        if attributes.size - offset > UInt64(maximumBytes) {
            offset = attributes.size - UInt64(maximumBytes)
            skippedToLineStart = true
        }
        let bytes = [UInt8](try fileSystem.read(url, offset: offset, maxLength: Int(attributes.size - offset)))
        guard let lastFeed = bytes.lastIndex(of: 0x0A) else {
            return ([], Position(offset: offset, fileNumber: attributes.fileNumber))
        }
        var lines = bytes[...lastFeed].split(separator: 0x0A, omittingEmptySubsequences: false).dropLast()
        if skippedToLineStart, !lines.isEmpty { lines.removeFirst() }
        return (lines.map(trimmed), Position(offset: offset + UInt64(lastFeed) + 1, fileNumber: attributes.fileNumber))
    }

    /// Where `forward` stopped in a file.
    struct Position: Equatable, Sendable {
        var offset: UInt64
        var fileNumber: UInt64
    }

    static func trimmed(_ line: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        line.last == 0x0D ? line.dropLast() : line
    }
}

/// `[YYYY-MM-DD HH:MM:SS]` at the start of a line, Steam's log timestamp (local time, whole seconds).
enum LogTimestamp {
    /// "[YYYY-MM-DD HH:MM:SS]" is 21 bytes.
    static let length = 21

    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func parse(_ line: ArraySlice<UInt8>, calendar: Calendar) -> Date? {
        let bytes = Array(line.prefix(length))
        guard bytes.count == length, bytes[0] == UInt8(ascii: "["), bytes[20] == UInt8(ascii: "]"),
              bytes[5] == UInt8(ascii: "-"), bytes[8] == UInt8(ascii: "-"), bytes[11] == UInt8(ascii: " "),
              bytes[14] == UInt8(ascii: ":"), bytes[17] == UInt8(ascii: ":") else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for byte in bytes[range] {
                guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { return nil }
                value = value * 10 + Int(byte - UInt8(ascii: "0"))
            }
            return value
        }
        guard let year = number(1..<5), let month = number(6..<8), let day = number(9..<11),
              let hour = number(12..<14), let minute = number(15..<17), let second = number(18..<20) else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                  hour: hour, minute: minute, second: second))
    }

    /// The text after "[timestamp] ", at most `limit` bytes of it; nil without a timestamp.
    static func message(of line: ArraySlice<UInt8>, limit: Int = 512) -> ArraySlice<UInt8>? {
        guard line.count > length, line[line.startIndex + length] == UInt8(ascii: " ") else { return nil }
        let start = line.startIndex + length + 1
        return line[start..<min(line.endIndex, start + limit)]
    }

    /// Log timestamps have whole seconds: a line from the second a process started in still counts.
    static func earliest(since: Date?) -> Date? {
        since.map { $0.addingTimeInterval(-1) }
    }
}

extension ArraySlice where Element == UInt8 {
    func firstRange(of needle: [UInt8]) -> Range<Index>? {
        guard !needle.isEmpty, count >= needle.count else { return nil }
        var index = startIndex
        let last = endIndex - needle.count
        while index <= last {
            if self[index] == needle[0], self[index..<(index + needle.count)].elementsEqual(needle) {
                return index..<(index + needle.count)
            }
            index += 1
        }
        return nil
    }

    func hasPrefix(_ prefix: [UInt8]) -> Bool {
        count >= prefix.count && self.prefix(prefix.count).elementsEqual(prefix)
    }
}
