import Foundation
import GameKit
import ProfileKit
import SteamHostKit
import Synchronization
import WarzagCore
import WineKit

/// `warzagctl content ...` and `warzagctl play ...`.
enum GameCommands {
    static let content = CommandGroup(usage: """
          content status [--json] [--prefix <dir>] [--library <dir>]
                                         installed / needs update / not installed (reads files only)
          content install [--msi <file>] [--host <Warzag.app>] [--prefix <dir>] [--library <dir>]
          content update [--host <Warzag.app>] [--prefix <dir>] [--library <dir>]
                                         Warframe.msi (Authenticode-checked), then DE's own launcher (you click
                                         I AGREE in its window); Ctrl-C closes DE's launcher before warzagctl exits
        """) { arguments, context in
        runBlocking { await runContent(arguments, context, dependencies: .live(context), output: .standardOutput) }
    }

    static let play = CommandGroup(usage: """
          play [--dry-run] [--no-steam] [--hud] [--skip-update] [--nvext]
               [--host <Warzag.app>] [--prefix <dir>] [--library <dir>]
                                         update, open the game host, watch EE.log until Warframe exits;
                                         --dry-run prints the exact launch and starts nothing; --nvext gives
                                         Warframe DXMT's NVIDIA identity (experiments only, no DLSS); Ctrl-C closes
                                         Warframe (and DE's launcher) and stops Wine before warzagctl exits
        """) { arguments, context in
        runBlocking { await runPlay(arguments, context, dependencies: .live(context), output: .standardOutput) }
    }

    // MARK: - Options

    struct Options: Equatable {
        var host: String?
        var prefix: String?
        var library: String?
        var msi: String?
        var json = false
        var dryRun = false
        var steam = true
        var hud = false
        var skipUpdate = false
        /// `--nvext`: DXMT's NVIDIA identity, for experiments (`PresetCatalog.nvextDefault`).
        var nvext = false
    }

    static let valuedOptions: Set<String> = ["--host", "--prefix", "--library", "--msi"]

