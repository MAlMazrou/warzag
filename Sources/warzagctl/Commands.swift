import EngineKit
import Foundation
import ProfileKit
import RuntimeKit
import SteamHostKit
import WarzagCore
import WineKit

/// Every side effect a command needs, injected so commands run against fakes in tests.
struct CommandContext: Sendable {
    var paths: WarzagPaths
    var steam: SteamLocations
    var fileSystem: any FileSystem
    var processes: any ProcessInspecting
    var system: any SystemInfoProviding
    var inheritedEnvironment: [String: String]
    var currentDirectory: URL
    var timeZone: TimeZone

    /// The real Mac, for the command's home (`--home`, wherever it stood on the line).
    static func live(home: String?) -> CommandContext {
        let homeURL = home.map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return CommandContext(
            paths: WarzagPaths(home: homeURL),
            steam: SteamLocations(home: homeURL),
            fileSystem: LocalFileSystem(),
            processes: DarwinProcessInspector(),
            system: LiveSystemInfo(),
            inheritedEnvironment: ProcessInfo.processInfo.environment,
            currentDirectory: URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory),
            timeZone: .current
        )
    }

    var runtimeStore: RuntimeStore { RuntimeStore(paths: paths, fileSystem: fileSystem) }
}

struct CommandResult: Equatable {
    var stdout = ""
    var stderr = ""
    var exitCode: Int32 = 0
}

enum Commands {
    static let version = "0.1.0"

    static func run(_ invocation: Invocation, in context: CommandContext) -> CommandResult {
        switch invocation {
        case .help: CommandResult(stdout: CommandLineParser.usage + "\n" + ExtensionCommands.usage + "\n")
        case .version: CommandResult(stdout: "warzagctl \(version)\n")
        case .paths(let json): paths(json: json, context)
        case .doctor(let json): doctor(json: json, context)
        case .steamStatus(let json): steamStatus(json: json, context)
        case .steamTimeline(let minutes, let follow):
            GameCommands.runBlocking {
                await SteamCommands.timeline(minutes: minutes, follow: follow, context, output: .standardOutput,
                                             clock: SystemClock())
            }
        case .steamProbe:
            GameCommands.runBlocking {
                await SteamCommands.probe(context, engine: .live(paths: context.paths,
                                                                 inheritedEnvironment: context.inheritedEnvironment),
                                          output: .standardOutput)
            }
        case .profile(let json): profile(json: json, context)
        case .env(let options): env(options, context)
        }
    }

    // MARK: paths

