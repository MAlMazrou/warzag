import Foundation
import GameKit
import Observation
import ProfileKit
import WarzagCore

/// Play's progress, from the button press until the game has exited.
enum PlayState: Equatable, Sendable {
    case idle
    /// Pre-launch checks; starts Steam if it is not running.
    case preparing
    /// Steam is running but no account is signed in.
    case waitingForSteam
    /// DE's launcher is updating the game.
    case updating(TrackActivity?)
    /// DE's launcher waits for the player to accept a new EULA in its window. `guessed`: inferred from the launcher
    /// going quiet at startup (GameKit's `mayNeedEULA`), not confirmed.
    case needsEULA(guessed: Bool)
    case launching
    case running(GameSession)
    /// Warframe has exited; Wine is shutting down.
    case finishing

    /// The game is running or shutting down (the Playing screen).
    var isInSession: Bool {
        switch self {
        case .running, .finishing: true
        default: false
        }
    }

    /// The game is not open yet. Quitting Warzag cancels Play only in this phase: DE's launcher is Warzag's child
    /// process, while an opening or running game is a separate app.
    var isBeforeLaunch: Bool {
        switch self {
        case .preparing, .waitingForSteam, .updating, .needsEULA: true
        case .idle, .launching, .running, .finishing: false
        }
    }
}

struct GameSession: Equatable, Sendable {
    var processIdentifier: Int32
    var startedAt: Date
    /// Signals parsed from EE.log so far; never the player's name.
    var signals: [GameSignal] = []
    /// When Quit was pressed; Force Quit is offered 10 seconds later.
    var quitRequestedAt: Date?
}

/// How the last Play ended, for Home's banner.
struct SessionResult: Equatable, Sendable {
    var seconds: TimeInterval?
    /// Error signals from EE.log.
    var problems: [GameSignal]
    /// Why Play failed to start or stopped early.
    var failure: String?
}

enum DoctorState: Equatable, Sendable {
    case idle
    case running
    case finished([HealthCheck], at: Date)
}

enum RepairState: Equatable, Sendable {
    case idle
    case running
    case succeeded(at: Date)
    case failed(String)
}

/// App state for the views. Drives `SetupOrchestrator` with `AppStepPerformer`, persists setup through
/// `SetupStateStore`, runs Play, Repair and the doctor, and owns `UpdatesModel`. Long work runs off the main actor;
/// this class only applies the results.
@MainActor
@Observable
final class AppModel {
    enum Screen: Equatable {
        /// First launch, before Get Started.
        case welcome
        case setup
        case home
        case playing
    }

    // MARK: Configuration

    let options: LaunchOptions
    let paths: WarzagPaths
    let services: AppServices
    let log: AppLog
    @ObservationIgnored private let fileSystem: any FileSystem
    @ObservationIgnored private let settingsStore: AppSettingsStore
    @ObservationIgnored let settingsBox: SettingsBox
    @ObservationIgnored private let activitySink = ActivitySink()
    /// Interval for re-checking waiting steps (Steam sign-in, network, power); nil disables it so tests call `tick()`.
    @ObservationIgnored var heartbeatInterval: Duration? = .seconds(3)
    /// Called once per milestone ("welcome", "setup", "needs-you-<id>", "downloading", "home", "playing"); demo mode
    /// snapshots the window there.
    @ObservationIgnored var onMilestone: ((String) -> Void)?
    /// Demo mode presses Get Started after this delay, so smoke tests run unattended.
    @ObservationIgnored var demoAutoStart: Duration? = .seconds(2)
    /// WARZAG_DEMO_AUTOPLAY: demo mode presses Play once at Home, then Quit a few seconds later.
    @ObservationIgnored var demoAutoPlay = false
    @ObservationIgnored private var demoAutoPlayed = false

    // MARK: State

    private(set) var settings: AppSettings
    private(set) var hardware: HardwareProfile
    private(set) var setup: SetupState
    private(set) var activities: [SetupTrack: TrackActivity] = [:]
    /// Get Started was pressed, in this or an earlier launch. Until then only the read-only checks run.
    private(set) var welcomed: Bool
    @ObservationIgnored let startGate: StartGate
    private(set) var powerAdvice: [PowerAdvice] = []
    /// Warframe's motion blur as last recorded in EE.cfg. Home shows a notice when it is on because it can smear under
    /// Warzag; Warzag cannot turn it off, since the game applies its per-account settings at startup.
    private(set) var motionBlur = MotionBlurSetting.unknown
    private(set) var content: ContentSummary?
    /// `refreshHome` is reading the game's state.
    private(set) var checkingContent = false
    private(set) var runtime: RuntimeSummary?
    private(set) var play = PlayState.idle
    private(set) var lastSession: SessionResult?
    private(set) var doctor = DoctorState.idle
    private(set) var repair = RepairState.idle
    /// Option-click on Settings › Advanced… showed the developer settings (this run only).
    private(set) var developerSettingsRevealed = false
    /// Hide Warzag while playing is in effect: Warzag is an accessory app (out of the Dock, windows stay open).
    private(set) var hiddenWhilePlaying = false
    @ObservationIgnored private(set) lazy var updates = UpdatesModel(app: self)
    /// What's New in Warzag, read from this build's changelog when the window first shows it.
    @ObservationIgnored private(set) lazy var whatsNew = WhatsNew.load(services.appUpdate, log: log)

