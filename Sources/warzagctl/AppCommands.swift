import AppUpdateKit
import Darwin
import EngineKit
import Foundation
import RuntimeKit
import Synchronization
import WarzagCore

/// `warzagctl app ...`: Warzag's own updates through AppUpdateKit, the code the app runs (docs/RELEASING.md), and
/// `app swap`, the helper a new Warzag's warzagctl runs to replace the installed one.
enum AppCommands {
    static let usage = """
          app status [--app <Warzag.app>] [--json]
                                         the installed Warzag (the one this warzagctl ships in, or --app): version,
                                         build, whether it can replace itself where it is, its app feed, the serial
                                         floor and a prepared update
          app check [--app <Warzag.app>] [--feed <URL>] [--json]
                                         the app feed's signed manifest, verified: up to date, or the newer Warzag
          app update [--yes] [--open] [--app <Warzag.app>] [--feed <URL>]
                                         check, download and verify the newer Warzag, then its own warzagctl replaces
                                         the installed one (quit Warzag first; --open opens the new one, --yes skips
                                         the question). The feed is the app's Info.plist WarzagAppManifestURL unless
                                         --feed (https; a development build also takes http on 127.0.0.1)
        """

    static let group = CommandGroup(usage: usage) { arguments, context in
        GameCommands.runBlocking {
            await run(arguments, context, dependencies: .live(context), output: .standardOutput)
        }
    }

    // MARK: - Options

    struct Options: Equatable {
        var json = false
        var yes = false
        var open = false
        var app: String?
        var feed: String?
    }

    static let valueOptions: Set<String> = ["--app", "--feed"]

