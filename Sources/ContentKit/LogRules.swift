import Foundation

/// DE's logs under %LOCALAPPDATA%\Warframe.
public enum LogKind: String, Codable, Sendable, CaseIterable {
    /// Launcher.log: DE's launcher, including the applet lines it mirrors.
    case launcher
    /// Preprocess.log: the ContentUpdate applet ("N assets to download" … "Done.").
    case preprocess
    /// EE.log: the game itself (Steam login, renderer start-up, fatal errors, its quit).
    case ee
}

/// Names of the signals Warzag understands. Rules can use any name; unknown ones arrive as `.other`.
public enum LogSignal: String, Sendable, CaseIterable {
    case commandLine, steamActive, steamLogin, loggedIn, steamNotRunning, steamOutOfDate, steamInitFailed
    case downloadCorrupted, mustRunFromLauncher, metalViewFailed, closing
    case launcherDownloaded, launcherPreprocess, updateRestarting
    case assetsToDownload, preprocessDone, wastedCacheSpace, fetchFailed
}

/// One data-driven pattern.
public struct LogRule: Codable, Sendable, Equatable {
    /// Event name, usually a `LogSignal` raw value.
    public var signal: String
    /// Logs the rule applies to; nil means every log.
    public var logs: [LogKind]?
    /// Plain substring the line must contain (cheap, and tolerant of prefixes such as timestamps).
    public var contains: String?
    /// Optional regular expression; its named groups (`(?<total>\d+)`) become the event's values.
    public var pattern: String?

    public init(signal: String, logs: [LogKind]? = nil, contains: String? = nil, pattern: String? = nil) {
        self.signal = signal
        self.logs = logs
        self.contains = contains
        self.pattern = pattern
    }

    init(_ signal: LogSignal, _ logs: [LogKind]?, contains: String? = nil, pattern: String? = nil) {
        self.init(signal: signal.rawValue, logs: logs, contains: contains, pattern: pattern)
    }
}

/// An ordered list of rules; the first rule that matches a line wins.
public struct LogRuleSet: Codable, Sendable, Equatable {
    public var rules: [LogRule]

    public init(rules: [LogRule]) {
        self.rules = rules
    }

    /// `first`, then these rules: a rule in `first` wins over a later one that matches the same line.
    public func extended(with first: [LogRule]) -> LogRuleSet {
        LogRuleSet(rules: first + rules)
    }

    /// Lines from DE's binaries and logs. Specific rules come before general ones: "Downloaded data was corrupted."
    /// must win over the "Downloaded " counters. DE prints large numbers with thousands separators, so numeric groups
    /// accept commas.
    ///
    /// `closing`: "Executing command: .../CmdQuit" starts a quit from Warframe's menu and "Destroying Graphics Worker
    /// Thread" is the last step of the shutdown. "Shutting down context..." is not used: Warframe also logs it during
    /// play.
    public static let builtIn = LogRuleSet(rules: [
        LogRule(.commandLine, [.ee], contains: "Process Command-line:",
                pattern: #"Process Command-line:\s*(?<arguments>.*?)\s*$"#),
        LogRule(.steamActive, [.ee], contains: "Steam active."),
        LogRule(.steamNotRunning, [.ee], contains: "Steam does not appear to be running."),
        LogRule(.steamOutOfDate, [.ee], contains: "The Steam client appears to be out of date."),
        LogRule(.steamInitFailed, [.ee], contains: "Failed to initialize Steam."),
        LogRule(.steamLogin, [.ee], contains: "SteamLogin", pattern: #"\bSteamLogin\b"#),
        LogRule(.loggedIn, [.ee], contains: "Logged in", pattern: #"(?:^|:\s)Logged in\b"#),
        LogRule(.mustRunFromLauncher, [.ee], contains: "Framework_MustRunFromLauncher"),
        LogRule(.closing, [.ee], contains: "Executing command: /EE/Editor/ToolMenus/Commands/CmdQuit",
                pattern: #"(?:^|:\s)Executing command: /EE/Editor/ToolMenus/Commands/CmdQuit\b"#),
        LogRule(.closing, [.ee], contains: "Destroying Graphics Worker Thread",
                pattern: #"(?:^|:\s)Destroying Graphics Worker Thread\b"#),
        LogRule(.metalViewFailed, nil, contains: "Failed to create metal view"),
        LogRule(.downloadCorrupted, nil, contains: "Downloaded data was corrupted."),
        LogRule(.launcherDownloaded, [.launcher, .preprocess], contains: "Downloaded ",
                pattern: #"Downloaded (?<downloaded>\d[\d,]*)\s*/\s*(?<total>\d[\d,]*)"#),
        LogRule(.launcherPreprocess, [.launcher], contains: "Preprocess ",
                pattern: #"Preprocess (?<done>\d[\d,]*)\s*/\s*(?<total>\d[\d,]*)"#),
        LogRule(.updateRestarting, [.launcher], contains: "restarted shortly"),
        LogRule(.assetsToDownload, [.preprocess], contains: "assets to download",
                pattern: #"(?<count>\d[\d,]*) assets to download"#),
        LogRule(.wastedCacheSpace, [.preprocess], contains: "Wasted cache space",
                pattern: #"Wasted cache space:\s*(?<bytes>\d[\d,]*)(?:\s*bytes)?(?:\s*\((?<percent>\d+(?:\.\d+)?)%\))?"#),
        LogRule(.fetchFailed, [.preprocess], contains: "failed!", pattern: #"Fetch of .* failed!"#),
        LogRule(.preprocessDone, [.preprocess], contains: "Done.", pattern: #"(?:^|\s)Done\.\s*$"#),
    ])
}
