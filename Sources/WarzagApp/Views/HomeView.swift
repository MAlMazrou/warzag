import AppKit
import GameKit
import ProfileKit
import SwiftUI
import WarzagCore

/// Ready to play: the big Play button, what will happen, warnings before Play, the way to fix things, and Updates.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                if model.isDemo { Banner(symbol: "theatermasks", tint: .purple, text: L10n.demoBanner) }
                ForEach(Array(model.powerAdvice.enumerated()), id: \.offset) { _, advice in
                    powerBanner(advice)
                }
                if model.motionBlur == .on {
                    Banner(symbol: "wind", tint: .orange, text: L10n.motionBlurOn)
                }
                if let session = model.lastSession { sessionBanner(session) }
                repairBanner
            }
            .padding([.horizontal, .top], 20)

            Spacer(minLength: 16)
            VStack(spacing: 14) {
                AppIconView(size: 104)
                HStack(spacing: 8) {
                    Text(L10n.trackTitle(.game)).font(.largeTitle.weight(.bold))
                    if model.isDemo { DemoBadge() }
                }
                if let status = model.homeStatus {
                    Text(status)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                SteamSection()
                    .padding(.top, 4)
                PlayButton()
                    .padding(.top, 6)
            }
            .padding(.horizontal, 24)
            Spacer(minLength: 16)

            ViewThatFits(in: .horizontal) {
                homeButtons.labelStyle(.titleAndIcon)
                homeButtons.labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .padding(.bottom, 10)
            Footer()
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.refreshHome() }
    }

    /// Repair, logs, Troubleshoot, Updates and What's New; the caller picks titles or icons only.
    private var homeButtons: some View {
        HStack(spacing: 10) {
            Button {
                Task { await model.repairNow() }
            } label: {
                Label(model.repair == .running ? L10n.repairing : L10n.repair, systemImage: "wrench.and.screwdriver")
            }
            .disabled(!model.canRepair)
            .accessibilityLabel(L10n.repair)
            .help(L10n.repair)
            Button(action: model.showLogs) {
                Label(L10n.showLogs, systemImage: "doc.text.magnifyingglass")
            }
            .accessibilityLabel(L10n.showLogs)
            .help(L10n.showLogs)
            Button {
                openWindow(id: WindowID.troubleshoot)
            } label: {
                Label(L10n.troubleshoot, systemImage: "stethoscope")
            }
            .accessibilityLabel(L10n.troubleshoot)
            .help(L10n.troubleshoot)
            // A newer Warzag or engine found by a check: a small badge, never a banner.
            Button {
                openWindow(id: WindowID.updates)
            } label: {
                Label(L10n.updates, systemImage: "arrow.down.circle")
            }
            .overlay(alignment: .topTrailing) {
                if model.updates.updateAvailable { UpdateBadge() }
            }
            .accessibilityLabel(model.updates.updateAvailable ? L10n.updatesAvailableAccessibility : L10n.updates)
            .help(L10n.updates)
            Button {
                openWindow(id: WindowID.whatsNew)
            } label: {
                Label(L10n.whatsNew, systemImage: "sparkles")
            }
            .accessibilityLabel(L10n.whatsNewTitle)
            .help(L10n.whatsNewTitle)
        }
    }

    private func powerBanner(_ advice: PowerAdvice) -> some View {
        let symbol = switch advice.kind {
        case .lowPowerMode: "battery.25percent"
        case .battery: "powerplug"
        case .thermal: "thermometer.high"
        case .weakCharger: "bolt.trianglebadge.exclamationmark"
        case .lowBattery: "battery.0percent"
        }
        // Only Low Power Mode is a setting the player can change from here.
        let model = model
        let action: (() -> Void)? = advice.kind == .lowPowerMode ? { model.openBatterySettings() } : nil
        return Banner(symbol: symbol, tint: .orange, text: L10n.power(advice),
                      actionTitle: advice.kind == .lowPowerMode ? L10n.batterySettings : nil, action: action)
    }

    @ViewBuilder private func sessionBanner(_ session: SessionResult) -> some View {
        if let failure = session.failure {
            Banner(symbol: "exclamationmark.triangle.fill", tint: .red, text: failure,
                   onDismiss: model.dismissSessionResult)
        } else if !session.problems.isEmpty {
            Banner(symbol: "exclamationmark.triangle.fill", tint: .orange,
                   text: L10n.sessionProblems + " " + session.problems.map(L10n.signal).joined(separator: " "),
                   actionTitle: L10n.troubleshoot, action: { openWindow(id: WindowID.troubleshoot) },
                   onDismiss: model.dismissSessionResult)
        }
        // A session that ended normally needs no message.
    }

    @ViewBuilder private var repairBanner: some View {
        switch model.repair {
        case .succeeded:
            Banner(symbol: "wrench.and.screwdriver", tint: .green, text: L10n.repairDone)
        case .failed(let message):
            Banner(symbol: "wrench.and.screwdriver", tint: .red, text: message,
                   actionTitle: L10n.troubleshoot, action: { openWindow(id: WindowID.troubleshoot) })
        case .idle, .running:
            EmptyView()
        }
    }
}

