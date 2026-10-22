import ContentKit
import Foundation

/// What DE's launcher writes about its progress in Launcher.log. "Current time:" starts a run and each step ends with
/// "Finished <step> (<n> seconds)": BinariesBP_LAUNCHER, EULA (once the player clicked I AGREE), the bulk download
/// BinariesBP_BULK, Preprocess (after the ContentUpdate applet ran) and Defrag1. "Total time: <n> seconds" ends the
/// run; the launcher then idles.
///
/// The rules are ContentKit `LogRule`s. Every pattern is anchored at the start of the line, so the applet's lines
/// mirrored into Launcher.log never match.
public enum LauncherLog {
    public enum Signal: String, CaseIterable, Sendable {
        case runStarted = "launcherRunStarted"
        case rate = "launcherRate"
        case phaseFinished = "launcherPhaseFinished"
        case bytesTotal = "launcherBytesTotal"
        case appletStarted = "launcherAppletStarted"
        case appletExited = "launcherAppletExited"
        case totalTime = "launcherTotalTime"
    }

    public static let rules: [LogRule] = [
        LogRule(signal: Signal.runStarted.rawValue, logs: [.launcher], contains: "Current time:",
                pattern: #"^Current time: "#),
        LogRule(signal: Signal.rate.rawValue, logs: [.launcher], contains: "Downloading @",
                pattern: #"^Downloading @ (?<rate>\d+(?:\.\d+)?) MB/s"#),
        LogRule(signal: Signal.phaseFinished.rawValue, logs: [.launcher], contains: "Finished ",
                pattern: #"^Finished (?<phase>[A-Za-z][A-Za-z0-9_]*) \((?<seconds>\d+(?:\.\d+)?) seconds\)"#),
        LogRule(signal: Signal.bytesTotal.rawValue, logs: [.launcher], contains: "bytes total",
                pattern: #"^Downloaded (?<bytes>\d[\d,]*) bytes total"#),
        LogRule(signal: Signal.appletStarted.rawValue, logs: [.launcher], contains: "Framework/ContentUpdate",
                pattern: #"^"[^"]*\.exe" .*-applet:/EE/Types/Framework/ContentUpdate"#),
        LogRule(signal: Signal.appletExited.rawValue, logs: [.launcher], contains: "Process returned",
                pattern: #"^Process returned (?<code>-?\d+)"#),
        LogRule(signal: Signal.totalTime.rawValue, logs: [.launcher], contains: "Total time:",
                pattern: #"^Total time: (?<seconds>\d+(?:\.\d+)?) seconds"#),
    ]

    /// Launcher.log's rules: these first, then ContentKit's (the applet's mirrored "Downloaded x/y" counters,
    /// "Downloaded data was corrupted.", self-update restarts).
    public static let ruleSet = LogRuleSet.builtIn.extended(with: rules)
}

/// One fact from Launcher.log.
public enum LauncherEvent: Equatable, Sendable {
    case runStarted
    case rate(megabytesPerSecond: Double)
    case phaseFinished(String, seconds: Double)
    case bytesTotal(Int64)
    case appletStarted
    case appletExited(code: Int)
    case totalTime(seconds: Double)
    /// ContentKit's own events (applet counters, corruption, restarts, a replaced log).
    case content(ContentEvent)

    public init(_ event: ContentEvent) {
        guard case .other(let name, let values) = event, let signal = LauncherLog.Signal(rawValue: name) else {
            self = .content(event)
            return
        }
        switch signal {
        case .runStarted:
            self = .runStarted
        case .rate:
            guard let rate = values["rate"].flatMap(Double.init) else { self = .content(event); return }
            self = .rate(megabytesPerSecond: rate)
        case .phaseFinished:
            guard let phase = values["phase"], let seconds = values["seconds"].flatMap(Double.init) else {
                self = .content(event)
                return
            }
            self = .phaseFinished(phase, seconds: seconds)
        case .bytesTotal:
            guard let bytes = values["bytes"].flatMap({ Int64($0.filter { $0 != "," }) }) else {
                self = .content(event)
                return
            }
            self = .bytesTotal(bytes)
        case .appletStarted:
            self = .appletStarted
        case .appletExited:
            guard let code = values["code"].flatMap({ Int($0) }) else { self = .content(event); return }
            self = .appletExited(code: code)
        case .totalTime:
            guard let seconds = values["seconds"].flatMap(Double.init) else { self = .content(event); return }
            self = .totalTime(seconds: seconds)
        }
    }
}

/// Where a launcher run is, as far as its log tells.
public enum LauncherPhase: String, Sendable, Codable, CaseIterable {
    /// Checking its own files, before the EULA step.
    case starting
    /// At the EULA step: DE's window shows the EULA until the player clicks I AGREE.
    case eula
    /// Past the EULA: checking and downloading game files.
    case downloading
    /// DE's ContentUpdate applet prepares the caches.
    case preprocessing
    /// Cache defragmentation after the applet.
    case finishing
    /// "Total time:", the launcher now idles until Play.
    case complete
}

/// Launcher.log (and Preprocess.log) folded into one state.
public struct LauncherLogState: Equatable, Sendable {
    /// Steps in the order the launcher finished them ("ClientIP", ..., "EULA", ..., "Preprocess", "Defrag1").
    public private(set) var finishedSteps: [String] = []
    /// The latest "Downloading @ N MB/s"; cleared when a step finishes.
    public private(set) var megabytesPerSecond: Double?
    public private(set) var appletStarted = false
    public private(set) var appletExitCode: Int?
    /// The ContentUpdate applet's counters (Preprocess.log, mirrored into Launcher.log).
    public private(set) var applet = ContentProgress()
    public private(set) var bytesDownloaded: Int64 = 0
    public private(set) var totalSeconds: Double?
    public private(set) var corruptionReported = false
    public private(set) var selfUpdateRestart = false
    /// Lines seen since the run (or the log) started over.
    public private(set) var lines = 0

    public init() {}

    public mutating func apply(_ event: LauncherEvent) {
        lines += 1
        switch event {
        case .runStarted, .content(.logRestarted):
            // A new launcher run (a restart, or a self-update starting over) repeats every step.
            self = LauncherLogState()
            lines = 1
        case .rate(let rate):
            megabytesPerSecond = rate
        case .phaseFinished(let step, _):
            finishedSteps.append(step)
            megabytesPerSecond = nil
        case .bytesTotal(let bytes):
            bytesDownloaded += bytes
        case .appletStarted:
            appletStarted = true
        case .appletExited(let code):
            appletExitCode = code
        case .totalTime(let seconds):
            totalSeconds = seconds
        case .content(let event):
            switch event {
            case .downloadCorrupted:
                corruptionReported = true
            case .updateRestarting:
                selfUpdateRestart = true
            default:
                break
            }
            applet.apply(event)
        }
    }

    /// Preprocess.log events (the applet writes its own log too).
    public mutating func applyApplet(_ event: ContentEvent) {
        if event == .downloadCorrupted { corruptionReported = true }
        applet.apply(event)
    }

    public func finished(_ step: String) -> Bool { finishedSteps.contains(step) }

    public var isComplete: Bool { totalSeconds != nil }

    /// The launcher has checked its own files, so its next step is the EULA.
    public var reachedEULAStep: Bool { finished("BinariesBP_LAUNCHER") || finished("EULA") }
    public var eulaFinished: Bool { finished("EULA") }
    /// Waiting at the EULA step right now.
    public var atEULAStep: Bool { reachedEULAStep && !eulaFinished }

    public var phase: LauncherPhase {
        if isComplete { return .complete }
        if finished("Preprocess") { return .finishing }
        if appletStarted || appletExitCode != nil || finished("BinariesBP_BULK") { return .preprocessing }
        if eulaFinished || megabytesPerSecond != nil { return .downloading }
        if reachedEULAStep { return .eula }
        return .starting
    }
}
