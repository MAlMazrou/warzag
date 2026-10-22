import ContentKit
import Foundation
import ProfileKit
import WarzagCore
import WineKit

/// What the player (or `warzagctl play`) chose for one session.
public struct PlayOptions: Sendable, Equatable {
    /// Sign in through the user's Mac Steam (the bridge); false is DE's own email login, with no Steam variables.
    public var steam: Bool
    /// Apple's Metal Performance HUD, with its per-second log.
    public var hud: Bool
    public var renderer: Renderer
    /// Warframe's `-language:` (DE's two-letter code).
    public var language: String
    /// NVEXT: an NVIDIA identity for experiments (`warzagctl play --nvext`, `PresetCatalog.nvextDefault`).
    public var nvext: Bool

    public init(steam: Bool = true, hud: Bool = false, renderer: Renderer = .dxmt, language: String = "en",
                nvext: Bool = PresetCatalog.nvextDefault) {
        self.steam = steam
        self.hud = hud
        self.renderer = renderer
        self.language = language
        self.nvext = nvext
    }
}

/// Exactly how the game host is opened: LaunchServices opens `application` (whose main executable, `executable`, is
/// the Wine loader) with these arguments and environment.
public struct GameLaunch: Sendable, Equatable {
    public var application: URL
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var renderer: RendererOptions
    public var steam: Bool
}

/// Builds the game launch: the steam.exe shim runs the game from X:\ and holds the session (a job object) until
/// Warframe exits.
public enum GameLaunchBuilder {
    /// The arguments DE's launcher hands Warframe; the game accepts them without the launcher in between.
    public static func gameArguments(steam: Bool, language: String) -> [String] {
        ["-windowMode:2", "-graphicsDriver:dx11", "-gpuPreference:2", "-cluster:public", "-language:\(language)"]
            + (steam ? ["-clienttype:Steam"] : [])
    }

    /// steam.exe, its working directory and the game, then the game's own arguments.
    public static func arguments(steam: Bool, language: String) -> [String] {
        [GameInstallation.steamWindowsPath, "--cwd", GameInstallation.libraryRoot, GameInstallation.gameWindowsPath]
            + gameArguments(steam: steam, language: language)
    }

    /// `MTL_HUD_ENABLED` shows Apple's HUD; `MTL_HUD_LOG_ENABLED` also logs its numbers.
    public static let hudEnvironment = ["MTL_HUD_ENABLED": "1", "MTL_HUD_LOG_ENABLED": "1"]

    /// The frame cap comes from ProfileKit's `SessionGraphics` (as `warzagctl env --session` shows it) and NVEXT only
    /// from `options.nvext`.
    public static func launch(installation: GameInstallation, options: PlayOptions, hardware: HardwareProfile,
                              steamClientDirectory: URL, inherited: [String: String]) -> GameLaunch {
        let graphics = SessionGraphics.make(for: hardware, nvext: options.nvext)
        let renderer = RendererOptions(renderer: options.renderer, frameRateCap: graphics.frameRateCap,
                                       enableNVEXT: graphics.enableNVEXT)
        let steam = options.steam ? SteamSession(clientDirectory: steamClientDirectory) : nil
        var environment = WineEnvironment.gameSession(prefix: installation.prefix.root, host: installation.host,
                                                      renderer: renderer, steam: steam, inherited: inherited)
        if options.hud { environment.merge(hudEnvironment) { $1 } }
        return GameLaunch(application: installation.host.bundle, executable: installation.host.wine,
                          arguments: arguments(steam: options.steam, language: options.language),
                          environment: environment, renderer: renderer, steam: options.steam)
    }
}

/// What EE.log says during a session, without anything personal: "Logged in <name>" becomes `.loggedIn`.
public enum GameSignal: String, Codable, Equatable, Sendable, CaseIterable {
    case steamActive, steamLogin, loggedIn
    case steamNotRunning, steamOutOfDate, steamInitFailed, mustRunFromLauncher, metalViewFailed, downloadCorrupted
    /// Warframe is quitting (its quit command, or the last step of its shutdown). Not a problem: Play watches for a
    /// game that never finishes its exit (`PlayConfiguration.closingGracePeriod`).
    case closing

