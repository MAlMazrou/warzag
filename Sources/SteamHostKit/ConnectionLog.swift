import Foundation
import WarzagCore

/// Steam's connection state as logged in connection_log.txt, e.g. "Logged On". Only state names made of letters
/// and spaces are kept in this type; the account bracket is read only into `ConnectionLogEntry.accountID`.
public struct SteamConnectionState: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let connecting = SteamConnectionState(rawValue: "Connecting")
    public static let connected = SteamConnectionState(rawValue: "Connected")
    public static let loggingOn = SteamConnectionState(rawValue: "Logging On")
    public static let loggedOn = SteamConnectionState(rawValue: "Logged On")
    public static let loggingOff = SteamConnectionState(rawValue: "Logging Off")
    public static let loggedOff = SteamConnectionState(rawValue: "Logged Off")

    public var isSignedIn: Bool { self == .loggedOn }
    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One state line of connection_log.txt: the state, when it was logged, and which account the line is about.
///
/// The account is the `[U:1:N]` bracket right after the state (`[…] [Logged On, 0, 341] [U:1:N] …`), strictly
/// `[U:1:` + 1 to 10 digits + `]` with N up to UInt32.max. `[U:1:0]` is a connection without an account (Steam at its
/// sign-in screen). N is package-internal: it never enters `SteamConnectionState`, which
/// `warzagctl steam status --json` prints, and the description, debug description and mirror leave it out.
public struct ConnectionLogEntry: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    public let state: SteamConnectionState
    /// The line's timestamp (whole seconds).
    public let at: Date
    /// The bracket after the state is `[U:1:0]`.
    public let anonymous: Bool
    /// N of `[U:1:N]` (SteamID64 = 76561197960265728 + N); nil for `[U:1:0]` and anything that is not an account.
    package let accountID: UInt32?

    package init(state: SteamConnectionState, at: Date, anonymous: Bool, accountID: UInt32?) {
        self.state = state
        self.at = at
        self.anonymous = anonymous
        self.accountID = accountID
    }

    /// The line names a signed-in or signing-in account (`[U:1:N]` with N ≠ 0).
    public var carriesAccount: Bool { accountID != nil }

    public var description: String {
        "\(state.rawValue) at \(at.formatted(.iso8601))" + (carriesAccount ? " (an account)" : anonymous ? " (no account)" : "")
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["state": state, "at": at, "anonymous": anonymous, "carriesAccount": carriesAccount],
               displayStyle: .struct)
    }
}

/// What the connection lines since Steam started say, for `SteamSignInPhase.derive`.
public struct ConnectionLogSummary: Equatable, Sendable {
    /// The latest state line since Steam started.
    public var latest: ConnectionLogEntry?
    /// Every account bracket since Steam started is `[U:1:0]`, and there is at least one: no account has connected in
    /// this run. Steam logs such lines repeatedly while it waits at its sign-in screen.
    public var onlyAnonymous: Bool

    public init(latest: ConnectionLogEntry?, onlyAnonymous: Bool) {
        self.latest = latest
        self.onlyAnonymous = onlyAnonymous
    }
}

/// Reads the sign-in state from ~/Library/Application Support/Steam/logs/connection_log.txt.
///
/// Lines look like `[YYYY-MM-DD HH:MM:SS] [Logged On, 0, 341] [U:1:…] …`. Only the timestamp, the state token and the
/// account bracket are read. The file is scanned backwards from the end, so a large log costs one or two small reads.
public enum ConnectionLog {
    /// Longest state token accepted ("Logging Off" is 11).
    static let maximumTokenLength = 32
    /// How far back, in bytes, `summary` looks for a line that names an account.
    public static let summaryByteLimit: UInt64 = 1 << 20

    /// The latest state token logged at or after `since` (Steam's process start), or nil if there is none.
    public static func lastState(
        in url: URL,
        since: Date?,
        fileSystem: any FileSystem,
        timeZone: TimeZone = .current,
        chunkSize: Int = 64 * 1024
    ) throws -> SteamConnectionState? {
        try lastEntry(in: url, since: since, fileSystem: fileSystem, timeZone: timeZone, chunkSize: chunkSize)?.state
    }

    /// The latest state line logged at or after `since` (Steam's process start), or nil if there is none.
    public static func lastEntry(
        in url: URL,
        since: Date?,
        fileSystem: any FileSystem,
        timeZone: TimeZone = .current,
        chunkSize: Int = 64 * 1024
    ) throws -> ConnectionLogEntry? {
        let calendar = LogTimestamp.calendar(timeZone)
        let earliest = LogTimestamp.earliest(since: since)
        var found: ConnectionLogEntry?
        try LogLines.backward(in: url, fileSystem: fileSystem, chunkSize: chunkSize) { line in
            guard let time = LogTimestamp.parse(line, calendar: calendar) else { return true }
            if let earliest, time < earliest { return false }
            guard let entry = entry(in: line, at: time) else { return true }
            found = entry
            return false
        }
        return found
    }