    static func parse(_ arguments: [String], allowed: Set<String>, command: String) throws(UsageError) -> Options {
        var options = Options()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard allowed.contains(argument) else {
                throw UsageError(message: argument.hasPrefix("-")
                    ? "unknown option for \(command): \(argument)" : "unexpected argument for \(command): \(argument)")
            }
            if valuedOptions.contains(argument) {
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                    throw UsageError(message: "\(argument) needs a value")
                }
                index += 1
                let value = arguments[index]
                switch argument {
                case "--host": options.host = value
                case "--prefix": options.prefix = value
                case "--library": options.library = value
                default: options.msi = value
                }
            } else {
                switch argument {
                case "--json": options.json = true
                case "--dry-run": options.dryRun = true
                case "--no-steam": options.steam = false
                case "--hud": options.hud = true
                case "--nvext": options.nvext = true
                default: options.skipUpdate = true
                }
            }
            index += 1
        }
        return options
    }

    static func usageFailure(_ error: UsageError, usage: String) -> CommandResult {
        CommandResult(stderr: "warzagctl: \(error)\n\nusage:\n\(usage)\n", exitCode: 64)
    }

    // MARK: - Dependencies

    /// Side effects of the game commands; tests swap in fakes.
    struct Dependencies: Sendable {
        var game: GameContext
        var downloader: ResumableDownloader
        var authenticode: any AuthenticodeVerifying
        var content: ContentConfiguration
        var play: PlayConfiguration
        /// SIGINT/SIGTERM while content or play runs.
        var interrupter: Interrupter

        static func live(_ context: CommandContext) -> Dependencies {
            var game = GameContext.live(paths: context.paths, inheritedEnvironment: context.inheritedEnvironment)
            game.fileSystem = context.fileSystem
            return Dependencies(game: game, downloader: ResumableDownloader(),
                                authenticode: NativeAuthenticodeVerifier(), content: ContentConfiguration(),
                                play: PlayConfiguration(), interrupter: .live())
        }
    }

    /// Where progress (stdout) and warnings (stderr) go while a long command runs.
    struct Output: Sendable {
        let write: @Sendable (String) -> Void
        let warn: @Sendable (String) -> Void

        static let standardOutput = Output(write: { FileHandle.standardOutput.write(Data($0.utf8)) },
                                           warn: { FileHandle.standardError.write(Data($0.utf8)) })
    }

    /// A path from the command line, relative ones taken from the working directory (Wine refuses a relative prefix).
    static func location(_ path: String, _ context: CommandContext, directory: Bool = true) -> URL {
        URL(filePath: path, directoryHint: directory ? .isDirectory : .notDirectory,
            relativeTo: context.currentDirectory).absoluteURL.standardized
    }

    /// The host (its channel read from the bundle), the prefix and the library.
    static func installation(_ options: Options, _ context: CommandContext,
                             files: any GameFiles) throws -> (GameInstallation, note: String?) {
        let hostPath = options.host.map { location($0, context).plainPath }
        let (host, note) = try Commands.resolveHost(EnvOptions(kind: .session, host: hostPath), context)
        let prefix = options.prefix.map { location($0, context) } ?? context.paths.prefix(for: host.channel)
        let user = GameInstallation.windowsUserName(
            inPrefix: prefix, fileSystem: context.fileSystem,
            fallback: context.inheritedEnvironment["USER"] ?? NSUserName())
        let installation = GameInstallation.resolve(
            host: host, prefix: prefix, library: options.library.map { location($0, context) },
            paths: context.paths, files: files, windowsUserName: user)
        return (installation, note)
    }

    // MARK: - content

    static func runContent(_ arguments: [String], _ context: CommandContext, dependencies: Dependencies,
                           output: Output) async -> CommandResult {
        let common: Set<String> = ["--host", "--prefix", "--library"]
        let options: Options
        let subcommand = arguments.first ?? ""
        do {
            switch subcommand {
            case "status":
                options = try parse(Array(arguments.dropFirst()),
                                    allowed: ["--json", "--prefix", "--library", "--host"],
                                    command: "content status")
            case "install":
                options = try parse(Array(arguments.dropFirst()), allowed: common.union(["--msi"]),
                                    command: "content install")
            case "update":
                options = try parse(Array(arguments.dropFirst()), allowed: common, command: "content update")
            case "":
                throw UsageError(message: "content needs status, install or update")
            default:
                throw UsageError(message: "unknown content command: \(subcommand)")
            }
        } catch let error as UsageError {
            return usageFailure(error, usage: content.usage)
        } catch {
            return usageFailure(UsageError(message: "\(error)"), usage: content.usage)
        }

        let installation: GameInstallation
        do {
            (installation, _) = try self.installation(options, context, files: dependencies.game.files)
        } catch {
            return failure(error)
        }
        let service = ContentService(installation: installation, context: dependencies.game,
                                     configuration: dependencies.content)
        switch subcommand {
        case "status":
            return contentStatus(service.status(), installation: installation, json: options.json, context)
        case "install":
            return await contentInstall(service, options: options, context, dependencies: dependencies, output: output)
        default:
            return await contentUpdate(service, dependencies: dependencies, output: output)
        }
    }

    static func contentStatus(_ status: ContentStatus, installation: GameInstallation, json: Bool,
                              _ context: CommandContext) -> CommandResult {
        if json { return CommandResult(stdout: Commands.encode(status)) }
        let state = switch status.state {
        case .installed: "installed"
        case .needsUpdate: "needs update"
        case .notInstalled: "not installed"
        }
        var rows: [(String, String)] = [("state", "\(state) (\(status.reason))")]
        rows.append(("library", status.library
            + (status.libraryBytes.map { " (\(Commands.gigabytes($0)) on disk)" } ?? " (missing)")))
        rows.append(("game", status.gamePresent
            ? "Warframe.x64.exe" + (status.gameModified.map { ", modified \(timestamp($0, context))" } ?? "")
            : "no Warframe.x64.exe"))
        rows.append(("launcher", status.launcherPresent ? #"Tools\Launcher.exe present"# : #"no Tools\Launcher.exe"#))
        if let lastUpdate = status.lastUpdate {
            let source = status.lastUpdateSource == "warzag" ? "Warzag" : "DE's Launcher.log"
            rows.append(("last update", "\(timestamp(lastUpdate, context)) (\(source))"))
        }
        rows.append(("prefix", installation.prefix.root.plainPath))
        return CommandResult(stdout: Table(rows).rendered(indent: ""))
    }

    static func contentInstall(_ service: ContentService, options: Options, _ context: CommandContext,
                               dependencies: Dependencies, output: Output) async -> CommandResult {
        let origin: InstallerSource.Origin = if let msi = options.msi {
            .file(location(msi, context, directory: false))
        } else {
            .download(dependencies.content.installerURL,
                      to: context.paths.caches.appending(path: "downloads/Warframe.msi"))
        }
        let source = InstallerSource(origin: origin, expectations: dependencies.content.installer,
                                     downloader: dependencies.downloader, authenticode: dependencies.authenticode,
                                     fileSystem: dependencies.game.fileSystem)
        let printer = ProgressPrinter(output: output, clock: dependencies.game.clock)
        let reached = ContentRunReach()
        let run = await dependencies.interrupter.run {
            try await service.install(installer: source) { reached.note($0); printer.show($0) }
        }
        return contentResult(run, success: "Warframe is installed.\n", reached: reached)
    }

    static func contentUpdate(_ service: ContentService, dependencies: Dependencies,
                              output: Output) async -> CommandResult {
        let printer = ProgressPrinter(output: output, clock: service.context.clock)
        let reached = ContentRunReach()
        let run = await dependencies.interrupter.run {
            try await service.update { reached.note($0); printer.show($0) }
        }
        return contentResult(run, success: "Warframe is up to date.\n", reached: reached)
    }

    /// A content run's end. After a signal, whatever the run had started in the prefix (msiexec, DE's launcher) has
    /// already been stopped as it unwound; the message says which.
    static func contentResult(_ run: (result: Result<LauncherRunOutcome, any Error>, signal: Int32?),
                              success: String, reached: ContentRunReach) -> CommandResult {
        if let signal = run.signal {
            return CommandResult(stderr: "warzagctl: \(Interrupter.name(of: signal)): stopped; \(reached.stoppedText)\n",
                                 exitCode: Interrupter.exitCode(for: signal))
        }
        switch run.result {
        case .success(let outcome): return finish(outcome, success: success)
        case .failure(let error): return failure(error)
        }
    }

    static func finish(_ outcome: LauncherRunOutcome, success: String) -> CommandResult {
        switch outcome {
        case .completed:
            CommandResult(stdout: success)
        case .eulaDeclined:
            CommandResult(stderr: "warzagctl: DE's launcher was closed before its EULA was accepted; nothing was "
                + "downloaded. Run the command again and click I AGREE in DE's window.\n", exitCode: 3)
        case .stuck(let reason):
            CommandResult(stderr: "warzagctl: the download is stuck: DE's launcher "
                + (reason == .stalled ? "made no progress" : "kept closing")
                + " even after restarts. Check the network and run the command again.\n", exitCode: 4)
        }
    }

    static func failure(_ error: any Error) -> CommandResult {
        if let content = error as? ContentError, case .prefixNotReady(let issues) = content {
            return CommandResult(stderr: notReadyText(issues), exitCode: 1)
        }
        if let play = error as? PlayError, case .notReady(let issues) = play {
            return CommandResult(stderr: notReadyText(issues), exitCode: 1)
        }
        return CommandResult(stderr: "warzagctl: \(error)\n", exitCode: 1)
    }

    static func notReadyText(_ issues: [PrefixIssue]) -> String {
        var text = "warzagctl: not ready:\n" + issues.map { "  - \($0)\n" }.joined()
        if issues.contains(where: \.needsPrefixRepair) {
            text += "The Wine prefix needs to be set up again: run warzagctl prefix repair, or Repair Windows Setup in "
                + "Warzag's Troubleshoot window.\n"
        }
        return text
    }

    // MARK: - play

    /// Printed before Play when EE.cfg says motion blur is on (the app shows the same notice on Home).
    static let motionBlurAdvice = "Motion blur is on. Under Warzag it can smear; turn it off in Warframe: Options > Display."

    static func runPlay(_ arguments: [String], _ context: CommandContext, dependencies: Dependencies,
                        output: Output) async -> CommandResult {
        let options: Options
        do {
            options = try parse(arguments, allowed: [
                "--dry-run", "--no-steam", "--hud", "--skip-update", "--nvext", "--host", "--prefix", "--library",
            ], command: "play")
        } catch {
            return usageFailure(error, usage: play.usage)
        }
        let installation: GameInstallation
        let hostNote: String?
        do {
            (installation, hostNote) = try self.installation(options, context, files: dependencies.game.files)
        } catch {
            return failure(error)
        }
        let hardware = HardwareProfile.detect(using: context.system)
        let launch = GameLaunchBuilder.launch(
            installation: installation,
            options: PlayOptions(steam: options.steam, hud: options.hud, nvext: options.nvext),
            hardware: hardware, steamClientDirectory: context.steam.clientDirectory,
            inherited: context.inheritedEnvironment)
        let service = ContentService(installation: installation, context: dependencies.game,
                                     configuration: dependencies.content)

        var warnings = hostNote.map { "warzagctl: \($0)\n" } ?? ""
        for advice in PowerAdvisor(system: context.system).advice(for: hardware.tierClassification.tier) {
            warnings += "warning: \(advice.message)\n"
        }
        // Read-only: EE.cfg keeps the player's last choice in Warframe; the per-account settings win at startup.
        if EEConfigReader.motionBlur(at: installation.prefix.eeConfig, fileSystem: dependencies.game.fileSystem) == .on {
            warnings += "warning: \(motionBlurAdvice)\n"
        }
        let steamStatus = SteamDetector(locations: context.steam, fileSystem: context.fileSystem,
                                        processes: context.processes, timeZone: context.timeZone).status()
        if options.steam, !steamStatus.signedIn {
            warnings += "warning: " + (steamStatus.running
                ? "Steam is running but nobody is signed in; Warframe will offer its own login.\n"
                : "Steam is not running; start Steam and sign in (or use --no-steam for a Warframe account).\n")
        }

        if options.dryRun {
            let issues = service.inspector.issues(for: .play(steam: options.steam, renderer: launch.renderer.renderer))
            for issue in issues { warnings += "warning: \(issue)\n" }
            let text = dryRunText(launch, update: !options.skipUpdate,
                                  launcher: service.launcherCommand(hidden: service.eulaAcceptedInRegistry()))
            return CommandResult(stdout: text, stderr: warnings)
        }

        if !warnings.isEmpty { output.warn(warnings) }
        if options.steam, !steamStatus.running {
            return CommandResult(stderr: "warzagctl: Steam is not running. Start Steam and sign in, or use "
                + "--no-steam to sign in with a Warframe account.\n", exitCode: 1)
        }
        let session = PlaySession(content: service, configuration: dependencies.play)
        let printer = ProgressPrinter(output: output, clock: dependencies.game.clock)
        let run = await dependencies.interrupter.run {
            try await session.run(launch, update: !options.skipUpdate) { event in printer.show(event) }
        }
        if let signal = run.signal {
            // Watching stopped (and an update in progress closed DE's launcher); now the game and Wine.
            output.write("stopping Warframe and Wine (\(Interrupter.name(of: signal)))\n")
            for problem in await session.closeGame() { output.warn("warning: \(problem)\n") }
            return CommandResult(stderr: "warzagctl: \(Interrupter.name(of: signal)): stopped; Warframe was closed and "
                + "the prefix stopped\n", exitCode: Interrupter.exitCode(for: signal))
        }
        switch run.result {
        case .success(let result):
            let minutes = Int((result.seconds / 60).rounded())
            let errors = result.signals.filter(\.isError)
            var summary = "Warframe exited after \(minutes) min."
            if !errors.isEmpty { summary += " Problems seen: " + errors.map(\.message).joined(separator: "; ") + "." }
            return CommandResult(stdout: summary + "\n")
        case .failure(let error):
            return failure(error)
        }
    }

    /// The exact launch: arguments one per line as LaunchServices passes them to the loader, then the environment as
    /// sorted KEY=VALUE lines.
    static func dryRunText(_ launch: GameLaunch, update: Bool, launcher: Command) -> String {
        let renderer = launch.renderer
        var rendererText = renderer.renderer.rawValue
        if let cap = renderer.frameRateCap { rendererText += ", frame cap \(cap) fps" }
        if renderer.renderer == .dxmt {
            rendererText += renderer.enableNVEXT
                ? ", NVEXT on (an NVIDIA identity only; DLSS is unavailable in Warframe)" : ", NVEXT off"
        }
        var text = "warzagctl play --dry-run: nothing was started\n"
        text += Table([
            ("open", "\(launch.application.plainPath) (LaunchServices, new instance)"),
            ("executable", launch.executable.plainPath),
            ("renderer", rendererText),
            ("sign-in", launch.steam ? "Steam (the Mac Steam client, through the bridge)" : "Warframe account (no Steam variables)"),
            ("update", update
                ? "first, \(launcher.description) from \(launcher.workingDirectory?.plainPath ?? "-") (no Steam variables)"
                : "skipped"),
        ]).rendered(indent: "")
        text += "arguments:\n" + launch.arguments.map { "  \($0)\n" }.joined()
        text += "environment:\n" + launch.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)\n" }.joined()
        return text
    }

    // MARK: - Helpers

    static func timestamp(_ date: Date, _ context: CommandContext) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = context.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// Runs async work from warzagctl's synchronous main, keeping the main run loop turning so work that needs the
    /// main actor (LaunchServices) can still run. Only for the command-line entry point: blocking a thread of Swift's
    /// cooperative pool this way could starve it.
    static func runBlocking(_ work: @escaping @Sendable () async -> CommandResult) -> CommandResult {
        let result = Mutex<CommandResult?>(nil)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let value = await work()
            result.withLock { $0 = value }
            done.signal()
        }
        while done.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        return result.withLock { $0 } ?? CommandResult(stderr: "warzagctl: no result\n", exitCode: 70)
    }
}