    @ObservationIgnored private var orchestrator: SetupOrchestrator?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var playWork: Task<Result<PlaySummary, any Error>, Never>?
    /// Keeps the game's window in front for its first minute (`SystemServicing.keepGameInFront`).
    @ObservationIgnored private var focusWork: Task<Void, Never>?
    /// Incremented per session, so late events from an earlier session are ignored.
    @ObservationIgnored private var focusSession = 0
    /// GameFocusKeeper reported `.finished`. Until then Warzag stays a regular app, because taking the front back from
    /// Steam activates Warzag first.
    @ObservationIgnored private(set) var focusWatchOver = false
    @ObservationIgnored private(set) var lastFocusEvent: GameFocusEvent?
    /// Set from AppDelegate's activation notifications.
    @ObservationIgnored private var appIsActive = false
    @ObservationIgnored private var background: [Task<Void, Never>] = []
    @ObservationIgnored private var estimators: [SetupTrack: RateEstimator] = [:]
    @ObservationIgnored private var attentionShown: Set<String> = []
    @ObservationIgnored private var milestones: Set<String> = []
    @ObservationIgnored private var keptAwake: KeepAwakeReason?
    @ObservationIgnored private var lastPowerCheck = Date.distantPast
    @ObservationIgnored private var motionBlurReads = 0
    @ObservationIgnored private var contentReads = 0
    @ObservationIgnored private var launched = false

    /// `settings` is shared with the services; `make(options:)` loads it from State/app-settings.json.
    init(options: LaunchOptions, services: AppServices, settings: SettingsBox, fileSystem: any FileSystem, log: AppLog) {
        self.options = options
        self.services = services
        self.fileSystem = fileSystem
        self.log = log
        paths = WarzagPaths(home: options.home)
        settingsStore = AppSettingsStore(paths: paths, fileSystem: fileSystem)
        settingsBox = settings
        self.settings = settings.settings
        hardware = services.system.hardware()
        let saved = SetupStateStore(paths: paths, fileSystem: fileSystem).load()
        // Progress on the engine, Steam or game track means Get Started was pressed, whatever the settings say. Steps
        // waiting at the start gate are saved as running at their first step, and Settings can skip the Steam track
        // before Get Started; neither counts as progress.
        let progressed = saved.map { state in
            [SetupTrack.engine, .steam, .game].contains { track in
                state[track].step != track.steps[0] || ![.pending, .running, .skipped].contains(state[track].status)
            }
        }
        let started = settings.settings.welcomed || progressed == true
        welcomed = started
        startGate = StartGate(open: started)
        setup = SetupMachine.resumed(saved ?? .initial)
    }

    // MARK: Derived

    var screen: Screen {
        if play.isInSession { return .playing }
        if setup.isReadyToPlay { return .home }
        return welcomed ? .setup : .welcome
    }

    var tier: PerformanceTier { hardware.tierClassification.tier }
    var graphics: GraphicsChoice { settings.graphics(for: tier) }
    var recommendedGraphics: GraphicsChoice { .recommended(for: tier) }
    var attentionItems: [AttentionItem] { SetupPresentation.attentionItems(in: setup, activities: activities) }
    var failedTracks: [SetupTrack] { SetupPresentation.failedTracks(in: setup) }
    var isDemo: Bool { services.isDemo }

    func stepStatus(_ step: SetupStep) -> StepDisplayStatus {
        SetupPresentation.status(of: step, in: setup, activity: activities[step.track])
    }

    func trackStatus(_ track: SetupTrack) -> StepDisplayStatus {
        SetupPresentation.status(of: track, in: setup, activity: activities[track])
    }

    var canPlay: Bool {
        setup.isReadyToPlay && play == .idle && repair != .running && updates.running == nil
            && !updates.prefixNeedsSetUp
    }

    var canRepair: Bool { repair != .running && play == .idle && updates.running == nil }

    /// A setup step is running after Get Started; updates wait for it.
    var setupIsWorking: Bool {
        welcomed && !setup.isReadyToPlay && SetupTrack.allCases.contains { setup[$0].status == .running }
    }

    // MARK: Launch and shutdown

