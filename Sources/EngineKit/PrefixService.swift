import Foundation
import RuntimeKit
import WarzagCore
import WineKit

public enum PrefixError: Error, Equatable, CustomStringConvertible {
    case hostIncomplete(String)
    case toolFailed(command: String, exitCode: Int32, log: String)
    /// A Wine tool passed its deadline: it was stopped, and so was everything else in the prefix (`wineserver -k`).
    case toolTimedOut(command: String, seconds: Int, log: String)
    case bootFailed(log: String)
    case notCreated(String)
    case libraryConflict(String)
    case libraryUnavailable(String)
    case registry(String)
    case volumeSerialUnreadable(drive: String, log: String)
    case manifestUnreadable(String)

    public var description: String {
        switch self {
        case .hostIncomplete(let path): "the runtime is incomplete: \(path) is missing"
        case .toolFailed(let command, let code, let log): "\(command) failed (exit \(code)); see \(log)"
        case .toolTimedOut(let command, let seconds, let log):
            "\(command) did not finish within \(seconds) s; it and the prefix's other processes were stopped; see \(log)"
        case .bootFailed(let log): "wineboot did not create the prefix; see \(log)"
        case .notCreated(let path): "there is no prefix at \(path) (warzagctl prefix create)"
        case .libraryConflict(let path): "\(path) is not a link Warzag made; move it away first"
        case .libraryUnavailable(let path): "the volume holding \(path) is not mounted"
        case .registry(let reason): "cannot write the registry file: \(reason)"
        case .volumeSerialUnreadable(let drive, let log): "could not read the volume serial of \(drive):; see \(log)"
        case .manifestUnreadable(let reason): "warzag-prefix.json is unreadable: \(reason)"
        }
    }
}

/// A file the prefix needs from the runtime host, and where it goes.
public struct PrefixFile: Sendable, Equatable {
    public enum Group: String, Sendable, Codable, CaseIterable {
        /// DXMT's DLLs need a copy in system32 before Wine looks for them in the DXMT overlay: without
        /// winemetal.dll's placeholder DXMT fails with c0000135.
        case dxmt
        /// The bridge's builtin lsteamclient.dll, for the same reason.
        case lsteamclient
        /// steam.exe, the forwarder under Steam's own name, and the probe (bridge/install-prefix.sh).
        case bridge
    }

    public var group: Group
    public var source: URL
    public var destination: URL
}

public enum PrefixFiles {
    /// The DXMT DLLs that need a placeholder in system32: Wine's own d3d11/dxgi are found there already.
    public static let dxmtPlaceholders = ["winemetal.dll", "nvapi64.dll", "nvngx.dll"]

    /// Every file copied from `host` into the prefix: the system32 placeholders, from `renderers/dxmt/aarch64-windows`
    /// and `lib/wine/aarch64-windows`, then the bridge files in the order bridge/install-prefix.sh installs them.
    public static func all(host: GameHost, layout: PrefixLayout) -> [PrefixFile] {
        let runtime = RuntimeHostLayout(host)
        let system32 = layout.driveC.appending(path: "windows/system32", directoryHint: .isDirectory)
        var files = dxmtPlaceholders.map {
            PrefixFile(group: .dxmt, source: runtime.dxmtWindowsDLLs.appending(path: $0),
                       destination: system32.appending(path: $0))
        }
        files.append(PrefixFile(group: .lsteamclient, source: runtime.builtinDLLs.appending(path: "lsteamclient.dll"),
                                destination: system32.appending(path: "lsteamclient.dll")))
        let bridge: [(String, String)] = [
            ("steam.exe", "steam.exe"),
            ("steamclient64-forwarder.dll", "steamclient64.dll"),
            ("wz-steamprobe.exe", "wz-steamprobe.exe"),
        ]
        files += bridge.map { shipped, name in
            PrefixFile(group: .bridge, source: runtime.bridgeDirectory.appending(path: shipped),
                       destination: layout.steamDirectory.appending(path: name))
        }
        return files
    }
}

/// What `create` or `repair` did.
public struct PrefixReport: Codable, Equatable, Sendable {
    public enum IdentitySource: String, Codable, Sendable {
        /// Read from the prefix after its first boot and saved to Identity/identity.json.
        case captured
        /// Re-applied from Identity/identity.json.
        case restored
    }

    public var prefix: String
    public var channel: RuntimeChannel
    public var runtimeID: String
    /// A new prefix was booted (wineboot on an empty directory).
    public var created: Bool
    public var library: String
    public var identity: IdentitySource
    /// User folders whose link into the Mac home was replaced by a real folder.
    public var replacedFolderLinks: [String]
    public var filesInstalled: Int
    /// Where the Wine tools' output went.
    public var log: String
}

