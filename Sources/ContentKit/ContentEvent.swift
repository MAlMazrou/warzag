import Foundation

/// A typed fact read from one of DE's logs.
public enum ContentEvent: Equatable, Sendable {
    /// EE.log's first line: the arguments the game received.
    case commandLine(String)
    case steamActive
    case steamLogin
    case loggedIn
    case steamNotRunning
    case steamOutOfDate
    case steamInitFailed
    case downloadCorrupted
    case mustRunFromLauncher
    /// DXMT could not find winemac's Metal exports: the engine is damaged.
    case metalViewFailed
    /// Warframe is quitting (EE.log): its quit command ran, or its shutdown destroyed the graphics worker thread.
    case closing
    /// "Downloaded x/y" bytes from DE's ContentUpdate applet (Preprocess.log, mirrored into Launcher.log). The
    /// launcher's own bulk download logs no counters.
    case launcherDownloaded(downloaded: Int64, total: Int64)
    case launcherPreprocess(done: Int64, total: Int64)
    case updateRestarting
    case assetsToDownload(Int)
    case preprocessDone
    case wastedCacheSpace(bytes: Int64, percent: Double?)
    case fetchFailed
    /// The log was replaced or truncated: a new run started.
    case logRestarted
    /// A rule whose signal has no built-in meaning (or whose values did not parse).
    case other(signal: String, values: [String: String])

    /// Maps a matched rule to its event. Known signals with unusable values fall back to `.other`.
    public init(signal: String, values: [String: String]) {
        let fallback = ContentEvent.other(signal: signal, values: values)
        guard let known = LogSignal(rawValue: signal) else {
            self = fallback
            return
        }
        switch known {
        case .commandLine: self = .commandLine(values["arguments"] ?? "")
        case .steamActive: self = .steamActive
        case .steamLogin: self = .steamLogin
        case .loggedIn: self = .loggedIn
        case .steamNotRunning: self = .steamNotRunning
        case .steamOutOfDate: self = .steamOutOfDate
        case .steamInitFailed: self = .steamInitFailed
        case .downloadCorrupted: self = .downloadCorrupted
        case .mustRunFromLauncher: self = .mustRunFromLauncher
        case .metalViewFailed: self = .metalViewFailed
        case .closing: self = .closing
        case .updateRestarting: self = .updateRestarting
        case .preprocessDone: self = .preprocessDone
        case .fetchFailed: self = .fetchFailed
        case .launcherDownloaded:
            guard let done: Int64 = Self.number(values["downloaded"]), let total: Int64 = Self.number(values["total"])
            else { self = fallback; return }
            self = .launcherDownloaded(downloaded: done, total: total)
        case .launcherPreprocess:
            guard let done: Int64 = Self.number(values["done"]), let total: Int64 = Self.number(values["total"])
            else { self = fallback; return }
            self = .launcherPreprocess(done: done, total: total)
        case .assetsToDownload:
            guard let count: Int = Self.number(values["count"]) else { self = fallback; return }
            self = .assetsToDownload(count)
        case .wastedCacheSpace:
            guard let bytes: Int64 = Self.number(values["bytes"]) else { self = fallback; return }
            self = .wastedCacheSpace(bytes: bytes, percent: values["percent"].flatMap(Double.init))
        }
    }

    /// DE writes large numbers with thousands separators ("1,628", "96,723,018").
    static func number<Integer: FixedWidthInteger>(_ text: String?) -> Integer? {
        guard let text else { return nil }
        let digits = text.filter { $0 != "," }
        return digits.isEmpty ? nil : Integer(digits)
    }
}
