import Foundation
import Testing
import WarzagCore
@testable import AppUpdateKit

/// CHANGELOG.md as tools/release/changelog.py reads it: the cases of qa/packaging/changelog-test.py, and the
/// repository's own file.
@Suite struct ChangelogTests {
    static let intro = "# Changelog\n\nFree text, with a list:\n\n- **Major**: big\n- **Minor**: small\n\n"
    static let unreleasedEmpty = "## [Unreleased]"
    static let unreleasedFix = "## [Unreleased]\n\n### Bug fixes\n\n- A fix."
    static let unreleasedMinor = """
        ## [Unreleased]

        ### Minor

        - A smaller feature,
          described on two lines.

        ### Bug fixes

        - A fix.
        """
    static let first = "## [0.1.0] - 2026-10-20\n\n### Major\n\n- The first version."

    /// The introduction, then the sections with a blank line between them (the sections start on line 8).
    static func changelog(_ sections: String...) -> String {
        intro + sections.map { $0 + "\n" }.joined(separator: "\n")
    }

    @Test func releasesNewestFirstWithTheirDatesAndEntries() throws {
        let second = "## [0.2.0] - 2026-10-21\n\n### Minor\n\n- Smaller, with `code`.\n\n"
            + "### Bug fixes\n\n- One.\n- Two."
        let changelog = try Changelog.parse(Self.changelog(Self.unreleasedMinor, second, Self.first))
        #expect(changelog.unreleased == [
            Changelog.Subsection(kind: .minor, entries: ["A smaller feature, described on two lines."]),
            Changelog.Subsection(kind: .bugFixes, entries: ["A fix."]),
        ])
        #expect(changelog.releases == [
            Changelog.Release(version: "0.2.0", date: DateComponents(year: 2026, month: 10, day: 21), subsections: [
                Changelog.Subsection(kind: .minor, entries: ["Smaller, with `code`."]),
                Changelog.Subsection(kind: .bugFixes, entries: ["One.", "Two."]),
            ]),
            Changelog.Release(version: "0.1.0", date: DateComponents(year: 2026, month: 10, day: 20), subsections: [
                Changelog.Subsection(kind: .major, entries: ["The first version."]),
            ]),
        ])
    }

    @Test func nothingYet() throws {
        #expect(try Changelog.parse(Self.changelog(Self.unreleasedEmpty)) == Changelog())
    }

    @Test func windowsLineEndingsAndTrailingSpacesReadTheSame() throws {
        let text = Self.changelog(Self.unreleasedMinor, Self.first)
        let changed = text.replacingOccurrences(of: "\n", with: " \r\n")
        #expect(try Changelog.parse(changed) == Changelog.parse(text))
    }

    /// Release numbers and dates follow rules only changelog.py checks; the parser only needs them newest first.
    @Test func versionRulesAreChangelogPysToCheck() throws {
        let unexpected = "## [0.1.1] - 2026-10-19\n\n### Minor\n\n- Small."
        let changelog = try Changelog.parse(Self.changelog(Self.unreleasedEmpty, unexpected, Self.first))
        #expect(changelog.releases.map(\.version) == ["0.1.1", "0.1.0"])
    }

    @Test(arguments: [
        (changelog(first, unreleasedFix), ChangelogError("the first section must be '## [Unreleased]'")),
        ("", ChangelogError("the first section must be '## [Unreleased]'")),
        (changelog("## [Unreleased]\n\n### Added\n\n- Something.", first),
         ChangelogError("'### Added' is not one of '### Major', '### Minor', '### Bug fixes'", line: 10)),
        (changelog("## [Unreleased]\n\n### Bug fixes\n\n- A fix.\n\n### Major\n\n- Big.", first),
         ChangelogError("'### Major' comes after a later heading in [Unreleased] (order: Major, Minor, Bug fixes)",
                        line: 14)),
        (changelog("## [Unreleased]\n\n### Minor\n\n- One.\n\n### Minor\n\n- Two.", first),
         ChangelogError("a second '### Minor' in [Unreleased]", line: 14)),
        (changelog("## [Unreleased]\n\n### Minor\n\n### Bug fixes\n\n- A fix.", first),
         ChangelogError("'### Minor' in [Unreleased] has no entry", line: 8)),
        (changelog("## [Unreleased]\n\nLoose text.", first),
         ChangelogError("text outside a '### Major', '### Minor' or '### Bug fixes' subsection in [Unreleased]",
                        line: 10)),
        (changelog("## [Unreleased]\n\n### Minor\n\n* Small.", first),
         ChangelogError("neither a '- ' entry nor its indented continuation in [Unreleased]", line: 12)),
        (changelog("## [Unreleased]\n\n### Minor\n\n  continued", first),
         ChangelogError("neither a '- ' entry nor its indented continuation in [Unreleased]", line: 12)),
        (changelog("## [Unreleased]\n\n### Minor\n\n- Small.\n\n#### Details", first),
         ChangelogError("unexpected heading '#### Details' in [Unreleased]", line: 14)),
        (changelog("## [Unreleased] - 2026-10-20", first), ChangelogError("'## [Unreleased]' takes no date", line: 8)),
        (changelog(unreleasedFix, unreleasedEmpty), ChangelogError("a second '## [Unreleased]'", line: 14)),
        (changelog(unreleasedEmpty, "## [0.1] - 2026-10-20\n\n### Major\n\n- First."),
         ChangelogError("'0.1' is not a version number x.y.z", line: 10)),
        (changelog(unreleasedEmpty, "## [01.0.0] - 2026-10-20\n\n### Major\n\n- First."),
         ChangelogError("'01.0.0' is not a version number x.y.z", line: 10)),
        (changelog(unreleasedEmpty, "## [0.1.0]\n\n### Major\n\n- First."),
         ChangelogError("[0.1.0] needs its date: '## [0.1.0] - YYYY-MM-DD'", line: 10)),
        (changelog(unreleasedEmpty, "## [0.1.0] - 2026/10/20\n\n### Major\n\n- First."),
         ChangelogError("[0.1.0] needs its date: '## [0.1.0] - YYYY-MM-DD'", line: 10)),
        // Not a section heading at all, as for changelog.py's pattern: a heading inside [Unreleased].
        (changelog(unreleasedEmpty, "## [0.1.0] - 20 October 2026\n\n### Major\n\n- First."),
         ChangelogError("unexpected heading '## [0.1.0] - 20 October 2026' in [Unreleased]", line: 10)),
        (changelog(unreleasedEmpty, "## [0.1.0] - 2026-02-30\n\n### Major\n\n- First."),
         ChangelogError("[0.1.0] has no real date: 2026-02-30", line: 10)),
        (changelog(unreleasedEmpty, "## [0.1.0] - 2026-10-20"), ChangelogError("[0.1.0] lists no change", line: 10)),
        (changelog(unreleasedEmpty, "## [0.0.9] - 2026-10-19\n\n### Major\n\n- Older.", first),
         ChangelogError("[0.0.9] must be newer than the release below it, [0.1.0]", line: 10)),
    ])
    func refusesWhatChangelogPyRefuses(_ text: String, _ error: ChangelogError) {
        #expect(throws: error) { try Changelog.parse(text) }
    }

    /// The file App/make-app.sh puts into the app: every entry is read, in order, and the releases are newest first.
    @Test func theRepositorysChangelog() throws {
        let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(contentsOf: repository.appending(path: "CHANGELOG.md"), encoding: .utf8)
        let changelog = try Changelog.parse(text)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let firstSection = try #require(lines.firstIndex { $0.hasPrefix("## [") })
        let entryLines = lines[firstSection...].filter { $0.hasPrefix("- ") }
        let entries = (changelog.unreleased + changelog.releases.flatMap(\.subsections)).flatMap(\.entries)
        #expect(!entries.isEmpty)
        #expect(entries.count == entryLines.count)
        for (entry, line) in zip(entries, entryLines) {
            #expect(entry.hasPrefix(line.dropFirst(2).trimmingCharacters(in: .whitespaces)))
            #expect(!entry.contains("\n"))
        }
        let versions = changelog.releases.compactMap { VersionNumber($0.version) }
        #expect(versions.count == changelog.releases.count)
        #expect(zip(versions, versions.dropFirst()).allSatisfy { newer, older in newer > older })
    }
}
