import Foundation
import WarzagCore

/// A step of Steam's sign-in screen, from steamui_login.txt's `SetLoginState: <step> - <reason>` lines.
public enum SteamLoginStep: Equatable, Hashable, Sendable {
    case none
    /// Steam's sign-in screen (or its "sign in again" dialog) waits for the player.
    case waitingForCredentials
    case waitingForNetwork
    case waitingForServerResponse
    case waitingForLibraryReady
    case success
    /// A step this build does not know (a later Steam client); its text is not kept.
    case other

    public static let known: [SteamLoginStep] = [
        .none, .waitingForCredentials, .waitingForNetwork, .waitingForServerResponse, .waitingForLibraryReady, .success,
    ]

    /// Steam's own token for the step ("WaitingForCredentials"); "other" for an unknown one.
    public var token: String {
        switch self {
        case .none: "None"
        case .waitingForCredentials: "WaitingForCredentials"
        case .waitingForNetwork: "WaitingForNetwork"
        case .waitingForServerResponse: "WaitingForServerResponse"
        case .waitingForLibraryReady: "WaitingForLibraryReady"
        case .success: "Success"
        case .other: "other"
        }
    }

    public init(token: String) {
        self = Self.known.first { $0.token == token } ?? .other
    }

    /// The steps Steam goes through on its own once it has what it needs (`SteamSignInPhase.signingIn`).
    public var isMoving: Bool {
        [.waitingForNetwork, .waitingForServerResponse, .waitingForLibraryReady, .success].contains(self)
    }
}

/// Why Steam is at a step. Only these two reasons mean anything to Warzag; any other text is `.other` and not kept.
public enum SteamLoginReason: Equatable, Hashable, Sendable {
    case ok
    /// "Logged In Elsewhere": Steam signed the account out because another session started playing (Steam shows its
    /// own "sign in again" dialog).
    case loggedInElsewhere
    case other

    public var token: String {
        switch self {
        case .ok: "OK"
        case .loggedInElsewhere: "Logged In Elsewhere"
        case .other: "other"
        }
    }

    public init(text: String) {
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "ok": self = .ok
        case "logged in elsewhere": self = .loggedInElsewhere
        default: self = .other
        }
    }
}

/// One `SetLoginState` line: the step Steam moved to, why, and when.
public struct SteamLoginTransition: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var step: SteamLoginStep
    public var reason: SteamLoginReason
    public var at: Date

    public init(step: SteamLoginStep, reason: SteamLoginReason, at: Date) {
        self.step = step
        self.reason = reason
        self.at = at
    }

    /// Fixed tokens only, e.g. "WaitingForCredentials - Logged In Elsewhere".
    public var description: String { "\(step.token) - \(reason.token)" }
}

/// Reads ~/Library/Application Support/Steam/logs/steamui_login.txt backwards, like `ConnectionLog`: only lines with
/// Steam's timestamp and `SetLoginState:` count, e.g.
/// `[YYYY-MM-DD HH:MM:SS] [ Success ] SetLoginState: WaitingForCredentials - Logged In Elsewhere`.
/// The bracket before `SetLoginState:` is the state *before* that line's event, so it is never read. A last line still
/// being written is left for the next read.
public enum LoginStateLog {
    static let marker = Array("SetLoginState:".utf8)
    /// Where in a line the marker may stand, and the longest step and reason read after it.
    static let markerSearchLength = 256
    static let longestStep = 48
    static let longestReason = 64

    /// The latest transition logged at or after `since` (Steam's process start), or nil if there is none.
    public static func lastTransition(
        in url: URL,
        since: Date?,
        fileSystem: any FileSystem,
        timeZone: TimeZone = .current,
        chunkSize: Int = 64 * 1024
    ) throws -> SteamLoginTransition? {
        try transitions(in: url, since: since, limit: 1, fileSystem: fileSystem, timeZone: timeZone,
                        chunkSize: chunkSize).last
    }

    /// The latest `limit` transitions logged at or after `since`, oldest first.
    public static func transitions(
        in url: URL,
        since: Date?,
        limit: Int,
        fileSystem: any FileSystem,
        timeZone: TimeZone = .current,
        chunkSize: Int = 64 * 1024
    ) throws -> [SteamLoginTransition] {
        guard limit > 0 else { return [] }
        let calendar = LogTimestamp.calendar(timeZone)
        let earliest = LogTimestamp.earliest(since: since)
        var found: [SteamLoginTransition] = []
        try LogLines.backward(in: url, fileSystem: fileSystem, chunkSize: chunkSize,
                              skipUnterminatedLastLine: true) { line in
            guard let time = LogTimestamp.parse(line, calendar: calendar) else { return true }
            if let earliest, time < earliest { return false }
            guard let transition = transition(in: line, at: time) else { return true }
            found.append(transition)
            return found.count < limit
        }
        return found.reversed()
    }

    /// The step and reason after `SetLoginState:`, given the line's timestamp. A step must be one word of letters;
    /// the reason is what follows " - " up to the end of the line (letters and spaces; anything else is `.other`).
    static func transition(in line: ArraySlice<UInt8>, at time: Date) -> SteamLoginTransition? {
        guard let message = LogTimestamp.message(of: line, limit: markerSearchLength + longestStep + longestReason + 8),
              let found = message.prefix(markerSearchLength + Self.marker.count).firstRange(of: Self.marker)
        else { return nil }
        var rest = message[found.upperBound...].drop { $0 == UInt8(ascii: " ") }
        let step = rest.prefix { isLetter($0) }
        guard !step.isEmpty, step.count <= longestStep else { return nil }
        rest = rest.dropFirst(step.count)
        // The step must end the line or be followed by a space.
        guard rest.isEmpty || rest.first == UInt8(ascii: " ") else { return nil }
        var reason = SteamLoginReason.other
        rest = rest.drop { $0 == UInt8(ascii: " ") }
        // A line longer than what was read has a reason too long to be one Warzag knows.
        if rest.first == UInt8(ascii: "-"), message.endIndex == line.endIndex {
            let text = rest.dropFirst().drop { $0 == UInt8(ascii: " ") }
            let words = text.prefix { isLetter($0) || $0 == UInt8(ascii: " ") }
            if words.count == text.count, text.count <= longestReason {
                reason = SteamLoginReason(text: String(decoding: words, as: UTF8.self))
            }
        }
        return SteamLoginTransition(step: SteamLoginStep(token: String(decoding: step, as: UTF8.self)),
                                    reason: reason, at: time)
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
    }
}
