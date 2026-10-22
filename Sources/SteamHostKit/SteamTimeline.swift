import Foundation
import WarzagCore

/// One line of `warzagctl steam timeline`: a time and fixed tokens. Never an ID, a name, a path or which other app
/// Steam tracks.
public struct SteamTimelineEvent: Equatable, Sendable, CustomStringConvertible {
    public enum Source: Int, Sendable, Comparable {
        case bootstrap, connection, login, gameProcess, warzag

        public static func < (lhs: Source, rhs: Source) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var at: Date
    public var source: Source
    public var text: String

    public init(at: Date, source: Source, text: String) {
        self.at = at
        self.source = source
        self.text = text
    }

    public var description: String { text }
}

/// gameprocess_log.txt: the games Steam tracks as running. The parser accepts each wording Steam uses and keeps only
/// whether it is Warframe and whether it was added or removed:
/// "Game process added : AppID 230410 …", "Game process removed: AppID …", "AppID 230410 adding PID …",
/// "AppID … no longer tracking PID …".
enum GameProcessLog {
    struct Event: Equatable, Sendable {
        var warframe: Bool
        var added: Bool
    }

    static let longestMessage = 4096

    static func event(in line: ArraySlice<UInt8>) -> Event? {
        guard let message = LogTimestamp.message(of: line, limit: longestMessage) else { return nil }
        let text = String(decoding: message, as: UTF8.self)
        let added: Bool
        if text.hasPrefix("Game process added") || text.contains(" adding PID ") {
            added = true
        } else if text.hasPrefix("Game process removed") || text.contains(" no longer tracking PID ") {
            added = false
        } else {
            return nil
        }
        guard let appID = appID(in: text) else { return nil }
        return Event(warframe: appID == Warframe.steamAppID, added: added)
    }

    /// The digits after the first "AppID ".
    static func appID(in text: String) -> Int? {
        guard let range = text.range(of: "AppID ") else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isASCII && $0.isNumber }
        return digits.isEmpty || digits.count > 10 ? nil : Int(digits)
    }
}

/// The merged, fixed-token timeline of Steam's start and stop (bootstrap_log.txt), connection states without IDs
/// (connection_log.txt), sign-in steps (steamui_login.txt), game processes (gameprocess_log.txt) and Warzag's own
/// play and steam lines (Warzag.log), for `warzagctl steam timeline`.
public struct SteamTimeline: Sendable {
    public let locations: SteamLocations
    /// ~/Library/Logs/Warzag/Warzag.log; nil leaves Warzag's lines out.
    public let warzagLog: URL?
    public let fileSystem: any FileSystem
    public let timeZone: TimeZone

    public init(locations: SteamLocations, warzagLog: URL?, fileSystem: any FileSystem, timeZone: TimeZone = .current) {
        self.locations = locations
        self.warzagLog = warzagLog
        self.fileSystem = fileSystem
        self.timeZone = timeZone
    }

    /// The most read from the end of each file for one listing: an hour of Steam's busiest log is far less.
    public static let byteLimit: UInt64 = 16 << 20

    /// Every event at or after `since`, oldest first. Repeated connection states are shown once (Steam logs the same
    /// state every few seconds while it waits at its sign-in screen). With `follower`, only what was written before it
    /// started (it reports the rest), so nothing shows twice.
    public func events(since: Date, before follower: Follower? = nil) -> [SteamTimelineEvent] {
        let calendar = LogTimestamp.calendar(timeZone)
        var events: [SteamTimelineEvent] = []
        for source in Self.steamSources {
            let url = url(of: source)
            var found: [SteamTimelineEvent] = []
            try? LogLines.backward(in: url, fileSystem: fileSystem, byteLimit: Self.byteLimit,
                                   endingAt: follower?.positions[url], skipUnterminatedLastLine: true) { line in
                guard let time = LogTimestamp.parse(line, calendar: calendar) else { return true }
                guard time >= since else { return false }
                if let event = Self.event(source, line: line, at: time) { found.append(event) }
                return true
            }
            events += Self.collapsed(found.reversed())
        }
        if let warzagLog {
            var found: [SteamTimelineEvent] = []
            try? LogLines.backward(in: warzagLog, fileSystem: fileSystem, byteLimit: Self.byteLimit,
                                   endingAt: follower?.positions[warzagLog], skipUnterminatedLastLine: true) { line in
                guard let (time, text) = Self.warzagLine(line) else { return true }
                guard time >= since else { return false }
                found.append(SteamTimelineEvent(at: time, source: .warzag, text: text))
                return true
            }
            events += found.reversed()
        }
        return Self.sorted(events)
    }

    /// Follows the files from where they end now (`--follow`): each `poll()` returns what was written since.
    public func follower() -> Follower {
        var follower = Follower(timeline: self)
        follower.positions = Dictionary(uniqueKeysWithValues: follower.urls.compactMap { url in
            (try? LogLines.endPosition(in: url, fileSystem: fileSystem)).map { (url, $0) }
        })
        return follower
    }

    public struct Follower: Sendable {
        let timeline: SteamTimeline
        var positions: [URL: LogLines.Position] = [:]
        var lastConnection: String?

        var urls: [URL] {
            SteamTimeline.steamSources.map(timeline.url(of:)) + (timeline.warzagLog.map { [$0] } ?? [])
        }

        /// After printing `events` (from `events(since:before:)`): a connection state they ended on is not shown
        /// again until it changes.
        public mutating func continueAfter(_ events: [SteamTimelineEvent]) {
            lastConnection = events.last { $0.source == .connection }?.text ?? lastConnection
        }