/// The Wine prefix: creation, repair after a runtime update, and checks. `create` and `repair`, in order:
///
/// 1. `wineboot --init`, then `wineserver -w`. On an existing prefix this applies a runtime update, so it runs before
///    anything is copied: the update reinstalls Wine's own DLL stubs over the placeholders.
/// 2. X: -> the library (`dosdevices/x:`).
/// 3. DXMT and lsteamclient placeholders, Steam bridge files.
/// 4. Real Desktop/Documents/Downloads/Music/Videos folders instead of Wine's links into the Mac home (no macOS
///    privacy prompts); Pictures stays linked.
/// 5. Identity: captured after the first boot, or restored from Identity/identity.json.
/// 6. Registry: WineKit's template plus the identity values, then the bridge's steam.reg, each with `reg import`.
/// 7. `wineserver -w`, then `warzag-prefix.json` with the runtime the prefix was set up with.
public struct PrefixService: Sendable {
    /// The user folders that become real directories.
    public static let realFolders = ["Desktop", "Documents", "Downloads", "Music", "Videos"]
    /// Keeps a user folder non-empty: Wine replaces an empty real folder with a link again when it relinks folders.
    public static let keepFileName = ".warzag-keep"
    static let keepFileContents = Data("Warzag: keeps this folder a real folder inside the Wine prefix.\n".utf8)
    /// The drives whose volume serials the identity pins.
    public static let identityDrives = ["C", "X"]
    /// Wine's record, at the prefix root, of the wine.inf it last installed: the file's modification time, written
    /// before that install starts (programs/wineboot). wineboot runs the install only when the two differ.
    public static let wineUpdateTimestamp = ".update-timestamp"

    public let engine: Engine

    public init(engine: Engine) {
        self.engine = engine
    }

    private var fileSystem: any EngineFileSystem { engine.fileSystem }

    public var layout: PrefixLayout {
        PrefixLayout(root: engine.paths.prefix(for: .n), windowsUserName: engine.windowsUserName)
    }

    public var logFile: URL {
        engine.paths.logs.appending(path: "prefix-\(RuntimeChannel.n.rawValue).log")
    }

    /// One of Wine's hive files as it is on disk (current once the prefix's wineserver has exited).
    public func hive(_ file: RegistryHiveFile, in layout: PrefixLayout) -> WineRegistryHive? {
        WineRegistryHive.load(layout.root.appending(path: file.fileName), fileSystem: fileSystem)
    }

    public func isBooted(_ layout: PrefixLayout) -> Bool {
        fileSystem.fileExists(at: layout.root.appending(path: "system.reg"))
            && fileSystem.fileExists(at: layout.root.appending(path: "user.reg"))
            && fileSystem.directoryExists(at: layout.driveC.appending(path: "windows/system32", directoryHint: .isDirectory))
    }

    // MARK: Create and repair

    /// Creates the prefix for the active runtime, or brings an existing one up to date (then it is `repair`).
    /// `library` defaults to the one the prefix already maps, else Library/Warframe.noindex.
    public func create(library: URL? = nil, macDriver: MacDriverSettings) async throws -> PrefixReport {
        try await setUp(library: library, macDriver: macDriver, mustExist: false)
    }

    /// Re-applies placeholders, bridge files, registry, user folders and identity, e.g. after a runtime update,
    /// without recreating the prefix (DE's files, EE.cfg and the game library stay).
    public func repair(library: URL? = nil, macDriver: MacDriverSettings) async throws -> PrefixReport {
        try await setUp(library: library, macDriver: macDriver, mustExist: true)
    }

