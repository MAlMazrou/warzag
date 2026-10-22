import Foundation

/// CHANGELOG.md: what each release of Warzag changed. App/make-app.sh copies it into the app for What's New in Warzag.
/// The format is the one tools/release/changelog.py checks and cuts releases from: free text, then "## [Unreleased]",
/// then one "## [x.y.z] - YYYY-MM-DD" section per release, newest first. A section has up to three subsections,
/// "### Major", "### Minor" and "### Bug fixes" in this order, each with "- " entries that may continue on lines
/// indented by two spaces. `parse` refuses what that tool's check refuses, except a version number that the release's
/// headings do not call for and a release dated before the one below it.
public struct Changelog: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case major = "Major"
        case minor = "Minor"
        case bugFixes = "Bug fixes"
    }

    /// One heading's entries, in file order. An entry's continuation lines are joined to it with single spaces, and
    /// its inline Markdown is kept.
    public struct Subsection: Equatable, Sendable {
        public var kind: Kind
        public var entries: [String]

        public init(kind: Kind, entries: [String]) {
            self.kind = kind
            self.entries = entries
        }
    }

    public struct Release: Equatable, Sendable {
        /// "0.1.0".
        public var version: String
        /// The day of the release: year, month and day.
        public var date: DateComponents
        /// In the order Major, Minor, Bug fixes.
        public var subsections: [Subsection]

        public init(version: String, date: DateComponents, subsections: [Subsection]) {
            self.version = version
            self.date = date
            self.subsections = subsections
        }
    }

    /// The changes no release has yet; empty when there are none.
    public var unreleased: [Subsection]
    /// Newest first.
    public var releases: [Release]

    public init(unreleased: [Subsection] = [], releases: [Release] = []) {
        self.unreleased = unreleased
        self.releases = releases
    }
}

public struct ChangelogError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    /// The line, from 1; nil when the problem is the file as a whole.
    public var line: Int?

    public init(_ message: String, line: Int? = nil) {
        self.message = message
        self.line = line
    }

    public var description: String { line.map { "line \($0): \(message)" } ?? message }
}

extension Changelog {
    private static let unreleasedName = "Unreleased"

    /// CHANGELOG.md's text; throws where it breaks the format.
    public static func parse(_ text: String) throws(ChangelogError) -> Changelog {
        var sections: [Draft] = []
        for (index, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            var line = raw
            while line.last?.isWhitespace == true { line.removeLast() }
            if let heading = sectionHeading(line) {
                sections.append(Draft(name: heading.name, date: heading.date, line: index + 1))
            } else if !sections.isEmpty {
                // Lines above the first section are the introduction, which is free text.
                try sections[sections.count - 1].add(line, number: index + 1)
            }
        }
        return try checked(sections)
    }

    /// "## [<name>]" or "## [<name>] - <date>", as changelog.py's SECTION pattern reads it.
    private static func sectionHeading(_ line: Substring) -> (name: String, date: String?)? {
        guard line.hasPrefix("## [") else { return nil }
        let rest = line.dropFirst(4)
        guard let close = rest.firstIndex(of: "]"), close != rest.startIndex else { return nil }
        let after = rest[rest.index(after: close)...]
        let name = String(rest[..<close])
        if after.isEmpty { return (name, nil) }
        let date = after.dropFirst(3)
        guard after.hasPrefix(" - "), !date.isEmpty, !date.contains(where: \.isWhitespace) else { return nil }
        return (name, String(date))
    }

