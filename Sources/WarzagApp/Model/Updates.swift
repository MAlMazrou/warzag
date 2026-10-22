import EngineKit
import Foundation
import GameKit
import Observation
import RuntimeKit
import WarzagCore

// Updates of Warzag, its engine and Warframe: one at a time, never during a game, setup or a repair. Checking only
// reads the two signed feeds; nothing downloads or installs unless the player asks.

/// The parts Updates covers, in the window's order.
enum UpdatePart: String, CaseIterable, Sendable {
    /// Warzag itself, from its signed app feed (`AppUpdateServicing`).
    case warzag
    /// The engine, from the signed runtime feed setup installed it from.
    case engine
    /// Warframe, through DE's own launcher, as before every Play.
    case warframe
}

/// Why an update cannot start now.
enum UpdateBlocker: Equatable, Sendable {
    /// Play is in progress: Steam, DE's update before the game, or the game itself.
    case playing
    /// Setup is downloading or installing.
    case settingUp
    case repairing
    /// Another part is updating; only one updates at a time.
    case updating(UpdatePart)
}

enum WarzagUpdateState: Equatable, Sendable {
    /// Not checked in this run yet.
    case unchecked
    case checking
    /// This build names no update feed.
    case notConfigured
    case upToDate
    case available(AppUpdateOffer)
    /// Downloading and verifying (`prepare`).
    case downloading(AppUpdateOffer, ProgressSnapshot?)
    /// The installed Warzag is being replaced; then Warzag quits and the new one opens.
    case installing(AppUpdateOffer)
    /// A check or update failed (a one-sentence message); an offer found earlier can be retried.
    case failed(String, offer: AppUpdateOffer?)

    /// The offer the row's Update button installs.
    var offerToInstall: AppUpdateOffer? {
        switch self {
        case .available(let offer): offer
        case .failed(_, let offer): offer
        default: nil
        }
    }
}

/// Where the engine row's updates come from, or why it has none.
enum EngineUpdateSource: Equatable, Sendable {
    /// The release page's signed runtime feed, the one setup installed the engine from.
    case feed
    /// Setup has not installed the engine yet.
    case setup
    /// A build without a runtime feed (a development engine, or one installed with warzagctl).
    case noFeed
    /// A development engine (WARZAG_DEV_RUNTIME, Settings › Advanced, warzagctl use-local): rebuilt, not updated.
    case development
}

/// The engine's row, when it has a feed.
enum EngineUpdateState: Equatable, Sendable {
    case unchecked
    case checking
    case upToDate
    case available(EngineOffer)
    case downloading(EngineOffer, ProgressSnapshot?)
    case verifying(EngineOffer)
    case installing(EngineOffer)
    /// The new engine is current; the prefix is being set up for it, as setup does after an engine change.
    case settingUpWindows
    /// A check or update failed (a one-sentence message); an offer found earlier can be retried.
    case failed(String, offer: EngineOffer?)

    var offerToInstall: EngineOffer? {
        switch self {
        case .available(let offer): offer
        case .failed(_, let offer): offer
        default: nil
        }
    }

    /// The offer being downloaded, checked or installed.
    var offerInProgress: EngineOffer? {
        switch self {
        case .downloading(let offer, _), .verifying(let offer), .installing(let offer): offer
        default: nil
        }
    }
}

enum WarframeUpdateState: Equatable, Sendable {
    case idle
    /// DE's launcher is running; progress as Play shows it.
    case updating(TrackActivity?)
    /// DE's window shows its EULA; `guessed` as in `PlayState.needsEULA`.
    case needsEULA(guessed: Bool)
    /// Cancel was pressed: DE's launcher is closing.
    case cancelling
    /// DE's launcher finished; `updated` when it downloaded an update.
    case finished(updated: Bool)
    case failed(String)
}

/// One row of the Updates window in words: what `UpdatesView` shows and VoiceOver reads.
struct UpdateRow: Equatable {
    enum Tone: Equatable {
        case neutral
        case upToDate
        case available
        case problem
    }

    enum Action: Equatable {
        /// Install the offer (Warzag, the engine).
        case update
        /// Run DE's launcher (Warframe).
        case updateNow
        /// Set up the prefix again for the current engine, after that failed.
        case setUpAgain
        /// Close DE's launcher (Warframe).
        case cancel
        /// Reveal the verified new Warzag in Finder to drag into Applications (Warzag could not replace itself).
        case showCopy
    }

