import EngineKit
import Foundation
import ProfileKit
import RuntimeKit
import WarzagCore
import WineKit

/// `warzagctl runtime ...` and `warzagctl prefix ...`.
enum EngineCommands {
    static let runtime = CommandGroup(usage: EngineCLI.runtimeUsage) { arguments, context in
        GameCommands.runBlocking { await EngineCLI.runtime(arguments, environment: .live(context)) }
    }
    static let prefix = CommandGroup(usage: EngineCLI.prefixUsage) { arguments, context in
        GameCommands.runBlocking { await EngineCLI.prefix(arguments, environment: .live(context)) }
    }
}

/// What the engine commands run against; tests build one from fakes.
struct EngineCLIEnvironment: Sendable {
    var engine: Engine
    /// Mac Driver settings for new prefixes (the tier preset's RetinaMode). An existing prefix keeps the settings
    /// recorded in its warzag-prefix.json, so `prefix repair` never undoes the player's choices.
    var macDriver: MacDriverSettings
    /// Checked against a runtime manifest's minLauncher and minMacOS.
    var appVersion: String
    var macOSVersion: String
    /// Relative paths on the command line are relative to this.
    var currentDirectory: URL

    static func live(_ context: CommandContext) -> EngineCLIEnvironment {
        let hardware = HardwareProfile.detect(using: context.system)
        return EngineCLIEnvironment(
            engine: .live(paths: context.paths, inheritedEnvironment: context.inheritedEnvironment),
            macDriver: MacDriverSettings(retinaMode: PresetCatalog.preset(for: hardware).retinaMode),
            appVersion: Commands.version, macOSVersion: hardware.macOSVersion,
            currentDirectory: context.currentDirectory)
    }

    /// `--home <dir>` after the command word: the same environment rooted at another home. warzagctl's own command line
    /// never gets here with one: `ExtensionCommands.dispatch` takes it off and builds the context for that home.
    func withHome(_ home: URL) -> EngineCLIEnvironment {
        var copy = self
        copy.engine.paths = WarzagPaths(home: home, userCacheDirectory: engine.paths.userCacheDirectory)
        return copy
    }

    func resolve(_ path: String) -> URL {
        let url = path.hasPrefix("/") ? URL(filePath: path) : currentDirectory.appending(path: path)
        return url.standardized
    }
}

/// Parsing, running and printing of the engine commands.
enum EngineCLI {
    static let runtimeUsage = """
          runtime status [--json]        active and previous runtime, accepted manifests
          runtime use-local <Warzag.app> [--json]
                                         register a local runtime build (development only)
          runtime install --manifest <file|https-url> [--pubkey <base64>] [--signer <sha256|adhoc>]
                          [--pack <file|https-url>] [--reinstall] [--json]
                                         verify a signed runtime pack and activate it, keeping the previous one;
                                         trusts the pinned manifest key and project certificate, plus
                                         --pubkey/--signer (development)
          runtime rollback [--json]      make the previous runtime current again
          runtime trust [--json]         the manifest keys and pack signer this build pins (a release build: the
                                         release key only; a debug build also the DEV key)
        """
    static let prefixUsage = """
          prefix create [--library <dir>] [--json]
                                         create the Wine prefix for the active runtime (X: = library)
          prefix repair [--library <dir>] [--json]
                                         re-apply placeholders, bridge, registry and identity
          prefix doctor [--json]         check every part of the prefix (PASS/FAIL)
          prefix path [--json]           where the prefix is
          prefix run [--renderer dxmt|wined3d] [--nvext] [--timeout <seconds>] -- <program> [arguments...]
                                         run a Windows program in the prefix with a game session's environment (QA
                                         and diagnostics, e.g. build/pe/wz-d3d11-smoke.exe); output: the prefix log
        """

    struct Arguments: Equatable {
        var words: [String] = []
        var flags: Set<String> = []
        var values: [String: String] = [:]
        /// Everything after `--`, untouched (a program and its own arguments).
        var rest: [String] = []

        static let valueOptions: Set<String> = ["--home", "--manifest", "--pubkey", "--signer", "--pack", "--library",
                                                "--renderer", "--timeout"]
        static let flagOptions: Set<String> = ["--json", "--reinstall", "--nvext", "--help", "-h"]

