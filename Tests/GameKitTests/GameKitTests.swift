import Foundation
import Synchronization
import Testing
import WarzagCore
import WarzagTestSupport
import WineKit
@testable import GameKit

// Test doubles and fixtures shared by the GameKit suites.

struct ClockLimitReached: Error {}

/// A clock that only moves when the code under test sleeps, running scripted actions as their time comes. A whole
/// 20-minute launcher run takes milliseconds, and every timing decision (stall watchdog, EULA wait) is exact.
final class ScriptedClock: WallClock {
    private struct Action {
        var time: Date
        var order: Int
        var run: @Sendable () -> Void
    }

    private struct State {
        var now: Date
        var actions: [Action] = []
        var order = 0
        var sleeps: [Duration] = []
    }

    let start: Date
    /// Safety net: a run that never ends fails instead of hanging the suite.
    let limit: TimeInterval
    private let state: Mutex<State>

    init(start: Date = Date(timeIntervalSince1970: 1_792_000_000), limit: TimeInterval = 7 * 24 * 3600) {
        self.start = start
        self.limit = limit
        state = Mutex(State(now: start))
    }

    var now: Date { state.withLock { $0.now } }
    var elapsed: TimeInterval { now.timeIntervalSince(start) }
    var sleeps: [Duration] { state.withLock { $0.sleeps } }

    /// Runs `action` once the clock reaches `seconds` after `start`.
    func at(_ seconds: TimeInterval, _ action: @escaping @Sendable () -> Void) {
        schedule(start.addingTimeInterval(seconds), action)
    }

    /// Runs `action` `seconds` from now.
    func after(_ seconds: TimeInterval, _ action: @escaping @Sendable () -> Void) {
        schedule(now.addingTimeInterval(seconds), action)
    }

    /// Runs `action(step)` every `interval` seconds from `first` (relative to now) for `count` times.
    func every(_ interval: TimeInterval, from first: TimeInterval, count: Int,
               _ action: @escaping @Sendable (Int) -> Void) {
        for step in 0..<count { after(first + Double(step) * interval) { action(step) } }
    }

    private func schedule(_ time: Date, _ action: @escaping @Sendable () -> Void) {
        state.withLock {
            $0.order += 1
            $0.actions.append(Action(time: time, order: $0.order, run: action))
        }
    }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        let due = state.withLock { state -> [Action] in
            state.sleeps.append(duration)
            state.now = state.now.addingTimeInterval(seconds)
            let due = state.actions.filter { $0.time <= state.now }.sorted { ($0.time, $0.order) < ($1.time, $1.order) }
            state.actions.removeAll { $0.time <= state.now }
            return due
        }
        if elapsed > limit { throw ClockLimitReached() }
        for action in due { action.run() }
        await Task.yield()
    }
}

/// Symbolic links and disk usage for an `InMemoryFileSystem`.
final class FakeGameFiles: GameFiles {
    private struct State {
        var links: [String: String] = [:]
        var usage: [String: Int64] = [:]
    }

    let fileSystem: InMemoryFileSystem
    private let state = Mutex(State())

    init(_ fileSystem: InMemoryFileSystem) {
        self.fileSystem = fileSystem
    }

    func link(_ path: String, to target: String) {
        state.withLock { $0.links[Self.key(path)] = Self.key(target) }
    }

    func unlink(_ path: String) {
        state.withLock { _ = $0.links.removeValue(forKey: Self.key(path)) }
    }

    func setUsage(_ directory: String, _ bytes: Int64) {
        state.withLock { $0.usage[Self.key(directory)] = bytes }
    }

    func addUsage(_ directory: String, _ bytes: Int64) {
        state.withLock { $0.usage[Self.key(directory), default: 0] += bytes }
    }

