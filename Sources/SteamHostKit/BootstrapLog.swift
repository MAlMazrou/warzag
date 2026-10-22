import Foundation
import WarzagCore

/// Reads ~/Library/Application Support/Steam/logs/bootstrap_log.txt for client starts and shutdowns. A start line is
/// `[YYYY-MM-DD HH:MM:SS] Startup - Steam Client launched with: '<path>' '-silent'`; only whether `-silent` is among
/// the arguments is kept, never the path (it contains the home folder).
public enum BootstrapLog {
    public enum Event: Equatable, Sendable {
        /// "Steam Client launched with:"; `silent` when `-silent` was among the arguments.
        case started(silent: Bool)
        /// "Shutdown".
        case shutdown
    }

    static let launchedWith = Array("Steam Client launched with:".utf8)
    static let shutdown = Array("Shutdown".utf8)
    /// A start line carries a path or two; anything far longer is not one.
    static let longestMessage = 8 * 1024

    /// Whether the latest start line at or after `since` (steam_osx's start) has `-silent`; nil when there is none.
    public static func startedSilently(
        in url: URL,
        since: Date?,
        fileSystem: any FileSystem,
        timeZone: TimeZone = .current,
        chunkSize: Int = 64 * 1024
    ) throws -> Bool? {
        let calendar = LogTimestamp.calendar(timeZone)
        let earliest = LogTimestamp.earliest(since: since)
        var silent: Bool?
        try LogLines.backward(in: url, fileSystem: fileSystem, chunkSize: chunkSize) { line in
            guard let time = LogTimestamp.parse(line, calendar: calendar) else { return true }
            if let earliest, time < earliest { return false }
            guard case .started(let flag) = event(in: line) else { return true }
            silent = flag
            return false
        }
        return silent
    }

    /// The latest start or shutdown logged at or after `since`; nil when there is none.
    public static func latestEvent(
        in url: URL,
        since: Date,
        fileSystem: any FileSystem,
        timeZone: TimeZone = .current,
        chunkSize: Int = 64 * 1024
    ) throws -> Event? {
        let calendar = LogTimestamp.calendar(timeZone)
        let earliest = LogTimestamp.earliest(since: since)
        var latest: Event?
        try LogLines.backward(in: url, fileSystem: fileSystem, chunkSize: chunkSize) { line in
            guard let time = LogTimestamp.parse(line, calendar: calendar) else { return true }
            if let earliest, time < earliest { return false }
            guard let found = event(in: line) else { return true }
            latest = found
            return false
        }
        return latest
    }

    static func event(in line: ArraySlice<UInt8>) -> Event? {
        guard let message = LogTimestamp.message(of: line, limit: longestMessage + 1),
              message.count <= longestMessage else { return nil }
        if message.hasPrefix(shutdown) { return .shutdown }
        guard let found = message.prefix(64).firstRange(of: launchedWith) else { return nil }
        return .started(silent: hasSilentFlag(message[found.upperBound...]))
    }

    /// `-silent` as an argument of its own, quoted (`'-silent'`, `"-silent"`) or not.
    static func hasSilentFlag(_ arguments: ArraySlice<UInt8>) -> Bool {
        let separators: Set<UInt8> = [UInt8(ascii: " "), UInt8(ascii: "'"), UInt8(ascii: "\""), UInt8(ascii: "\t")]
        return arguments.split(whereSeparator: { separators.contains($0) })
            .contains { $0.count == 7 && String(decoding: $0, as: UTF8.self).lowercased() == "-silent" }
    }
}