        static func parse(_ arguments: [String]) throws(UsageError) -> Arguments {
            var result = Arguments()
            var index = 0
            while index < arguments.count {
                let argument = arguments[index]
                if argument == "--" {
                    result.rest = Array(arguments[(index + 1)...])
                    break
                }
                if valueOptions.contains(argument) {
                    guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                        throw UsageError(message: "\(argument) needs a value")
                    }
                    result.values[argument] = arguments[index + 1]
                    index += 2
                    continue
                }
                if flagOptions.contains(argument) {
                    result.flags.insert(argument)
                } else if argument.hasPrefix("-") {
                    throw UsageError(message: "unknown option: \(argument)")
                } else {
                    result.words.append(argument)
                }
                index += 1
            }
            return result
        }

        var json: Bool { flags.contains("--json") }
        var wantsHelp: Bool { flags.contains("--help") || flags.contains("-h") }

        /// Throws for any option the command does not take (`--home` is global).
        func allow(_ options: Set<String>) throws(UsageError) {
            let given = flags.union(values.keys).subtracting(["--home", "--json", "--help", "-h"])
            if let unexpected = given.subtracting(options).sorted().first {
                throw UsageError(message: "unknown option for \(words.joined(separator: " ")): \(unexpected)")
            }
        }
    }

    // MARK: Entry points

    static func runtime(_ arguments: [String], environment: EngineCLIEnvironment) async -> CommandResult {
        await run(group: "runtime", arguments, environment: environment, usage: runtimeUsage) { parsed, environment in
            switch parsed.words.first {
            case "status":
                try parsed.allow([])
                return try await runtimeStatus(parsed, environment)
            case "use-local":
                try parsed.allow([])
                return try useLocal(parsed, environment)
            case "install":
                try parsed.allow(["--manifest", "--pubkey", "--signer", "--pack", "--reinstall"])
                return try await install(parsed, environment)
            case "rollback":
                try parsed.allow([])
                return try rollback(parsed, environment)
            case "trust":
                try parsed.allow([])
                return try trust(parsed)
            case nil: throw UsageError(message: "runtime needs a subcommand")
            case let other?: throw UsageError(message: "unknown command: runtime \(other)")
            }
        }
    }

    static func prefix(_ arguments: [String], environment: EngineCLIEnvironment) async -> CommandResult {
        await run(group: "prefix", arguments, environment: environment, usage: prefixUsage) { parsed, environment in
            switch parsed.words.first {
            case "create", "repair":
                try parsed.allow(["--library"])
                return try await setUp(parsed, environment)
            case "doctor":
                try parsed.allow([])
                return await doctor(parsed, environment)
            case "path":
                try parsed.allow([])
                return try path(parsed, environment)
            case "run":
                try parsed.allow(["--renderer", "--nvext", "--timeout"])
                return try await runProgram(parsed, environment)
            case nil: throw UsageError(message: "prefix needs a subcommand")
            case let other?: throw UsageError(message: "unknown command: prefix \(other)")
            }
        }
    }

    private static func run(
        group: String, _ arguments: [String], environment: EngineCLIEnvironment, usage: String,
        _ body: (Arguments, EngineCLIEnvironment) async throws -> CommandResult
    ) async -> CommandResult {
        let parsed: Arguments
        do {
            parsed = try Arguments.parse(arguments)
        } catch {
            return usageFailure(error, usage)
        }
        if parsed.wantsHelp { return CommandResult(stdout: usage + "\n") }
        var environment = environment
        if let home = parsed.values["--home"] {
            environment = environment.withHome(environment.resolve(home))
        }
        do {
            return try await body(parsed, environment)
        } catch let error as UsageError {
            return usageFailure(error, usage)
        } catch {
            let command = ([group] + parsed.words.prefix(1)).joined(separator: " ")
            return CommandResult(stderr: "warzagctl \(command): \(error)\n", exitCode: 1)
        }
    }

    private static func usageFailure(_ error: UsageError, _ usage: String) -> CommandResult {
        // 64 is EX_USAGE from sysexits(3).
        CommandResult(stderr: "warzagctl: \(error)\n\n\(usage)\n", exitCode: 64)
    }

    private static func positional(_ parsed: Arguments, _ name: String) throws(UsageError) -> String {
        guard parsed.words.count == 2 else {
            throw UsageError(message: "\(parsed.words.joined(separator: " ")) needs \(name)")
        }
        return parsed.words[1]
    }

    private static func noPositional(_ parsed: Arguments) throws(UsageError) {
        guard parsed.words.count == 1 else {
            throw UsageError(message: "unexpected argument: \(parsed.words.dropFirst().joined(separator: " "))")
        }
    }

    // MARK: runtime

    struct RuntimeStatusReport: Encodable {
        var runtime: RuntimeStatus
    }

    static func runtimeStatus(_ parsed: Arguments, _ environment: EngineCLIEnvironment) async throws -> CommandResult {
        try noPositional(parsed)
        let status = try environment.engine.runtime.status()
        if parsed.json { return CommandResult(stdout: Commands.encode(RuntimeStatusReport(runtime: status))) }
        var rows: [(String, String)] = []
        if let current = status.current {
            rows.append(("current", describe(current)))
            rows.append(("host", current.host + (current.onDisk ? "" : " (missing)")))
        } else {
            rows.append(("current", "none (warzagctl runtime install, or runtime use-local for a development build)"))
        }
        rows.append(("previous", status.previous.map(describe) ?? "none"))
        if status.currentRevoked {
            rows.append(("blocked", "the current runtime was revoked and there is no previous runtime"))
        }
        rows.append(("serial", status.lastSerial.map(String.init) ?? "no signed manifest accepted yet"))
        rows.append(("revoked", status.revoked.isEmpty ? "none" : status.revoked.joined(separator: ", ")))
        if !status.rolledBack.isEmpty { rows.append(("rolled back", status.rolledBack.joined(separator: ", "))) }
        return CommandResult(stdout: Table(rows).rendered(indent: ""))
    }

    static func describe(_ entry: RuntimeStatus.Entry) -> String {
        var notes = ["version \(entry.version)", "channel \(entry.channel.rawValue)"]
        notes.append(entry.signer == RuntimeSigner.adHoc ? "ad-hoc signed" : "signer \(entry.signer.prefix(16))…")
        if entry.development { notes.append("development build") }
        if let activated = entry.activatedAt { notes.append("activated \(activated.formatted(.iso8601))") }
        return "\(entry.id) (\(notes.joined(separator: ", ")))"
    }

    static func useLocal(_ parsed: Arguments, _ environment: EngineCLIEnvironment) throws -> CommandResult {
        let bundle = environment.resolve(try positional(parsed, "the path of a Warzag.app runtime build"))
        let runtime = environment.engine.runtime
        try runtime.useLocal(bundle)
        let status = try runtime.status()
        if parsed.json { return CommandResult(stdout: Commands.encode(status)) }
        var text = "registered development runtime \(status.current?.id ?? "?") from \(bundle.plainPath)\n"
        text += Table([
            ("current", status.current.map(describe) ?? "none"),
            ("host", status.current?.host ?? "none"),
            ("previous", status.previous.map(describe) ?? "none"),
        ]).rendered(indent: "  ")
        text += "development only: this build is not a signed runtime pack\n"
        return CommandResult(stdout: text)
    }

    static func install(_ parsed: Arguments, _ environment: EngineCLIEnvironment) async throws -> CommandResult {
        try noPositional(parsed)
        guard let manifestLocation = parsed.values["--manifest"] else {
            throw UsageError(message: "runtime install needs --manifest <file|https-url>")
        }
        // A malformed key is refused before anything is read.
        var explicitKey: Data?
        if let keyText = parsed.values["--pubkey"] {
            guard let key = Data(base64Encoded: keyText) else { throw RuntimeServiceError.invalidPublicKey }
            explicitKey = key
        }
        let engine = environment.engine
        let manifestData: Data
        do {
            if let url = try httpsURL(manifestLocation) {
                manifestData = try await engine.http.data(from: url)
            } else {
                manifestData = try engine.fileSystem.contents(of: environment.resolve(manifestLocation))
            }
        } catch let error as UsageError {
            throw error
        } catch {
            throw RuntimeServiceError.unreadableManifest("\(error)")
        }
        var pack = PackSource.manifestURL
        if let location = parsed.values["--pack"] {
            pack = try httpsURL(location).map(PackSource.url) ?? .file(environment.resolve(location))
        }
        // The pinned manifest key and project certificate; for development, one more key (which then also vouches
        // for the signer its manifest names) and one more signer.
        var trust = RuntimeTrust.pinned
        if let explicitKey {
            trust = try RuntimeTrust.explicitKey(explicitKey, for: manifestData)
        }
        if let signer = parsed.values["--signer"] {
            trust = try RuntimeTrust.extending(trust, signers: [signer])
        }
        let runtime = engine.runtime
        try await runtime.install(signedManifest: manifestData, pack: pack, trust: trust,
                                  appVersion: environment.appVersion, macOSVersion: environment.macOSVersion,
                                  allowRolledBack: parsed.flags.contains("--reinstall"))
        let status = try runtime.status()
        if parsed.json { return CommandResult(stdout: Commands.encode(status)) }
        var text = "installed runtime \(status.current?.id ?? "?")\n"
        text += Table([
            ("current", status.current.map(describe) ?? "none"),
            ("host", status.current?.host ?? "none"),
            ("previous", status.previous.map(describe) ?? "none"),
        ]).rendered(indent: "  ")
        return CommandResult(stdout: text)
    }

    /// An https URL, nil for a path; other schemes are refused.
    private static func httpsURL(_ text: String) throws(UsageError) -> URL? {
        guard text.contains("://") else { return nil }
        guard text.hasPrefix("https://"), let url = URL(string: text) else {
            throw UsageError(message: "only https URLs are supported: \(text)")
        }
        return url
    }

    struct TrustReport: Encodable, Equatable {
        struct Key: Encodable, Equatable {
            var id: String
            /// "release", "development" or nil for a key the tools do not name.
            var name: String?
            var publicKey: String
        }

        /// "release" or "debug": which pins this build compiled in (`RuntimeTrust.isDebugBuild`).
        var build: String
        var manifestKeys: [Key]
        var signers: [String]
    }

    static func trustReport(_ trust: ManifestTrust, debugBuild: Bool) -> TrustReport {
        let keys = trust.publicKeys.sorted { $0.key < $1.key }.map { id, key in
            TrustReport.Key(id: id, name: id == RuntimeTrust.releaseKeyID ? "release"
                                : id == RuntimeTrust.developmentKeyID ? "development" : nil,
                            publicKey: key.base64EncodedString())
        }
        return TrustReport(build: debugBuild ? "debug" : "release", manifestKeys: keys,
                           signers: trust.signerFingerprints.sorted())
    }

    /// `runtime trust`: what this build pins, so a release can be checked (App/make-app.sh refuses an app whose
    /// warzagctl trusts the DEV key).
    static func trust(_ parsed: Arguments) throws -> CommandResult {
        try noPositional(parsed)
        let report = trustReport(RuntimeTrust.pinned, debugBuild: RuntimeTrust.isDebugBuild)
        if parsed.json { return CommandResult(stdout: Commands.encode(report)) }
        var rows: [(String, String)] = [("build", report.build)]
        for key in report.manifestKeys {
            rows.append(("key", "\(key.id)" + (key.name.map { " (\($0))" } ?? "") + " \(key.publicKey)"))
        }
        for signer in report.signers { rows.append(("signer", signer)) }
        return CommandResult(stdout: Table(rows).rendered(indent: ""))
    }

    static func rollback(_ parsed: Arguments, _ environment: EngineCLIEnvironment) throws -> CommandResult {
        try noPositional(parsed)
        let runtime = environment.engine.runtime
        let before = try runtime.status().current?.id
        try runtime.rollback()
        let status = try runtime.status()
        if parsed.json { return CommandResult(stdout: Commands.encode(status)) }
        var text = "rolled back to \(status.current?.id ?? "?") (\(status.current?.host ?? "?"))\n"
        if let before { text += "\(before) will not be installed again automatically\n" }
        return CommandResult(stdout: text)
    }

    // MARK: prefix

    static func setUp(_ parsed: Arguments, _ environment: EngineCLIEnvironment) async throws -> CommandResult {
        try noPositional(parsed)
        let library = parsed.values["--library"].map(environment.resolve)
        let prefix = environment.engine.prefix
        let macDriver = prefix.recordedMacDriver() ?? environment.macDriver
        let report = parsed.words[0] == "create"
            ? try await prefix.create(library: library, macDriver: macDriver)
            : try await prefix.repair(library: library, macDriver: macDriver)
        if parsed.json { return CommandResult(stdout: Commands.encode(report)) }
        let folders = report.replacedFolderLinks.isEmpty
            ? "already real folders" : report.replacedFolderLinks.joined(separator: ", ") + " made real folders"
        let identity = switch report.identity {
        case .captured: "captured after the first boot (Identity/identity.json)"
        case .restored: "restored from Identity/identity.json"
        }
        let text = Table([
            ("prefix", report.prefix + (report.created ? " (created)" : " (updated)")),
            ("runtime", "\(report.runtimeID) (channel \(report.channel.rawValue))"),
            ("library", "X: -> \(report.library)"),
            ("files", "\(report.filesInstalled) DXMT/lsteamclient placeholders and Steam bridge files"),
            ("folders", folders),
            ("identity", identity),
            ("log", report.log),
        ]).rendered(indent: "") + "next: warzagctl prefix doctor\n"
        return CommandResult(stdout: text)
    }

    static func doctor(_ parsed: Arguments, _ environment: EngineCLIEnvironment) async -> CommandResult {
        let report = await environment.engine.prefix.doctor()
        let exitCode: Int32 = report.passed ? 0 : 1
        if parsed.json { return CommandResult(stdout: Commands.encode(report), exitCode: exitCode) }
        let failed = report.checks.filter { !$0.passed }.count
        let summary = failed == 0
            ? "all \(report.checks.count) checks passed\n"
            : "\(failed) of \(report.checks.count) checks failed\n"
        return CommandResult(stdout: report.lines.map { $0 + "\n" }.joined() + summary, exitCode: exitCode)
    }

    struct PrefixPath: Encodable {
        var prefix: String
        var channel: RuntimeChannel
    }

    static func path(_ parsed: Arguments, _ environment: EngineCLIEnvironment) throws -> CommandResult {
        try noPositional(parsed)
        let layout = environment.engine.prefix.layout
        if parsed.json { return CommandResult(stdout: Commands.encode(PrefixPath(prefix: layout.root.plainPath, channel: .n))) }
        return CommandResult(stdout: layout.root.plainPath + "\n")
    }

    static func runProgram(_ parsed: Arguments, _ environment: EngineCLIEnvironment) async throws -> CommandResult {
        try noPositional(parsed)
        guard let program = parsed.rest.first else {
            throw UsageError(message: "prefix run needs -- <program> [arguments...]")
        }
        let rendererName = parsed.values["--renderer"] ?? Renderer.dxmt.rawValue
        guard let renderer = Renderer(rawValue: rendererName) else {
            throw UsageError(message: "unknown renderer: \(rendererName) (dxmt or wined3d)")
        }
        var timeout: Duration?
        if let text = parsed.values["--timeout"] {
            guard let seconds = Int(text), seconds > 0 else {
                throw UsageError(message: "--timeout needs a number of seconds")
            }
            timeout = .seconds(seconds)
        }
        // A Unix path (relative ones from the working directory); a Windows path (C:\...) is passed as it is.
        let isWindowsPath = program.count > 2 && Array(program)[1] == ":"
        let programPath = isWindowsPath ? program : environment.resolve(program).plainPath
        let prefix = environment.engine.prefix
        let output = try await prefix.runProgram(
            programPath, arguments: Array(parsed.rest.dropFirst()),
            renderer: RendererOptions(renderer: renderer, enableNVEXT: parsed.flags.contains("--nvext")),
            timeout: timeout)
        try await prefix.waitForServer()
        let log = prefix.logFile.plainPath
        let text = "\(program) exited with status \(output.exitCode); its output is in \(log)\n"
        return output.succeeded ? CommandResult(stdout: text) : CommandResult(stderr: text, exitCode: 1)
    }
}