    func symbolicLinkDestination(of url: URL) -> URL? {
        state.withLock { $0.links[Self.key(url.plainPath)] }.map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    func isSameDirectory(_ first: URL, _ second: URL) -> Bool {
        let a = resolve(first.plainPath)
        let b = resolve(second.plainPath)
        return a == b && fileSystem.directoryExists(at: URL(filePath: a))
    }

    func diskUsage(of directory: URL) -> Int64 {
        state.withLock { $0.usage[Self.key(directory.plainPath)] ?? 0 }
    }

    func copyItem(at source: URL, to destination: URL) throws {
        try fileSystem.writeAtomically(try fileSystem.contents(of: source), to: destination)
    }

    private func resolve(_ path: String) -> String {
        state.withLock { $0.links[Self.key(path)] } ?? Self.key(path)
    }

    private static func key(_ path: String) -> String { URL(filePath: path).standardized.plainPath }
}

/// The host signature check before Play: passes unless told otherwise, and counts its calls.
final class FakeHostSignatures: HostSignatureChecking {
    struct Broken: Error, CustomStringConvertible {
        var description: String { "code signature validation failed (OSStatus -67061)" }
    }

    private let state = Mutex((broken: false, checked: [String]()))

    func breakSignature() { state.withLock { $0.broken = true } }
    var checked: [String] { state.withLock { $0.checked } }

    func verify(_ host: GameHost) throws {
        let broken = state.withLock { state -> Bool in
            state.checked.append(host.bundle.plainPath)
            return state.broken
        }
        if broken { throw Broken() }
    }
}

final class FakePrefixProbe: PrefixActivityProbing {
    private let busy = Mutex<Int32?>(nil)

    func setBusy(_ pid: Int32?) {
        busy.withLock { $0 = pid }
    }

    func wineserver(for prefix: URL) -> Int32? {
        busy.withLock { $0 }
    }
}

final class FakeProcess: RunningProcess {
    let processIdentifier: Int32
    let latch = ExitLatch()
    private let terminatedFlag = Mutex(false)

    init(_ processIdentifier: Int32) {
        self.processIdentifier = processIdentifier
    }

    var isRunning: Bool { !latch.isSet }
    var wasTerminated: Bool { terminatedFlag.withLock { $0 } }

    func exit(_ status: Int32? = 0) {
        latch.set(status)
    }

    func waitForExit() async -> Int32? {
        await latch.wait()
    }

    func terminate() {
        terminatedFlag.withLock { $0 = true }
        exit(15)
    }
}

/// Records each launch and hands every new process to `onLaunch(index, process)` so a test can script it.
final class FakeLauncher: ProcessLaunching {
    private let state = Mutex<(commands: [Command], processes: [FakeProcess])>(([], []))
    private let onLaunch: @Sendable (Int, FakeProcess) -> Void

    init(onLaunch: @escaping @Sendable (Int, FakeProcess) -> Void = { _, _ in }) {
        self.onLaunch = onLaunch
    }

    var commands: [Command] { state.withLock { $0.commands } }
    var processes: [FakeProcess] { state.withLock { $0.processes } }
    var current: FakeProcess? { processes.last }

    func launch(_ command: Command) throws -> any RunningProcess {
        let (index, process) = state.withLock { state -> (Int, FakeProcess) in
            let process = FakeProcess(Int32(4000 + state.processes.count))
            state.commands.append(command)
            state.processes.append(process)
            return (state.processes.count - 1, process)
        }
        onLaunch(index, process)
        return process
    }
}

final class FakeOpener: ApplicationOpening {
    struct Opened: Equatable {
        var application: URL
        var arguments: [String]
        var environment: [String: String]
        var activates: Bool
    }

    private let state = Mutex<(opened: [Opened], processes: [FakeProcess])>(([], []))
    private let onOpen: @Sendable (FakeProcess) -> Void
    let failure: (any Error & Sendable)?

    init(failure: (any Error & Sendable)? = nil, onOpen: @escaping @Sendable (FakeProcess) -> Void = { _ in }) {
        self.failure = failure
        self.onOpen = onOpen
    }