    /// The latest state line since `since`, and whether every line since then is without an account. Stops at the
    /// first line (from the end) that names an account, or after `byteLimit` bytes: a run that logged that much
    /// without one has had none.
    public static func summary(
        in url: URL,
        since: Date?,
        fileSystem: any FileSystem,
        timeZone: TimeZone = .current,
        chunkSize: Int = 64 * 1024,
        byteLimit: UInt64 = summaryByteLimit
    ) throws -> ConnectionLogSummary {
        let calendar = LogTimestamp.calendar(timeZone)
        let earliest = LogTimestamp.earliest(since: since)
        var latest: ConnectionLogEntry?
        var sawAnonymous = false
        var sawAccount = false
        try LogLines.backward(in: url, fileSystem: fileSystem, chunkSize: chunkSize, byteLimit: byteLimit) { line in
            guard let time = LogTimestamp.parse(line, calendar: calendar) else { return true }
            if let earliest, time < earliest { return false }
            guard let entry = entry(in: line, at: time) else { return true }
            if latest == nil { latest = entry }
            if entry.carriesAccount {
                sawAccount = true
                return false
            }
            if entry.anonymous { sawAnonymous = true }
            return true
        }
        return ConnectionLogSummary(latest: latest, onlyAnonymous: sawAnonymous && !sawAccount)
    }

    static func entry(in line: ArraySlice<UInt8>, at time: Date) -> ConnectionLogEntry? {
        guard let (token, end) = stateBlock(in: line) else { return nil }
        let account = accountBracket(in: line, after: end)
        return ConnectionLogEntry(state: SteamConnectionState(rawValue: token), at: time,
                                  anonymous: account == 0, accountID: account.flatMap { $0 == 0 ? nil : $0 })
    }

    /// The state token ("Logged On" from "[…] [Logged On, 0, 341] …") and the index just past the state block's
    /// closing bracket (nil when the block does not close within a few bytes: the token still counts, the account then
    /// does not).
    private static func stateBlock(in line: ArraySlice<UInt8>) -> (token: String, end: Int?)? {
        let length = LogTimestamp.length
        let bytes = Array(line.prefix(length + 2 + maximumTokenLength + 1 + 32))
        // "[YYYY-MM-DD HH:MM:SS] [" then letters and spaces up to a comma.
        guard bytes.count > length + 2, bytes[length] == UInt8(ascii: " "),
              bytes[length + 1] == UInt8(ascii: "[") else { return nil }
        var token: [UInt8] = []
        var index = length + 2
        while index < bytes.count, index <= length + 2 + maximumTokenLength {
            let byte = bytes[index]
            if byte == UInt8(ascii: ",") {
                let text = String(decoding: token, as: UTF8.self).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { return nil }
                // The rest of the block: numbers, commas and spaces up to "]".
                var close = index + 1
                while close < bytes.count {
                    let byte = bytes[close]
                    if byte == UInt8(ascii: "]") { return (text, line.startIndex + close + 1) }
                    let isNumber = (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                    guard isNumber || [UInt8(ascii: " "), UInt8(ascii: ","), UInt8(ascii: "-")].contains(byte)
                    else { break }
                    close += 1
                }
                return (text, nil)
            }
            let isLetter = (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            guard isLetter || (byte == UInt8(ascii: " ") && !token.isEmpty) else { return nil }
            token.append(byte)
            index += 1
        }
        return nil
    }

    /// N of " [U:1:N]" right at `index` (0 for `[U:1:0]`), or nil for anything else: no bracket, letters, more than 10
    /// digits, or a number above UInt32.max.
    static func accountBracket(in line: ArraySlice<UInt8>, after index: Int?) -> UInt32? {
        guard let index else { return nil }
        let opening = Array(" [U:1:".utf8)
        guard index + opening.count < line.endIndex,
              line[index..<(index + opening.count)].elementsEqual(opening) else { return nil }
        var value: UInt64 = 0
        var digits = 0
        var position = index + opening.count
        while position < line.endIndex {
            let byte = line[position]
            if byte == UInt8(ascii: "]") {
                guard digits > 0, value <= UInt64(UInt32.max) else { return nil }
                return UInt32(value)
            }
            guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte), digits < 10 else { return nil }
            value = value * 10 + UInt64(byte - UInt8(ascii: "0"))
            digits += 1
            position += 1
        }
        return nil
    }
}