    var title: String
    /// The installed version, or when Warframe last finished an update.
    var detail: String?
    var status: String
    var tone: Tone
    /// Shows a progress bar under the status (indeterminate without numbers).
    var working = false
    var progress: ProgressSnapshot?
    var action: Action?
    /// False while the action waits for Play, setup, Repair or another update.
    var actionEnabled = true
    /// DE's window waits for the player; the row offers Show the Window.
    var showsDEWindow = false
    /// Warzag's row offers What's New in Warzag, except beside a newer Warzag.
    var showsWhatsNew = false
    var releaseNotes: URL?
}

/// Warframe or DE's launcher is running in the prefix, so nothing may be installed.
struct GameIsRunning: Error, CustomStringConvertible {
    var description: String { "something runs in the prefix (Warframe or DE's launcher)" }
}

/// Where an engine update stopped.
enum EngineUpdateFailure: Error, CustomStringConvertible {
    /// Before the new engine became current (a feed step, or a game running): the installed engine stays.
    case beforeSwitch(any Error)
    /// A step failed after the engine had changed anyway (a revocation in the fetched manifest rolled back to the
    /// previous one, or the switch happened before the failure); the prefix was set up for `current`.
    case changed(any Error, current: RuntimeSummary)
    /// The engine changed (to the new one, or back to the previous one after a revocation), but the prefix could not
    /// be set up for it.
    case prefix(any Error)

    var description: String {
        switch self {
        case .beforeSwitch(let error): "\(error)"
        case .changed(let error, let current): "\(error); \(current.id) is current now"
        case .prefix(let error): "the prefix could not be set up for it: \(error)"
        }
    }
}

/// What an update's work reports to the model, in order.
private enum UpdateStep: Sendable {
    case bytes(received: Int64, total: Int64)
    case verifying
    case installing
    case settingUpWindows
    case game(ContentRunState)
}

/// Update checks and the three updates; owned by `AppModel`, whose Play, setup and Repair they wait for. Long work runs
/// in detached tasks; progress and results are applied on the main actor.
@MainActor
@Observable
final class UpdatesModel {
    /// The automatic check's period, and the retry delay after a check that did not get every answer.
    static let checkInterval: TimeInterval = 24 * 3600
    static let retryInterval: TimeInterval = 3600

    private(set) var warzag = WarzagUpdateState.unchecked
    /// The verified new Warzag, kept when Warzag could not replace itself (Show in Finder on its row).
    private(set) var warzagCopy: URL?
    private(set) var engine = EngineUpdateState.unchecked
    private(set) var warframe = WarframeUpdateState.idle
    /// The part updating now; only one at a time.
    private(set) var running: UpdatePart?
    private(set) var checking = false
    /// The prefix is not set up for the current engine (found at launch, or setting it up failed). Play and Update Now
    /// wait until Repair or Updates sets it up.
    private(set) var prefixNeedsSetUp = false

    @ObservationIgnored private unowned let app: AppModel
    /// The running update's work, and how to stop it (Cancel, quit).
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var cancelOperation: (@Sendable () -> Void)?
    /// Claimed once, by Warzag's install or by a quit that comes first (which then stops the update).
    @ObservationIgnored private var warzagInstall: Once?
    @ObservationIgnored private var estimator = RateEstimator()
    @ObservationIgnored private var lastAutomaticAttempt: Date?
    /// Warzag is quitting: nothing new starts.
    @ObservationIgnored private var shuttingDown = false

    init(app: AppModel) {
        self.app = app
    }

    // MARK: Derived

    var currentVersion: AppVersion { app.services.appUpdate.currentVersion() }

    var engineSource: EngineUpdateSource {
        let engine = app.services.engine
        if engine.developmentRuntime() != nil || app.runtime?.development == true { return .development }
        if engine.feedURL() == nil { return .noFeed }
        return app.setup.isReadyToPlay ? .feed : .setup
    }

    /// A newer Warzag or engine was found (Home's badge). Only DE's launcher finds Warframe updates.
    var updateAvailable: Bool {
        warzag.offerToInstall != nil || (engineSource == .feed && engine.offerToInstall != nil)
    }

    /// Why `part` cannot update now; nil when it can (given something to update).
    func blocker(for part: UpdatePart) -> UpdateBlocker? {
        if let running, running != part { return .updating(running) }
        if app.play != .idle { return .playing }
        if app.repair == .running { return .repairing }
        if app.setupIsWorking { return .settingUp }
        return nil
    }

    /// The blocker shown above the rows while every update waits; another part updating shows in its own row.
    var waitingFor: UpdateBlocker? {
        guard let blocker = blocker(for: running ?? .warzag) else { return nil }
        if case .updating = blocker { return nil }
        return blocker
    }