    var opened: [Opened] { state.withLock { $0.opened } }

    func openNewInstance(of application: URL, arguments: [String], environment: [String: String],
                         activates: Bool) async throws -> any RunningProcess {
        if let failure { throw failure }
        let process = state.withLock { state -> FakeProcess in
            state.opened.append(Opened(application: application, arguments: arguments, environment: environment,
                                       activates: activates))
            let process = FakeProcess(Int32(7000 + state.processes.count))
            state.processes.append(process)
            return process
        }
        onOpen(process)
        return process
    }
}

/// A runtime host, a prefix and a library in memory, laid out as Warzag installs them.
struct GameFixture {
    let fileSystem = InMemoryFileSystem()
    let files: FakeGameFiles
    let probe = FakePrefixProbe()
    let signatures = FakeHostSignatures()
    let clock = ScriptedClock()
    let host = GameHost(bundle: URL(filePath: "/Users/tenno/Library/Application Support/Warzag/Runtimes.noindex/n/0.2.0/Warzag.app",
                                    directoryHint: .isDirectory), channel: .n)
    let prefixPath = "/Users/tenno/Library/Application Support/Warzag/Prefixes/warframe-arm64"
    let libraryPath = "/Users/tenno/Library/Application Support/Warzag/Library/Warframe.noindex"
    let inherited = ["HOME": "/Users/tenno", "USER": "tenno", "DYLD_INSERT_LIBRARIES": "/x.dylib", "SteamAppUser": "x"]

    init() {
        files = FakeGameFiles(fileSystem)
    }

    var installation: GameInstallation {
        GameInstallation(host: host, prefix: PrefixLayout(root: URL(filePath: prefixPath, directoryHint: .isDirectory),
                                                          windowsUserName: "tenno"),
                         library: URL(filePath: libraryPath, directoryHint: .isDirectory))
    }

    var warframeData: String { prefixPath + "/drive_c/users/tenno/AppData/Local/Warframe" }
    var launcherLog: String { warframeData + "/Launcher.log" }
    var preprocessLog: String { warframeData + "/Preprocess.log" }
    var eeLog: String { warframeData + "/EE.log" }
    var userReg: String { prefixPath + "/user.reg" }

    func context(runner: any ProcessRunning = RecordingProcessRunner(), launcher: any ProcessLaunching = FakeLauncher(),
                 opener: any ApplicationOpening = FakeOpener()) -> GameContext {
        GameContext(fileSystem: fileSystem, files: files, runner: runner, launcher: launcher, opener: opener,
                    probe: probe, hostSignatures: signatures, clock: clock, inheritedEnvironment: inherited,
                    logDirectory: URL(filePath: "/Users/tenno/Library/Logs/Warzag", directoryHint: .isDirectory),
                    stateDirectory: URL(filePath: "/Users/tenno/Library/Application Support/Warzag/State",
                                        directoryHint: .isDirectory))
    }

    func addHost() {
        let contents = host.contents.plainPath
        fileSystem.addFile(contents + "/MacOS/wine", "loader")
        fileSystem.addFile(contents + "/MacOS/wineserver", "server")
        fileSystem.addDirectory(contents + "/renderers/dxmt/aarch64-windows")
    }

