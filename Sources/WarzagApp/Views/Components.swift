import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WarzagCore

/// A step's or track's status as a symbol, never as colour alone: every glyph carries its text for VoiceOver.
struct StatusGlyph: View {
    let status: StepDisplayStatus
    var size: CGFloat = 15

    var body: some View {
        Group {
            switch status {
            case .active:
                ProgressView()
                    .controlSize(.small)
                    .frame(width: size + 2, height: size + 2)
            default:
                Image(systemName: symbol)
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: size + 2, height: size + 2)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(L10n.status(status))
    }

    private var symbol: String {
        switch status {
        case .done: "checkmark.circle.fill"
        case .active: "circle.dotted"
        case .needsYou: "hand.raised.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .offline: "wifi.slash"
        case .pending: "circle"
        case .skipped: "minus.circle"
        }
    }

    private var tint: Color {
        switch status {
        case .done: .green
        case .active: .accentColor
        case .needsYou: .orange
        case .failed: .red
        case .offline, .skipped: .secondary
        case .pending: Color(nsColor: .tertiaryLabelColor)
        }
    }
}

/// The "DEMO" capsule shown in every screen of a demo run.
struct DemoBadge: View {
    var body: some View {
        Text(L10n.demoBadge)
            .font(.caption.weight(.bold))
            .tracking(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(.white)
            .background(Capsule().fill(Color.purple))
            .accessibilityLabel(L10n.demoBadgeAccessibility)
    }
}

/// A rounded card on the window background, in light and dark mode.
struct CardBackground: ViewModifier {
    var tint: Color?

    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(tint?.opacity(0.55) ?? Color(nsColor: .separatorColor), lineWidth: tint == nil ? 0.5 : 1.5)
            )
    }
}

extension View {
    func card(tint: Color? = nil) -> some View { modifier(CardBackground(tint: tint)) }
}

/// A one-line notice with an optional action, for power warnings, session results and repair results.
struct Banner: View {
    let symbol: String
    let tint: Color
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .accessibilityLabel(actionTitle)
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.dismiss)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.12)))
        .accessibilityElement(children: .contain)
    }
}

/// Warzag's own icon (the app bundle's), large.
struct AppIconView: View {
    var size: CGFloat

    var body: some View {
        Image(nsImage: NSApp?.applicationIconImage ?? NSImage())
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A determinate bar when the fraction is known, an indeterminate one otherwise, with the numbers underneath.
struct ProgressDetail: View {
    let progress: ProgressSnapshot?
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let fraction = progress?.displayFraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let progress, let line = Formatting.progressLine(progress) {
                Text(line)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption ?? L10n.status(.active))
        .accessibilityValue(progress.flatMap { Formatting.accessibilityProgress($0) } ?? "")
    }
}

/// Opens an engine (a Warzag.app game host) with an open panel.
@MainActor
enum EnginePicker {
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.message = L10n.chooseEnginePanelMessage
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