/// How far a content run got in the prefix, from its progress, so the message after Ctrl-C names only what was
/// actually stopped.
final class ContentRunReach: Sendable {
    private struct Reach {
        var unpacking = false
        var launcher = false
    }

    private let reach = Mutex(Reach())

    func note(_ state: ContentRunState) {
        switch state {
        case .downloadingInstaller, .checkingInstaller, .installerChecked, .warning:
            break
        case .extractingInstaller:
            reach.withLock { $0.unpacking = true }
        case .startingLauncher, .needsEULA, .mayNeedEULA, .downloading, .preprocessing, .finishing,
             .restartingLauncher, .closingLauncher, .complete, .stuck:
            reach.withLock { $0.launcher = true }
        }
    }

    /// The end of the "stopped" line.
    var stoppedText: String {
        let reach = reach.withLock { $0 }
        if reach.launcher { return "DE's launcher was closed and the prefix stopped" }
        if reach.unpacking { return "msiexec was stopped and the prefix with it" }
        return "nothing had been started in the prefix yet"
    }
}

/// Prints progress lines without flooding: a line when the kind of work changes, and every half minute while a
/// long download runs.
final class ProgressPrinter: Sendable {
    private struct State {
        var lastKey = ""
        var lastPrinted = Date.distantPast
        var lastFraction = -1.0
    }

