import EngineKit
import Foundation
import GameKit
import WarzagCore

/// How much free space setup asks for: a fresh install needs `Platform.minimumLibraryBytes`; whatever Warframe already
/// occupies counts towards it, but updates always need some room.
enum StoragePolicy {
    static let minimumForUpdates: Int64 = 10_000_000_000

    static func requiredFreeBytes(libraryBytes: Int64) -> Int64 {
        max(minimumForUpdates, Platform.minimumLibraryBytes - max(0, libraryBytes))
    }

    static func isEnough(_ check: StorageCheck) -> Bool {
        guard let volume = check.volume, !volume.isCaseSensitive else { return false }
        return (volume.availableCapacity ?? 0) >= requiredFreeBytes(libraryBytes: check.libraryBytes)
    }
}

/// Does setup's steps with the app's services. Every step checks before it acts, because after a crash or a restart
/// the interrupted step runs again from the top; long steps report live progress to the activity sink. Errors become
/// one sentence for the UI; the technical detail goes to Warzag.log.
struct AppStepPerformer: SetupStepPerforming {
    let services: AppServices
    let paths: WarzagPaths
    let activity: ActivitySink
    let log: AppLog
    /// Everything but the read-only checks on this Mac waits for Get Started.
    var gate = StartGate(open: true)
    /// How long startSteam waits for steam_osx (its bootstrapper may update itself first).
    var steamStartTimeout = 90
    /// How long waitForSignIn watches a Steam that is still logging on before asking the player.
    var signInGrace = 5

    func perform(_ step: SetupStep, in state: SetupState) async -> StepOutcome {
        if step.track != .preflight {
            await gate.wait()
            // Woken by cancellation (Warzag is quitting): do nothing; the orchestrator drops this result.
            if Task.isCancelled { return .offline }
        }
        let outcome = await run(step, in: state)
        if case .failed(let failure) = outcome {
            log.write("setup: \(step.rawValue) failed (\(failure.kind.rawValue)): \(failure.message)")
        }
        return outcome
    }

    private func run(_ step: SetupStep, in state: SetupState) async -> StepOutcome {
        switch step.track {
        case .preflight: await preflight(step, in: state)
        case .engine: await engine(step, in: state)
        case .steam: await steam(step, in: state)
        case .game: await game(step)
        }
    }

    // MARK: Preflight

    private func preflight(_ step: SetupStep, in state: SetupState) async -> StepOutcome {
        switch step {
        case .checkPlatform:
            let hardware = services.system.hardware()
            guard hardware.isAppleSilicon else {
                return .failed(SetupFailure(.unsupported, L10n.failureNeedsAppleSilicon))
            }
            guard let os = VersionNumber(hardware.macOSVersion), os >= Platform.minimumMacOS else {
                return .failed(SetupFailure(.unsupported, L10n.failureNeedsMacOS(Platform.minimumMacOS.description)))
            }
            return .completed
        case .checkLocation:
            if services.system.applicationLocation().inApplicationsFolder { return .completed }
            guard state.isApproved(.moveToApplications) else { return .needsUser(.moveToApplications) }
            do {
                try await services.system.moveToApplications()
            } catch {
                log.write("setup: move to Applications: \(error)")
                return .failed(SetupFailure(.permanent, L10n.failureMove))
            }
            // The copy in Applications is starting and this one is quitting; the quit (deferred to the run loop by
            // AppTermination) shuts setup down and cancels this step. Completing it now would let this copy start the
            // engine, Steam and game steps next to the new copy until it is gone.
            await StartGate(open: false).wait()
            return .offline
        case .checkStorage:
            return StoragePolicy.isEnough(services.system.storage(for: paths.warframeLibrary))
                ? .completed : .needsUser(.chooseStorage)
        case .checkNetwork:
            return await services.system.networkIsAvailable() ? .completed : .offline
        default:
            return .completed
        }
    }

    // MARK: Engine

    /// The engine comes from the release page's signed feed: the build names one and no development engine is set.
    private var usesFeed: Bool {
        let engine = services.engine
        return engine.feedURL() != nil && engine.developmentRuntime() == nil
    }

