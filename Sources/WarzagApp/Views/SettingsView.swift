import AppKit
import ProfileKit
import SwiftUI
import UniformTypeIdentifiers
import WarzagCore

/// Settings. "Advanced…" adds the performance HUD; Option-clicking it also shows the development engine, as does a run
/// started with WARZAG_DEV_RUNTIME (`AppModel.showsDevelopmentEngineChoice`).
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showsAdvanced = false

    var body: some View {
        Form {
            Section(L10n.settingsGraphics) {
                Picker(L10n.settingsGraphics, selection: graphics) {
                    ForEach(GraphicsChoice.allCases, id: \.self) { choice in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.graphicsName(choice)
                                + (choice == model.recommendedGraphics ? " — " + L10n.recommended : ""))
                            Text(L10n.graphicsDescription(
                                L10n.upscalingName(choice), String(GraphicsTuning.frameRateCap(choice, tier: model.tier))))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(choice)
                        .accessibilityLabel(L10n.graphicsName(choice))
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .accessibilityLabel(L10n.settingsGraphics)
                Text(L10n.graphicsFootnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L10n.settingsPlaying) {
                // No hint: VoiceOver reads the footnote right after the toggle, as for the graphics footnote.
                Toggle(L10n.hideWhilePlaying, isOn: hideWhilePlaying)
                    .accessibilityLabel(L10n.hideWhilePlaying)
                Text(L10n.hideWhilePlayingNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L10n.settingsSteam) {
                Toggle(L10n.signInWithSteam, isOn: useSteam)
                    .disabled(model.play != .idle)
                    .accessibilityLabel(L10n.signInWithSteam)
                Text(L10n.signInWithSteamNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(L10n.keepSteamOutOfSight, isOn: keepSteamOutOfSight)
                    .disabled(!model.usesSteam)
                    .accessibilityLabel(L10n.keepSteamOutOfSight)
                Text(L10n.keepSteamOutOfSightNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L10n.settingsUpdates) {
                // No hint: VoiceOver reads the footnote right after the toggle.
                Toggle(L10n.checkForUpdatesAutomatically, isOn: checkForUpdatesAutomatically)
                    .accessibilityLabel(L10n.checkForUpdatesAutomatically)
                Text(L10n.checkForUpdatesAutomaticallyNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showsAdvanced {
                Section(L10n.settingsAdvanced) {
                    Toggle(L10n.performanceHUD, isOn: performanceHUD)
                        .accessibilityLabel(L10n.performanceHUD)
                    if model.showsDevelopmentEngineChoice {
                        developmentEngine
                    }
                }
            }

            HStack {
                if model.isDemo { DemoBadge() }
                Spacer()
                Button(L10n.advancedButton) {
                    // Option-click: the developer settings too, remembered by the model for this run (the engine card's
                    // Choose Engine… follows it).
                    if NSEvent.modifierFlags.contains(.option) { model.revealDeveloperSettings() }
                    showsAdvanced = true
                }
                .disabled(showsAdvanced && model.developerSettingsRevealed)
                .accessibilityLabel(L10n.advancedButton)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var developmentEngine: some View {
        LabeledContent(L10n.developmentEngine) {
            VStack(alignment: .trailing, spacing: 4) {
                if let path = model.options.developmentRuntime?.plainPath {
                    Text(path).font(.caption).textSelection(.enabled)
                    Text(L10n.developmentEngineFromEnvironment).font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(model.settings.developmentRuntimePath ?? L10n.developmentEngineNone)
                        .font(.caption)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    HStack {
                        Button(L10n.choose) {
                            guard let url = EnginePicker.choose() else { return }
                            Task { await model.setDevelopmentRuntime(url) }
                        }
                        .accessibilityLabel(L10n.chooseEngine)
                        Button(L10n.clear) { Task { await model.setDevelopmentRuntime(nil) } }
                            .disabled(model.settings.developmentRuntimePath == nil)
                            .accessibilityLabel(L10n.clear)
                    }
                    .disabled(model.play != .idle)
                }
            }
        }
    }

    private var graphics: Binding<GraphicsChoice> {
        Binding(get: { model.graphics }, set: { model.setGraphics($0) })
    }

    private var useSteam: Binding<Bool> {
        Binding(get: { model.usesSteam }, set: { model.setUseSteam($0) })
    }

    private var keepSteamOutOfSight: Binding<Bool> {
        Binding(get: { model.settings.keepSteamOutOfSight }, set: { model.setKeepSteamOutOfSight($0) })
    }

    private var performanceHUD: Binding<Bool> {
        Binding(get: { model.settings.performanceHUD }, set: { model.setPerformanceHUD($0) })
    }

    private var hideWhilePlaying: Binding<Bool> {
        Binding(get: { model.settings.hideWhilePlaying }, set: { model.setHideWhilePlaying($0) })
    }

    private var checkForUpdatesAutomatically: Binding<Bool> {
        Binding(get: { model.settings.checkForUpdatesAutomatically },
                set: { model.setCheckForUpdatesAutomatically($0) })
    }
}

/// Help › Troubleshoot: the doctor's checks, Repair, the logs, and a redacted diagnostics export.
struct TroubleshootView: View {
    @Environment(AppModel.self) private var model
    @State private var exportResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(L10n.troubleshootTitle).font(.title2.weight(.bold))
                if model.isDemo { DemoBadge() }
            }
            Text(L10n.troubleshootIntro)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // The checks take the room the window has (and scroll when it is small); the buttons below always show.
            VStack(alignment: .leading, spacing: 6) {
                switch model.doctor {
                case .idle, .running:
                    ProgressView(L10n.checking)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .finished(let checks, let date):
                    List(checks) { check in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            StatusGlyph(status: check.passed ? .done : .failed, size: 13)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(check.title)
                                Text(check.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .textSelection(.enabled)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(L10n.accessibilityStatus(
                            check.title, check.passed ? L10n.passed : L10n.failedCheck))
                    }
                    .listStyle(.bordered)
                    Text(L10n.lastChecked(Formatting.relative(date, to: Date())))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 160, maxHeight: .infinity)

            if case .failed(let message) = model.repair {
                Banner(symbol: "wrench.and.screwdriver", tint: .red, text: message)
            } else if case .succeeded = model.repair {
                Banner(symbol: "wrench.and.screwdriver", tint: .green, text: L10n.repairDone)
            }
            if let exportResult {
                Banner(symbol: "doc.text", tint: .accentColor, text: exportResult)
            }

            HStack(spacing: 10) {
                Button(L10n.checkAgain) { Task { await model.runDoctor() } }
                    .disabled(model.doctor == .running)
                    .accessibilityLabel(L10n.checkAgain)
                Button(model.repair == .running ? L10n.repairing : L10n.repairWindowsSetup) {
                    Task { await model.repairNow() }
                }
                .disabled(!model.canRepair)
                .accessibilityLabel(L10n.repairWindowsSetup)
                Spacer()
                Button(L10n.openLogsFolder, action: model.showLogs)
                    .accessibilityLabel(L10n.openLogsFolder)
                Button(L10n.exportDiagnostics, action: export)
                    .accessibilityLabel(L10n.exportDiagnostics)
            }
            Text(L10n.diagnosticsPrivacy)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 440)
        .task { await model.runDoctor() }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Warzag-Diagnostics-\(Date().formatted(.iso8601.year().month().day())).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await model.exportDiagnostics(to: url)
                exportResult = L10n.diagnosticsSaved
            } catch {
                exportResult = L10n.diagnosticsFailed
            }
        }
    }
}