    /// A prefix as setup leaves it.
    func addPrefix(eula: String? = nil, launcherOverrides: Bool = true, steam: Bool = true,
                   placeholders: Bool = true) {
        fileSystem.addFile(prefixPath + "/system.reg", "WINE REGISTRY Version 2\n")
        fileSystem.addDirectory(libraryPath)
        fileSystem.addFile(prefixPath + "/dosdevices/x:", "")
        files.link(prefixPath + "/dosdevices/x:", to: libraryPath)
        fileSystem.addDirectory(prefixPath + "/drive_c/windows/temp")
        fileSystem.addDirectory(prefixPath + "/drive_c/users/Public")
        fileSystem.addDirectory(warframeData)
        if placeholders {
            for name in ["winemetal.dll", "nvapi64.dll", "nvngx.dll"] {
                fileSystem.addFile(prefixPath + "/drive_c/windows/system32/" + name, "PE")
            }
        }
        if steam {
            let steamDirectory = prefixPath + "/drive_c/Program Files (x86)/Steam/"
            for name in ["steam.exe", "steamclient64.dll", "wz-steamprobe.exe"] {
                fileSystem.addFile(steamDirectory + name, "PE")
            }
            fileSystem.addFile(prefixPath + "/drive_c/windows/system32/lsteamclient.dll", "PE")
        }
        fileSystem.addFile(userReg, Fixtures.userReg(eula: eula, launcherOverrides: launcherOverrides, steam: steam))
    }

    func setEULA(_ value: String?) {
        fileSystem.addFile(userReg, Fixtures.userReg(eula: value, launcherOverrides: true, steam: true))
    }

    func addLauncher() {
        fileSystem.addFile(libraryPath + "/Tools/Launcher.exe", "launcher")
    }

    func addGame() {
        addLauncher()
        fileSystem.addFile(libraryPath + "/Warframe.x64.exe", "game")
    }

    func appendLauncherLog(_ lines: [String]) {
        fileSystem.append(launcherLog, lines.map { $0 + "\r\n" }.joined())
    }
}

/// Non-personal lines from real logs. Nothing here comes from EE.log's sign-in lines; names, addresses and the Windows
/// user are invented.
enum Fixtures {
    static let eulaHash = "0123456789ABCDEF0123456789ABCDEF"

    static func userReg(eula: String?, launcherOverrides: Bool, steam: Bool) -> String {
        var text = """
            WINE REGISTRY Version 2
            ;; All keys relative to REGISTRY\\\\User\\\\S-1-5-21-0-0-0-1000

            #arch=win64

            [Control Panel\\\\Desktop] 1792166958
            #time=1dd5d88b2751e68
            "LogPixels"=dword:00000060

            [Software\\\\Digital Extremes\\\\Warframe\\\\Launcher] 1792167025
            #time=1dd5d88da7916d0
            "EnableAggressiveDownload"=dword:00000001
            "EnableBulkDownload"=dword:00000001
            "GraphicsAPI"=dword:00000000
            "Language"="en"
            "LauncherExe"="X:\\\\Tools\\\\Launcher.exe"

            """
        if let eula {
            text += """
                [Software\\\\Digital Extremes\\\\Warframe\\\\SteamLauncher] 1792169924
                #time=1dd5d8f9a93c270
                "LauncherAudio"=dword:00000001
                "ReadCba"=""
                "ReadEula"="\(eula)"
                "ServerCluster"=dword:00000000

                """
        }
        if steam {
            text += """
                [Software\\\\Valve\\\\Steam] 1792172903
                #time=1dd5d968a4ce606
                "SteamExe"="C:\\\\Program Files (x86)\\\\Steam\\\\steam.exe"
                "SteamPath"="C:\\\\Program Files (x86)\\\\Steam"

                [Software\\\\Valve\\\\Steam\\\\ActiveProcess] 1792172903
                #time=1dd5d968a4cd102
                "SteamClientDll64"="C:\\\\Program Files (x86)\\\\Steam\\\\steamclient64.dll"
                "SteamPath"="C:\\\\Program Files (x86)\\\\Steam"
                "Universe"="Public"

                """
        }
        if launcherOverrides {
            text += """
                [Software\\\\Wine\\\\AppDefaults\\\\Launcher.exe\\\\DllOverrides] 1792166971
                #time=1dd5d88ba3c6e62
                "dwrite"=""
                "libglesv2"=""
                "nvapi64"=""
                "nvngx"=""

                """
        }
        return text
    }

