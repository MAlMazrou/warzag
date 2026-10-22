import SwiftUI
import WarzagCore

/// First launch, before anything is set up or started.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 12)
            AppIconView(size: 112)
            VStack(spacing: 8) {
                Text(L10n.welcomeTitle)
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(L10n.welcomeBody)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            VStack(alignment: .leading, spacing: 10) {
                point("person.crop.circle.badge.checkmark", L10n.welcomeSteam)
                point("arrow.down.circle", L10n.welcomeContent)
                point("cpu", L10n.welcomeTuned)
            }
            .frame(maxWidth: 440, alignment: .leading)
            Button(action: model.getStarted) {
                Text(L10n.getStarted)
                    .frame(minWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel(L10n.getStarted)
            Spacer(minLength: 12)
            Footer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Color.accentColor)
        }
        .font(.body)
    }
}

/// The setup checklist, scrolling.
struct SetupView: View {
    var body: some View {
        ScrollView {
            SetupContent()
        }
    }
}

/// Cards for what needs the player, then one section per track with its steps.
struct SetupContent: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: [SetupTrack: Bool] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if model.isDemo { Banner(symbol: "theatermasks", tint: .purple, text: L10n.demoBanner) }
            ForEach(model.attentionItems) { item in
                AttentionCard(item: item)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            ForEach(stuckTracks, id: \.self) { track in
                FailureCard(track: track)
            }
            ForEach(SetupPresentation.tracks, id: \.self) { track in
                TrackSection(track: track, expanded: binding(for: track))
            }
            Footer()
                .padding(.top, 4)
        }
        .padding(24)
        .animation(.snappy, value: model.attentionItems)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            AppIconView(size: 52)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(L10n.setupTitle).font(.title2.weight(.bold))
                    if model.isDemo { DemoBadge() }
                }
                Text(L10n.setupSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                let fraction = SetupPresentation.overallFraction(model.setup)
                HStack(spacing: 8) {
                    ProgressView(value: fraction)
                        .frame(maxWidth: 220)
                    Text(L10n.setupProgress(Formatting.percent(fraction)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.setupTitle)
                .accessibilityValue(L10n.setupProgress(Formatting.percent(fraction)))
            }
        }
    }

    /// Failed tracks that are not about to retry by themselves get a card with Try Again.
    private var stuckTracks: [SetupTrack] {
        model.failedTracks.filter { SetupMachine.automaticRetryDelay(for: model.setup[$0]) == nil }
    }

    private func binding(for track: SetupTrack) -> Binding<Bool> {
        Binding(
            get: { expanded[track] ?? Self.expandedByDefault(model.trackStatus(track)) },
            set: { expanded[track] = $0 }
        )
    }

    static func expandedByDefault(_ status: StepDisplayStatus) -> Bool {
        switch status {
        case .active, .needsYou, .failed, .offline: true
        case .done, .pending, .skipped: false
        }
    }
}

/// One track: its status line (and progress) and, expanded, every step.
struct TrackSection: View {
    @Environment(AppModel.self) private var model
    let track: SetupTrack
    @Binding var expanded: Bool

    var body: some View {
        let state = model.setup[track]
        let status = model.trackStatus(track)
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    StatusGlyph(status: status, size: 17)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.trackTitle(track)).font(.headline)
                        Text(summary(state, status))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.accessibilityStatus(L10n.trackTitle(track), summary(state, status)))
            .accessibilityHint(L10n.showSteps(L10n.trackTitle(track)))
            .accessibilityAddTraits(.isButton)

            if !expanded, status == .active, let activity = model.activities[track], activity.progress != nil {
                ProgressDetail(progress: activity.progress, caption: nil)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(track.steps, id: \.self) { step in
                        StepRow(step: step)
                    }
                }
                .padding(.leading, 27)
                .transition(.opacity)
            }
        }
        .card(tint: status == .needsYou ? .orange : status == .failed ? .red : nil)
    }

    private func summary(_ state: TrackState, _ status: StepDisplayStatus) -> String {
        switch status {
        case .done:
            if track == .engine { return L10n.engineDone }
            return L10n.status(.done)
        case .skipped:
            return L10n.steamSkipped
        case .failed:
            // The card above says why; a failure that retries by itself says so.
            return SetupMachine.automaticRetryDelay(for: state) == nil ? L10n.status(.failed) : L10n.retryingSoon
        case .needsYou:
            if let action = state.action { return L10n.cardTitle(action) }
            switch model.activities[track]?.attention {
            case .acceptEULAInDEWindow: return L10n.cardTitle(.acceptEULA)
            case .maybeAcceptEULAInDEWindow: return L10n.eulaGuessedTitle
            case nil: return L10n.status(.needsYou)
            }
        case .active:
            return L10n.stepActive(state.step)
        case .offline:
            return L10n.status(.offline)
        case .pending:
            guard !SetupMachine.dependenciesMet(state.step, in: model.setup) else { return L10n.status(.pending) }
            return model.setup.preflight.status == .done ? L10n.waitsForEngine : L10n.waitsForChecks
        }
    }
}

/// One step: its glyph, its name, its status; the running step also shows what it is doing and its numbers.
struct StepRow: View {
    @Environment(AppModel.self) private var model
    let step: SetupStep