/// The small dot on Home's Updates button (its accessibility label says it instead).
private struct UpdateBadge: View {
    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 9, height: 9)
            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
            .offset(x: 3, y: -3)
            .accessibilityHidden(true)
    }
}

/// Play, or what Play is doing before the game appears (Steam, DE's update, opening the game), or the update Play waits
/// for.
struct PlayButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            switch model.play {
            case .idle:
                if let part = model.updates.running {
                    updating(part)
                } else {
                    Button(action: model.playGame) {
                        Label(L10n.play, systemImage: "play.fill")
                            .font(.title2.weight(.semibold))
                            .frame(minWidth: 200, minHeight: 34)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.extraLarge)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canPlay)
                    .accessibilityLabel(L10n.playAccessibility)
                }
            case .updating(let activity):
                busy(L10n.playUpdating, progress: activity?.progress)
            case .needsEULA(let guessed):
                eula(guessed: guessed)
            case .preparing:
                busy(L10n.playPreparing, progress: nil)
            case .waitingForSteam:
                VStack(spacing: 8) {
                    busy(L10n.playWaitingForSteam, progress: nil)
                    Button(L10n.cardPrimary(.signInToSteam), action: model.showSteam)
                        .accessibilityLabel(L10n.cardPrimary(.signInToSteam))
                }
            case .launching, .running, .finishing:
                busy(L10n.playLaunching, progress: nil)
            }
        }
    }

    private func busy(_ title: String, progress: ProgressSnapshot?) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.headline)
            ProgressDetail(progress: progress, caption: nil)
                .frame(width: 300)
        }
        .accessibilityElement(children: .combine)
    }

    /// DE's updated EULA waits in DE's window, during the update before Play or Updates' own.
    private func eula(guessed: Bool) -> some View {
        VStack(spacing: 8) {
            busy(L10n.playUpdating, progress: nil)
            Banner(symbol: "doc.text.magnifyingglass", tint: .orange,
                   text: guessed ? L10n.playEULAGuessed : L10n.playEULA,
                   actionTitle: L10n.showDEWindow, action: model.showDEWindow)
                .frame(maxWidth: 460)
        }
    }

    /// An update runs (Updates): Play waits, and says for what.
    @ViewBuilder private func updating(_ part: UpdatePart) -> some View {
        if part == .warframe, case .needsEULA(let guessed) = model.updates.warframe {
            eula(guessed: guessed)
        } else {
            busy(L10n.homeUpdating(part), progress: model.updates.progress(of: part))
        }
    }
}