    public init?(_ event: ContentEvent) {
        switch event {
        case .steamActive: self = .steamActive
        case .steamLogin: self = .steamLogin
        case .loggedIn: self = .loggedIn
        case .steamNotRunning: self = .steamNotRunning
        case .steamOutOfDate: self = .steamOutOfDate
        case .steamInitFailed: self = .steamInitFailed
        case .mustRunFromLauncher: self = .mustRunFromLauncher
        case .metalViewFailed: self = .metalViewFailed
        case .downloadCorrupted: self = .downloadCorrupted
        case .closing: self = .closing
        default: return nil
        }
    }

    public var isError: Bool {
        switch self {
        case .steamActive, .steamLogin, .loggedIn, .closing: false
        default: true
        }
    }

    public var message: String {
        switch self {
        case .steamActive: "Warframe reached Steam through the bridge"
        case .steamLogin: "Warframe is signing in with Steam"
        case .loggedIn: "signed in to Warframe"
        case .steamNotRunning: "Warframe says Steam is not running"
        case .steamOutOfDate: "Warframe says the Steam client is out of date"
        case .steamInitFailed: "Warframe could not initialize Steam (license or sign-in)"
        case .mustRunFromLauncher: "this Warframe build refuses to start without DE's launcher"
        case .metalViewFailed: "DXMT could not create its Metal view: the runtime is damaged"
        case .downloadCorrupted: "Warframe reports corrupted downloaded data"
        case .closing: "Warframe is closing"
        }
    }
}

public enum PlayEvent: Equatable, Sendable {
    /// DE's launcher updates the game first.
    case updating(ContentRunState)
    case opening
    case started(processIdentifier: Int32)
    case signal(GameSignal)
    /// While Warframe was closing, DE's launcher took over (it wrote its logs or runs in the prefix) for an update or a
    /// restart. Play never ends the launcher; the wait for a hang at exit restarts from its last sign of life.
    case handedOverToLauncher
    /// EE.log said Warframe was closing `seconds` ago, the closing went quiet, and Warframe still runs without DE's
    /// launcher: it hung at exit, and `wineserver -k` ends the prefix. The session then ends as usual.
    case hungAtExit(seconds: TimeInterval)
    case exited(seconds: TimeInterval)
    /// `forced`: Wine was still running after the grace period and `wineserver -k` ended it.
    case cleanedUp(forced: Bool)
    /// A problem that did not stop the session, such as a Wine tool stopped at its deadline.
    case warning(String)
}

public enum PlayError: Error, Equatable, CustomStringConvertible {
    case notReady([PrefixIssue])
    /// The runtime host's code signature no longer verifies (or is no longer its installer's): nothing was started.
    case hostSignatureInvalid(String)
    case updateDidNotComplete(LauncherRunOutcome)
    case openFailed(String)

    public var description: String {
        switch self {
        case .notReady(let issues): "Warframe cannot start: " + issues.map(\.description).joined(separator: "; ")
        case .hostSignatureInvalid(let reason):
            "Warframe was not started: the engine's code signature does not verify (\(reason)); reinstall the engine"
        case .updateDidNotComplete(let outcome):
            switch outcome {
            case .eulaDeclined: "DE's EULA was not accepted, so DE's launcher could not update the game"
            case .stuck: "DE's launcher could not update the game (it stalled repeatedly)"
            case .completed: "the update did not complete"
            }
        case .openFailed(let reason): "could not open the game host: \(reason)"
        }
    }
}

public struct PlayResult: Equatable, Sendable {
    /// Every signal EE.log produced, in order (`closing` once for each run of the game).
    public var signals: [GameSignal]
    public var seconds: TimeInterval
    public var forcedCleanup: Bool
    /// Warframe hung at exit and Warzag ended the prefix with `wineserver -k` (`PlayEvent.hungAtExit`).
    public var hungAtExit: Bool
}