    static func parse(_ arguments: [String], allowed: Set<String>, command: String) throws(UsageError) -> Options {
        var options = Options()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard allowed.contains(argument) else {
                throw UsageError(message: argument.hasPrefix("-")
                    ? "unknown option for \(command): \(argument)" : "unexpected argument for \(command): \(argument)")
            }
            if valueOptions.contains(argument) {
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                    throw UsageError(message: "\(argument) needs a value")
                }
                index += 1
                if argument == "--app" { options.app = arguments[index] } else { options.feed = arguments[index] }
            } else {
                switch argument {
                case "--json": options.json = true
                case "--yes": options.yes = true
                default: options.open = true
                }
            }
            index += 1
        }
        return options
    }

    // MARK: - Dependencies

    /// Side effects of the app commands; tests swap in fakes.
    struct Dependencies: Sendable {
        /// The updater for an installed app and a feed, against Warzag's data in `paths`.
        var updater: @Sendable (_ installed: InstalledApp, _ feed: URL?, _ paths: WarzagPaths) -> AppUpdater
        /// The swap `app swap` makes.
        var swap: @Sendable (_ installed: URL, _ staged: URL, _ requirement: AppRequirement,
                             _ log: @escaping @Sendable (String) -> Void) -> AppSwap
        /// warzagctl's own executable, to find the Warzag.app it ships in.
        var executable: URL?
        /// The certificates a swap may install (this build's pins).
        var signers: Set<String>
        var fileSystem: any FileSystem
        /// Whether a question can be asked (stdin is a terminal).
        var isInteractive: Bool
        var ask: @Sendable (String) -> Bool

        static func live(_ context: CommandContext) -> Dependencies {
            // Its real home's Applications folder counts as one, whatever --home says.
            let home = FileManager.default.homeDirectoryForCurrentUser
            return Dependencies(
                updater: { installed, feed, paths in
                    AppUpdater.live(installed: installed, feed: feed, trust: RuntimeTrust.pinned, paths: paths, home: home)
                },
                swap: { installed, staged, requirement, log in
                    AppSwap(installed: installed, staged: staged, requirement: requirement, bundles: LiveAppBundleVerifier(),
                            files: LocalBundleFiles(), processes: context.processes, runner: SystemProcessRunner(),
                            clock: SystemClock(), log: log)
                },
                executable: Bundle.main.executableURL?.resolvingSymlinksInPath(),
                signers: RuntimeTrust.pinned.signerFingerprints, fileSystem: context.fileSystem,
                isInteractive: isatty(STDIN_FILENO) == 1,
                ask: { question in
                    FileHandle.standardOutput.write(Data(question.utf8))
                    return ["y", "yes"].contains(readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? "")
                })
        }
    }

    // MARK: - Entry point

    static func run(_ arguments: [String], _ context: CommandContext, dependencies: Dependencies,
                    output: GameCommands.Output) async -> CommandResult {
        let subcommand = arguments.first ?? ""
        let rest = Array(arguments.dropFirst())
        do {
            switch subcommand {
            case "status":
                return try status(parse(rest, allowed: ["--app", "--json"], command: "app status"), context, dependencies)
            case "check":
                return try await check(parse(rest, allowed: ["--app", "--feed", "--json"], command: "app check"),
                                       context, dependencies)
            case "update":
                return try await update(parse(rest, allowed: ["--app", "--feed", "--yes", "--open"], command: "app update"),
                                        context, dependencies, output: output)
            case "swap":
                let command: AppSwapCommand
                do {
                    command = try AppSwapCommand.parse(rest)
                } catch {
                    throw UsageError(message: error.message)
                }
                return await swap(command, context, dependencies, output: output)
            case "--help", "-h", "help":
                return CommandResult(stdout: usage + "\n")
            case "":
                throw UsageError(message: "app needs status, check or update")
            default:
                throw UsageError(message: "unknown command: app \(subcommand)")
            }
        } catch let error as UsageError {
            // 64 is EX_USAGE from sysexits(3).
            return CommandResult(stderr: "warzagctl: \(error)\n\n\(usage)\n", exitCode: 64)
        } catch {
            return CommandResult(stderr: "warzagctl app \(subcommand): \(error)\n", exitCode: 1)
        }
    }

    /// The installed Warzag: `--app`, else the Warzag.app this warzagctl ships in.
    static func installedApp(_ options: Options, _ context: CommandContext,
                             _ dependencies: Dependencies) throws(UsageError) -> InstalledApp {
        let bundle: URL
        if let path = options.app {
            bundle = GameCommands.location(path, context)
        } else if let executable = dependencies.executable, let own = InstalledApp.bundle(containing: executable) {
            bundle = own
        } else {
            throw UsageError(message: "this warzagctl does not ship in a Warzag.app; pass --app <Warzag.app>")
        }
        guard dependencies.fileSystem.directoryExists(at: bundle) else {
            throw UsageError(message: "no app at \(bundle.plainPath)")
        }
        return InstalledApp.read(bundle, fileSystem: dependencies.fileSystem)
    }

    static func updater(_ options: Options, _ context: CommandContext,
                        _ dependencies: Dependencies) throws(UsageError) -> AppUpdater {
        let installed = try installedApp(options, context, dependencies)
        var feed = installed.feed
        if let text = options.feed {
            guard let url = AppFeed.url(text) else {
                throw UsageError(message: "--feed must be an https URL" + (AppFeed.allowsLoopbackHTTP
                    ? " (or http on 127.0.0.1 in a development build)" : "") + ": \(text)")
            }
            feed = url
        }
        return dependencies.updater(installed, feed, context.paths)
    }

    // MARK: - status

    struct StatusReport: Encodable, Equatable {
        struct Prepared: Encodable, Equatable {
            var version: String
            var build: String
            var bytes: Int64
            var path: String
        }

        var app: String
        var version: String
        var build: String
        var identifier: String?
        var replaceable: Bool
        var obstacle: String?
        var feed: String?
        var lastSerial: UInt64?
        var prepared: Prepared?
    }

    static func status(_ options: Options, _ context: CommandContext,
                       _ dependencies: Dependencies) throws(UsageError) -> CommandResult {
        let updater = try updater(options, context, dependencies)
        let installed = updater.installed
        let obstacle = updater.location.obstacle(replacing: installed.bundle)
        let report = StatusReport(
            app: installed.bundle.plainPath, version: installed.version, build: installed.build,
            identifier: installed.identifier, replaceable: obstacle == nil, obstacle: obstacle,
            feed: updater.feed?.absoluteString, lastSerial: updater.lastAcceptedSerial(),
            prepared: updater.prepared().map {
                StatusReport.Prepared(version: $0.version, build: $0.build, bytes: $0.bytes,
                                      path: updater.stagedApp.plainPath)
            })
        if options.json { return CommandResult(stdout: Commands.encode(report)) }
        var rows: [(String, String)] = [
            ("app", report.app),
            ("version", "\(report.version) (build \(report.build))"
                + (report.identifier == AppManifest.bundleIdentifier ? "" : ", identifier \(report.identifier ?? "none")")),
            ("location", obstacle.map { "cannot replace itself: \($0)" } ?? "can replace itself"),
            ("feed", report.feed ?? "none (this build names no app feed: App/make-app.sh --update-url)"),
            ("serial", report.lastSerial.map(String.init) ?? "no app manifest accepted yet"),
        ]
        rows.append(("prepared", report.prepared.map {
            "Warzag \($0.version) (build \($0.build)), \(ProgressPrinter.megabytes($0.bytes)), in \($0.path)"
        } ?? "none"))
        return CommandResult(stdout: Table(rows).rendered(indent: ""))
    }

    // MARK: - check

    struct CheckReport: Encodable, Equatable {
        struct Offer: Encodable, Equatable {
            var version: String
            var build: String
            var bytes: Int64
            var minMacOS: String
            var serial: UInt64
            var expires: Date
            var releaseNotes: String?
        }

        var installedVersion: String
        var installedBuild: String
        /// "available", "upToDate" or "notConfigured".
        var result: String
        var latest: Offer?
    }

    static func check(_ options: Options, _ context: CommandContext,
                      _ dependencies: Dependencies) async throws -> CommandResult {
        let updater = try updater(options, context, dependencies)
        let installed = updater.installed
        let found = try await updater.check()
        let latest: AppManifest? = switch found {
        case .notConfigured: nil
        case .upToDate(let manifest), .available(let manifest): manifest
        }
        let result = switch found {
        case .notConfigured: "notConfigured"
        case .upToDate: "upToDate"
        case .available: "available"
        }
        let report = CheckReport(
            installedVersion: installed.version, installedBuild: installed.build, result: result,
            latest: latest.map {
                CheckReport.Offer(version: $0.version, build: $0.build, bytes: $0.size, minMacOS: $0.minMacOS,
                                  serial: $0.serial, expires: $0.expires, releaseNotes: $0.releaseNotes?.absoluteString)
            })
        if options.json { return CommandResult(stdout: Commands.encode(report), exitCode: found == .notConfigured ? 1 : 0) }
        let current = "Warzag \(installed.version) (build \(installed.build))"
        switch found {
        case .notConfigured:
            return CommandResult(stderr: "warzagctl app check: \(AppUpdateFailure.notConfigured) (App/make-app.sh "
                + "--update-url, or --feed)\n", exitCode: 1)
        case .upToDate(let manifest):
            return CommandResult(stdout: "\(current) is up to date (the feed offers build \(manifest.build))\n")
        case .available(let manifest):
            var rows = [("installed", current),
                        ("latest", "Warzag \(manifest.version) (build \(manifest.build)), "
                            + "\(ProgressPrinter.megabytes(manifest.size)), macOS \(manifest.minMacOS) or later"),
                        ("manifest", "serial \(manifest.serial), expires \(manifest.expires.formatted(.iso8601))")]
            if let notes = manifest.releaseNotes { rows.append(("notes", notes.absoluteString)) }
            return CommandResult(stdout: Table(rows).rendered(indent: "") + "next: warzagctl app update\n")
        }
    }

    // MARK: - update

    static func update(_ options: Options, _ context: CommandContext, _ dependencies: Dependencies,
                       output: GameCommands.Output) async throws -> CommandResult {
        let updater = try updater(options, context, dependencies)
        let installed = updater.installed
        let manifest: AppManifest
        switch try await updater.check() {
        case .notConfigured:
            throw AppUpdateFailure.notConfigured
        case .upToDate(let latest):
            return CommandResult(stdout: "Warzag \(installed.version) (build \(installed.build)) is up to date (the feed "
                + "offers build \(latest.build))\n")
        case .available(let offered):
            manifest = offered
        }
        let name = "Warzag \(manifest.version) (build \(manifest.build))"
        output.write("available: \(name), \(ProgressPrinter.megabytes(manifest.size))\n")
        if !options.yes {
            guard dependencies.isInteractive else {
                return CommandResult(stderr: "warzagctl app update: pass --yes to replace \(installed.bundle.plainPath) "
                    + "with \(name) without a question\n", exitCode: 1)
            }
            guard dependencies.ask("Replace \(installed.bundle.plainPath) with \(name)? [y/N] ") else {
                return CommandResult(stdout: "nothing was changed\n", exitCode: 1)
            }
        }
        let shown = Mutex(-1)
        try await updater.prepare(build: manifest.build) { received, total in
            let tenth = total > 0 ? Int(received * 10 / total) : 0
            guard shown.withLock({ last in
                defer { last = max(last, tenth) }
                return tenth > last
            }) else { return }
            output.write("downloading: \(tenth * 10)% of \(ProgressPrinter.megabytes(total))\n")
        }
        output.write("downloaded and checked: \(name), signed by \(manifest.signerFingerprint.prefix(16))…\n")
        do {
            let printed = try await updater.install(.now(reopen: options.open),
                                                    log: context.paths.logs.appending(path: "Warzag.log"))
            return CommandResult(stdout: printed + "installed \(name) in \(installed.bundle.plainPath)\n")
        } catch {
            var text = "warzagctl app update: \(error)\n"
            if case .cannotReplace = error, dependencies.fileSystem.directoryExists(at: updater.stagedApp) {
                text += "the checked new Warzag is at \(updater.stagedApp.plainPath): drag it into Applications\n"
            }
            return CommandResult(stderr: text, exitCode: 1)
        }
    }

    // MARK: - swap (the helper)

    /// `app swap`: the update helper (`AppSwapCommand`), run by `warzagctl app update` from the new Warzag's own
    /// warzagctl in its checked copy, never by hand. `--probe` checks that the installed app can be replaced (and puts
    /// the new copy next to it); otherwise it waits for `--wait-pid` to exit, swaps, checks the new Warzag in place and
    /// opens it with `--open`. Exits 0 when replaced, 65 when the new copy failed a check, 1 otherwise.
    static func swap(_ command: AppSwapCommand, _ context: CommandContext, _ dependencies: Dependencies,
                     output: GameCommands.Output) async -> CommandResult {
        let result = await command.run(signers: dependencies.signers, paths: context.paths,
                                       currentDirectory: context.currentDirectory, output: { output.write($0) },
                                       swap: dependencies.swap)
        guard let reason = result.reason else { return CommandResult(exitCode: result.exitCode) }
        return CommandResult(stderr: "warzagctl app swap: \(reason)\n", exitCode: result.exitCode)
    }
}