/// While the game runs: how long, what Warframe said, and the ways out.
struct PlayingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            AppIconView(size: 88)
            HStack(spacing: 8) {
                Text(model.play == .finishing ? L10n.playingFinishing : L10n.playingTitle)
                    .font(.title.weight(.bold))
                if model.isDemo { DemoBadge() }
            }
            if case .running(let session) = model.play {
                TimelineView(.periodic(from: session.startedAt, by: 1)) { context in
                    VStack(spacing: 14) {
                        Text(L10n.playingElapsed(Formatting.elapsed(context.date.timeIntervalSince(session.startedAt))))
                            .font(.title3.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if let signal = session.signals.last {
                            Label(L10n.signal(signal), systemImage: signal.isError ? "exclamationmark.triangle" : "checkmark.seal")
                                .foregroundStyle(signal.isError ? .orange : .secondary)
                        } else {
                            Text(L10n.playingStarting).foregroundStyle(.secondary)
                        }
                        controls(session, now: context.date)
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Footer().padding(.bottom, 16)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func controls(_ session: GameSession, now: Date) -> some View {
        HStack(spacing: 12) {
            Button(L10n.returnToGame, action: model.returnToGame)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel(L10n.returnToGame)
            Button(L10n.quitGame, action: model.quitGame)
                .controlSize(.large)
                .disabled(session.quitRequestedAt != nil)
                .accessibilityLabel(L10n.quitGame)
        }
        if session.quitRequestedAt != nil {
            if model.canForceQuit(at: now) {
                VStack(spacing: 8) {
                    Text(L10n.forceQuitHint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    Button(L10n.forceQuit, role: .destructive, action: model.forceQuitGame)
                        .accessibilityLabel(L10n.forceQuit)
                }
            } else {
                Text(L10n.quitting).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// The window's content for the current phase.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.screen {
            case .welcome: WelcomeView()
            case .setup: SetupView()
            case .home: HomeView()
            case .playing: PlayingView()
            }
        }
        .animation(.smooth, value: model.screen)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Sign in with Steam, and while it is on, the Steam account: picture, profile name and Log In / Log Out. Steam's other
/// windows stay out of sight; Log In shows only Steam's own sign-in window.
private struct SteamSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            Toggle(L10n.signInWithSteam, isOn: useSteam)
                .toggleStyle(.switch)
                .disabled(model.play != .idle)
                .accessibilityLabel(L10n.signInWithSteam)
            if model.usesSteam, let card = model.steamCard {
                SteamCardView(card: card, busy: model.steamLoggingIn, canLogOut: model.play == .idle,
                              logIn: model.steamLogIn, logOut: model.steamLogOut)
            }
        }
        .frame(maxWidth: 420)
        .task { await model.watchSteamCard() }
    }

    private var useSteam: Binding<Bool> {
        Binding(get: { model.usesSteam }, set: { model.setUseSteam($0) })
    }
}

private struct SteamCardView: View {
    let card: SteamCard
    let busy: Bool
    let canLogOut: Bool
    let logIn: () -> Void
    let logOut: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            picture
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            action
        }
        .padding(12)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var picture: some View {
        if card.state == .signedIn, let data = card.avatar, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 40, height: 40)
                .clipShape(Circle())
                .accessibilityHidden(true)
        } else {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)
        }
    }

    private var title: String {
        switch card.state {
        case .notInstalled: L10n.steamCardNotInstalled
        case .off: L10n.steamCardOff
        case .starting: L10n.steamCardStarting
        case .signingIn: L10n.steamCardSigningIn
        case .signedOut: L10n.steamCardSignedOut
        case .signedOutElsewhere: L10n.steamCardSignedOutElsewhere
        case .signedIn: card.name ?? L10n.steamCardSignedIn
        }
    }

    private var subtitle: String? {
        switch card.state {
        case .notInstalled: L10n.steamCardNotInstalledNote
        case .off, .starting, .signingIn: nil
        case .signedOut: busy ? L10n.steamCardSignInWindowNote : L10n.steamCardSignedOutNote
        case .signedOutElsewhere: L10n.steamCardSignedOutElsewhereNote
        case .signedIn: card.name == nil ? nil : L10n.steamCardSignedIn
        }
    }

    @ViewBuilder private var action: some View {
        switch card.state {
        case .notInstalled:
            EmptyView()
        case .starting, .signingIn:
            ProgressView().controlSize(.small)
        case .off, .signedOut:
            Button(action: logIn) { Label(L10n.steamLogIn, systemImage: "person.badge.key") }
                .buttonStyle(.bordered)
                .accessibilityLabel(L10n.steamLogIn)
        case .signedOutElsewhere:
            Button(action: logIn) { Label(L10n.steamSignInAgain, systemImage: "arrow.clockwise") }
                .buttonStyle(.bordered)
                .accessibilityLabel(L10n.steamSignInAgain)
        case .signedIn:
            Button(action: logOut) { Label(L10n.steamLogOut, systemImage: "rectangle.portrait.and.arrow.right") }
                .buttonStyle(.bordered)
                .disabled(!canLogOut)
                .help(canLogOut ? "" : L10n.steamQuitWarframeFirst)
                .accessibilityLabel(L10n.steamLogOut)
        }
    }
}