        /// The events written since the last poll (or since `follower()`), oldest first. A file that appears later is
        /// read from its start; one replaced or truncated (a rotated log) too.
        public mutating func poll() -> [SteamTimelineEvent] {
            let calendar = LogTimestamp.calendar(timeline.timeZone)
            var events: [SteamTimelineEvent] = []
            for source in SteamTimeline.steamSources {
                let url = timeline.url(of: source)
                guard let (lines, position) = try? LogLines.forward(in: url, from: positions[url],
                                                                    fileSystem: timeline.fileSystem) else { continue }
                positions[url] = position
                for line in lines {
                    guard let time = LogTimestamp.parse(line, calendar: calendar),
                          let event = SteamTimeline.event(source, line: line, at: time) else { continue }
                    if source == .connection {
                        guard event.text != lastConnection else { continue }
                        lastConnection = event.text
                    }
                    events.append(event)
                }
            }
            if let url = timeline.warzagLog,
               let (lines, position) = try? LogLines.forward(in: url, from: positions[url],
                                                             fileSystem: timeline.fileSystem) {
                positions[url] = position
                events += lines.compactMap { line in
                    SteamTimeline.warzagLine(line).map { SteamTimelineEvent(at: $0.0, source: .warzag, text: $0.1) }
                }
            }
            return SteamTimeline.sorted(events)
        }
    }

    // MARK: Lines to tokens

    static let steamSources: [SteamTimelineEvent.Source] = [.bootstrap, .connection, .login, .gameProcess]

    func url(of source: SteamTimelineEvent.Source) -> URL {
        switch source {
        case .bootstrap: locations.bootstrapLog
        case .connection: locations.connectionLog
        case .login: locations.loginStateLog
        case .gameProcess: locations.gameProcessLog
        case .warzag: warzagLog ?? locations.logsDirectory
        }
    }

    static func event(_ source: SteamTimelineEvent.Source, line: ArraySlice<UInt8>, at time: Date)
        -> SteamTimelineEvent? {
        let text: String?
        switch source {
        case .bootstrap:
            text = switch BootstrapLog.event(in: line) {
            case .started(let silent): "steam: started (-silent: \(silent ? "yes" : "no"))"
            case .shutdown: "steam: shut down"
            case nil: nil
            }
        case .connection:
            text = ConnectionLog.entry(in: line, at: time).map { entry in
                "connection: \(entry.state.rawValue)"
                    + (entry.carriesAccount ? " (account)" : entry.anonymous ? " (no account)" : "")
            }
        case .login:
            text = LoginStateLog.transition(in: line, at: time).map { "login: \($0.step.token) - \($0.reason.token)" }
        case .gameProcess:
            text = GameProcessLog.event(in: line).map { event in
                "game: " + (event.warframe ? "Warframe (\(Warframe.steamAppID))" : "another app")
                    + (event.added ? " added" : " removed")
            }
        case .warzag:
            text = nil
        }
        return text.map { SteamTimelineEvent(at: time, source: source, text: $0) }
    }

    /// Connection states once per change.
    static func collapsed(_ events: some Sequence<SteamTimelineEvent>) -> [SteamTimelineEvent] {
        var result: [SteamTimelineEvent] = []
        var lastConnection: String?
        for event in events {
            if event.source == .connection {
                guard event.text != lastConnection else { continue }
                lastConnection = event.text
            }
            result.append(event)
        }
        return result
    }

    static func sorted(_ events: [SteamTimelineEvent]) -> [SteamTimelineEvent] {
        events.enumerated().sorted { ($0.element.at, $0.element.source, $0.offset) < ($1.element.at, $1.element.source, $1.offset) }
            .map(\.element)
    }

    /// A Warzag.log line ("<ISO 8601 time> play: …" or "… steam: …") as a token: its category and first clause only
    /// ("play: failed: <detail>" becomes "play: failed"); a line that could carry a path, an address or an ID is
    /// reduced to its category.
    static func warzagLine(_ line: ArraySlice<UInt8>) -> (Date, String)? {
        guard let space = line.firstIndex(of: UInt8(ascii: " ")), space - line.startIndex <= 32,
              let time = try? Date(String(decoding: line[..<space], as: UTF8.self), strategy: .iso8601) else { return nil }
        let message = String(decoding: line[(space + 1)...].prefix(512), as: UTF8.self)
        guard let category = ["play", "steam"].first(where: { message.hasPrefix($0 + ": ") }) else { return nil }
        var text = message
        if let first = text.range(of: ": "), let second = text.range(of: ": ", range: first.upperBound..<text.endIndex) {
            text = String(text[..<second.lowerBound])
        }
        let unsafe = ["/", "\\", "@", "[U:", "://"].contains { text.contains($0) }
            || text.range(of: #"\d{7,}"#, options: .regularExpression) != nil
        return (time, "warzag: " + (unsafe ? "\(category) (details left out)" : String(text.prefix(120))))
    }

    // MARK: Rendering

    /// One line per event: its time relative to `origin` ("-12:04", "+0:37"), the time since the event before it
    /// ("+2s"), and the tokens.
    public static func render(_ events: [SteamTimelineEvent], relativeTo origin: Date, after previous: Date? = nil)
        -> String {
        var last = previous
        return events.map { event in
            let delta = last.map { "+" + duration(event.at.timeIntervalSince($0)) } ?? ""
            last = event.at
            let offset = event.at.timeIntervalSince(origin)
            let when = (offset < 0 ? "-" : "+") + clock(abs(offset))
            return when.padding(toLength: 10, withPad: " ", startingAt: 0)
                + delta.padding(toLength: 8, withPad: " ", startingAt: 0) + event.text + "\n"
        }.joined()
    }

    /// "12:04" or "1:02:03".
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    /// "2s", "1m05s", "2h03m".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return String(format: "%dm%02ds", total / 60, total % 60) }
        return String(format: "%dh%02dm", total / 3600, total / 60 % 60)
    }
}