    private let output: GameCommands.Output
    private let clock: any WallClock
    private let state = Mutex(State())
    static let repeatInterval: TimeInterval = 30

    init(output: GameCommands.Output, clock: any WallClock) {
        self.output = output
        self.clock = clock
    }

    func show(_ state: ContentRunState) {
        let (key, line, fraction) = Self.describe(state)
        emit(key: key, line: line, fraction: fraction)
    }

    func show(_ event: PlayEvent) {
        switch event {
        case .updating(let state): show(state)
        case .opening: emit(key: "opening", line: "opening the game host", fraction: nil)
        case .started(let pid): emit(key: "started", line: "Warframe is starting (pid \(pid))", fraction: nil)
        case .signal(let signal):
            emit(key: "signal-\(signal.rawValue)", line: (signal.isError ? "problem: " : "") + signal.message,
                 fraction: nil, always: true)
        case .handedOverToLauncher:
            emit(key: "handed-over", line: "Warframe handed over to DE's launcher while closing (an update or a "
                + "restart); leaving it running", fraction: nil, always: true)
        case .hungAtExit(let seconds):
            emit(key: "hung-at-exit",
                 line: "Warframe stopped responding while closing (still running \(Int(seconds)) s later); ending it "
                    + "(wineserver -k)", fraction: nil, always: true)
        case .exited(let seconds): emit(key: "exited", line: "Warframe exited after \(Int(seconds)) s", fraction: nil)
        case .cleanedUp(let forced):
            emit(key: "cleanup", line: forced ? "stopped what Wine left running (wineserver -k)" : "Wine shut down cleanly",
                 fraction: nil)
        case .warning(let text):
            emit(key: "warning-\(text)", line: "warning: \(text)", fraction: nil, always: true)
        }
    }