    private func engine(_ step: SetupStep, in state: SetupState) async -> StepOutcome {
        let engine = services.engine
        let activity = activity
        switch step {
        case .fetchManifest:
            // A development build (WARZAG_DEV_RUNTIME or Settings › Advanced) wins; then the release page's feed; a
            // build without a feed needs an engine installed already (warzagctl runtime install).
            if let development = engine.developmentRuntime() {
                return development.channel == nil
                    ? .failed(SetupFailure(.permanent, L10n.failureNotAnEngine)) : .completed
            }
            if usesFeed {
                activity.report(.engine, TrackActivity(detail: .checkingForEngine))
                return await fromFeed(step) {
                    let offer = try await engine.fetchEngineManifest()
                    log.write("setup: the release page offers engine \(offer.id) (\(offer.bytes) bytes)"
                        + (offer.installed ? ", already installed" : ""))
                }
            }
            if engine.activeRuntime() != nil { return .completed }
            return .failed(SetupFailure(.permanent, L10n.failureNoEngine))
        case .downloadRuntime:
            if let development = engine.developmentRuntime() {
                activity.report(.engine, TrackActivity(detail: .registeringEngine))
                do {
                    let runtime = try await engine.registerDevelopmentRuntime(development)
                    log.write("setup: development engine \(runtime.id) (channel \(runtime.channel.rawValue))")
                    return .completed
                } catch {
                    log.write("setup: use-local \(development.bundle.plainPath): \(error)")
                    return .failed(SetupFailure(.permanent, L10n.failureRegisterEngine))
                }
            }
            guard usesFeed else { return .completed }
            activity.report(.engine, TrackActivity(detail: .downloadingEngine))
            return await fromFeed(step) {
                try await engine.downloadEngine { received, total in
                    activity.report(.engine, TrackActivity(detail: .downloadingEngine,
                                                           progress: .bytes(received, of: total)))
                }
            }
        case .verifyRuntime:
            if usesFeed {
                // The new engine is checked here and becomes current only in the next step.
                activity.report(.engine, TrackActivity(detail: .verifyingEngine))
                return await fromFeed(step) { try await engine.verifyEngine() }
            }
            return activeEngineOutcome()
        case .activateRuntime:
            if usesFeed {
                activity.report(.engine, TrackActivity(detail: .installingEngine))
                let outcome = await fromFeed(step) {
                    let runtime = try await engine.activateEngine()
                    log.write("setup: engine \(runtime.id) is current (channel \(runtime.channel.rawValue))")
                }
                guard outcome == .completed else { return outcome }
            }
            return activeEngineOutcome()
        case .createPrefix:
            activity.report(.engine, TrackActivity(detail: .settingUpWindows))
            do {
                let summary = try await engine.setUpPrefix()
                log.write("setup: prefix \(summary.created ? "created" : "updated"), X: -> \(summary.library)")
                return .completed
            } catch let error as PrefixError {
                log.write("setup: prefix: \(error)")
                switch error {
                case .libraryUnavailable: return .needsUser(.chooseStorage)
                default: return .failed(SetupFailure(.transient, L10n.failurePrefix))
                }
            } catch {
                log.write("setup: prefix: \(error)")
                return .failed(SetupFailure(.transient, L10n.failurePrefix))
            }
        default:
            return .completed
        }
    }

    // MARK: Steam

    private func steam(_ step: SetupStep, in state: SetupState) async -> StepOutcome {
        let steam = services.steam
        switch step {
        case .installSteam:
            if steam.status().installed { return .completed }
            guard state.isApproved(.installSteam) else { return .needsUser(.installSteam) }
            activity.report(.steam, TrackActivity(detail: .installingSteam))
            do {
                try await steam.install()
                return .completed
            } catch {
                log.write("setup: Steam install: \(error)")
                return await networkOr(.failed(SetupFailure(.transient, L10n.failureSteamInstall)))
            }
        case .startSteam:
            if steam.status().running { return .completed }
            activity.report(.steam, TrackActivity(detail: .startingSteam))
            do {
                try await steam.start()
            } catch {
                log.write("setup: Steam start: \(error)")
                return .failed(SetupFailure(.transient, L10n.failureSteamStart))
            }
            for _ in 0..<steamStartTimeout {
                if steam.status().running { return .completed }
                guard (try? await services.clock.sleep(for: .seconds(1))) != nil else { break }
            }
            return steam.status().running ? .completed : .failed(SetupFailure(.transient, L10n.failureSteamStart))
        case .waitForSignIn:
            for _ in 0..<signInGrace {
                if steam.status().signedIn { return .completed }
                guard (try? await services.clock.sleep(for: .seconds(1))) != nil else { break }
            }
            return steam.status().signedIn ? .completed : .needsUser(.signInToSteam)
        case .checkLicense:
            activity.report(.steam, TrackActivity(detail: .checkingLicense))
            let result = await services.engine.probeSteamLicense()
            log.write("setup: license probe: \(result)")
            switch result {
            case .owned: return .completed
            case .notOwned: return .needsUser(.addWarframeToLibrary)
            case .signedOut:
                // Steam told the probe nobody is logged on. If Steam's own log says someone is (still connecting, or
                // offline mode), a sign-in card would be wrong, and the heartbeat would dismiss it at once and run the
                // probe again every few seconds without end: retry with back-off instead.
                return steam.status().signedIn
                    ? .failed(SetupFailure(.transient, L10n.failureSteamOffline)) : .needsUser(.signInToSteam)
            case .steamNotRunning: return .failed(SetupFailure(.transient, L10n.failureSteamNotRunning))
            case .timedOut, .failed: return .failed(SetupFailure(.transient, L10n.failureProbe))
            case .bridgeFailed: return .failed(SetupFailure(.permanent, L10n.failureBridge))
            }
        default:
            return .completed
        }
    }