public struct PlayConfiguration: Sendable, Equatable {
    public var pollInterval: Duration
    /// After the game exits, how long Wine gets to wind down on its own before `wineserver -k`.
    public var cleanupGracePeriod: TimeInterval
    /// Bring the game to the front when it opens.
    public var activates: Bool
    /// How long to wait for the prefix to go quiet after the update before giving up on Play.
    public var idleTimeout: TimeInterval
    /// After EE.log says Warframe is closing, how long the closing may go without a sign of life before Play asks Wine
    /// what still runs. Warframe can hang at exit with a thread stuck in pthread_exit; it is then ended with
    /// `wineserver -k`.
    public var closingGracePeriod: TimeInterval

    public init(pollInterval: Duration = .seconds(1), cleanupGracePeriod: TimeInterval = 10, activates: Bool = true,
                idleTimeout: TimeInterval = 30, closingGracePeriod: TimeInterval = 30) {
        self.pollInterval = pollInterval
        self.cleanupGracePeriod = cleanupGracePeriod
        self.activates = activates
        self.idleTimeout = idleTimeout
        self.closingGracePeriod = closingGracePeriod
    }
}

/// One Play: check the runtime host's code signature, update through DE's launcher (unless skipped), open the host
/// through LaunchServices, follow EE.log from its end, wait for the steam.exe shim to exit (it outlives the game),
/// then let Wine wind down and `wineserver -k` whatever is left.
///
/// A game that hangs at exit is ended too: once EE.log says Warframe is closing and nothing has shown a sign of life
/// for `closingGracePeriod`, Play asks Wine what runs (`tasklist`). Warframe without DE's launcher has hung and gets
/// `wineserver -k`; DE's launcher running or writing its logs is a hand-off (an update or a restart) and restarts the
/// wait. Without the closing signal nothing is ended, however long the session.
///
/// Cancelling stops the watching only; the game keeps running. `closeGame()` is the explicit stop.
public struct PlaySession: Sendable {
    public let content: ContentService
    public let configuration: PlayConfiguration

    public init(content: ContentService, configuration: PlayConfiguration = PlayConfiguration()) {
        self.content = content
        self.configuration = configuration
    }

    var installation: GameInstallation { content.installation }
    var context: GameContext { content.context }