    private func emit(key: String, line: String, fraction: Double?, always: Bool = false) {
        let now = clock.now
        let print = state.withLock { state -> Bool in
            let changed = key != state.lastKey
            let due = now.timeIntervalSince(state.lastPrinted) >= Self.repeatInterval
            let moved = fraction.map { $0 - state.lastFraction >= 0.1 } ?? false
            guard always || changed || due || moved else { return false }
            state.lastKey = key
            state.lastPrinted = now
            if let fraction { state.lastFraction = fraction } else if changed { state.lastFraction = -1 }
            return true
        }
        if print { output.write(line + "\n") }
    }

    static func describe(_ state: ContentRunState) -> (key: String, line: String, fraction: Double?) {
        switch state {
        case .downloadingInstaller(let received, let total):
            let fraction = total.map { Double(received) / Double(max($0, 1)) }
            return ("installer", "downloading Warframe.msi: \(megabytes(received))"
                + (total.map { " of \(megabytes($0))" } ?? ""), fraction)
        case .checkingInstaller:
            return ("checking", "checking Warframe.msi", nil)
        case .installerChecked(let sha256, let verdict):
            let signature = switch verdict {
            case .trusted(let signer): "Authenticode: signed by \(signer)"
            case .unavailable(let reason): "Authenticode signature NOT checked (\(reason))"
            case .rejected(let reason): "Authenticode signature rejected: \(reason)"
            }
            return ("checked", "Warframe.msi SHA-256 \(sha256); \(signature)", nil)
        case .extractingInstaller:
            return ("extracting", #"unpacking Warframe.msi into the library (msiexec /a, TARGETDIR=X:\)"#, nil)
        case .startingLauncher(let attempt):
            return ("starting-\(attempt)", "starting DE's launcher" + (attempt > 0 ? " (restart \(attempt))" : ""), nil)
        case .needsEULA:
            return ("eula", "DE's launcher is showing its EULA: read it and click I AGREE in DE's window "
                + "(Warzag never accepts it for you)", nil)
        case .mayNeedEULA:
            return ("eula-guessed", "DE's launcher has gone quiet at its start and may be showing its EULA: if its "
                + "window does, read it and click I AGREE there (Warzag never accepts it for you)", nil)
        case .downloading(let thisRun, let onDisk, let expected, let rate):
            var line: String
            if let expected {
                // A first install: how much of the whole game is on disk (a resumed install counts what it has).
                let fraction = min(0.99, Double(onDisk) / Double(max(expected, 1)))
                line = "downloading: \(gigabytes(onDisk)) of about \(gigabytes(expected)) (\(Int(fraction * 100))%)"
            } else {
                // An update: its own size is unknown, so what it has added so far.
                line = "downloading the update: \(gigabytes(thisRun)) so far"
            }
            if let rate { line += ", \(Int(rate)) MB/s" }
            return ("downloading", line, nil)
        case .preprocessing(let fraction):
            return ("preprocessing", "preparing game files (DE's ContentUpdate)"
                + (fraction.map { ": \(Int($0 * 100))%" } ?? ""), fraction)
        case .finishing:
            return ("finishing", "finishing (cache defragmentation)", nil)
        case .restartingLauncher(let attempt, let reason):
            return ("restart-\(attempt)", reason == .stalled
                ? "DE's launcher made no progress; restarting it (\(attempt))"
                : "DE's launcher closed before finishing; starting it again (\(attempt))", nil)
        case .closingLauncher:
            return ("closing", "closing DE's launcher", nil)
        case .complete(let seconds):
            return ("complete", "DE's launcher finished" + (seconds.map { " (its total: \($0) s)" } ?? ""), nil)
        case .stuck:
            return ("stuck", "the download is stuck", nil)
        case .warning(let text):
            return ("warning-\(text)", "warning: \(text)", nil)
        }
    }

    static func megabytes(_ bytes: Int64) -> String { "\(Int((Double(bytes) / 1_000_000).rounded())) MB" }

    static func gigabytes(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1_000_000_000) }
}