    var body: some View {
        let status = model.stepStatus(step)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusGlyph(status: status, size: 13)
                Text(L10n.stepTitle(step))
                    .font(.callout)
                    .foregroundStyle(status == .pending ? .secondary : .primary)
                Spacer()
                Text(L10n.status(status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.accessibilityStatus(L10n.stepTitle(step), L10n.status(status)))
            if status == .active {
                let activity = model.activities[step.track]
                ProgressDetail(progress: activity?.progress,
                               caption: activity.map { L10n.activity($0.detail) } ?? L10n.stepActive(step))
                    .padding(.leading, 23)
            } else if status == .needsYou, let activity = model.activities[step.track] {
                // Waiting for the player in another window: what for, no progress bar.
                Text(L10n.activity(activity.detail))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 23)
            }
        }
    }
}

/// Something only the player can do, with the one button that does it.
struct AttentionCard: View {
    @Environment(AppModel.self) private var model
    let item: AttentionItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 24))
                .foregroundStyle(.orange)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .action(_, .chooseStorage) = item {
                    Text(L10n.storageFree(freeSpace))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                buttons
                    .padding(.top, 4)
            }
        }
        .card(tint: .orange)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private var title: String {
        switch item {
        case .action(_, let action): L10n.cardTitle(action)
        case .live(_, .acceptEULAInDEWindow): L10n.cardTitle(.acceptEULA)
        case .live(_, .maybeAcceptEULAInDEWindow): L10n.eulaGuessedTitle
        }
    }

    private var message: String {
        switch item {
        case .action(_, let action): L10n.cardBody(action)
        case .live(_, .acceptEULAInDEWindow): L10n.eulaLiveBody
        case .live(_, .maybeAcceptEULAInDEWindow): L10n.eulaGuessedBody
        }
    }

    private var symbol: String {
        switch item {
        case .action(_, .moveToApplications): "folder.badge.plus"
        case .action(_, .chooseStorage): "internaldrive"
        case .action(_, .installSteam): "arrow.down.app"
        case .action(_, .signInToSteam): "person.crop.circle.badge.questionmark"
        case .action(_, .addWarframeToLibrary): "books.vertical"
        case .action(_, .acceptEULA), .live(_, .acceptEULAInDEWindow), .live(_, .maybeAcceptEULAInDEWindow):
            "doc.text.magnifyingglass"
        }
    }

    private var freeSpace: String {
        model.services.system.storage(for: model.paths.warframeLibrary).volume?.availableCapacity
            .map { Formatting.bytes($0) } ?? L10n.unknown
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 10) {
            switch item {
            case .action(_, let action):
                primary(L10n.cardPrimary(action)) { perform(action) }
                switch action {
                case .moveToApplications:
                    secondary(L10n.notNow, action: model.skipRelocation)
                case .chooseStorage:
                    secondary(L10n.openStorageSettings, action: model.openStorageSettings)
                case .installSteam, .signInToSteam:
                    if action == .signInToSteam {
                        secondary(L10n.checkAgain) { model.respond(.signInToSteam) }
                    }
                    secondary(L10n.useWarframeAccount) { model.setLoginMode(.warframeAccount) }
                case .addWarframeToLibrary:
                    secondary(L10n.checkAgain) { model.respond(.addWarframeToLibrary) }
                case .acceptEULA:
                    EmptyView()
                }
            case .live(_, .acceptEULAInDEWindow), .live(_, .maybeAcceptEULAInDEWindow):
                primary(L10n.showDEWindow, action: model.showDEWindow)
            }
        }
    }

    /// The primary button acts: approvals let the step go ahead, the others open the window where the player acts.
    private func perform(_ action: UserAction) {
        switch action {
        case .signInToSteam: model.showSteam()
        case .addWarframeToLibrary: model.openSteamStorePage()
        default: model.respond(action)
        }
    }

    /// No Return shortcut: several cards can show at once, and none of them should fire by accident.
    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(title)
    }

    private func secondary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .accessibilityLabel(title)
    }
}

/// A track that failed and is not retrying by itself: one sentence, Try Again, and help.
struct FailureCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let track: SetupTrack

    var body: some View {
        let state = model.setup[track]
        let unsupported = state.failure?.kind == .unsupported
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.red)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(unsupported ? L10n.setupUnsupportedTitle : L10n.trackTitle(track)).font(.headline)
                Text(state.failure?.message ?? L10n.status(.failed))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !unsupported {
                    HStack(spacing: 10) {
                        // Developers only: a chosen bundle skips the checks runtime packs get.
                        if track == .engine, [.fetchManifest, .downloadRuntime].contains(state.step),
                           model.showsDevelopmentEngineChoice {
                            Button(L10n.chooseEngine, action: chooseEngine)
                                .buttonStyle(.borderedProminent)
                                .accessibilityLabel(L10n.chooseEngine)
                            Button(L10n.tryAgain) { model.retry(track) }
                                .accessibilityLabel(L10n.tryAgain)
                        } else {
                            Button(L10n.tryAgain) { model.retry(track) }
                                .buttonStyle(.borderedProminent)
                                .accessibilityLabel(L10n.tryAgain)
                        }
                        Button(L10n.troubleshoot) { openWindow(id: WindowID.troubleshoot) }
                            .accessibilityLabel(L10n.troubleshoot)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .card(tint: .red)
        .accessibilityElement(children: .contain)
    }

    private func chooseEngine() {
        guard let url = EnginePicker.choose() else { return }
        Task { await model.setDevelopmentRuntime(url) }
    }
}

/// The disclaimer under every screen.
struct Footer: View {
    var body: some View {
        Text(L10n.disclaimer)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
    }
}

enum WindowID {
    static let main = "main"
    static let troubleshoot = "troubleshoot"
    static let updates = "updates"
    static let whatsNew = "whats-new"
}