    private func mayStart(_ part: UpdatePart) -> Bool { !shuttingDown && running == nil && blocker(for: part) == nil }

    // MARK: Checking

    /// Asks the app feed and the runtime feed what they offer; downloads nothing. The engine manifest is verified but
    /// not recorded (`checkEngineManifest`), so checking is safe during a game. Warframe's state is only re-read from
    /// disk: only DE's launcher knows whether an update is out.
    func checkForUpdates() {
        check(automatic: false)
    }

    /// Checks when the window opens, if nothing was checked in this run yet.
    func windowOpened() {
        guard warzag == .unchecked || (engineSource == .feed && engine == .unchecked) else { return }
        check(automatic: false)
    }

    /// At a launch that opens on Home: finishes an interrupted engine update, then runs the automatic check if due.
    func launch() {
        reportLastInstall()
        finishInterruptedEngineUpdate()
        checkIfDue()
    }

    /// Reports, once, an update that failed after the previous Warzag quit (its helper restored that Warzag), with the
    /// verified copy to drag into Applications when macOS refused the replacement.
    private func reportLastInstall() {
        guard let error = app.services.appUpdate.lastInstallResult() else { return }
        app.log.write("updates: the last update did not replace Warzag: \(error)")
        failWarzag(error, offer: nil)
    }

    /// Marks Warzag's row failed, with Show in Finder when Warzag cannot replace itself but kept the verified copy.
    private func failWarzag(_ error: any Error, offer: AppUpdateOffer?) {
        if case .cannotReplace = error as? AppUpdateError, let copy = app.services.appUpdate.preparedCopy() {
            warzagCopy = copy
            warzag = .failed(L10n.updatesWarzagCannotReplaceCopy, offer: offer)
        } else {
            warzagCopy = nil
            warzag = .failed(UpdateMessages.warzag(error), offer: offer)
        }
    }

    /// Show in Finder on the Warzag row.
    func showWarzagCopy() {
        guard let warzagCopy else { return }
        app.services.system.revealInFinder(warzagCopy)
    }

    /// The automatic check, at launch and on the heartbeat: a day after the last complete check, an hour after an
    /// incomplete automatic one; never before Get Started or during Play.
    func checkIfDue() {
        guard app.settings.checkForUpdatesAutomatically, app.welcomed, app.play == .idle, !checking else { return }
        let now = app.services.clock.now
        // A check dated in the future (the clock went back) does not delay the next one.
        func recent(_ date: Date?, within interval: TimeInterval) -> Bool {
            guard let date else { return false }
            let age = now.timeIntervalSince(date)
            return age >= 0 && age < interval
        }
        guard !recent(app.settings.lastUpdateCheck, within: Self.checkInterval),
              !recent(lastAutomaticAttempt, within: Self.retryInterval) else { return }
        lastAutomaticAttempt = now
        check(automatic: true)
    }

    private func check(automatic: Bool) {
        guard !checking, !shuttingDown else { return }
        let checksWarzag = running != .warzag
        let checksEngine = engineSource == .feed && running != .engine
        // Re-reads Warframe's last update and the engine's version.
        app.refreshHome()
        guard checksWarzag || checksEngine else { return }
        checking = true
        app.log.write("updates: " + (automatic ? "automatic check" : "check"))
        let services = app.services
        var warzagCheck: Task<Bool, Never>?
        if checksWarzag {
            warzag = .checking
            warzagCheck = Task { [weak self] in
                let result = await Self.offMainActor { try await services.appUpdate.check() }
                return self?.apply(warzagCheck: result) ?? false
            }
        }
        var engineCheck: Task<Bool, Never>?
        if checksEngine {
            engine = .checking
            engineCheck = Task { [weak self] in
                let result = await Self.offMainActor { try await services.engine.checkEngineManifest() }
                return self?.apply(engineCheck: result) ?? false
            }
        }
        Task { [weak self, warzagCheck, engineCheck] in
            let warzagAnswered = await warzagCheck?.value ?? true
            let engineAnswered = await engineCheck?.value ?? true
            self?.finishCheck(answered: warzagAnswered && engineAnswered)
        }
    }

    /// Returns whether the app feed answered.
    private func apply(warzagCheck result: Result<AppUpdateCheck, any Error>) -> Bool {
        guard warzag == .checking else { return true }
        // A copy kept from an earlier refusal is offered again only if the next install is refused too.
        warzagCopy = nil
        switch result {
        case .success(.notConfigured), .failure(AppUpdateError.notConfigured):
            warzag = .notConfigured
            app.log.write("updates: this build has no update feed")
        case .success(.upToDate):
            warzag = .upToDate
            app.log.write("updates: Warzag is up to date")
        case .success(.available(let offer)):
            warzag = .available(offer)
            app.log.write("updates: Warzag \(offer.version) (\(offer.build)) is available, \(offer.bytes) bytes")
        case .failure(let error):
            warzag = .failed(UpdateMessages.warzag(error), offer: nil)
            app.log.write("updates: checking for Warzag: \(error)")
            return false
        }
        return true
    }