    private func setUp(library: URL?, macDriver: MacDriverSettings, mustExist: Bool) async throws -> PrefixReport {
        let active = try engine.runtime.active()
        try active.host.validate(fileSystem: fileSystem)
        let channel = active.runtime.channel
        let layout = self.layout
        let tools = tools(host: active.host, layout: layout)
        let created = !isBooted(layout)
        if created {
            if mustExist { throw PrefixError.notCreated(layout.root.plainPath) }
            try fileSystem.createDirectory(at: layout.root)
        }
        let files = PrefixFiles.all(host: active.host, layout: layout)
        let steamRegistry = RuntimeHostLayout(active.host).steamRegistry
        for source in files.map(\.source) + [steamRegistry] where !fileSystem.fileExists(at: source) {
            throw PrefixError.hostIncomplete(source.plainPath)
        }

        // An unreadable manifest is rewritten below; until then the X: link still says where the library is.
        let existing = try? PrefixManifest.load(from: layout, fileSystem: fileSystem)
        let timestamp = layout.root.appending(path: Self.wineUpdateTimestamp)
        if existing?.runtimeID != active.runtime.id,
           fileSystem.fileExists(at: timestamp) || fileSystem.isSymbolicLink(at: timestamp) {
            // Wine writes .update-timestamp before it runs wine.inf, so a first boot or a runtime update that was cut
            // short would never be redone and the prefix would stay half-built; nor would a new runtime whose wine.inf
            // kept the old modification time ever be applied. Without the file, this boot runs the whole update again,
            // the same one a new runtime triggers.
            try fileSystem.removeItem(at: timestamp)
        }

        try await tools.run(.wineboot)
        try await tools.waitForServer()
        guard isBooted(layout) else { throw PrefixError.bootFailed(log: tools.log.plainPath) }

        let mapped = (try? fileSystem.destinationOfSymbolicLink(at: layout.libraryDrive))
            .flatMap { $0.hasPrefix("/") ? $0 : nil }
        // `standardized`, not `standardizedFileURL`: the latter drops "/private" only for paths that already exist.
        let libraryURL = (library ?? (existing?.library ?? mapped).map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? engine.paths.warframeLibrary).standardized
        try mapLibrary(libraryURL, in: layout)

        for file in files {
            try fileSystem.replaceFile(at: file.destination, withCopyOf: file.source)
        }
        let replacedLinks = try makeRealUserFolders(in: layout)

        let (identity, source) = try await loadOrCaptureIdentity(layout: layout, library: libraryURL, tools: tools)

        var registry = Self.registryTemplate(macDriver: macDriver)
        for key in identity.registry.keys {
            for entry in key.entries { registry.set(key.hive, key.path, entry.name, entry.value) }
        }
        let rendered: Data
        do {
            rendered = try registry.data()
        } catch {
            throw PrefixError.registry(error.description)
        }
        try await tools.importRegistry(rendered, named: "warzag-prefix.reg")
        try await tools.importRegistry(try fileSystem.contents(of: steamRegistry), named: "warzag-steam.reg")
        try writeVolumeSerials(identity, layout: layout, library: libraryURL)
        try await tools.waitForServer()

        let now = engine.clock.now
        let manifest = PrefixManifest(
            channel: channel, runtimeID: active.runtime.id, runtimeVersion: active.runtime.version,
            library: libraryURL.plainPath, macDriver: MacDriverOptions(macDriver),
            createdAt: existing?.createdAt ?? now, configuredAt: now)
        try manifest.save(in: layout, fileSystem: fileSystem)
        return PrefixReport(prefix: layout.root.plainPath, channel: channel, runtimeID: active.runtime.id,
                            created: created, library: libraryURL.plainPath, identity: source,
                            replacedFolderLinks: replacedLinks, filesInstalled: files.count, log: tools.log.plainPath)
    }