    /// Called once at launch: resumes setup (or waits behind the Welcome screen) and starts the monitors.
    func launch() async {
        guard !launched else { return }
        launched = true
        let openedOnHome = setup.isReadyToPlay
        let sink = activitySink
        background.append(Task { [weak self] in
            for await update in sink.updates { self?.apply(update) }
        })
        refreshPower(force: true)
        if let heartbeatInterval {
            let clock = services.clock
            background.append(Task { [weak self] in
                while !Task.isCancelled {
                    do { try await clock.sleep(for: heartbeatInterval) } catch { return }
                    guard let self else { return }
                    await self.tick()
                }
            })
        }
        let network = services.system.networkAvailability()
        background.append(Task { [weak self] in
            for await available in network where available { self?.networkCameBack() }
        })
        reachedMilestone(screen == .welcome ? "welcome" : "setup")
        // Read-only checks run behind the Welcome screen; everything else waits at the StartGate for Get Started.
        await beginSetup()
        if !welcomed, isDemo, let delay = demoAutoStart {
            let clock = services.clock
            background.append(Task { [weak self] in
                do { try await clock.sleep(for: delay) } catch { return }
                self?.getStarted()
            })
        }
        if setup.isReadyToPlay { refreshHome() }
        // Finishes an interrupted engine update, then runs the automatic check; during setup the heartbeat runs it.
        if openedOnHome { updates.launch() }
    }

    /// Get Started: from now on setup may download and start things. Persisted across launches.
    func getStarted() {
        guard !welcomed else { return }
        welcomed = true
        settings.welcomed = true
        saveSettings()
        startGate.open()
        log.write("setup: get started")
        afterChange()
    }

    func beginSetup() async {
        guard orchestrator == nil else { return }
        var performer = AppStepPerformer(services: services, paths: paths, activity: activitySink, log: log)
        performer.gate = startGate
        let orchestrator = SetupOrchestrator(store: SetupStateStore(paths: paths, fileSystem: fileSystem),
                                             performer: performer, clock: services.clock)
        self.orchestrator = orchestrator
        setupChanged(await orchestrator.state)
        observation?.cancel()
        observation = Task { [weak self] in
            let updates = await orchestrator.updates()
            for await state in updates { self?.setupChanged(state) }
        }
        await orchestrator.start()
    }

    /// App termination: stops setup, DE's launcher (for setup, Play or Updates) and downloads; a game that is opening
    /// or running is left alone. Returns after the cancelled steps have cleaned up (child processes, `wineserver -k`
    /// after `msiexec /a`, Steam's disk image); the termination watchdog bounds the wait.
    func shutdown() async {
        background.forEach { $0.cancel() }
        background.removeAll()
        observation?.cancel()
        let steps = await orchestrator?.shutdown() ?? []
        // Before awaiting the steps: a downloadContent step waits for DE's launcher, which only this call ends.
        await services.game.cancelContentRun()
        await updates.shutdown()
        if let playWork, play.isBeforeLaunch {
            playWork.cancel()
            _ = await playWork.value
        }
        for step in steps { await step.value }
        // The game keeps running; only the focus keeper stops.
        focusWork?.cancel()
        focusWork = nil
        keepAwake(nil)
        log.write("app: quit")
    }

    /// Returns when no setup step runs and no automatic retry is due (for tests).
    func waitUntilSetupIsIdle() async {
        await orchestrator?.waitUntilIdle()
    }

    // MARK: Setup events

    func send(_ event: SetupEvent) {
        guard let orchestrator else { return }
        Task { await orchestrator.send(event) }
    }

    /// Try Again on a failed or offline track.
    func retry(_ track: SetupTrack) {
        send(.retry(track))
    }

    /// The player answered a card. Approvals (install Steam, move to Applications) let the step act; other actions
    /// mean "done, check again".
    func respond(_ action: UserAction) {
        send(.userResponded(action))
    }

    func skipRelocation() { send(.skipRelocation) }

    func setLoginMode(_ mode: LoginMode) { send(.setLoginMode(mode)) }

    // MARK: Steam card

    /// Home's Steam card; nil until first read and when the player signs in with a Warframe account. The name and
    /// picture stay in memory and are never logged.
    private(set) var steamCard: SteamCard?
    /// Log In was pressed and Steam is not signed in yet: the card refreshes faster and Steam is hidden once signed in.
    private(set) var steamLoggingIn = false
    private var steamLogInDeadline: Date?
    /// The switch's last value, until setup's login mode (changed asynchronously by the orchestrator) catches up.
    private var useSteamSwitch: Bool?

    /// The Sign in with Steam switch, including before setup has applied it.
    var usesSteam: Bool { useSteamSwitch ?? (setup.loginMode == .steam) }

    /// Off means a Warframe account: Warzag then never starts, hides or quits Steam.
    func setUseSteam(_ on: Bool) {
        useSteamSwitch = on
        setLoginMode(on ? .steam : .warframeAccount)
        if !on {
            steamCard = nil
            steamLoggingIn = false
        }
        services.steam.allowHiding(steamHidingAllowed)
        Task { await refreshSteamCard() }
    }

    func setKeepSteamOutOfSight(_ enabled: Bool) {
        settings.keepSteamOutOfSight = enabled
        saveSettings()
        services.steam.allowHiding(steamHidingAllowed)
    }

    var steamHidingAllowed: Bool { settings.keepSteamOutOfSight && usesSteam }