    public func run(_ launch: GameLaunch, update: Bool,
                    events: @escaping @Sendable (PlayEvent) -> Void) async throws -> PlayResult {
        let task = GameTask.play(steam: launch.steam, renderer: launch.renderer.renderer)
        // Check before a possibly long update; activity is checked after it.
        let issues = content.inspector.issues(for: task, ignoringActivity: true)
        guard issues.isEmpty else { throw PlayError.notReady(issues) }
        // Before any of the host's code runs, DE's launcher included.
        do {
            try context.hostSignatures.verify(installation.host)
        } catch {
            throw PlayError.hostSignatureInvalid(String(describing: error))
        }

        if update {
            let outcome = try await content.update { events(.updating($0)) }
            guard case .completed = outcome else { throw PlayError.updateDidNotComplete(outcome) }
        }
        _ = await content.waitUntilPrefixIsIdle(timeout: configuration.idleTimeout)
        // Cancelled while waiting (the wait itself just stops): never open the game after that.
        try Task.checkCancellation()
        if let pid = context.probe.wineserver(for: installation.prefix.root) {
            throw PlayError.notReady([.prefixBusy(wineserver: pid)])
        }

        var eeLog = LogMonitor(url: installation.prefix.eeLog, kind: .ee)
        try eeLog.seekToEnd(context.fileSystem)
        // Launcher.log or Preprocess.log growing while Warframe closes is a hand-off to DE's launcher. Read from their
        // ends: the update before Play wrote them.
        var launcherLogs = [LogTailer(url: installation.prefix.launcherLog),
                            LogTailer(url: installation.prefix.preprocessLog)]
        for index in launcherLogs.indices { try? launcherLogs[index].seekToEnd(context.fileSystem) }
        // Any line Warframe writes while it closes is a sign of life; a hung exit writes nothing after the closing
        // signal.
        var gameLog = LogTailer(url: installation.prefix.eeLog)
        try? gameLog.seekToEnd(context.fileSystem)

        events(.opening)
        let process: any RunningProcess
        do {
            process = try await context.opener.openNewInstance(of: launch.application, arguments: launch.arguments,
                                                               environment: launch.environment,
                                                               activates: configuration.activates)
        } catch {
            throw PlayError.openFailed(String(describing: error))
        }
        let started = context.clock.now
        events(.started(processIdentifier: process.processIdentifier))

        var signals: [GameSignal] = []
        // This run of the game has said it is closing, and the watch for a hang at exit while that lasts.
        var closingSeen = false
        var closing: ClosingWatch?
        var hungAtExit = false
        func readLog() {
            for event in (try? eeLog.poll(context.fileSystem)) ?? [] {
                // A new EE.log is a new run of the game: the closing of the one before is over.
                if event == .logRestarted {
                    closingSeen = false
                    closing = nil
                }
                guard let signal = GameSignal(event) else { continue }
                if signal == .closing {
                    // The quit command and the end of the shutdown are one closing; the wait starts at the first.
                    guard !closingSeen else { continue }
                    closingSeen = true
                    closing = ClosingWatch(since: context.clock.now)
                }
                signals.append(signal)
                events(.signal(signal))
            }
        }
        // Whether DE's launcher or its applet wrote anything since the last look.
        func launcherWrote() -> Bool {
            var wrote = false
            for index in launcherLogs.indices {
                guard let chunk = try? launcherLogs[index].poll(context.fileSystem) else { continue }
                if chunk.restarted || chunk.lines.contains(where: { !$0.allSatisfy(\.isWhitespace) }) { wrote = true }
            }
            return wrote
        }
        // Warframe wrote EE.log while it closes: the wait starts over.
        func gameWrote() {
            guard let chunk = try? gameLog.poll(context.fileSystem),
                  chunk.lines.contains(where: { !$0.allSatisfy(\.isWhitespace) }), var watch = closing else { return }
            watch.gameActive(at: context.clock.now)
            closing = watch
        }
        // DE's launcher showed a sign of life while Warframe closes: the wait starts over; the first is the hand-off.
        func launcherActive() {
            guard var watch = closing else { return }
            if watch.launcherActive(at: context.clock.now) { events(.handedOverToLauncher) }
            closing = watch
        }
        while process.isRunning {
            // Cancelling stops the watching only; the game keeps running.
            try await context.clock.sleep(for: configuration.pollInterval)
            readLog()
            gameWrote()
            if launcherWrote() { launcherActive() }
            guard !hungAtExit, let watch = closing, process.isRunning,
                  watch.isQuiet(at: context.clock.now, for: configuration.closingGracePeriod) else { continue }
            // The process Play opened is the steam.exe shim, alive while anything in its job runs: what runs is
            // Wine's to say.
            let listed = await content.runningImages()
            // Cancelled meanwhile (the tool was stopped too): decide nothing and end nothing.
            try Task.checkCancellation()
            if case .failure(let failure) = listed { events(.warning(failure.description)) }
            // What happened while Wine was asked comes first: a new run, DE's launcher writing or the game host's exit
            // make the answer stale.
            readLog()
            gameWrote()
            if launcherWrote() { launcherActive() }
            guard closing == watch, process.isRunning else { continue }
            switch watch.verdict(running: try? listed.get()) {
            case .handedOver:
                launcherActive()
            case .over:
                closing = nil
            case .hung:
                // Hung at exit. The game host ends with the prefix, and the loop then finishes as for any exit.
                closing = nil
                hungAtExit = true
                events(.hungAtExit(seconds: context.clock.now.timeIntervalSince(watch.since)))
                if let problem = await content.runTool(.wineserverKill) { events(.warning(problem)) }
            }
        }
        readLog()
        let seconds = context.clock.now.timeIntervalSince(started)
        events(.exited(seconds: seconds))

        let idle = await content.waitUntilPrefixIsIdle(timeout: configuration.cleanupGracePeriod)
        if !idle {
            if let problem = await content.runTool(.wineserverKill) { events(.warning(problem)) }
            _ = await content.waitUntilPrefixIsIdle(timeout: 10)
        }
        events(.cleanedUp(forced: !idle))
        return PlayResult(signals: signals, seconds: seconds, forcedCleanup: !idle, hungAtExit: hungAtExit)
    }