    // MARK: Game

    private func game(_ step: SetupStep) async -> StepOutcome {
        let game = services.game
        let activity = activity
        let report: @Sendable (ContentRunState) -> Void = { activity.report(.game, TrackActivity($0)) }
        switch step {
        case .downloadInstaller:
            if game.launcherExtracted() { return .completed }
            do {
                try await game.downloadInstaller(progress: report)
                return .completed
            } catch {
                return await contentFailure(error, step, L10n.failureInstallerDownload)
            }
        case .extractGame:
            if game.launcherExtracted() { return .completed }
            do {
                try await game.extractInstaller(progress: report)
                return .completed
            } catch {
                return await contentFailure(error, step, L10n.failureExtract)
            }
        case .applyProfile:
            do {
                let seeded = try game.seedProfile()
                log.write("setup: EE.cfg " + (seeded ? "seeded for this Mac" : "already exists; left alone"))
                return .completed
            } catch {
                log.write("setup: EE.cfg seed: \(error)")
                return .failed(SetupFailure(.permanent, L10n.failureProfile))
            }
        case .acceptEULA:
            if game.eulaAccepted() { return .completed }
            do {
                switch try await game.waitForEULA(progress: report) {
                case .accepted: return .completed
                case .declined: return .needsUser(.acceptEULA)
                case .stuck: return .failed(SetupFailure(.transient, L10n.failureLauncherStuck))
                }
            } catch {
                return await contentFailure(error, step, L10n.failureLauncher)
            }
        case .pinDirectX11:
            do {
                try await game.pinDirectX11()
                return .completed
            } catch {
                log.write("setup: DirectX 11: \(error)")
                return .failed(SetupFailure(.transient, L10n.failureDirectX11))
            }
        case .downloadContent:
            do {
                switch try await game.downloadContent(progress: report) {
                case .completed: return .completed
                case .eulaDeclined: return .needsUser(.acceptEULA)
                case .stuck: return await networkOr(.failed(SetupFailure(.transient, L10n.failureDownloadStuck)))
                }
            } catch {
                return await contentFailure(error, step, L10n.failureDownload)
            }
        default:
            return .completed
        }
    }

    private func contentFailure(_ error: any Error, _ step: SetupStep, _ message: String) async -> StepOutcome {
        log.write("setup: \(step.rawValue): \(error)")
        if let content = error as? ContentError, case .prefixNotReady(let issues) = content,
           issues.contains(where: \.needsPrefixRepair) {
            return .failed(SetupFailure(.permanent, L10n.failureNeedsRepair))
        }
        if error is InstallerCheckError { return .failed(SetupFailure(.permanent, L10n.failureInstallerCheck)) }
        return await networkOr(.failed(SetupFailure(.transient, message)))
    }

    /// The active runtime is on disk and not revoked.
    private func activeEngineOutcome() -> StepOutcome {
        guard services.engine.activeRuntime() != nil else {
            return .failed(SetupFailure(.permanent, L10n.failureEngineMissing))
        }
        return .completed
    }

    /// Runs one step of the engine feed. A failure keeps an engine that is installed already (an update that fails
    /// must never stand between the player and the game); without one it becomes one sentence
    /// (`EngineFeedFailure`), retried by itself when retrying may help, and paused while the network is down.
    private func fromFeed(_ step: SetupStep, _ body: () async throws -> Void) async -> StepOutcome {
        do {
            try await body()
            return .completed
        } catch {
            log.write("setup: \(step.rawValue): \(error)")
            if let active = services.engine.activeRuntime() {
                log.write("setup: keeping the installed engine \(active.id)")
                return .completed
            }
            let failure = EngineFeedFailure.failure(for: error)
            return failure.kind == .transient ? await networkOr(.failed(failure)) : .failed(failure)
        }
    }

    /// `.offline` when the network is down (the track resumes when it is back), else `outcome`.
    private func networkOr(_ outcome: StepOutcome) async -> StepOutcome {
        await services.system.networkIsAvailable() ? outcome : .offline
    }
}
