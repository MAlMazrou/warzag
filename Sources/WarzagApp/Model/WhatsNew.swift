import AppUpdateKit
import Foundation

/// What's New in Warzag in words: what each version changed, newest first, from the changelog this build carries
/// (`AppUpdateServicing.changelog`), with the changes no release has yet first. A release build shows only released
/// sections: it is built from the commit where tools/release/changelog.py's `release` emptied Unreleased.
struct WhatsNew: Equatable {
    /// A version, or the changes no release has yet, with its subsections.
    struct Section: Equatable, Identifiable {
        /// nil for the changes no release has yet.
        var version: String?
        /// "Version 0.1.0", or "Not released yet".
        var title: String
        /// The day of the release, "October 20, 2026"; nil when not released.
        var date: String?
        var subsections: [Changelog.Subsection]

        var id: String { version ?? "" }

        /// The heading as VoiceOver reads it.
        var accessibilityLabel: String { date.map { L10n.whatsNewReleased(title, $0) } ?? title }
    }

    /// Empty when the build carries no changelog or nothing is in it; the window then says so in one sentence.
    var sections: [Section]

    init(sections: [Section] = []) {
        self.sections = sections
    }

    /// `changelog` as the window shows it.
    init(_ changelog: Changelog, locale: Locale = .current) {
        sections = changelog.releases.map { release in
            Section(version: release.version, title: L10n.updatesVersion(release.version),
                    date: Formatting.day(release.date, locale: locale), subsections: release.subsections)
        }
        if !changelog.unreleased.isEmpty {
            sections.insert(Section(title: L10n.whatsNewNotReleased, subsections: changelog.unreleased), at: 0)
        }
    }

    /// The running Warzag's changelog. One that breaks the format counts as none: App/make-app.sh only copies one that
    /// passes tools/release/changelog.py's check.
    static func load(_ appUpdate: any AppUpdateServicing, log: AppLog) -> WhatsNew {
        guard let text = appUpdate.changelog() else { return WhatsNew() }
        do {
            return WhatsNew(try Changelog.parse(text))
        } catch {
            log.write("app: the app's CHANGELOG.md breaks the format: \(error)")
            return WhatsNew()
        }
    }

    /// An entry with its inline Markdown (code spans, emphasis, links) applied; as written when it is not Markdown.
    static func text(_ entry: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: entry, options: options)) ?? AttributedString(entry)
    }
}