    private static func checked(_ sections: [Draft]) throws(ChangelogError) -> Changelog {
        guard let first = sections.first, first.name == unreleasedName else {
            throw ChangelogError("the first section must be '## [\(unreleasedName)]'")
        }
        if first.date != nil {
            throw ChangelogError("'## [\(unreleasedName)]' takes no date", line: first.line)
        }
        var releases: [Release] = []
        var newer: (section: Draft, numbers: [Int])?
        for section in sections.dropFirst() {
            if section.name == unreleasedName {
                throw ChangelogError("a second '## [\(unreleasedName)]'", line: section.line)
            }
            guard let numbers = versionNumbers(section.name) else {
                throw ChangelogError("'\(section.name)' is not a version number x.y.z", line: section.line)
            }
            guard let text = section.date, isDayShaped(text) else {
                throw ChangelogError("[\(section.name)] needs its date: '## [\(section.name)] - YYYY-MM-DD'",
                                     line: section.line)
            }
            guard let date = day(text) else {
                throw ChangelogError("[\(section.name)] has no real date: \(text)", line: section.line)
            }
            if section.subsections.allSatisfy(\.entries.isEmpty) {
                throw ChangelogError("[\(section.name)] lists no change", line: section.line)
            }
            if let newer, !numbers.lexicographicallyPrecedes(newer.numbers) {
                throw ChangelogError("[\(newer.section.name)] must be newer than the release below it, "
                    + "[\(section.name)]", line: newer.section.line)
            }
            newer = (section, numbers)
            releases.append(Release(version: section.name, date: date, subsections: try section.finished()))
        }
        return Changelog(unreleased: try first.finished(), releases: releases)
    }

    /// x.y.z, without leading zeros.
    private static func versionNumbers(_ name: String) -> [Int]? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(isDigit), part == "0" || part.first != "0",
                  let number = Int(part) else { return nil }
            numbers.append(number)
        }
        return numbers
    }

    /// YYYY-MM-DD, whether or not that day exists.
    private static func isDayShaped(_ text: String) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        return parts.map(\.count) == [4, 2, 2] && parts.allSatisfy { $0.allSatisfy(isDigit) }
    }

    /// A YYYY-MM-DD day that exists in the Gregorian calendar.
    private static func day(_ text: String) -> DateComponents? {
        let numbers = text.split(separator: "-").compactMap { Int($0) }
        guard numbers.count == 3, numbers[0] >= 1 else { return nil }
        let date = DateComponents(year: numbers[0], month: numbers[1], day: numbers[2])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return date.isValidDate(in: calendar) ? date : nil
    }

    private static func isDigit(_ character: Character) -> Bool { character.isASCII && character.isWholeNumber }

    /// A section while it is read: its subsections, each entry as its lines.
    private struct Draft {
        var name: String
        var date: String?
        var line: Int
        var subsections: [(kind: Kind, entries: [[Substring]])] = []

        mutating func add(_ line: Substring, number: Int) throws(ChangelogError) {
            if line.isEmpty { return }
            if line.hasPrefix("### ") {
                let heading = line.dropFirst(4)
                guard let kind = Kind(rawValue: String(heading)) else {
                    throw ChangelogError("'### \(heading)' is not one of "
                        + Kind.allCases.map { "'### \($0.rawValue)'" }.joined(separator: ", "), line: number)
                }
                if subsections.contains(where: { $0.kind == kind }) {
                    throw ChangelogError("a second '### \(heading)' in [\(name)]", line: number)
                }
                if subsections.contains(where: { $0.kind.order > kind.order }) {
                    throw ChangelogError("'### \(heading)' comes after a later heading in [\(name)] (order: "
                        + Kind.allCases.map(\.rawValue).joined(separator: ", ") + ")", line: number)
                }
                subsections.append((kind, []))
                return
            }
            if line.hasPrefix("#") {
                throw ChangelogError("unexpected heading '\(line)' in [\(name)]", line: number)
            }
            guard let last = subsections.indices.last else {
                throw ChangelogError("text outside a '### Major', '### Minor' or '### Bug fixes' subsection "
                    + "in [\(name)]", line: number)
            }
            if line.hasPrefix("- ") {
                subsections[last].entries.append([line.dropFirst(2)])
            } else if line.hasPrefix("  "), let entry = subsections[last].entries.indices.last {
                subsections[last].entries[entry].append(line)
            } else {
                throw ChangelogError("neither a '- ' entry nor its indented continuation in [\(name)]", line: number)
            }
        }

        /// Each entry on one line.
        func finished() throws(ChangelogError) -> [Subsection] {
            var finished: [Subsection] = []
            for (kind, entries) in subsections {
                guard !entries.isEmpty else {
                    throw ChangelogError("'### \(kind.rawValue)' in [\(name)] has no entry", line: line)
                }
                finished.append(Subsection(kind: kind, entries: entries.map { lines in
                    lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                }))
            }
            return finished
        }
    }
}

private extension Changelog.Kind {
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}
