import AppUpdateKit
import SwiftUI

/// Help › What's New in Warzag, and What's New on Warzag's row in Updates. The changes scroll.
struct WhatsNewView: View {
    var body: some View {
        ScrollView {
            WhatsNewContent()
        }
        .frame(minWidth: 480, minHeight: 360)
    }
}

/// The title, then a card per version, newest first.
struct WhatsNewContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sections = model.whatsNew.sections
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(L10n.whatsNewTitle).font(.title2.weight(.bold))
                if model.isDemo { DemoBadge() }
            }
            Text(sections.isEmpty ? L10n.whatsNewNone : L10n.whatsNewIntro)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(sections) { section in
                WhatsNewSectionView(section: section)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A version and its date, then its changes under Major, Minor and Bug fixes.
private struct WhatsNewSectionView: View {
    let section: WhatsNew.Section

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(section.title).font(.title3.weight(.semibold))
                if let date = section.date {
                    Text(date)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(section.accessibilityLabel)
            .accessibilityAddTraits(.isHeader)
            ForEach(section.subsections, id: \.kind) { subsection in
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.changeKind(subsection.kind))
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(Array(subsection.entries.enumerated()), id: \.offset) { _, entry in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(L10n.whatsNewBullet)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text(WhatsNew.text(entry))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .card()
        .accessibilityElement(children: .contain)
    }
}