    /// WineKit's template as create and repair apply it. The template writes Command-as-Ctrl only when it is on;
    /// here it is also written when off ("n", Wine's default), so a repair can turn it off instead of leaving an
    /// earlier "y" in the prefix.
    static func registryTemplate(macDriver: MacDriverSettings) -> RegistryFile {
        var file = PrefixTemplate.registry(macDriver: macDriver)
        if !macDriver.commandAsControl {
            for name in ["LeftCommandIsCtrl", "RightCommandIsCtrl"] {
                file.set(.currentUser, #"Software\Wine\Mac Driver"#, name, .string("n"))
            }
        }
        return file
    }

    /// The Mac Driver settings the prefix was last set up with (warzag-prefix.json); nil without a readable one.
    /// A repair should re-apply these, not defaults, so the player's choices survive it.
    public func recordedMacDriver() -> MacDriverSettings? {
        (try? PrefixManifest.load(from: layout, fileSystem: fileSystem))?.macDriver.settings
    }

    /// `dosdevices/x:` -> the library folder (created if missing, but never on an unmounted volume: a folder made
    /// under /Volumes/<name> would land on the startup disk and hide the real volume when it is mounted).
    func mapLibrary(_ library: URL, in layout: PrefixLayout) throws {
        let components = library.pathComponents
        if components.count > 2, components[1] == "Volumes",
           !fileSystem.directoryExists(at: URL(filePath: "/Volumes/\(components[2])", directoryHint: .isDirectory)) {
            throw PrefixError.libraryUnavailable(library.plainPath)
        }
        try fileSystem.createDirectory(at: library)
        let link = layout.libraryDrive
        if fileSystem.isSymbolicLink(at: link) {
            if (try? fileSystem.destinationOfSymbolicLink(at: link)) == library.plainPath { return }
            try fileSystem.removeItem(at: link)
        } else if fileSystem.fileExists(at: link) {
            throw PrefixError.libraryConflict(link.plainPath)
        }
        try fileSystem.createSymbolicLink(at: link, destination: library.plainPath)
    }

    /// Replaces Wine's links into the Mac home with real folders. Returns the folders that were links.
    func makeRealUserFolders(in layout: PrefixLayout) throws -> [String] {
        var replaced: [String] = []
        for name in Self.realFolders {
            let folder = layout.userProfile.appending(path: name, directoryHint: .isDirectory)
            if fileSystem.isSymbolicLink(at: folder) {
                try fileSystem.removeItem(at: folder)
                replaced.append(name)
            }
            try fileSystem.createDirectory(at: folder)
            _ = try fileSystem.createExclusively(Self.keepFileContents, at: folder.appending(path: Self.keepFileName))
        }
        return replaced
    }

    // MARK: Identity

    private func loadOrCaptureIdentity(layout: PrefixLayout, library: URL,
                                       tools: WineTools) async throws -> (MachineIdentity, PrefixReport.IdentitySource) {
        let vault = engine.identity
        if var identity = try vault.load() {
            // A drive missing from the saved identity gets its current serial; nothing else changes.
            let missing = Self.identityDrives.filter { identity.volumeSerials[$0] == nil }
            if !missing.isEmpty {
                for (drive, serial) in try await readVolumeSerials(missing, layout: layout, tools: tools) {
                    identity.volumeSerials[drive] = serial
                }
                try vault.save(identity)
            }
            return (identity, .restored)
        }

        let system = hive(.system, in: layout) ?? WineRegistryHive(text: "")
        var machineGuid = ""
        if case .string(let value)? = system.value(MachineIdentity.cryptographyKey, "MachineGuid"),
           MachineIdentity.isValidMachineGuid(value) {
            machineGuid = value
        } else {
            // Wine creates it on the first CryptAcquireContext; make sure it exists from now on.
            machineGuid = UUID().uuidString.lowercased()
        }
        var computerName = MachineIdentity.fallbackComputerName
        if case .string(let value)? = system.value(MachineIdentity.computerNameKey, "ComputerName"),
           MachineIdentity.isValidComputerName(value) {
            computerName = value
        }
        let serials = try await readVolumeSerials(Self.identityDrives, layout: layout, tools: tools)
        let identity = MachineIdentity(machineGuid: machineGuid, computerName: computerName,
                                       volumeSerials: serials, windowsUserName: layout.windowsUserName,
                                       capturedAt: engine.clock.now)
        try vault.save(identity)
        return (identity, .captured)
    }

    /// What Windows programs see now: `vol` for each drive, written by cmd itself into C:\windows\temp so Wine's
    /// own messages on stderr cannot mix in.
    private func readVolumeSerials(_ drives: [String], layout: PrefixLayout,
                                   tools: WineTools) async throws -> [String: String] {
        let outputs = drives.map { drive in
            (drive, layout.windowsTemp.appending(path: "warzag-vol-\(drive).txt"))
        }
        var line: [String] = []
        for (index, (drive, file)) in outputs.enumerated() {
            try? fileSystem.removeItem(at: file)
            if index > 0 { line.append("&") }
            line += ["vol", "\(drive):", ">", layout.windowsPath(for: file) ?? ""]
        }
        // cmd's exit status is that of the last `vol`; the files decide.
        _ = try await tools.output(of: .cmd(line))
        var serials: [String: String] = [:]
        for (drive, file) in outputs {
            defer { try? fileSystem.removeItem(at: file) }
            guard let data = try? fileSystem.contents(of: file),
                  let serial = VolumeSerial.parse(volOutput: String(decoding: data, as: UTF8.self)) else {
                throw PrefixError.volumeSerialUnreadable(drive: drive, log: tools.log.plainPath)
            }
            serials[drive] = serial
        }
        return serials
    }

    private func writeVolumeSerials(_ identity: MachineIdentity, layout: PrefixLayout, library: URL) throws {
        let roots = ["C": layout.driveC, "X": library]
        for (drive, root) in roots {
            guard let serial = identity.volumeSerials[drive] else { continue }
            try fileSystem.writeAtomically(VolumeSerial.fileContents(serial),
                                           to: root.appending(path: VolumeSerial.fileName))
        }
    }

    // MARK: Programs

    /// Runs a Windows program in the prefix with a game session's environment (`WineEnvironment.gameSession`),
    /// output appended to the prefix log. For QA and diagnostics; Play opens the host through LaunchServices (GameKit).
    /// A program still running after `timeout` is stopped with the rest of the prefix (`PrefixError.toolTimedOut`).
    public func runProgram(_ program: String, arguments: [String] = [], renderer: RendererOptions,
                           steam: SteamSession? = nil, workingDirectory: URL? = nil,
                           timeout: Duration? = nil) async throws -> ProcessOutput {
        let active = try engine.runtime.active()
        let layout = self.layout
        guard isBooted(layout) else { throw PrefixError.notCreated(layout.root.plainPath) }
        let environment = WineEnvironment.gameSession(prefix: layout.root, host: active.host, renderer: renderer,
                                                      steam: steam, inherited: engine.inheritedEnvironment)
        let command = Command(executable: active.host.wine, arguments: [program] + arguments, environment: environment,
                              workingDirectory: workingDirectory, logFile: logFile, timeout: timeout)
        do {
            return try await engine.runner.run(command)
        } catch let timeout as ProcessTimedOut {
            let name = program.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? program
            throw await tools(host: active.host, layout: layout).stoppedPrefix(after: timeout, running: name)
        }
    }

    /// `wineserver -w` for the active runtime's prefix: returns once every process in it has exited (or stops the
    /// prefix and throws `toolTimedOut` after `WineTool.wineserverWait`'s deadline).
    public func waitForServer() async throws {
        let active = try engine.runtime.active()
        try await tools(host: active.host, layout: layout).waitForServer()
    }

    func tools(host: GameHost, layout: PrefixLayout) -> WineTools {
        WineTools(host: host, layout: layout, inherited: engine.inheritedEnvironment, log: logFile,
                  runner: engine.runner, fileSystem: fileSystem)
    }
}

/// Wine tool invocations for one prefix, all with the tool-run environment, a deadline per tool (`WineTool.timeout`)
/// and their output in one log file (see `Command.logFile`). After a tool's deadline, `wineserver -k` stops whatever it
/// started before the failure is reported (`PrefixError.toolTimedOut`).
struct WineTools: Sendable {
    let host: GameHost
    let layout: PrefixLayout
    let inherited: [String: String]
    let log: URL
    let runner: any ProcessRunning
    let fileSystem: any EngineFileSystem