    func refreshSteamCard() async {
        guard usesSteam else {
            steamCard = nil
            return
        }
        let steam = services.steam
        let card = await Task.detached { await steam.card() }.value
        // The switch may have been turned off while Steam was read.
        guard usesSteam else {
            steamCard = nil
            return
        }
        steamCard = card
        guard steamLoggingIn else { return }
        if card.state == .signedIn {
            steamLoggingIn = false
            log.write("steam: signed in")
            if steamHidingAllowed {
                steam.allowHiding(true)
                await Task.detached { await steam.hideSteam() }.value
            }
        } else if let deadline = steamLogInDeadline, services.clock.now > deadline {
            steamLoggingIn = false
        }
    }

    /// Runs while Home is visible; polls faster while Steam starts or signs in.
    func watchSteamCard() async {
        while !Task.isCancelled {
            await refreshSteamCard()
            let moving = steamLoggingIn || steamCard?.state == .starting || steamCard?.state == .signingIn
            try? await Task.sleep(for: .seconds(moving ? 2 : 5))
        }
    }

    /// Log In and Sign In Again: starts Steam in the background or with its sign-in window, or brings Steam's window
    /// forward. Warzag never sees credentials.
    func steamLogIn() {
        guard usesSteam else { return }
        steamLoggingIn = true
        steamLogInDeadline = services.clock.now.addingTimeInterval(600)
        log.write("steam: log in")
        let steam = services.steam
        Task {
            let installed = await Task.detached { await steam.logIn() }.value
            if !installed { steamLoggingIn = false }
            await refreshSteamCard()
        }
    }

    /// Shows Steam's own sign-out confirmation; only while no game runs.
    func steamLogOut() {
        guard usesSteam, play == .idle else { return }
        steamLoggingIn = false
        log.write("steam: log out")
        let steam = services.steam
        Task {
            await Task.detached { await steam.logOut() }.value
            await refreshSteamCard()
        }
    }

