import SwiftUI
import WarzagCore

/// The Updates window (Home's Updates button, App menu › Check for Updates…): one row each for Warzag, the engine and
/// Warframe, then Check for Updates.
struct UpdatesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let updates = model.updates
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(L10n.updatesTitle).font(.title2.weight(.bold))
                if model.isDemo { DemoBadge() }
            }
            Text(L10n.updatesIntro)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let blocker = updates.waitingFor {
                Banner(symbol: "hourglass", tint: .orange, text: L10n.updatesWait(blocker))
            }
            ForEach(UpdatePart.allCases, id: \.self) { part in
                UpdateRowView(part: part, row: updates.row(part))
            }
            HStack(spacing: 8) {
                if updates.checking {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text(L10n.checking)
                } else if let date = model.settings.lastUpdateCheck {
                    Text(L10n.lastChecked(Formatting.relative(date, to: model.services.clock.now)))
                }
                Spacer()
                Button(L10n.checkForUpdates, action: updates.checkForUpdates)
                    .disabled(updates.checking)
                    .accessibilityLabel(L10n.checkForUpdates)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
        .task { updates.windowOpened() }
    }
}

/// One part: its symbol, its name and version, the status with a glyph, its progress while it updates, and its button.
private struct UpdateRowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let part: UpdatePart
    let row: UpdateRow

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.title).font(.headline)
                        if let detail = row.detail {
                            Text(detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        glyph
                        Text(row.status)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.accessibilityStatus(row.title, row.status))
                .accessibilityValue(row.detail ?? "")
                if row.working {
                    ProgressDetail(progress: row.progress, caption: nil)
                }
                if row.showsDEWindow || row.showsWhatsNew || row.releaseNotes != nil {
                    HStack(spacing: 10) {
                        if row.showsDEWindow {
                            Button(L10n.showDEWindow, action: model.showDEWindow)
                                .accessibilityLabel(L10n.showDEWindow)
                        }
                        if row.showsWhatsNew {
                            Button(L10n.whatsNew) { openWindow(id: WindowID.whatsNew) }
                                .accessibilityLabel(L10n.whatsNewTitle)
                        }
                        if let notes = row.releaseNotes {
                            Button(L10n.releaseNotes) { model.services.system.open(notes) }
                                .accessibilityLabel(L10n.releaseNotes)
                        }
                    }
                    .controlSize(.small)
                }
            }
            Spacer(minLength: 8)
            action
        }
        .card(tint: row.showsDEWindow ? .orange : row.tone == .problem ? .red : nil)
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        switch part {
        case .warzag: "macwindow"
        case .engine: "cpu"
        case .warframe: "gamecontroller"
        }
    }

    /// Never colour alone: the status text says the same.
    @ViewBuilder private var glyph: some View {
        if row.working {
            ProgressView().controlSize(.mini)
        } else {
            let (name, tint): (String, Color) = switch row.tone {
            case .upToDate: ("checkmark.circle.fill", .green)
            case .available: ("arrow.down.circle.fill", .accentColor)
            case .problem: row.showsDEWindow ? ("hand.raised.circle.fill", .orange) : ("exclamationmark.triangle.fill", .red)
            case .neutral: ("info.circle", .secondary)
            }
            Image(systemName: name)
                .foregroundStyle(tint)
        }
    }

    @ViewBuilder private var action: some View {
        let updates = model.updates
        switch row.action {
        case .update?:
            Button(L10n.update) {
                if part == .warzag { updates.updateWarzag() } else { updates.updateEngine() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!row.actionEnabled)
            .accessibilityLabel(L10n.updateAccessibility(row.title))
        case .updateNow?:
            Button(L10n.updateNow, action: updates.updateWarframe)
                .disabled(!row.actionEnabled)
                .accessibilityLabel(L10n.updateAccessibility(row.title))
        case .setUpAgain?:
            Button(L10n.tryAgain, action: updates.setUpPrefixAgain)
                .disabled(!row.actionEnabled)
                .accessibilityLabel(L10n.tryAgain)
        case .cancel?:
            Button(L10n.cancelUpdate, action: updates.cancelWarframeUpdate)
                .accessibilityLabel(L10n.cancelWarframeUpdateAccessibility)
        case .showCopy?:
            Button(L10n.showInFinder, action: updates.showWarzagCopy)
                .accessibilityLabel(L10n.showWarzagCopyAccessibility)
        case nil:
            EmptyView()
        }
    }
}
