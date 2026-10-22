import Foundation
import WarzagCore

/// Turns lines of one DE log into events using a `LogRuleSet`. Rules that fail to compile are skipped and listed in
/// `invalidRules`, so one broken rule never disables the rest.
public struct LogParser: Sendable {
    public let kind: LogKind
    public let invalidRules: [LogRule]
    private let rules: [CompiledRule]

    public init(kind: LogKind, rules: LogRuleSet = .builtIn) {
        self.kind = kind
        var compiled: [CompiledRule] = []
        var invalid: [LogRule] = []
        for rule in rules.rules where rule.logs?.contains(kind) ?? true {
            if let ready = CompiledRule(rule) { compiled.append(ready) } else { invalid.append(rule) }
        }
        self.rules = compiled
        invalidRules = invalid
    }

    /// The event for `line`, from the first matching rule.
    public func event(for line: String) -> ContentEvent? {
        for rule in rules {
            if let values = rule.match(line) { return ContentEvent(signal: rule.signal, values: values) }
        }
        return nil
    }
}

/// A rule with its regular expression compiled. NSRegularExpression is immutable and documented as thread-safe.
private struct CompiledRule: @unchecked Sendable {
    let signal: String
    let contains: String?
    let regex: NSRegularExpression?
    let groupNames: [String]

    init?(_ rule: LogRule) {
        guard rule.contains?.isEmpty == false || rule.pattern?.isEmpty == false else { return nil }
        signal = rule.signal
        contains = rule.contains?.isEmpty == false ? rule.contains : nil
        if let pattern = rule.pattern, !pattern.isEmpty {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            self.regex = regex
            groupNames = Self.groupNames(in: pattern)
        } else {
            regex = nil
            groupNames = []
        }
    }

    func match(_ line: String) -> [String: String]? {
        if let contains, !line.contains(contains) { return nil }
        guard let regex else { return [:] }
        let range = NSRange(line.startIndex..., in: line)
        guard let result = regex.firstMatch(in: line, range: range) else { return nil }
        var values: [String: String] = [:]
        for name in groupNames {
            let groupRange = result.range(withName: name)
            if groupRange.location != NSNotFound, let swiftRange = Range(groupRange, in: line) {
                values[name] = String(line[swiftRange])
            }
        }
        return values
    }

    private static let groupNamePattern = try! NSRegularExpression(pattern: #"\(\?<([A-Za-z][A-Za-z0-9]*)>"#)

    private static func groupNames(in pattern: String) -> [String] {
        let range = NSRange(pattern.startIndex..., in: pattern)
        return groupNamePattern.matches(in: pattern, range: range).compactMap {
            Range($0.range(at: 1), in: pattern).map { String(pattern[$0]) }
        }
    }
}

/// A tailer and a parser for one log: poll it and get events.
public struct LogMonitor: Sendable {
    public private(set) var tailer: LogTailer
    public let parser: LogParser

    public init(url: URL, kind: LogKind, rules: LogRuleSet = .builtIn) {
        tailer = LogTailer(url: url)
        parser = LogParser(kind: kind, rules: rules)
    }

    public mutating func poll(_ fileSystem: any FileSystem) throws -> [ContentEvent] {
        let chunk = try tailer.poll(fileSystem)
        return (chunk.restarted ? [.logRestarted] : []) + chunk.lines.compactMap(parser.event(for:))
    }

    /// Ignores what the log already holds (the previous run); see `LogTailer.seekToEnd(_:)`.
    public mutating func seekToEnd(_ fileSystem: any FileSystem) throws {
        try tailer.seekToEnd(fileSystem)
    }
}