    /// Secondary card buttons that open another app.
    func showSteam() { services.system.showSteam() }
    func openSteamStorePage() {
        services.system.open(URL(string: "steam://store/\(Warframe.steamAppID)")!)
    }
    func showDEWindow() { services.system.showGameHost(openedProcess: nil) }
    func openStorageSettings() {
        services.system.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!)
    }
    func openBatterySettings() {
        services.system.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
    }
    func showLogs() {
        try? fileSystem.createDirectory(at: paths.logs)
        services.system.open(paths.logs)
    }

    /// Re-checks what a card may have asked for (sign-in, free space); during a game Warzag returns to the Dock.
    func appBecameActive() {
        appIsActive = true
        updateDockPresence(showingWindow: false)
        Task { await tick() }
        if setup.preflight.status == .waitingForUser, setup.preflight.action == .chooseStorage,
           StoragePolicy.isEnough(services.system.storage(for: paths.warframeLibrary)) {
            send(.userResponded(.chooseStorage))
        }
        refreshPower(force: true)
        // The player may have changed it in Warframe, which writes it back to EE.cfg.
        if setup.isReadyToPlay { refreshMotionBlur() }
    }

    /// During a game whose first minute is over, Warzag may now leave the Dock (Hide Warzag while playing).
    func appResignedActive() {
        appIsActive = false
        updateDockPresence()
    }

    /// Warzag was opened again (Dock, Finder, Spotlight, `open`). If it was hidden during a game, it returns to the
    /// Dock with its main window until the player leaves it again. Returns whether AppKit should still handle the
    /// reopen: true unless Warzag was hidden.
    func reopened() -> Bool {
        guard play.isInSession else { return true }
        // Opening an app activates it. Mark Warzag active now, so nothing (such as the end of the game's first minute)
        // hides it before macOS reports the activation.
        appIsActive = true
        guard hiddenWhilePlaying else { return true }
        hiddenWhilePlaying = false
        services.system.setDockPresence(.shown)
        log.write("play: Warzag was opened again; back in the Dock")
        services.system.showMainWindow()
        return false
    }

    /// Heartbeat: re-checks state that changes outside Warzag.
    func tick() async {
        if setup.steam.status == .waitingForUser, setup.steam.action == .signInToSteam,
           services.steam.status().signedIn {
            send(.userResponded(.signInToSteam))
        }
        if SetupTrack.allCases.contains(where: { setup[$0].status == .offline }),
           await services.system.networkIsAvailable() {
            send(.networkAvailable)
        }
        refreshPower(force: false)
        updates.checkIfDue()
    }

    private func networkCameBack() {
        if SetupTrack.allCases.contains(where: { setup[$0].status == .offline }) { send(.networkAvailable) }
    }

    // MARK: State updates

    private func setupChanged(_ state: SetupState) {
        let previous = setup
        setup = state
        if let wanted = useSteamSwitch, (state.loginMode == .steam) == wanted { useSteamSwitch = nil }
        for track in SetupTrack.allCases {
            let now = state[track]
            // Progress belongs to the running step: clear it when the step changes or stops. Pending keeps it, because
            // a step may report before its running state arrives.
            if now.step != previous[track].step || ![.running, .pending].contains(now.status) {
                activities[track] = nil
                estimators[track] = nil
            }
        }
        if state.isReadyToPlay, !previous.isReadyToPlay {
            log.write("setup: ready to play")
            refreshHome()
        }
        afterChange()
    }

    private func apply(_ update: ActivityUpdate) {
        // Ignore late reports from a step that finished, failed or is waiting for the player.
        guard [.running, .pending].contains(setup[update.track].status) else { return }
        guard var activity = update.activity else {
            activities[update.track] = nil
            estimators[update.track] = nil
            afterChange()
            return
        }
        if var progress = activity.progress, let completed = progress.completed {
            var estimator = activities[update.track]?.detail == activity.detail
                ? estimators[update.track] ?? RateEstimator() : RateEstimator()
            let measured = estimator.add(bytes: completed, at: services.clock.now)
            if progress.bytesPerSecond == nil { progress.bytesPerSecond = measured }
            progress.secondsRemaining = RateEstimator.secondsRemaining(progress)
            activity.progress = progress
            estimators[update.track] = estimator
        }
        activities[update.track] = activity
        afterChange()
    }

    /// Updates the Dock badge, attention requests, sleep prevention and milestones after any change.
    private func afterChange() {
        // Nothing needs the player before Get Started.
        let items = screen == .welcome ? [] : attentionItems
        if !items.isEmpty {
            services.system.setDockBadge("!")
            let new = Set(items.map(\.id)).subtracting(attentionShown)
            if !new.isEmpty { services.system.requestAttention() }
            for id in new.sorted() { reachedMilestone("needs-you-\(id)") }
            attentionShown.formUnion(new)
        } else if case .running = setup.game.status, let fraction = activities[.game]?.progress?.displayFraction,
                  activities[.game]?.detail == .downloadingGame {
            services.system.setDockBadge(Formatting.percent(fraction))
            if fraction >= 0.3 { reachedMilestone("downloading") }
        } else {
            services.system.setDockBadge(nil)
        }
        attentionShown.formIntersection(Set(items.map(\.id)))

        // Work (setup, DE's update before Play, an update) keeps the Mac awake; a session also keeps the display on.
        // `setupIsWorking` is false behind the Welcome screen, where tracks wait at the start gate as running.
        let working = setupIsWorking || play != .idle || updates.running != nil
        keepAwake(play.isInSession ? .playing : working ? .setup : nil)
        updateDockPresence()
        switch screen {
        case .welcome: reachedMilestone("welcome")
        case .setup: reachedMilestone("setup")
        case .home:
            reachedMilestone("home")
            demoPlayOnce()
        case .playing:
            reachedMilestone("playing")
        }
    }

    /// WARZAG_DEMO_AUTOPLAY: one simulated session, so a smoke test sees Home, Playing, then Home again.
    private func demoPlayOnce() {
        guard isDemo, demoAutoPlay, !demoAutoPlayed else { return }
        demoAutoPlayed = true
        let clock = services.clock
        background.append(Task { [weak self] in
            do { try await clock.sleep(for: .seconds(3)) } catch { return }
            self?.playGame()
            for _ in 0..<120 {
                guard let self else { return }
                if case .running = self.play { break }
                do { try await clock.sleep(for: .milliseconds(500)) } catch { return }
            }
            do { try await clock.sleep(for: .seconds(6)) } catch { return }
            self?.quitGame()
        })
    }

    private func keepAwake(_ reason: KeepAwakeReason?) {
        guard reason != keptAwake else { return }
        keptAwake = reason
        services.system.keepAwake(reason)
    }

    // MARK: Hide Warzag while playing

    /// The game's host already shows in the Dock (with Warframe's icon), so Warzag itself can leave it while the game
    /// runs.
    private var shouldHideWhilePlaying: Bool {
        guard case .running = play else { return false }
        return settings.hideWhilePlaying && focusWatchOver && !appIsActive
    }

    /// Applies `shouldHideWhilePlaying`. On returning to the Dock, `showingWindow` also shows the main window; it is
    /// false when the player clicked one of Warzag's windows, which is already in front.
    private func updateDockPresence(showingWindow: Bool = true) {
        let hide = shouldHideWhilePlaying
        guard hide != hiddenWhilePlaying else { return }
        hiddenWhilePlaying = hide
        services.system.setDockPresence(hide ? .hidden : .shown)
        if hide {
            log.write("play: Warzag left the Dock while Warframe runs")
        } else {
            if showingWindow { services.system.showMainWindow() }
            log.write("play: Warzag is back in the Dock")
        }
    }

    /// Warzag may leave the Dock once the focus keeper reports `.finished`.
    private func focusChanged(_ event: GameFocusEvent, session: Int) {
        guard session == focusSession else { return }
        lastFocusEvent = event
        guard case .finished = event else { return }
        focusWatchOver = true
        updateDockPresence()
    }

    private func reachedMilestone(_ name: String) {
        guard !milestones.contains(name) else { return }
        milestones.insert(name)
        onMilestone?(name)
    }

    // MARK: Home

    func refreshHome() {
        runtime = services.engine.activeRuntime()
        contentReads += 1
        let read = contentReads
        checkingContent = true
        let game = services.game
        Task { [weak self] in
            let summary = await Task.detached { game.contentStatus() }.value
            // Only the latest read counts, so a slow earlier read cannot restore an old state.
            guard let self, read == self.contentReads else { return }
            self.content = summary
            self.checkingContent = false
        }
        refreshMotionBlur()
    }

    /// Home's status line: Warframe's version, or what needs the player; nil when there is nothing to say (the game's
    /// state could not be read, or Warframe has not reported its version yet).
    var homeStatus: String? {
        if updates.prefixNeedsSetUp, updates.running == nil { return L10n.homePrefixNeedsSetUp }
        guard let content else { return checkingContent ? L10n.homeChecking : nil }
        if content.state == .notInstalled { return L10n.homeNotInstalled }
        return content.build.map(L10n.homeWarframeVersion)
    }

    /// Re-reads motion blur from EE.cfg; only the latest read is applied.
    func refreshMotionBlur() {
        motionBlurReads += 1
        let read = motionBlurReads
        let game = services.game
        Task { [weak self] in
            let setting = await Task.detached { game.motionBlur() }.value
            guard let self, read == self.motionBlurReads else { return }
            self.motionBlur = setting
        }
    }

    private func refreshPower(force: Bool) {
        let now = services.clock.now
        guard force || now.timeIntervalSince(lastPowerCheck) >= 30 else { return }
        lastPowerCheck = now
        hardware = services.system.hardware()
        powerAdvice = services.system.powerAdvice(for: tier)
    }

    // MARK: Play

    func playGame() {
        guard canPlay else { return }
        lastSession = nil
        play = .preparing
        refreshMotionBlur()
        let request = PlayRequest(steam: setup.loginMode == .steam, graphics: graphics, hud: settings.performanceHUD)
        let game = services.game
        log.write("play: start (\(request.steam ? "Steam" : "Warframe account"), \(request.graphics.rawValue))")
        let (updates, continuation) = AsyncStream<PlayUpdate>.makeStream()
        let work = Task.detached { () -> Result<PlaySummary, any Error> in
            defer { continuation.finish() }
            do {
                return .success(try await game.play(request) { continuation.yield($0) })
            } catch {
                return .failure(error)
            }
        }
        playWork = work
        Task { [weak self] in
            for await update in updates { self?.applyPlay(update) }
            self?.finishPlay(await work.value)
        }
    }

    private func applyPlay(_ update: PlayUpdate) {
        switch update {
        case .startingSteam:
            play = .preparing
        case .waitingForSteamSignIn:
            play = .waitingForSteam
        case .game(let event):
            switch event {
            case .updating(let state):
                switch state {
                case .needsEULA: play = .needsEULA(guessed: false)
                case .mayNeedEULA: play = .needsEULA(guessed: true)
                default: play = .updating(TrackActivity(state))
                }
            case .opening:
                play = .launching
            case .started(let processIdentifier):
                play = .running(GameSession(processIdentifier: processIdentifier, startedAt: services.clock.now))
                keepGameInFront(openedProcess: processIdentifier)
            case .signal(let signal):
                if case .running(var session) = play {
                    session.signals.append(signal)
                    play = .running(session)
                }
            case .handedOverToLauncher:
                // An update or a restart: the session continues with DE's launcher and the game it starts.
                log.write("play: Warframe handed over to DE's launcher while closing (an update or a restart); "
                    + "Warzag leaves it running")
            case .hungAtExit(let seconds):
                // The session then ends normally, without a banner; only Warzag.log records it.
                log.write("play: Warframe stopped responding while closing; Warzag is ending it (wineserver -k, "
                    + "\(Int(seconds)) s after it began closing)")
            case .exited:
                play = .finishing
            case .cleanedUp:
                break
            case .warning(let message):
                // A Wine tool exceeded its deadline; the session continues.
                log.write("play: \(message)")
            }
        }
        afterChange()
    }

    /// Brings the game's window to the front when it appears and back from Steam during its first minute: a window
    /// that is not in front is composited and gets no Game Mode. Warzag stays a regular app until `.finished`, because
    /// taking the front back from Steam activates Warzag first (`WorkspaceFocusEnvironment.activate`).
    private func keepGameInFront(openedProcess: Int32) {
        focusWork?.cancel()
        focusSession += 1
        focusWatchOver = false
        lastFocusEvent = nil
        let session = focusSession
        let system = services.system
        let log = log
        let (events, continuation) = AsyncStream<GameFocusEvent>.makeStream()
        let hidingSteam = steamHidingAllowed
        services.steam.allowHiding(hidingSteam)
        focusWork = Task.detached {
            await system.keepGameInFront(openedProcess: openedProcess, hidingSteam: hidingSteam) { event in
                log.write("play: \(Self.describe(event))")
                continuation.yield(event)
            }
            continuation.finish()
        }
        Task { [weak self] in
            for await event in events { self?.focusChanged(event, session: session) }
        }
    }

    /// Text for Warzag.log; never names the other app, for privacy.
    nonisolated static func describe(_ event: GameFocusEvent) -> String {
        switch event {
        case .windowAppeared(_, let broughtForward, let front):
            broughtForward ? "Warframe's window appeared; brought it to the front"
                : front == nil ? "Warframe's window appeared in front"
                : "Warframe's window appeared while the player was in another app; left there"
        case .steamTookFront(let count):
            "Steam took the front; brought Warframe back (\(count) of \(GameFocusPolicy().maximumReturns))"
        case .steamHidden:
            "hid Steam before bringing Warframe back"
        case .finished(let returns):
            "kept Warframe in front for its first minute (brought back from Steam: \(returns))"
        }
    }

    private func finishPlay(_ result: Result<PlaySummary, any Error>) {
        playWork = nil
        focusWork?.cancel()
        focusWork = nil
        switch result {
        case .success(let summary):
            lastSession = SessionResult(seconds: summary.seconds, problems: summary.signals.filter(\.isError),
                                        failure: nil)
            log.write("play: Warframe exited after \(Int(summary.seconds)) s"
                + (summary.forcedCleanup ? " (wineserver -k)" : "")
                + summary.signals.filter(\.isError).map { "; \($0.rawValue)" }.joined())
        case .failure(let error):
            lastSession = SessionResult(seconds: nil, problems: [], failure: Self.message(for: error))
            log.write("play: failed: \(error)")
        }
        play = .idle
        afterChange()
        refreshHome()
    }

    static func message(for error: any Error) -> String {
        switch error as? PlayFailure {
        case .steamNotSignedIn: L10n.playFailureSteam
        case .needsRepair: L10n.playFailureRepair
        case .busy: L10n.playFailureBusy
        case .updateDeclinedEULA: L10n.playFailureEULA
        case .updateStuck: L10n.playFailureStuck
        case .notInstalled: L10n.playFailureNotInstalled
        case .other, nil: L10n.playFailureOther
        }
    }

    func quitGame() {
        guard case .running(var session) = play else { return }
        session.quitRequestedAt = services.clock.now
        play = .running(session)
        let game = services.game
        Task.detached { await game.quitGame() }
    }

    func canForceQuit(at now: Date) -> Bool {
        guard case .running(let session) = play, let requested = session.quitRequestedAt else { return false }
        return now.timeIntervalSince(requested) >= 10
    }

    func forceQuitGame() {
        let game = services.game
        Task.detached { await game.forceQuitGame() }
    }

    /// Shows the game's window, not the process Play opened (the steam.exe shim has no visible window).
    func returnToGame() {
        guard case .running(let session) = play else { return }
        services.system.showGameHost(openedProcess: session.processIdentifier)
    }

    func dismissSessionResult() { lastSession = nil }

    // MARK: Updates

    /// An update started or ended. Play waits while one runs, and the Mac stays awake.
    func updatesChanged() { afterChange() }

    /// Records a complete update check; the next automatic check is due a day later.
    func recordUpdateCheck() {
        settings.lastUpdateCheck = services.clock.now
        saveSettings()
    }

    // MARK: Troubleshooting

    func runDoctor() async {
        guard doctor != .running else { return }
        doctor = .running
        let services = services
        let library = paths.warframeLibrary
        let steamMode = setup.loginMode == .steam
        let checks = await Task.detached {
            Self.appChecks(services: services, library: library, steamMode: steamMode) + (await services.engine.doctor())
        }.value
        doctor = .finished(checks, at: services.clock.now)
    }

    /// Checks the engine's doctor does not cover: free space, Steam and the game files. Reads the disk, so it runs off
    /// the main actor.
    nonisolated static func appChecks(services: AppServices, library: URL, steamMode: Bool) -> [HealthCheck] {
        var checks: [HealthCheck] = []
        let storage = services.system.storage(for: library)
        let free = storage.volume?.availableCapacity.map { Formatting.bytes($0) } ?? L10n.unknown
        checks.append(HealthCheck(id: "storage", title: L10n.checkStorage, passed: StoragePolicy.isEnough(storage),
                                  detail: storage.volume?.isCaseSensitive == true ? L10n.checkStorageCaseSensitive
                                      : L10n.checkStorageFree(free)))
        if steamMode {
            let steam = services.steam.status()
            let detail = !steam.installed ? L10n.steamNotInstalled
                : !steam.running ? L10n.steamNotRunning
                : steam.signedIn ? L10n.steamSignedIn : L10n.steamSignedOut
            checks.append(HealthCheck(id: "steam", title: L10n.checkSteam,
                                      passed: steam.installed && steam.running && steam.signedIn, detail: detail))
        }
        if let summary = services.game.contentStatus() {
            let detail = switch summary.state {
            case .installed: L10n.contentInstalled
            case .needsUpdate: L10n.contentNeedsUpdate
            case .notInstalled: L10n.contentNotInstalled
            }
            checks.append(HealthCheck(id: "content", title: L10n.checkGameFiles, passed: summary.state != .notInstalled,
                                      detail: detail))
        }
        return checks
    }

    /// Re-applies the engine's prefix setup (placeholders, Steam bridge, registry, identity), then runs the doctor.
    func repairNow() async {
        guard canRepair else { return }
        repair = .running
        let engine = services.engine
        let result = await Task.detached { () -> Result<PrefixSummary, any Error> in
            do { return .success(try await engine.repairPrefix()) } catch { return .failure(error) }
        }.value
        switch result {
        case .success:
            repair = .succeeded(at: services.clock.now)
            log.write("repair: done")
            // The prefix now matches the current engine.
            updates.prefixWasSetUp()
        case .failure(let error):
            repair = .failed(L10n.repairFailed)
            log.write("repair: \(error)")
        }
        await runDoctor()
        refreshHome()
    }

    /// The diagnostics report, redacted.
    func diagnosticsReport() async -> String {
        let snapshot = DiagnosticsSnapshot(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            demo: isDemo, hardware: hardware, settings: settings, setup: setup,
            runtime: services.engine.activeRuntime(), steam: services.steam.status(),
            content: content, doctor: doctor, lastSession: lastSession)
        let logs = paths.logs
        let home = options.home
        return await Task.detached {
            DiagnosticsReport.render(snapshot, logDirectory: logs, home: home)
        }.value
    }

    func exportDiagnostics(to url: URL) async throws {
        let text = await diagnosticsReport()
        try Data(text.utf8).write(to: url, options: .atomic)
        log.write("diagnostics: exported")
    }

    // MARK: Settings

    func setGraphics(_ choice: GraphicsChoice) {
        settings.graphics = choice
        saveSettings()
    }

    func setPerformanceHUD(_ enabled: Bool) {
        settings.performanceHUD = enabled
        saveSettings()
    }

    /// Turned on during a game, Warzag leaves the Dock only once the player is back in the game (the Settings window
    /// keeps Warzag active).
    func setHideWhilePlaying(_ enabled: Bool) {
        settings.hideWhilePlaying = enabled
        saveSettings()
        updateDockPresence()
    }

    /// When on, the heartbeat runs a check whenever one is due.
    func setCheckForUpdatesAutomatically(_ enabled: Bool) {
        settings.checkForUpdatesAutomatically = enabled
        saveSettings()
        log.write("settings: automatic update checks " + (enabled ? "on" : "off"))
    }

    /// "Choose Engine…" and Settings' development engine accept any validly signed bundle, ad hoc included, without
    /// the manifest, SHA-256 and certificate checks of runtime packs. They show only with WARZAG_DEV_RUNTIME
    /// (`--dev-runtime`) or after the Option-click reveal.
    nonisolated static func showsDevelopmentEngineChoice(launchDevelopmentRuntime: URL?, revealed: Bool) -> Bool {
        launchDevelopmentRuntime != nil || revealed
    }

    var showsDevelopmentEngineChoice: Bool {
        Self.showsDevelopmentEngineChoice(launchDevelopmentRuntime: options.developmentRuntime,
                                          revealed: developerSettingsRevealed)
    }

    /// Option-click on Settings › Advanced…: shows the development engine until Warzag quits.
    func revealDeveloperSettings() {
        guard !developerSettingsRevealed else { return }
        developerSettingsRevealed = true
        log.write("settings: developer settings shown")
    }

    /// Clearing always works; choosing a bundle only where `showsDevelopmentEngineChoice` offers it.
    func setDevelopmentRuntime(_ bundle: URL?) async {
        guard bundle?.plainPath != settings.developmentRuntimePath, play == .idle, updates.running == nil else { return }
        guard bundle == nil || showsDevelopmentEngineChoice else {
            log.write("settings: a development engine needs the developer settings; ignored")
            return
        }
        settings.developmentRuntimePath = bundle?.plainPath
        saveSettings()
        log.write("settings: development engine " + (bundle == nil ? "cleared" : "set"))
        await restartSetup(resetting: [.engine])
    }

    private func saveSettings() {
        settingsBox.update(settings)
        do {
            try settingsStore.save(settings)
        } catch {
            log.write("settings: could not save: \(error)")
        }
    }

    /// Starts the given tracks over; their steps skip what is already done. SetupOrchestrator has no reset event, so
    /// it is replaced: the old one is shut down, setup.json rewritten and a new one started.
    func restartSetup(resetting tracks: Set<SetupTrack>) async {
        let wasStarted = orchestrator != nil
        observation?.cancel()
        await orchestrator?.shutdown()
        orchestrator = nil
        if tracks.contains(.game) { await services.game.cancelContentRun() }
        var state = setup
        for track in SetupPresentation.tracks where tracks.contains(track) && state[track].status != .skipped {
            state[track] = .start(of: track)
            activities[track] = nil
            estimators[track] = nil
        }
        do {
            try SetupStateStore(paths: paths, fileSystem: fileSystem).save(state)
        } catch {
            log.write("setup: could not save the reset state: \(error)")
        }
        setup = state
        if wasStarted { await beginSetup() }
    }
}