    /// Stops the game the way a player quitting does, then Wine: WM_CLOSE to Warframe and to DE's launcher (`taskkill`
    /// without /F), up to `cleanupGracePeriod` for the prefix to wind down, then `wineserver -k`. Harmless when
    /// nothing runs. Returns the problems to report (a tool that passed its deadline).
    @discardableResult
    public func closeGame() async -> [String] {
        var problems: [String] = []
        for image in [GameInstallation.gameImageName, GameInstallation.launcherImageName] {
            if let problem = await content.runTool(.taskkill(imageName: image)) { problems.append(problem) }
        }
        if !(await content.waitUntilPrefixIsIdle(timeout: configuration.cleanupGracePeriod)) {
            if let problem = await content.runTool(.wineserverKill) { problems.append(problem) }
            _ = await content.waitUntilPrefixIsIdle(timeout: 10)
        }
        return problems
    }
}

/// How Play follows one run of the game after EE.log said it is closing (`PlaySession`).
struct ClosingWatch: Equatable, Sendable {
    /// What a closing that has gone quiet means, from what runs in the prefix.
    enum Verdict: Equatable, Sendable {
        /// DE's launcher runs: Warframe handed over to it, and the wait starts over.
        case handedOver
        /// Warframe still runs without DE's launcher: it hung at exit.
        case hung
        /// Nothing to end for this run: Warframe has gone (or, with no list after a hand-off, nothing shows it runs).
        case over
    }

    /// When EE.log said so.
    let since: Date
    /// The closing's last sign of life: the closing signal, then Warframe writing EE.log, or DE's launcher writing its
    /// logs or running in the prefix.
    private(set) var lastSign: Date
    /// DE's launcher took over while Warframe closed (an update or a restart).
    private(set) var handedOver = false

    init(since: Date) {
        self.since = since
        lastSign = since
    }

    /// No sign of life for `gracePeriod`: time to ask what still runs.
    func isQuiet(at now: Date, for gracePeriod: TimeInterval) -> Bool {
        now.timeIntervalSince(lastSign) >= gracePeriod
    }

    /// Warframe wrote EE.log: its shutdown is still going (or the game is still being played), and the wait starts
    /// over.
    mutating func gameActive(at now: Date) {
        if now > lastSign { lastSign = now }
    }

    /// DE's launcher showed a sign of life: the wait starts over. True the first time, which is the hand-off itself.
    mutating func launcherActive(at now: Date) -> Bool {
        if now > lastSign { lastSign = now }
        let first = !handedOver
        handedOver = true
        return first
    }

    /// From the image names `ContentService.runningImages()` lists (lowercased), or nil when there is no list. Without
    /// one, DE's logs decide: quiet since the closing signal, Warframe hung; after a hand-off, Play never ends the
    /// launcher on a guess.
    func verdict(running: Set<String>?) -> Verdict {
        guard let running else { return handedOver ? .over : .hung }
        if running.contains(GameInstallation.launcherImageName.lowercased()) { return .handedOver }
        return running.contains(GameInstallation.gameImageName.lowercased()) ? .hung : .over
    }
}