    static func paths(json: Bool, _ context: CommandContext) -> CommandResult {
        let all = context.paths.all
        if json {
            return CommandResult(stdout: encode(Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0.url.plainPath) })))
        }
        return CommandResult(stdout: Table(all.map { ($0.name, $0.url.plainPath) }).rendered(indent: ""))
    }

    // MARK: doctor

    struct DoctorReport: Encodable {
        var hardware: HardwareProfile
        var tier: TierClassification
        var steam: SteamStatus
        var setup: String
        var runtime: String?
        var libraryVolume: VolumeInfo?
        var problems: [String]
        var warnings: [String]
    }

    static func doctorReport(_ context: CommandContext) -> DoctorReport {
        let hardware = HardwareProfile.detect(using: context.system)
        let steam = SteamDetector(locations: context.steam, fileSystem: context.fileSystem,
                                  processes: context.processes, timeZone: context.timeZone).status()
        let setupSummary = switch SetupStateStore(paths: context.paths, fileSystem: context.fileSystem).inspect() {
        case .missing: "not started"
        case .readable(let state): state.isReadyToPlay ? "ready" : "in progress"
        case .unreadable: "setup.json is unreadable (Warzag will set it aside and start setup over)"
        }
        let store = context.runtimeStore
        let runtime: String?
        do {
            runtime = try store.load().current.map { "\($0.id) (\(store.hostURL(for: $0).plainPath))" }
        } catch {
            // An unreadable store, or one still in the old place that cannot move yet, is not "none installed".
            runtime = "\(error)"
        }
        let volume = try? context.fileSystem.volumeInfo(for: context.paths.warframeLibrary)

        var problems: [String] = []
        var warnings: [String] = []
        if !hardware.isAppleSilicon { problems.append("Warzag needs an Apple silicon Mac") }
        if let os = VersionNumber(hardware.macOSVersion), os < Platform.minimumMacOS {
            problems.append("Warzag needs macOS \(Platform.minimumMacOS) or later (this Mac has \(hardware.macOSVersion))")
        }
        if hardware.lowPowerMode {
            warnings.append("Low Power Mode is on: Warframe will be capped at \(FramePacing.coolCap) fps")
        }
        if hardware.thermalState >= .serious {
            warnings.append("the Mac is hot (thermal state \(hardware.thermalState.rawValue))")
        }
        if let volume {
            if volume.isCaseSensitive {
                problems.append("the library volume is case-sensitive; Wine needs case-insensitive")
            }
            if let free = volume.availableCapacity, free < Platform.minimumLibraryBytes {
                warnings.append("only \(gigabytes(free)) free for the library; a fresh install needs about "
                    + gigabytes(Platform.minimumLibraryBytes))
            }
        }
        if !steam.installed { warnings.append("Steam is not installed (Warzag offers to install it)") }
        return DoctorReport(hardware: hardware, tier: hardware.tierClassification, steam: steam, setup: setupSummary,
                            runtime: runtime, libraryVolume: volume, problems: problems, warnings: warnings)
    }

    static func doctor(json: Bool, _ context: CommandContext) -> CommandResult {
        let report = doctorReport(context)
        let exitCode: Int32 = report.problems.isEmpty ? 0 : 1
        if json { return CommandResult(stdout: encode(report), exitCode: exitCode) }

        let hardware = report.hardware
        var cores = "\(hardware.performanceCores) performance + \(hardware.efficiencyCores) efficiency cores"
        if let gpu = hardware.gpuCores { cores += ", \(gpu)-core GPU" }
        var text = "Hardware\n" + Table([
            ("chip", "\(hardware.chip) (\(cores))"),
            ("memory", "\(hardware.memoryGB) GB"),
            ("model", hardware.modelIdentifier + (hardware.productName.map { " — \($0)" } ?? "")),
            ("fanless", yesNo(hardware.isFanless)),
            ("macOS", hardware.macOSVersion),
            ("power", "\(hardware.powerSource.rawValue), Low Power Mode \(hardware.lowPowerMode ? "on" : "off"), "
                + "thermal \(hardware.thermalState.rawValue)"),
            ("tier", "\(report.tier.tier.rawValue) — \(report.tier.reason)"),
        ]).rendered()
        text += "Steam\n" + Table(steamRows(report.steam)).rendered()
        var warzag: [(String, String)] = [("setup", report.setup), ("runtime", report.runtime ?? "none installed")]
        if let volume = report.libraryVolume {
            let free = volume.availableCapacity.map { "\(gigabytes($0)) free" } ?? "free space unknown"
            let naming = volume.isCaseSensitive ? "case-sensitive" : "case-insensitive"
            warzag.append(("library volume", "\(volume.format ?? "unknown"), \(naming), \(free)"))
        }
        text += "Warzag\n" + Table(warzag).rendered()
        for problem in report.problems { text += "problem: \(problem)\n" }
        for warning in report.warnings { text += "warning: \(warning)\n" }
        return CommandResult(stdout: text, exitCode: exitCode)
    }

    // MARK: steam status

    static func steamStatus(json: Bool, _ context: CommandContext) -> CommandResult {
        let status = SteamDetector(locations: context.steam, fileSystem: context.fileSystem,
                                   processes: context.processes, timeZone: context.timeZone).status()
        if json { return CommandResult(stdout: encode(status)) }
        return CommandResult(stdout: Table(steamRows(status)).rendered(indent: ""))
    }

    static func steamRows(_ status: SteamStatus) -> [(String, String)] {
        let signedIn: String
        if !status.running {
            signedIn = "no (Steam is not running)"
        } else if let connection = status.connection {
            signedIn = status.signedIn ? "yes" : "no (\(connection.rawValue))"
        } else {
            signedIn = "no (no connection state logged since Steam started)"
        }
        return [
            ("installed", status.appBundle.map { "yes (\($0.plainPath))" } ?? "no"),
            ("client", (status.clientVersion ?? "unknown version")
                + (status.clientRuntimeInstalled ? " (steamclient.dylib present)" : " (steamclient.dylib missing)")),
            ("running", status.processID.map { "yes (pid \($0))" } ?? "no"),
            ("signed in", signedIn),
        ]
    }

    // MARK: profile

    struct ProfileReport: Encodable {
        var tier: TierClassification
        /// The app preset whose upscaler the seed carries: the one recommended for this Mac.
        var recommendedPreset: GraphicsChoice
        var preset: GraphicsPreset
        var sessionFrameRateCap: Int
        var dxmtConfig: String
        var eeConfig: String
    }

    static func profile(json: Bool, _ context: CommandContext) -> CommandResult {
        let hardware = HardwareProfile.detect(using: context.system)
        // The seed the app writes (LiveGameService.seedProfile) for a player who kept the recommended preset; the app
        // passes the player's own preset when they chose another.
        let recommended = GraphicsChoice.recommended(for: hardware.tierClassification.tier)
        let preset = PresetCatalog.preset(for: hardware, upscaling: recommended.upscaling)
        let session = SessionGraphics.make(for: hardware)
        let cap = session.frameRateCap
        let dxmtConfig = DXMTConfig(preferredMaxFrameRate: cap).rendered ?? ""
        let report = ProfileReport(tier: hardware.tierClassification, recommendedPreset: recommended, preset: preset,
                                   sessionFrameRateCap: cap, dxmtConfig: dxmtConfig,
                                   eeConfig: EEConfigSeed.render(preset.eeConfig))
        if json { return CommandResult(stdout: encode(report)) }
        let presetName = recommended.rawValue.capitalized
        var text = Table([
            ("tier", "\(report.tier.tier.rawValue) — \(report.tier.reason)"),
            ("frame cap", cap == preset.frameRateCap ? "\(cap) fps" : "\(cap) fps now (preset \(preset.frameRateCap) fps)"),
            ("DXMT_CONFIG", dxmtConfig),
            ("upscaling", upscalingText(preset.upscaling) + ": the \(presetName) preset, recommended for this Mac"),
            ("RetinaMode", yesNo(preset.retinaMode)),
            ("NVEXT", nvextText(session.enableNVEXT)),
        ]).rendered(indent: "")
        text += "EE.cfg seed (written once, only if the player has no EE.cfg; with the \(presetName) preset's upscaler "
            + "unless the player chose another preset in the app):\n"
        text += report.eeConfig.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n")
            .map { "  \($0)\n" }.joined()
        return CommandResult(stdout: text)
    }

    /// Warframe's upscaler as the seed sets it (the player can change it in Options > Display > Upscaling).
    static func upscalingText(_ upscaling: Upscaling) -> String {
        switch upscaling.method {
        case .disabled: "none (native resolution, temporal anti-aliasing)"
        case .fsr3: "FSR 3" + (upscaling.quality.map { " (\($0.rawValue))" } ?? " (quality left to Warframe)")
        }
    }

    /// NVEXT as `warzagctl profile` shows it (`PresetCatalog.nvextDefault`).
    static func nvextText(_ enabled: Bool) -> String {
        enabled ? "on (an NVIDIA identity only; DLSS is unavailable in Warframe)"
            : "off (it would only give Warframe an NVIDIA identity; DLSS is unavailable in Warframe)"
    }

    // MARK: env

    static func env(_ options: EnvOptions, _ context: CommandContext) -> CommandResult {
        var note = ""
        let environment: [String: String]
        switch options.kind {
        case .tool:
            let prefix = options.prefix.map { URL(filePath: $0, directoryHint: .isDirectory) }
                ?? context.paths.prefix(for: .n)
            environment = WineEnvironment.toolRun(prefix: prefix, inherited: context.inheritedEnvironment)
        case .session:
            let host: GameHost
            do {
                let (resolved, hostNote) = try resolveHost(options, context)
                host = resolved
                note = hostNote.map { "warzagctl: \($0)\n" } ?? ""
            } catch {
                return CommandResult(stderr: "warzagctl: \(error)\n", exitCode: 1)
            }
            let prefix = options.prefix.map { URL(filePath: $0, directoryHint: .isDirectory) }
                ?? context.paths.prefix(for: host.channel)
            // The same frame cap and NVEXT `warzagctl play` uses (ProfileKit's SessionGraphics; NVEXT only on request).
            let graphics = SessionGraphics.make(for: HardwareProfile.detect(using: context.system), nvext: options.nvext)
            let renderer = RendererOptions(renderer: options.renderer, frameRateCap: graphics.frameRateCap,
                                           enableNVEXT: graphics.enableNVEXT)
            let steam = options.steam ? SteamSession(clientDirectory: context.steam.clientDirectory) : nil
            environment = WineEnvironment.gameSession(prefix: prefix, host: host, renderer: renderer, steam: steam,
                                                      inherited: context.inheritedEnvironment)
        }
        let lines = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)\n" }.joined()
        return CommandResult(stdout: lines, stderr: note)
    }

    /// `--host` (its channel read from the bundle), else the active runtime, else the development host that
    /// runtime/n/make-host.sh builds.
    static func resolveHost(_ options: EnvOptions, _ context: CommandContext) throws -> (GameHost, String?) {
        if let path = options.host {
            let bundle = URL(filePath: path, directoryHint: .isDirectory)
            guard context.fileSystem.directoryExists(at: bundle) else {
                return (GameHost(bundle: bundle, channel: .n),
                        "\(bundle.plainPath) does not exist; showing the environment it would get")
            }
            return (try GameHost.detect(bundle: bundle, fileSystem: context.fileSystem), nil)
        }
        let store = context.runtimeStore
        if let current = (try? store.load())?.current, let active = try? store.activeHost() {
            return (GameHost(bundle: active, channel: current.channel), nil)
        }
        let development = context.currentDirectory.appending(path: "build/n/\(WarzagPaths.gameHostName)",
                                                              directoryHint: .isDirectory)
        let note = context.fileSystem.directoryExists(at: development)
            ? nil : "no runtime installed; showing the environment for \(development.plainPath)"
        return (GameHost(bundle: development, channel: .n), note)
    }

    // MARK: helpers

    static func encode(_ value: some Encodable) -> String {
        guard let data = try? WarzagJSON.encoder(pretty: true).encode(value) else { return "{}\n" }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }

    static func gigabytes(_ bytes: Int64) -> String {
        "\(Int((Double(bytes) / 1_000_000_000).rounded())) GB"
    }
}

/// Two aligned columns.
struct Table {
    var rows: [(String, String)]

    init(_ rows: [(String, String)]) {
        self.rows = rows
    }

    func rendered(indent: String = "  ") -> String {
        let width = rows.map(\.0.count).max() ?? 0
        return rows.map { name, value in
            indent + name.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + value + "\n"
        }.joined()
    }
}
