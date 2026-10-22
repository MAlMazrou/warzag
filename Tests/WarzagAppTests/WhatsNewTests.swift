import AppUpdateKit
import Foundation
import Testing
@testable import WarzagApp

/// What's New in Warzag: the changelog the build carries, newest first, with the changes no release has yet first in a
/// development build.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WhatsNewTests {
    static let changelog = """
        # Changelog

        Every change players would notice.

        ## [Unreleased]

        ### Minor

        - What's New in Warzag, with `warzagctl`
          on a second line.

        ## [0.2.0] - 2026-11-02

        ### Minor

        - Something smaller.

        ### Bug fixes

        - A fix.

        ## [0.1.0] - 2026-10-20

        ### Major

        - The first version.
        """

    /// `changelog` as tools/release/changelog.py's `release 0.3.0` leaves it, in the commit 0.3.0 is built from.
    static let released = """
        # Changelog

        Every change players would notice.

        ## [Unreleased]

        ## [0.3.0] - 2026-11-20

        ### Minor

        - What's New in Warzag, with `warzagctl`
          on a second line.

        ## [0.2.0] - 2026-11-02

        ### Minor

        - Something smaller.

        ### Bug fixes

        - A fix.

        ## [0.1.0] - 2026-10-20

        ### Major

        - The first version.
        """

    let english = Locale(identifier: "en_US")
    let fixture = AppFixture(settings: UpdatesTests.manualChecks)

    private func whatsNew(_ text: String = Self.changelog) throws -> WhatsNew {
        WhatsNew(try Changelog.parse(text), locale: english)
    }

    @Test func aDevelopmentBuildShowsTheUnreleasedChangesFirst() throws {
        let sections = try whatsNew().sections
        #expect(sections.map(\.title) == [L10n.whatsNewNotReleased, L10n.updatesVersion("0.2.0"),
                                          L10n.updatesVersion("0.1.0")])
        #expect(sections.map(\.version) == [nil, "0.2.0", "0.1.0"])
        #expect(sections.map(\.date) == [nil, "November 2, 2026", "October 20, 2026"])
        #expect(sections[0].subsections == [
            Changelog.Subsection(kind: .minor, entries: ["What's New in Warzag, with `warzagctl` on a second line."]),
        ])
        #expect(sections[1].subsections.map(\.kind) == [.minor, .bugFixes])
        #expect(sections[2].subsections == [Changelog.Subsection(kind: .major, entries: ["The first version."])])
    }

    /// Cutting a release empties Unreleased: the release build shows its releases alone.
    @Test func aReleaseBuildShowsOnlyReleasedSections() throws {
        let sections = try whatsNew(Self.released).sections
        #expect(sections.map(\.version) == ["0.3.0", "0.2.0", "0.1.0"])
        #expect(sections[0].subsections == [
            Changelog.Subsection(kind: .minor, entries: ["What's New in Warzag, with `warzagctl` on a second line."]),
        ])
    }

    /// A development build made after a release has that release's version until the next one is cut
    /// (docs/RELEASING.md); its Unreleased changes still come first.
    @Test func aDevelopmentBuildAfterAReleaseShowsTheUnreleasedChangesFirst() {
        fixture.appUpdate.set {
            $0.changelog = Self.changelog
            $0.version = AppVersion(version: "0.2.0", build: "130")
        }
        #expect(fixture.makeModel().whatsNew.sections.map(\.title) == [
            L10n.whatsNewNotReleased, L10n.updatesVersion("0.2.0"), L10n.updatesVersion("0.1.0"),
        ])
    }

    @Test func headingsForVoiceOver() throws {
        let sections = try whatsNew().sections
        #expect(sections[0].accessibilityLabel == "Not released yet")
        #expect(sections[1].accessibilityLabel == "Version 0.2.0, released November 2, 2026")
        #expect(L10n.changeKind(.bugFixes) == "Bug fixes")
    }

    /// A release's day is the day the changelog names, in any time zone, written the reader's way.
    @Test func releaseDays() {
        let day = DateComponents(year: 2026, month: 10, day: 20)
        #expect(Formatting.day(day, locale: english) == "October 20, 2026")
        #expect(Formatting.day(day, locale: Locale(identifier: "en_GB")) == "20 October 2026")
        #expect(Formatting.day(DateComponents(year: 2026, month: 1, day: 1), locale: english) == "January 1, 2026")
    }

    @Test func entriesShowTheirInlineMarkdown() throws {
        let text = WhatsNew.text("Run `warzagctl app check` **now**, see [the guide](https://example.org/guide).")
        #expect(String(text.characters) == "Run warzagctl app check now, see the guide.")
        let code = try #require(text.range(of: "warzagctl app check"))
        #expect(text[code].runs.allSatisfy { $0.inlinePresentationIntent == .code })
        let strong = try #require(text.range(of: "now"))
        #expect(text[strong].runs.allSatisfy { $0.inlinePresentationIntent == .stronglyEmphasized })
        let link = try #require(text.range(of: "the guide"))
        #expect(text[link].runs.allSatisfy { $0.link == URL(string: "https://example.org/guide") })
        #expect(String(WhatsNew.text("Plain words: 3 * 4, Warzag's engine.").characters)
            == "Plain words: 3 * 4, Warzag's engine.")
    }

    @Test func theModelReadsTheRunningBuildsChangelogOnce() {
        fixture.appUpdate.set { $0.changelog = Self.changelog }
        let model = fixture.makeModel()
        #expect(fixture.appUpdate.calls.isEmpty, "read when the window first shows it")
        #expect(model.whatsNew.sections.map(\.version) == [nil, "0.2.0", "0.1.0"])
        #expect(model.whatsNew.sections.count == 3)
        #expect(fixture.appUpdate.calls == ["changelog"])
    }

    /// App/make-app.sh copies CHANGELOG.md into Contents/Resources, where the running Warzag looks it up.
    @Test func theChangelogInTheAppsResources() throws {
        let root = try temporaryDirectory("whats-new-bundle")
        defer { try? FileManager.default.removeItem(at: root) }
        func app(_ name: String, changelog: String?) throws -> Bundle {
            let app = root.appending(path: "\(name)/Warzag.app", directoryHint: .isDirectory)
            let resources = app.appending(path: "Contents/Resources", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            if let changelog { try Data(changelog.utf8).write(to: resources.appending(path: "CHANGELOG.md")) }
            return try #require(Bundle(url: app))
        }
        #expect(UnconfiguredAppUpdates.bundledChangelog(in: try app("with", changelog: Self.changelog))
            == Self.changelog)
        #expect(UnconfiguredAppUpdates.bundledChangelog(in: try app("without", changelog: nil)) == nil)
    }

    /// `swift test` and `swift run` have no CHANGELOG.md in their bundle; the window says so in one sentence.
    @Test func withoutAChangelogThereIsNothingToShow() {
        #expect(UnconfiguredAppUpdates().changelog() == nil)
        #expect(fixture.makeModel().whatsNew.sections.isEmpty)
    }

    /// Demo mode reads the running build's changelog as every run does (none under `swift test`).
    @Test func demoMode() throws {
        let home = try temporaryDirectory("whats-new-demo")
        defer { try? FileManager.default.removeItem(at: home) }
        let model = AppModel.make(options: LaunchOptions(home: home, isDemo: true))
        #expect(model.isDemo)
        #expect(model.services.appUpdate.changelog() == nil)
        #expect(model.whatsNew.sections.isEmpty)
    }

    @Test func aChangelogThatBreaksTheFormatCountsAsNoneAndIsLogged() throws {
        let logs = try temporaryDirectory("whats-new")
        defer { try? FileManager.default.removeItem(at: logs) }
        fixture.log = AppLog(directory: logs)
        fixture.appUpdate.set { $0.changelog = "# Changelog\n\n## [0.1.0] - 2026-10-20\n\n### Major\n\n- First.\n" }
        #expect(fixture.makeModel().whatsNew.sections.isEmpty)
        let log = try String(contentsOf: logs.appending(path: AppLog.fileName), encoding: .utf8)
        #expect(log.contains("app: the app's CHANGELOG.md breaks the format: "
            + "the first section must be '## [Unreleased]'"))
    }

    /// The repository's CHANGELOG.md, which App/make-app.sh copies into the app.
    @Test func theRepositorysChangelog() throws {
        let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let changelog = try Changelog.parse(String(contentsOf: repository.appending(path: "CHANGELOG.md"),
                                                   encoding: .utf8))
        let released = changelog.releases.map { Optional($0.version) }
        let sections = WhatsNew(changelog, locale: english).sections
        if changelog.unreleased.isEmpty {
            #expect(sections.map(\.version) == released)
        } else {
            #expect(sections.map(\.version) == [nil] + released)
            #expect(sections.first?.subsections == changelog.unreleased)
        }
        for section in sections {
            #expect(!section.subsections.isEmpty)
            #expect((section.version == nil) == (section.date == nil))
            for entry in section.subsections.flatMap(\.entries) {
                #expect(!String(WhatsNew.text(entry).characters).isEmpty)
            }
        }
    }

    /// Updates shows What's New on Warzag's row only, and not beside a newer Warzag: What's New lists the running
    /// version's changes, Release Notes the newer one's.
    @Test func warzagsRowInUpdatesOffersWhatsNew() async throws {
        try fixture.saveReadyState()
        let model = fixture.makeModel()
        await model.launch()
        #expect(model.updates.row(.warzag).showsWhatsNew)
        #expect(!model.updates.row(.engine).showsWhatsNew)
        #expect(!model.updates.row(.warframe).showsWhatsNew)

        fixture.appUpdate.set {
            $0.check = .success(.available(FakeAppUpdates.offer))
            $0.prepareError = .unreachable("offline")
        }
        model.updates.checkForUpdates()
        #expect(await eventually { model.updates.warzag == .available(FakeAppUpdates.offer) })
        #expect(!model.updates.row(.warzag).showsWhatsNew)
        #expect(model.updates.row(.warzag).releaseNotes == FakeAppUpdates.offer.releaseNotes)
        model.updates.updateWarzag()
        #expect(!model.updates.row(.warzag).showsWhatsNew, "downloading")
        #expect(await eventually { model.updates.running == nil })
        // The failed download keeps the offer for Update.
        #expect(model.updates.row(.warzag).action == .update)
        #expect(!model.updates.row(.warzag).showsWhatsNew)

        // A check that fails offers nothing.
        fixture.appUpdate.set { $0.check = .failure(.unreachable("offline")) }
        model.updates.checkForUpdates()
        #expect(await eventually { model.updates.warzag == .failed(L10n.updatesUnreachable, offer: nil) })
        #expect(model.updates.row(.warzag).showsWhatsNew)
    }
}