    /// Returns whether the runtime feed answered.
    private func apply(engineCheck result: Result<EngineOffer, any Error>) -> Bool {
        guard engine == .checking else { return true }
        switch result {
        case .success(let offer):
            engine = offer.installed ? .upToDate : .available(offer)
            app.log.write("updates: engine " + (offer.installed ? "\(offer.id) is current"
                : "\(offer.id) is available, \(offer.bytes) bytes"))
            return true
        case .failure(let error):
            engine = .failed(UpdateMessages.engine(error, checking: true), offer: nil)
            app.log.write("updates: checking for the engine: \(error)")
            return false
        }
    }

    private func finishCheck(answered: Bool) {
        checking = false
        if answered { app.recordUpdateCheck() }
    }

    // MARK: Warzag

    /// Downloads and verifies the offer (`prepare`), installs it, then quits through `AppTermination` so the new Warzag
    /// opens. Nothing installs while the prefix is busy. The install begins at most once and never after a quit has
    /// begun; once begun, quitting waits for it.
    func updateWarzag() {
        guard let offer = warzag.offerToInstall, mayStart(.warzag) else { return }
        begin(.warzag)
        warzag = .downloading(offer, nil)
        app.log.write("updates: downloading Warzag \(offer.version) (\(offer.build))")
        let services = app.services
        let installOrQuit = Once()
        warzagInstall = installOrQuit
        let (steps, continuation) = AsyncStream<UpdateStep>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let operation = Task.detached { () -> Result<Void, any Error> in
            defer { continuation.finish() }
            do {
                try await services.appUpdate.prepare(offer) { continuation.yield(.bytes(received: $0, total: $1)) }
                guard !services.game.prefixIsBusy() else { throw AppUpdateError.gameRunning }
                // The install and a quit race for this claim; the first one wins (`shutdown`).
                guard installOrQuit.claim() else { throw CancellationError() }
                continuation.yield(.installing)
                // Detached so a quit cannot cancel it: an install cut short could leave no Warzag to open.
                try await Task.detached { try await services.appUpdate.installPreparedUpdate() }.value
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        follow(operation, steps: steps) { [weak self] in self?.finishWarzag($0, offer: offer) }
    }

    private func finishWarzag(_ result: Result<Void, any Error>, offer: AppUpdateOffer) {
        switch result {
        case .success:
            // `running` stays set until Warzag has quit, so nothing else starts. If a quit is already under way, the
            // new Warzag opens after it.
            app.log.write("updates: Warzag \(offer.version) (\(offer.build)) is installed; quitting so it opens")
            if !shuttingDown { app.services.system.quit() }
        case .failure(let error):
            app.log.write("updates: Warzag \(offer.version) (\(offer.build)): \(error)")
            failWarzag(error, offer: offer)
            end()
        }
    }

    // MARK: Engine

    /// Runs setup's engine steps (fetch and record the manifest, download, verify, activate), then sets up the prefix
    /// for the new engine. The prefix must be idle before the fetch, whose revocations may roll back to the previous
    /// engine, and before the switch. After such a rollback the prefix is set up for that engine even when a later
    /// step fails.
    func updateEngine() {
        guard engineSource == .feed, let offer = engine.offerToInstall, mayStart(.engine) else { return }
        begin(.engine)
        engine = .downloading(offer, nil)
        app.log.write("updates: downloading engine \(offer.id)")
        let services = app.services
        let (steps, continuation) = AsyncStream<UpdateStep>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let operation = Task.detached { () -> Result<RuntimeSummary, EngineUpdateFailure> in
            defer { continuation.finish() }
            let before = services.engine.activeRuntime()?.id
            let runtime: RuntimeSummary
            do {
                guard !services.game.prefixIsBusy() else { throw GameIsRunning() }
                _ = try await services.engine.fetchEngineManifest()
                try await services.engine.downloadEngine { continuation.yield(.bytes(received: $0, total: $1)) }
                continuation.yield(.verifying)
                try await services.engine.verifyEngine()
                guard !services.game.prefixIsBusy() else { throw GameIsRunning() }
                continuation.yield(.installing)
                runtime = try await services.engine.activateEngine()
            } catch {
                // If the engine changed anyway, set up the prefix for it, unless something is running in it.
                guard let current = services.engine.activeRuntime(), current.id != before else {
                    return .failure(.beforeSwitch(error))
                }
                guard !(error is GameIsRunning) else { return .failure(.prefix(error)) }
                continuation.yield(.settingUpWindows)
                do {
                    _ = try await services.engine.setUpPrefix()
                    return .failure(.changed(error, current: current))
                } catch {
                    return .failure(.prefix(error))
                }
            }
            continuation.yield(.settingUpWindows)
            do {
                _ = try await services.engine.setUpPrefix()
                return .success(runtime)
            } catch {
                return .failure(.prefix(error))
            }
        }
        follow(operation, steps: steps) { [weak self] in self?.finishEngine($0, offer: offer) }
    }

    /// Sets up the prefix for the current engine: Try Again after a failure, and at launch after an interrupted update.
    func setUpPrefixAgain() {
        guard mayStart(.engine) else { return }
        begin(.engine)
        engine = .settingUpWindows
        app.log.write("updates: setting the prefix up for the current engine")
        let services = app.services
        let operation = Task.detached { () -> Result<RuntimeSummary, EngineUpdateFailure> in
            guard !services.game.prefixIsBusy() else { return .failure(.prefix(GameIsRunning())) }
            do {
                _ = try await services.engine.setUpPrefix()
                guard let runtime = services.engine.activeRuntime() else {
                    return .failure(.prefix(RuntimeServiceError.noRuntime))
                }
                return .success(runtime)
            } catch {
                return .failure(.prefix(error))
            }
        }
        follow(operation, steps: AsyncStream { $0.finish() }) { [weak self] in self?.finishEngine($0, offer: nil) }
    }

    /// `offer`: the engine an update installed; nil when only the prefix was set up again, in which case it is unknown
    /// whether a newer engine is out.
    private func finishEngine(_ result: Result<RuntimeSummary, EngineUpdateFailure>, offer: EngineOffer?) {
        switch result {
        case .success(let runtime):
            app.log.write("updates: engine \(runtime.id) is current and the prefix is set up for it")
            engine = offer == nil ? .unchecked : .upToDate
            prefixNeedsSetUp = false
        case .failure(.prefix(let error)):
            app.log.write("updates: setting the prefix up for the current engine: \(error)")
            engine = .failed(error is GameIsRunning ? L10n.updatesGameRunning : L10n.updatesEnginePrefixFailed,
                             offer: nil)
            prefixNeedsSetUp = true
        case .failure(.changed(let error, let current)):
            app.log.write("updates: engine \(offer?.id ?? "update"): \(error); \(current.id) is current now and the "
                + "prefix is set up for it")
            engine = .failed(UpdateMessages.engine(error, checking: false), offer: offer)
            prefixNeedsSetUp = false
        case .failure(.beforeSwitch(let error)):
            app.log.write("updates: engine \(offer?.id ?? "update"): \(error); the installed engine stays")
            engine = .failed(UpdateMessages.engine(error, checking: false), offer: offer)
        }
        end()
        app.refreshHome()
    }

    /// At launch on Home: when the prefix was set up for another engine (an interrupted update, or a change made with
    /// warzagctl), sets it up for the current one before anything runs in it. Play and Update Now wait until that
    /// succeeds, here, through Try Again or through Repair.
    private func finishInterruptedEngineUpdate() {
        guard app.setup.isReadyToPlay, running == nil else { return }
        // Read synchronously, before anything else can start (two small files, as in `refreshHome`).
        let service = app.services.engine
        guard let active = service.activeRuntime(), let prepared = service.prefixRuntimeID(),
              prepared != active.id else { return }
        prefixNeedsSetUp = true
        app.log.write("updates: the prefix is set up for \(prepared), the current engine is \(active.id); "
            + "setting it up again")
        setUpPrefixAgain()
    }

    /// Called after Repair has set up the prefix for the current engine.
    func prefixWasSetUp() {
        guard prefixNeedsSetUp else { return }
        prefixNeedsSetUp = false
        if case .failed = engine { engine = .unchecked }
    }

    // MARK: Warframe

    /// Runs DE's launcher to update the game, as before every Play. Like Play, it waits while the prefix is not set up
    /// for the current engine, because DE's launcher runs in the prefix on that engine.
    func updateWarframe() {
        guard app.setup.isReadyToPlay, !prefixNeedsSetUp, mayStart(.warframe) else { return }
        begin(.warframe)
        warframe = .updating(nil)
        app.log.write("updates: DE's launcher updates Warframe")
        let game = app.services.game
        let (steps, continuation) = AsyncStream<UpdateStep>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let operation = Task.detached { () -> Result<GameUpdateOutcome, any Error> in
            defer { continuation.finish() }
            do {
                return .success(try await game.updateGame { continuation.yield(.game($0)) })
            } catch {
                return .failure(error)
            }
        }
        follow(operation, steps: steps) { [weak self] in self?.finishWarframe($0) }
    }

    /// Closes DE's launcher (`cancelContentRun`); the next run resumes from what it downloaded.
    func cancelWarframeUpdate() {
        guard running == .warframe, warframe != .cancelling else { return }
        warframe = .cancelling
        app.log.write("updates: Warframe's update cancelled; closing DE's launcher")
        cancelOperation?()
        let game = app.services.game
        Task.detached { await game.cancelContentRun() }
    }

    private func apply(game state: ContentRunState) {
        guard warframe != .cancelling else { return }
        switch state {
        case .needsEULA:
            warframe = .needsEULA(guessed: false)
        case .mayNeedEULA:
            warframe = .needsEULA(guessed: true)
        default:
            // A tool deadline or a stuck run has nothing to show; keep the last activity.
            guard let activity = TrackActivity(state) else { return }
            warframe = .updating(activity)
        }
    }

    private func finishWarframe(_ result: Result<GameUpdateOutcome, any Error>) {
        let cancelled = warframe == .cancelling
        switch result {
        case .success(.upToDate):
            warframe = .finished(updated: false)
            app.log.write("updates: DE's launcher finished; nothing shows it changed anything")
        case .success(.updated):
            warframe = .finished(updated: true)
            app.log.write("updates: DE's launcher finished; it updated Warframe")
        case .success(.eulaDeclined):
            warframe = .failed(L10n.playFailureEULA)
            app.log.write("updates: DE's window closed before its EULA was accepted")
        case .success(.stuck):
            warframe = .failed(L10n.playFailureStuck)
            app.log.write("updates: DE's launcher kept stalling; the update did not finish")
        case .failure(let error):
            if cancelled || error is CancellationError {
                warframe = .idle
                app.log.write("updates: DE's launcher closed")
            } else {
                warframe = .failed(UpdateMessages.warframe(error))
                app.log.write("updates: Warframe: \(error)")
            }
        }
        end()
        app.refreshHome()
    }

    // MARK: Running

    private func begin(_ part: UpdatePart) {
        running = part
        estimator = RateEstimator()
        app.updatesChanged()
    }

    private func end() {
        running = nil
        work = nil
        cancelOperation = nil
        warzagInstall = nil
        app.updatesChanged()
    }

    /// Applies the work's steps as they arrive, then its result; `shutdown` and Cancel can stop the work.
    private func follow<Outcome: Sendable>(_ operation: Task<Outcome, Never>, steps: AsyncStream<UpdateStep>,
                                           finish: @escaping @MainActor (Outcome) -> Void) {
        cancelOperation = { operation.cancel() }
        work = Task { [weak self] in
            for await step in steps { self?.apply(step) }
            finish(await operation.value)
        }
    }

    private func apply(_ step: UpdateStep) {
        switch (running, step) {
        case (.warzag?, .bytes(let received, let total)):
            if case .downloading(let offer, _) = warzag { warzag = .downloading(offer, progress(received, total)) }
        case (.warzag?, .installing):
            if case .downloading(let offer, _) = warzag { warzag = .installing(offer) }
        case (.engine?, .bytes(let received, let total)):
            if case .downloading(let offer, _) = engine { engine = .downloading(offer, progress(received, total)) }
        case (.engine?, .verifying):
            if let offer = engine.offerInProgress { engine = .verifying(offer) }
        case (.engine?, .installing):
            if let offer = engine.offerInProgress { engine = .installing(offer) }
        case (.engine?, .settingUpWindows):
            engine = .settingUpWindows
        case (.warframe?, .game(let state)):
            apply(game: state)
        default:
            break
        }
    }

    /// Bytes with the speed and the time left, as setup's downloads show them.
    private func progress(_ received: Int64, _ total: Int64) -> ProgressSnapshot {
        var snapshot = ProgressSnapshot.bytes(received, of: total > 0 ? total : nil)
        snapshot.bytesPerSecond = estimator.add(bytes: received, at: app.services.clock.now)
        snapshot.secondsRemaining = RateEstimator.secondsRemaining(snapshot)
        return snapshot
    }

    /// The running update's progress, for Home while Play waits for it.
    func progress(of part: UpdatePart) -> ProgressSnapshot? {
        switch part {
        case .warzag: if case .downloading(_, let progress) = warzag { return progress }
        case .engine: if case .downloading(_, let progress) = engine { return progress }
        case .warframe: if case .updating(let activity) = warframe { return activity?.progress }
        }
        return nil
    }

    /// Stops a download, DE's launcher or the prefix set-up. A Warzag install that has begun finishes; one that has not
    /// never begins. Returns once the work has ended (the termination watchdog bounds the wait).
    func shutdown() async {
        shuttingDown = true
        guard let work else { return }
        // Decided through the install's claim, because the `warzag` state lags behind the operation.
        if warzagInstall?.claim() ?? true { cancelOperation?() }
        await work.value
    }

    // MARK: Rows

    func row(_ part: UpdatePart) -> UpdateRow {
        switch part {
        case .warzag: warzagRow
        case .engine: engineRow
        case .warframe: warframeRow
        }
    }

    private var warzagRow: UpdateRow {
        let version = currentVersion
        var row = UpdateRow(title: L10n.appName, detail: L10n.updatesVersionBuild(version.version, version.build),
                            status: L10n.updatesNotChecked, tone: .neutral)
        switch warzag {
        case .unchecked: break
        case .checking: row.status = L10n.checking
        case .notConfigured: row.status = L10n.updatesNotConfigured
        case .upToDate:
            row.status = L10n.updatesUpToDate
            row.tone = .upToDate
        case .available(let offer):
            row.status = L10n.updatesAvailable(offer.version, Formatting.bytes(offer.bytes))
            row.tone = .available
            row.releaseNotes = offer.releaseNotes
        case .downloading(let offer, let progress):
            row.status = L10n.updatesDownloadingWarzag(offer.version)
            row.working = true
            row.progress = progress
        case .installing:
            row.status = L10n.updatesInstallingWarzag
            row.working = true
        case .failed(let message, _):
            row.status = message
            row.tone = .problem
        }
        if case .failed = warzag, warzagCopy != nil {
            // Installing again would be refused the same way; the player drags the verified copy in instead.
            row.action = .showCopy
        } else if warzag.offerToInstall != nil {
            row.action = .update
            row.actionEnabled = mayStart(.warzag)
        }
        // What's New lists the running version's changes, so it is not offered beside a newer Warzag (Update, Show in
        // Finder) or while one downloads and installs.
        row.showsWhatsNew = row.action == nil && !row.working
        return row
    }

    private var engineRow: UpdateRow {
        var row = UpdateRow(title: L10n.trackTitle(.engine),
                            detail: app.runtime.map { L10n.updatesVersion($0.version) } ?? L10n.updatesEngineNotInstalled,
                            status: L10n.updatesNotChecked, tone: .neutral)
        if let work = engineWork {
            // Also without a feed: the prefix is set up for whatever engine is current.
            row.status = work.status
            row.working = true
            row.progress = work.progress
            return row
        }
        switch engineSource {
        case .setup: row.status = L10n.updatesEngineSetup
        case .noFeed: row.status = L10n.updatesEngineNoFeed
        case .development: row.status = L10n.updatesEngineDevelopment
        case .feed:
            switch engine {
            case .checking:
                row.status = L10n.checking
            case .upToDate:
                row.status = L10n.updatesUpToDate
                row.tone = .upToDate
            case .available(let offer):
                row.status = L10n.updatesAvailable(offer.version, Formatting.bytes(offer.bytes))
                row.tone = .available
            case .failed(let message, _):
                row.status = message
                row.tone = .problem
            case .unchecked, .downloading, .verifying, .installing, .settingUpWindows:
                break
            }
            if engine.offerToInstall != nil {
                row.action = .update
                row.actionEnabled = mayStart(.engine)
            }
        }
        if prefixNeedsSetUp {
            if case .failed(let message, _) = engine {
                row.status = message
            } else {
                row.status = L10n.homePrefixNeedsSetUp
            }
            row.tone = .problem
            row.action = .setUpAgain
            row.actionEnabled = mayStart(.engine)
        }
        return row
    }

    /// What the engine row says while its update runs.
    private var engineWork: (status: String, progress: ProgressSnapshot?)? {
        switch engine {
        case .downloading(_, let progress): (L10n.activity(.downloadingEngine), progress)
        case .verifying: (L10n.activity(.verifyingEngine), nil)
        case .installing: (L10n.activity(.installingEngine), nil)
        case .settingUpWindows: (L10n.activity(.settingUpWindows), nil)
        case .unchecked, .checking, .upToDate, .available, .failed: nil
        }
    }

    private var warframeRow: UpdateRow {
        let now = app.services.clock.now
        var row = UpdateRow(title: L10n.trackTitle(.game),
                            detail: app.content?.build.map(L10n.updatesVersion)
                                ?? app.content?.lastUpdate.map { L10n.homeUpdated(Formatting.relative($0, to: now)) },
                            status: L10n.updatesWarframeBeforePlay, tone: .neutral)
        guard app.setup.isReadyToPlay else {
            row.status = L10n.updatesWarframeSetup
            return row
        }
        switch warframe {
        case .idle:
            switch app.content?.state {
            case .needsUpdate: row.status = L10n.updatesWarframeDue
            case .notInstalled: row.status = L10n.homeNotInstalled
            case .installed, nil: break
            }
        case .updating(let activity):
            row.status = activity.map { L10n.activity($0.detail) } ?? L10n.activity(.startingLauncher(restart: 0))
            row.working = true
            row.progress = activity?.progress
        case .needsEULA(let guessed):
            row.status = guessed ? L10n.playEULAGuessed : L10n.playEULA
            row.tone = .problem
            row.showsDEWindow = true
        case .cancelling:
            row.status = L10n.activity(.closingLauncher)
            row.working = true
        case .finished(let updated):
            row.status = updated ? L10n.updatesWarframeUpdated : L10n.updatesWarframeUpToDate
            row.tone = .upToDate
        case .failed(let message):
            row.status = message
            row.tone = .problem
        }
        switch warframe {
        case .updating, .needsEULA:
            row.action = .cancel
        case .cancelling:
            break
        case .idle, .finished, .failed:
            guard app.content?.state != .notInstalled else { break }
            row.action = .updateNow
            row.actionEnabled = mayStart(.warframe) && !prefixNeedsSetUp
            if prefixNeedsSetUp {
                // The engine's row (Try Again) or Repair sets the prefix up.
                row.status = L10n.updatesWarframeWaitsForPrefix
                row.tone = .neutral
            }
        }
        return row
    }
}

/// One sentence for each way a check or an update fails; the detail goes to Warzag.log.
enum UpdateMessages {
    static func warzag(_ error: any Error) -> String {
        switch error as? AppUpdateError {
        case .unreachable: L10n.updatesUnreachable
        case .rejected: L10n.updatesWarzagRejected
        case .requiresNewerMacOS(let version): L10n.updatesWarzagNeedsMacOS(version)
        case .cannotReplace: L10n.updatesWarzagCannotReplace
        case .gameRunning: L10n.updatesGameRunning
        case .notConfigured: L10n.updatesNotConfigured
        case nil: L10n.updatesWarzagFailed
        }
    }

    /// A failed engine check or update step. Feed refusals read as in setup (`EngineFeedFailure`), except a manifest
    /// that needs a newer Warzag, which Updates can install first. Other check failures say the check failed, not an
    /// install.
    static func engine(_ error: any Error, checking: Bool) -> String {
        if error is GameIsRunning { return L10n.updatesGameRunning }
        if let error = error as? RuntimeServiceError, case .manifestRejected(.requiresNewerApp) = error {
            return L10n.updatesEngineNeedsNewerWarzag
        }
        guard checking else { return EngineFeedFailure.failure(for: error).message }
        switch error {
        case is URLError, is HTTPError, is DownloadError:
            return L10n.updatesUnreachable
        case let error as RuntimeServiceError:
            switch error {
            case .manifestRejected, .insecureFeed, .invalidSigner, .invalidPublicKey:
                return EngineFeedFailure.failure(for: error).message
            default:
                return L10n.updatesEngineCheckFailed
            }
        default:
            return L10n.updatesEngineCheckFailed
        }
    }

    static func warframe(_ error: any Error) -> String {
        switch error as? PlayFailure {
        case .busy: L10n.updatesGameRunning
        case .needsRepair: L10n.updatesWarframeNeedsRepair
        case .notInstalled: L10n.playFailureNotInstalled
        case .updateDeclinedEULA: L10n.playFailureEULA
        case .updateStuck: L10n.playFailureStuck
        case .steamNotSignedIn, .other, nil: L10n.updatesWarframeFailed
        }
    }
}

extension UpdatesModel {
    /// Runs `body` off the main actor and returns its result or error.
    nonisolated static func offMainActor<Value: Sendable>(
        _ body: @escaping @Sendable () async throws -> Value) async -> Result<Value, any Error> {
        await Task.detached {
            do {
                return .success(try await body())
            } catch {
                return .failure(error)
            }
        }.value
    }
}