    /// The first steps of a launcher run, up to the EULA (Launcher.log, without the client-IP block).
    static let launcherStart = [
        "Current time: Fri Oct 16 20:38:54 2026 [UTC Fri Oct 16 16:38:54 2026]",
        "WINE detected.",
        "LoadCEFLib",
        "LoadCEFLib failed",
        "Using single cluster mode",
        "Finished ClientIP (0.6 seconds)",
        "OS Version: 10.0 (SP0, build 19045)",
        "Finished Platform (0.0 seconds)",
        "Finished PickDirectory (0.0 seconds)",
        "INetFwProfile2::get_CurrentProfileTypes failed: 0x80004001",
        "Finished Firewall (0.0 seconds)",
        "Finished GameRunning (0.0 seconds)",
        #"Hashing X:\Tools\CEF3_1\V7\libcef.dll..."#,
        "Finished BinariesBP_CEF (1.7 seconds)",
        #"Hashing X:\Tools\Launcher.exe..."#,
        #"Hashing X:\Lotus\Language\EULA_en.rtf..."#,
        "Finished BinariesBP_LAUNCHER (0.2 seconds)",
    ]

    static func eulaAccepted(seconds: Double) -> [String] {
        [
            "Finished EULA (\(seconds) seconds)",
            "Windows build 19045 should support the DirectX 12 Agility SDK.",
            "Checking IDXGIFactory2...",
            "Found D3D adapter 0: Apple M2 (D3D_FEATURE_LEVEL_11_1)",
            "Finished DirectX (0.3 seconds)",
            #"Queuing X:\Warframe.x64.exe [AF84E6612C009ECEF51ABC23814BA7E2]"#,
            "HTTP GET /Warframe.x64.exe.AF84E6612C009ECEF51ABC23814BA7E2.lzma",
        ]
    }

    static let bulkFinished = [
        "Downloaded 52,514,328,367 bytes total ~ 44,318,693 B/s",
        "Finished BinariesBP_BULK (1184.9 seconds)",
        "Finished Repair (0.0 seconds)",
        "ReqSpawnProcess - InitDialog",
        "",
        #""X:\Warframe.x64.exe" -silent -log:/Preprocess.log -graphicsDriver:dx11 -cluster:public -language:en -applet:/EE/Types/Framework/ContentUpdate"#,
        "0.167 Sys [Diag]: Process Command-line: -silent -log:/Preprocess.log -graphicsDriver:dx11 -cluster:public -language:en -applet:/EE/Types/Framework/ContentUpdate",
        "0.177 Sys [Diag]: Current time: Fri Oct 16 20:58:45 2026 [UTC: Fri Oct 16 16:58:45 2026]",
        "0.177 Sys [Diag]: Current directory: X:\\Tools",
        "9.785 Sys [Info]: Finished load of Flyweight batch (1) [0.00s and 0 frames at 3 ms/frame avg, 4 ms/update peak], 1/1/1, 5 item(s), 0k total so far, 0.00% utilization",
        "11.215 Sys [Info]: Downloaded 0/21544",
    ]

    static let appletLines = [
        "20.968 Sys [Info]: 73,617,644 bytes, 1,628 assets to download",
        "21.288 Sys [Info]: Downloaded 1520265/73617644",
        "23.436 Sys [Info]: Downloaded 66893152/73617644",
        "24.034 Sys [Info]: Done.",
        "24.041 Sys [Info]: Wasted cache space: 96,723,018 bytes (0%)",
    ]

    static let finished = [
        "24.168 Sys [Info]: Copied 120,934,425 bytes at 8.14 MB/s",
        "Sys [Info]: All smart pointers were destroyed!",
        "24.268 Sys [Info]: Main Shutdown Complete.",
        "Process returned 0",
        "Finished Preprocess (24.7 seconds)",
        "Finished Defrag1 (0.0 seconds)",
        "Total time: 1214.5 seconds",
    ]
}