    func command(_ tool: WineTool) -> Command {
        tool.command(host: host, prefix: layout.root, inherited: inherited, logFile: log)
    }

    /// Runs `tool` and throws unless it exits 0.
    func run(_ tool: WineTool, name: String? = nil) async throws {
        let result = try await output(of: tool)
        guard result.succeeded else {
            throw PrefixError.toolFailed(command: name ?? tool.name, exitCode: result.exitCode, log: log.plainPath)
        }
    }

    /// Runs `tool`, whatever its exit status; a passed deadline stops the prefix and throws `toolTimedOut`.
    func output(of tool: WineTool) async throws -> ProcessOutput {
        do {
            return try await runner.run(command(tool))
        } catch let timeout as ProcessTimedOut {
            throw await stoppedPrefix(after: timeout, running: tool.name, stopServer: tool != .wineserverKill)
        }
    }

    /// After `name` passed its deadline (the runner has stopped it): a line in the log, `wineserver -k` for whatever
    /// else runs in the prefix, and the error to report.
    func stoppedPrefix(after timeout: ProcessTimedOut, running name: String, stopServer: Bool = true) async -> PrefixError {
        note("\(name) did not finish within \(timeout.seconds) s and was stopped; stopping the prefix")
        if stopServer {
            _ = try? await runner.run(command(.wineserverKill))
        }
        return PrefixError.toolTimedOut(command: name, seconds: timeout.seconds, log: log.plainPath)
    }

    func waitForServer() async throws {
        try await run(.wineserverWait)
    }

    /// Writes `data` to C:\windows\temp\<name>, imports it with `reg import` (a Windows path, so it never depends on
    /// the Z: drive), then removes it.
    func importRegistry(_ data: Data, named name: String) async throws {
        let file = layout.windowsTemp.appending(path: name)
        guard let windowsPath = layout.windowsPath(for: file) else { return }
        try fileSystem.writeAtomically(data, to: file)
        defer { try? fileSystem.removeItem(at: file) }
        try await run(.regImport(windowsPath: windowsPath), name: "reg import \(name)")
    }

    /// Appends a line of Warzag's own to the log the tools write.
    private func note(_ text: String) {
        try? fileSystem.append(Data("warzag: \(text)\n".utf8), to: log)
    }
}
