import Foundation
import GameKit
import Synchronization
import Testing
import WarzagCore
import WarzagTestSupport
import WineKit
@testable import warzagctl

// Small fakes for the game commands (GameKit's own suite has fuller ones).

final class GameLinkedFiles: GameFiles {
    let fileSystem: InMemoryFileSystem
    let links: [String: String]

    init(_ fileSystem: InMemoryFileSystem, links: [String: String]) {
        self.fileSystem = fileSystem
        self.links = links
    }

    func symbolicLinkDestination(of url: URL) -> URL? {
        links[url.plainPath].map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    func isSameDirectory(_ first: URL, _ second: URL) -> Bool {
        let a = links[first.plainPath] ?? first.plainPath
        let b = links[second.plainPath] ?? second.plainPath
        return a == b && fileSystem.directoryExists(at: URL(filePath: a))
    }

    func diskUsage(of directory: URL) -> Int64 { fileSystem.directoryExists(at: directory) ? 52_600_000_000 : 0 }

    func copyItem(at source: URL, to destination: URL) throws {
        try fileSystem.writeAtomically(try fileSystem.contents(of: source), to: destination)
    }
}

final class GameProbe: PrefixActivityProbing {
    let busy = Mutex<Int32?>(nil)
    func wineserver(for prefix: URL) -> Int32? { busy.withLock { $0 } }
}

final class GameStubProcess: RunningProcess {
    let processIdentifier: Int32 = 4100
    let running = Mutex(true)
    var isRunning: Bool { running.withLock { $0 } }
    func waitForExit() async -> Int32? { nil }
    func terminate() { running.withLock { $0 = false } }
}

/// DE's launcher that finishes at once: a fresh Launcher.log ending in "Total time:".
final class InstantLauncher: ProcessLaunching {
    let fileSystem: InMemoryFileSystem
    let log: String
    let probe: GameProbe
    let process = GameStubProcess()
    let launches = Mutex(0)

    init(fileSystem: InMemoryFileSystem, log: String, probe: GameProbe) {
        self.fileSystem = fileSystem
        self.log = log
        self.probe = probe
    }

    func launch(_ command: Command) throws -> any RunningProcess {
        launches.withLock { $0 += 1 }
        probe.busy.withLock { $0 = 9000 }
        fileSystem.addFile(log, [
            "Current time: Fri Oct 16 23:00:00 2026", "Finished BinariesBP_LAUNCHER (0.2 seconds)",
            "Finished EULA (0.0 seconds)", "Process returned 0", "Finished Preprocess (1.0 seconds)",
            "Total time: 2.0 seconds",
        ].map { $0 + "\r\n" }.joined())
        return process
    }
}

/// The game host "opened": a process that runs until it is told to stop; `onOpen` sees it.
final class GameStubOpener: ApplicationOpening {
    let process = GameStubProcess()
    let onOpen: @Sendable () -> Void

    init(onOpen: @escaping @Sendable () -> Void) {
        self.onOpen = onOpen
    }

    func openNewInstance(of application: URL, arguments: [String], environment: [String: String],
                         activates: Bool) async throws -> any RunningProcess {
        onOpen()
        return process
    }
}

struct PassingSignatures: HostSignatureChecking {
    func verify(_ host: GameHost) throws {}
}

/// DE's launcher that starts, runs and never finishes; `onLaunch` sees it start.
final class HangingLauncher: ProcessLaunching {
    let process = GameStubProcess()
    let probe: GameProbe
    let onLaunch: @Sendable () -> Void

    init(probe: GameProbe, onLaunch: @escaping @Sendable () -> Void) {
        self.probe = probe
        self.onLaunch = onLaunch
    }

    func launch(_ command: Command) throws -> any RunningProcess {
        probe.busy.withLock { $0 = 9000 }
        onLaunch()
        return process
    }
}

final class GameNoOpener: ApplicationOpening {
    func openNewInstance(of application: URL, arguments: [String], environment: [String: String],
                         activates: Bool) async throws -> any RunningProcess {
        Issue.record("nothing may be opened in this test")
        throw CocoaError(.featureUnsupported)
    }
}

final class CollectedOutput: Sendable {
    let text = Mutex("")
    let warnings = Mutex("")
    var output: GameCommands.Output {
        GameCommands.Output(write: { line in self.text.withLock { $0 += line } },
                            warn: { line in self.warnings.withLock { $0 += line } })
    }
}

@Suite struct GameCommandsTests {
    let fileSystem = InMemoryFileSystem()
    let probe = GameProbe()
    let interrupter = Interrupter()
    let home = "/Users/tenno"
    var system = FakeSystemInfo.mac(chip: "Apple M2", model: "Mac14,15", product: "MacBook Air (15-inch, M2, 2023)",
                                    performanceCores: 4, efficiencyCores: 4, gpuCores: 10, memoryGB: 24)

    var prefix: String { home + "/Library/Application Support/Warzag/Prefixes/warframe-arm64" }
    var library: String { home + "/Library/Application Support/Warzag/Library/Warframe.noindex" }
    var hostPath: String { home + "/src/warzag/build/n/Warzag.app" }
    var launcherLog: String { prefix + "/drive_c/users/tenno/AppData/Local/Warframe/Launcher.log" }

    var context: CommandContext {
        let homeURL = URL(filePath: home, directoryHint: .isDirectory)
        return CommandContext(
            paths: WarzagPaths(home: homeURL, userCacheDirectory: nil),
            steam: .init(home: homeURL, systemApplications: URL(filePath: "/Applications", directoryHint: .isDirectory)),
            fileSystem: fileSystem, processes: FakeProcessInspector(), system: system,
            inheritedEnvironment: ["HOME": home, "USER": "tenno", "DYLD_INSERT_LIBRARIES": "/x.dylib"],
            currentDirectory: URL(filePath: home + "/src/warzag", directoryHint: .isDirectory),
            timeZone: TimeZone(identifier: "UTC")!)
    }

    func dependencies(runner: RecordingProcessRunner = RecordingProcessRunner(),
                      launcher: (any ProcessLaunching)? = nil,
                      opener: (any ApplicationOpening)? = nil) -> GameCommands.Dependencies {
        let files = GameLinkedFiles(fileSystem, links: [prefix + "/dosdevices/x:": library])
        let game = GameContext(
            fileSystem: fileSystem, files: files, runner: runner,
            launcher: launcher ?? InstantLauncher(fileSystem: fileSystem, log: launcherLog, probe: probe),
            opener: opener ?? GameNoOpener(), probe: probe, hostSignatures: PassingSignatures(), clock: ManualClock(),
            inheritedEnvironment: context.inheritedEnvironment,
            logDirectory: URL(filePath: home + "/Library/Logs/Warzag", directoryHint: .isDirectory),
            stateDirectory: URL(filePath: home + "/Library/Application Support/Warzag/State", directoryHint: .isDirectory))
        return GameCommands.Dependencies(game: game, downloader: ResumableDownloader(), authenticode: NoAuthenticodeVerifier(),
                                         content: ContentConfiguration(), play: PlayConfiguration(),
                                         interrupter: interrupter)
    }

    /// A prefix and library as the engine and DE's launcher leave them, for the development build's host, unless `host`
    /// names another.
    func prepare(game: Bool = true, host: String? = nil) {
        let hostPath = host ?? self.hostPath
        for name in ["wine", "wineserver"] { fileSystem.addFile(hostPath + "/Contents/MacOS/" + name, "x") }
        fileSystem.addFile(hostPath + "/Contents/Info.plist", """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>WarzagRuntimeChannel</key><string>n</string></dict></plist>
            """)
        fileSystem.addDirectory(hostPath + "/Contents/renderers/dxmt/aarch64-windows")
        fileSystem.addFile(prefix + "/system.reg", "WINE REGISTRY Version 2\n")
        fileSystem.addFile(prefix + "/dosdevices/x:", "")
        fileSystem.addDirectory(prefix + "/drive_c/users/Public")
        fileSystem.addDirectory(prefix + "/drive_c/users/tenno/AppData/Local/Warframe")
        for path in ["system32/winemetal.dll", "system32/nvapi64.dll", "system32/nvngx.dll", "system32/lsteamclient.dll"] {
            fileSystem.addFile(prefix + "/drive_c/windows/" + path, "PE")
        }
        for name in ["steam.exe", "steamclient64.dll"] {
            fileSystem.addFile(prefix + "/drive_c/Program Files (x86)/Steam/" + name, "PE")
        }
        // As DE's launcher leaves it: its settings (DirectX 11, so Warzag has nothing to pin) and the EULA flag.
        fileSystem.addFile(prefix + "/user.reg", #"""
            WINE REGISTRY Version 2

            [Software\\Digital Extremes\\Warframe\\Launcher] 1792167025
            "GraphicsAPI"=dword:00000000

            [Software\\Digital Extremes\\Warframe\\SteamLauncher] 1792169924
            "ReadEula"="0123456789ABCDEF0123456789ABCDEF"

            [Software\\Valve\\Steam\\ActiveProcess] 1792172903
            "SteamClientDll64"="C:\\Program Files (x86)\\Steam\\steamclient64.dll"

            [Software\\Wine\\AppDefaults\\Launcher.exe\\DllOverrides] 1792166971
            "dwrite"=""
            "libglesv2"=""
            "nvapi64"=""
            "nvngx"=""

            """#)
        fileSystem.addFile(library + "/Tools/Launcher.exe", "PE")
        if game { fileSystem.addFile(library + "/Warframe.x64.exe", "PE") }
    }

    func play(_ line: String, _ dependencies: GameCommands.Dependencies? = nil) async -> (CommandResult, CollectedOutput) {
        let collected = CollectedOutput()
        let result = await GameCommands.runPlay(line.split(separator: " ").map(String.init), context,
                                                dependencies: dependencies ?? self.dependencies(),
                                                output: collected.output)
        return (result, collected)
    }

    func content(_ line: String, _ dependencies: GameCommands.Dependencies? = nil) async -> (CommandResult, CollectedOutput) {
        let collected = CollectedOutput()
        let result = await GameCommands.runContent(line.split(separator: " ").map(String.init), context,
                                                   dependencies: dependencies ?? self.dependencies(),
                                                   output: collected.output)
        return (result, collected)
    }

    /// With an engine installed, Play opens that engine through LaunchServices and runs Wine from it: a copy inside
    /// Runtimes.noindex, which Spotlight skips, so it never shows next to Warzag in Spotlight or the Apps view.
    @Test func dryRunOpensTheInstalledEngineInsideTheNoindexStore() async {
        let installed = context.paths.gameHost(.n, version: "0.3.0").plainPath
        prepare(host: installed)
        fileSystem.addFile(context.paths.activeRuntimePointer.plainPath, """
            {"schema":1,"current":{"id":"n-0.3.0","version":"0.3.0","channel":"n","signerFingerprint":"adhoc"},
             "revoked":[],"rolledBack":[]}
            """)
        let (result, _) = await play("--dry-run")
        #expect(result.exitCode == 0, "\(result.stderr)")
        #expect(installed == home + "/Library/Application Support/Warzag/Runtimes.noindex/n/0.3.0/Warzag.app")
        #expect(result.stdout.contains("open        \(installed) (LaunchServices, new instance)\n"))
        #expect(result.stdout.contains("executable  \(installed)/Contents/MacOS/wine\n"))
        let engineLines = result.stdout.split(separator: "\n").filter { $0.contains("Warzag.app") }
        #expect(engineLines.count >= 4)
        #expect(engineLines.allSatisfy { $0.contains(installed) }, "\(engineLines)")
    }

    @Test func dryRunPrintsTheExactLaunch() async {
        prepare()
        let (result, collected) = await play("--dry-run")
        #expect(result.exitCode == 0)
        #expect(result.stdout == """
            warzagctl play --dry-run: nothing was started
            open        \(hostPath) (LaunchServices, new instance)
            executable  \(hostPath)/Contents/MacOS/wine
            renderer    dxmt, frame cap 60 fps, NVEXT off
            sign-in     Steam (the Mac Steam client, through the bridge)
            update      first, \(hostPath)/Contents/MacOS/wine X:\\Tools\\Launcher.exe -cluster:public -registry:Steam from \(library)/Tools (no Steam variables)
            arguments:
              C:\\Program Files (x86)\\Steam\\steam.exe
              --cwd
              X:\\
              X:\\Warframe.x64.exe
              -windowMode:2
              -graphicsDriver:dx11
              -gpuPreference:2
              -cluster:public
              -language:en
              -clienttype:Steam
            environment:
            DXMT_CONFIG=d3d11.preferredMaxFrameRate=60;
            HOME=/Users/tenno
            NEUTRON_FAST_QPC=1
            NEUTRON_MSYNC=0
            NEUTRON_NATIVE_FULLSCREEN=0
            NEUTRON_PRECISE_TIMERS=1
            NEUTRON_RAW_MOUSE=1
            NEUTRON_RENDER_SCALE=1
            PATH=/usr/bin:/bin:/usr/sbin:/sbin
            STEAM_COMPAT_APP_ID=230410
            STEAM_COMPAT_CLIENT_INSTALL_PATH=/Users/tenno/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS
            SteamAppId=230410
            SteamDeck=0
            SteamGameId=230410
            SteamOverlayGameId=230410
            USER=tenno
            WINEDEBUG=-all
            WINEDLLOVERRIDES=steamclient64=n;lsteamclient=b
            WINEDLLPATH_PREPEND=\(hostPath)/Contents/renderers/dxmt
            WINEPREFIX=\(prefix)

            """)
        // Steam is not running in this imaginary Mac: a warning, not a failure, for a dry run.
        #expect(result.stderr == "warning: Steam is not running; start Steam and sign in (or use --no-steam for a Warframe account).\n")
        #expect(collected.text.withLock { $0 }.isEmpty)
    }

    /// NVEXT is an experiment (DLSS cannot start under Warzag): only `--nvext` turns it on.
    @Test func nvextOnlyWithTheOption() async {
        prepare()
        let (result, _) = await play("--dry-run --skip-update --nvext")
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains(
            "renderer    dxmt, frame cap 60 fps, NVEXT on (an NVIDIA identity only; DLSS is unavailable in Warframe)\n"))
        #expect(result.stdout.contains("\nDXMT_ENABLE_NVEXT=1\n"))
        let (plain, _) = await play("--dry-run --skip-update")
        #expect(!plain.stdout.contains("DXMT_ENABLE_NVEXT"))
    }

    /// EE.cfg says what the player last chose in Warframe; play reads it (never writes it) and passes the advice on.
    @Test func playSaysWhenMotionBlurIsOn() async {
        prepare()
        let eeConfig = prefix + "/drive_c/users/tenno/AppData/Local/Warframe/EE.cfg"
        func file(motionBlur: Int) -> String {
            ["+nowarning", "+version=5", "[KeyBindings,/EE/Types/Input/KeyBindings]", "+nowarning", "_Jump=,Space",
             "_Melee=,E", "[Windows_Config,/EE/Types/Base/Config]", "+nowarning", "Graphics.EnableMotionBlur=\(motionBlur)",
             "Graphics.UpscaleMethod=UM_FSR3", "Graphics.UpscaleQuality=UQ_BALANCED"].map { $0 + "\r\n" }.joined()
        }
        fileSystem.addFile(eeConfig, file(motionBlur: 1))
        let (on, _) = await play("--dry-run --skip-update")
        #expect(on.exitCode == 0)
        #expect(on.stderr.contains(
            "warning: Motion blur is on. Under Warzag it can smear; turn it off in Warframe: Options > Display.\n"))
        #expect(fileSystem.text(at: eeConfig) == file(motionBlur: 1))

        fileSystem.addFile(eeConfig, file(motionBlur: 0))
        let (off, _) = await play("--dry-run --skip-update")
        #expect(!off.stderr.contains("Motion blur"))
    }

    @Test func dryRunVariantsAndWarnings() async {
        var lowPower = self
        lowPower.system.isLowPowerModeEnabled = true
        let (result, _) = await lowPower.play("--dry-run --no-steam --hud --skip-update")
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("renderer    dxmt, frame cap 30 fps, NVEXT off\n"))
        #expect(result.stdout.contains("sign-in     Warframe account (no Steam variables)\n"))
        #expect(result.stdout.contains("update      skipped\n"))
        #expect(result.stdout.contains("MTL_HUD_ENABLED=1\nMTL_HUD_LOG_ENABLED=1\n"))
        #expect(result.stdout.contains("DXMT_CONFIG=d3d11.preferredMaxFrameRate=30;\n"))
        #expect(!result.stdout.contains("SteamAppId") && !result.stdout.contains("-clienttype:Steam"))
        // Nothing is prepared, so every problem is listed, and the host note is there.
        #expect(result.stderr.contains("warzagctl: no runtime installed; showing the environment for \(lowPower.hostPath)\n"))
        #expect(result.stderr.contains("warning: Low Power Mode is on"))
        #expect(result.stderr.contains("warning: no runtime host at \(lowPower.hostPath)\n"))
        #expect(!result.stderr.contains("Steam is not running"))
    }

    /// An 8 W adapter and a nearly empty battery: play says both, in English, before anything starts.
    @Test func playWarnsAboutAWeakChargerAndALowBattery() async {
        var weak = self
        weak.system.powerAdapterWatts = 8
        weak.system.batteryPercent = 7
        weak.prepare()
        let (result, _) = await weak.play("--dry-run --skip-update")
        #expect(result.exitCode == 0)
        #expect(result.stderr.contains("warning: The charger supplies only 8 W. Warframe needs about 20-30 W, so the "
            + "battery drains while you play and the Mac slows down when it gets low. Use the Mac's own charger (30 W or "
            + "more).\n"))
        #expect(result.stderr.contains("warning: The battery is at 7%."))

        var plugged = self
        plugged.system.powerAdapterWatts = 70
        plugged.system.batteryPercent = 64
        plugged.prepare()
        let (fine, _) = await plugged.play("--dry-run --skip-update")
        #expect(!fine.stderr.contains("charger") && !fine.stderr.contains("battery"))
    }

    @Test func relativeLocationsAreTakenFromTheWorkingDirectory() async {
        let (result, _) = await play("--dry-run --prefix ../prefixes/m2 --library lib --host build/n/Warzag.app")
        #expect(result.stdout.contains("\nWINEPREFIX=/Users/tenno/src/prefixes/m2\n"))
        #expect(result.stdout.contains("\nWINEDLLPATH_PREPEND=/Users/tenno/src/warzag/build/n/Warzag.app/Contents/renderers/dxmt\n"))
        #expect(result.stdout.contains(" from /Users/tenno/src/warzag/lib/Tools (no Steam variables)\n"))
    }

    @Test(arguments: [
        ("--json", "unknown option for play: --json"),
        ("--renderer dxmt", "unknown option for play: --renderer"),
        ("--prefix", "--prefix needs a value"),
        ("now", "unexpected argument for play: now"),
    ])
    func playUsageErrors(_ line: String, _ message: String) async {
        let (result, _) = await play(line)
        #expect(result.exitCode == 64)
        #expect(result.stderr.hasPrefix("warzagctl: \(message)\n"))
    }

    @Test(arguments: [
        ("", "content needs status, install or update"),
        ("frobnicate", "unknown content command: frobnicate"),
        ("status --msi /x.msi", "unknown option for content status: --msi"),
        ("update --json", "unknown option for content update: --json"),
    ])
    func contentUsageErrors(_ line: String, _ message: String) async {
        let (result, _) = await content(line)
        #expect(result.exitCode == 64)
        #expect(result.stderr.hasPrefix("warzagctl: \(message)\n"))
    }

    @Test func statusAsTextAndJSON() async throws {
        prepare()
        let (text, _) = await content("status")
        #expect(text.exitCode == 0)
        #expect(text.stdout == """
            state     needs update (no finished update is recorded)
            library   \(library) (53 GB on disk)
            game      Warframe.x64.exe
            launcher  Tools\\Launcher.exe present
            prefix    \(prefix)

            """)
        let (json, _) = await content("status --json")
        let decoded = try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any]
        #expect(decoded?["state"] as? String == "needsUpdate")
        #expect(decoded?["gamePresent"] as? Bool == true)
    }

    @Test func updateRunsDEsLauncherAndPrintsProgress() async {
        prepare()
        let launcher = InstantLauncher(fileSystem: fileSystem, log: launcherLog, probe: probe)
        let runner = RecordingProcessRunner { [probe] command in
            if command.arguments.first == "taskkill" { launcher.process.terminate() }
            if command.arguments == ["-k"] { probe.busy.withLock { $0 = nil } }
            return ProcessOutput(exitCode: 0)
        }
        let (result, collected) = await content("update", dependencies(runner: runner, launcher: launcher))
        #expect(result == CommandResult(stdout: "Warframe is up to date.\n"))
        #expect(collected.text.withLock { $0 } == """
            starting DE's launcher
            closing DE's launcher
            DE's launcher finished (its total: 2.0 s)

            """)
        #expect(runner.commandLines == ["wine taskkill /IM Launcher.exe", "wineserver -k"])
        // The next status knows about it.
        let (status, _) = await content("status")
        #expect(status.stdout.hasPrefix("state        installed (the last update finished less than an hour ago)\n"))
    }

    @Test func aPrefixThatIsNotReadySaysWhatIsMissing() async {
        prepare(game: false)
        fileSystem.addFile(prefix + "/user.reg", "WINE REGISTRY Version 2\n")
        let (update, _) = await content("update")
        #expect(update.exitCode == 1)
        #expect(update.stderr == "warzagctl: Warframe is not installed yet\n")
        fileSystem.addFile(library + "/Warframe.x64.exe", "PE")
        let (again, _) = await content("update")
        #expect(again.exitCode == 1)
        #expect(again.stderr.hasPrefix("warzagctl: not ready:\n  - DE's launcher would load dwrite, libglesv2, nvapi64, nvngx"))
        #expect(again.stderr.hasSuffix("The Wine prefix needs to be set up again: run warzagctl prefix repair, or "
            + "Repair Windows Setup in Warzag's Troubleshoot window.\n"))
    }

    @Test func playWithoutSteamRunningStopsBeforeAnything() async {
        prepare()
        let (result, collected) = await play("--skip-update")
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("Steam is not running"))
        #expect(collected.warnings.withLock { $0 }.contains("warning: Steam is not running"))
    }

    /// Warframe handing over to DE's launcher while it closes is said once; the session goes on.
    @Test func aHandOverToDEsLauncherIsSaidOnce() {
        let collected = CollectedOutput()
        let printer = ProgressPrinter(output: collected.output, clock: ManualClock())
        printer.show(PlayEvent.signal(.closing))
        printer.show(PlayEvent.handedOverToLauncher)
        #expect(collected.text.withLock { $0 } == """
            Warframe is closing
            Warframe handed over to DE's launcher while closing (an update or a restart); leaving it running

            """)
    }

    @Test func anUpdateShowsItsOwnSize() {
        let collected = CollectedOutput()
        let printer = ProgressPrinter(output: collected.output, clock: ManualClock())
        printer.show(.downloading(bytesThisRun: 1_200_000_000, bytesOnDisk: 53_000_000_000, expectedBytes: nil,
                                  megabytesPerSecond: 40))
        printer.show(ContentRunState.warning("taskkill /IM Launcher.exe did not finish within 60 s and was stopped"))
        #expect(collected.text.withLock { $0 } == """
            downloading the update: 1.2 GB so far, 40 MB/s
            warning: taskkill /IM Launcher.exe did not finish within 60 s and was stopped

            """)
    }

    @Test func ctrlCDuringAnUpdateClosesDEsLauncher() async {
        prepare()
        // DE's launcher starts and never finishes; Ctrl-C arrives once it runs.
        let interrupter = interrupter
        let launcher = HangingLauncher(probe: probe) { interrupter.trigger(SIGINT) }
        let runner = RecordingProcessRunner { [probe] command in
            if command.arguments.first == "taskkill" { launcher.process.terminate() }
            if command.arguments == ["-k"] { probe.busy.withLock { $0 = nil } }
            return ProcessOutput(exitCode: 0)
        }
        let (result, _) = await content("update", dependencies(runner: runner, launcher: launcher))
        #expect(result.exitCode == 130)
        #expect(result.stderr == "warzagctl: SIGINT: stopped; DE's launcher was closed and the prefix stopped\n")
        #expect(runner.commandLines == ["wine taskkill /IM Launcher.exe", "wineserver -k"])
        #expect(!launcher.process.isRunning)
    }

    /// `content install --msi` dependencies for a library that has no launcher yet, so Warframe.msi is unpacked.
    func installDependencies(runner: RecordingProcessRunner) -> GameCommands.Dependencies {
        prepare(game: false)
        try? fileSystem.removeItem(at: URL(filePath: library + "/Tools/Launcher.exe"))
        fileSystem.addFile(home + "/Downloads/Warframe.msi",
                           Data(InstallerExpectations.compoundFileSignature) + Data("a package".utf8))
        var dependencies = dependencies(runner: runner)
        dependencies.content = ContentConfiguration(installer: InstallerExpectations(minimumBytes: 0))
        return dependencies
    }

    @Test func ctrlCWhileWarframeMsiIsUnpackedStopsMsiexecAndSaysSo() async {
        // The real process runner stops msiexec when the run is cancelled and throws CancellationError (and starts
        // nothing for a cancelled task); what msiexec started would go on without the prefix's stop.
        let interrupter = interrupter
        let runner = RecordingProcessRunner { command in
            if Task.isCancelled { throw CancellationError() }
            guard command.arguments.first == "msiexec" else { return ProcessOutput(exitCode: 0) }
            interrupter.trigger(SIGINT)
            throw CancellationError()
        }
        let (result, _) = await content("install --msi \(home)/Downloads/Warframe.msi", installDependencies(runner: runner))
        #expect(result.exitCode == 130)
        #expect(result.stderr == "warzagctl: SIGINT: stopped; msiexec was stopped and the prefix with it\n")
        #expect(runner.commandLines == [#"wine msiexec /a C:\windows\temp\warzag-Warframe.msi /qn TARGETDIR=X:\"#,
                                        "wineserver -k"])
    }

    @Test func ctrlCBeforeAnythingRanInThePrefixSaysSo() async {
        let runner = RecordingProcessRunner()
        let dependencies = installDependencies(runner: runner)
        interrupter.trigger(SIGTERM)
        let (result, _) = await content("install --msi \(home)/Downloads/Warframe.msi", dependencies)
        #expect(result.exitCode == 143)
        #expect(result.stderr == "warzagctl: SIGTERM: stopped; nothing had been started in the prefix yet\n")
        #expect(runner.commands.isEmpty)
    }

    @Test func ctrlCDuringPlayClosesTheGameAndWine() async {
        prepare()
        let interrupter = interrupter
        let opener = GameStubOpener { interrupter.trigger(SIGTERM) }
        let runner = RecordingProcessRunner()
        let (result, collected) = await play("--no-steam --skip-update", dependencies(runner: runner, opener: opener))
        #expect(result.exitCode == 143)
        #expect(result.stderr == "warzagctl: SIGTERM: stopped; Warframe was closed and the prefix stopped\n")
        #expect(runner.commandLines == ["wine taskkill /IM Warframe.x64.exe", "wine taskkill /IM Launcher.exe"])
        #expect(collected.text.withLock { $0 }.contains("stopping Warframe and Wine (SIGTERM)"))
        // A second signal does not run anything again.
        interrupter.trigger(SIGINT)
        #expect(interrupter.received == SIGTERM)
    }

    /// A game that hangs while closing: play says so when Warzag ends it (30 s after EE.log said Warframe was closing,
    /// once Wine lists Warframe without DE's launcher), then finishes as after any exit.
    @Test func playSaysWhenAGameThatHungWhileClosingWasEnded() async {
        prepare()
        let eeLog = prefix + "/drive_c/users/tenno/AppData/Local/Warframe/EE.log"
        let processList = prefix + "/drive_c/windows/temp/warzag-tasklist.txt"
        let fileSystem = fileSystem
        let opener = GameStubOpener {
            fileSystem.addFile(eeLog, """
                1835.402 Sys [Info]: Executing command: /EE/Editor/ToolMenus/Commands/CmdQuit\r
                1836.118 Gfx [Info]: Destroying Graphics Worker Thread\r

                """)
        }
        let runner = RecordingProcessRunner { command in
            if command.arguments.starts(with: ["cmd", "/c", "tasklist"]) {
                fileSystem.addFile(processList, """
                    "services.exe","52","Console","1","0 K"\r
                    "steam.exe","96","Console","1","0 K"\r
                    "Warframe.x64.exe","104","Console","1","0 K"\r
                    "tasklist.exe","212","Console","1","0 K"\r

                    """)
            }
            if command.arguments == ["-k"] { opener.process.terminate() }
            return ProcessOutput(exitCode: 0)
        }
        let (result, collected) = await play("--no-steam --skip-update", dependencies(runner: runner, opener: opener))
        #expect(result.exitCode == 0)
        #expect(result.stdout == "Warframe exited after 1 min.\n")
        #expect(runner.commandLines
            == [#"wine cmd /c tasklist /nh /fo csv > C:\windows\temp\warzag-tasklist.txt"#, "wineserver -k"])
        #expect(collected.text.withLock { $0 }.hasSuffix("""
            Warframe is closing
            Warframe stopped responding while closing (still running 30 s later); ending it (wineserver -k)
            Warframe exited after 31 s
            Wine shut down cleanly

            """))
    }

    @Test func theGroupsAreRegistered() {
        #expect(ExtensionCommands.usage.contains("content status [--json]"))
        #expect(ExtensionCommands.usage.contains("play [--dry-run] [--no-steam] [--hud] [--skip-update]"))
    }

    @Test func progressLinesAreThrottled() {
        let collected = CollectedOutput()
        let clock = ManualClock()
        let printer = ProgressPrinter(output: collected.output, clock: clock)
        let downloading = ContentRunState.downloading(bytesThisRun: 12_300_000_000, bytesOnDisk: 12_300_000_000,
                                                      expectedBytes: 55_700_000_000, megabytesPerSecond: 46)
        printer.show(.needsEULA)
        printer.show(.needsEULA)
        printer.show(downloading)
        printer.show(downloading)
        clock.advance(by: 31)
        printer.show(downloading)
        printer.show(.preprocessing(fraction: 0.05))
        printer.show(.preprocessing(fraction: 0.10))
        printer.show(.preprocessing(fraction: 0.16))
        printer.show(.installerChecked(sha256: "9f94", authenticode: .unavailable("no verifier")))
        #expect(collected.text.withLock { $0 } == """
            DE's launcher is showing its EULA: read it and click I AGREE in DE's window (Warzag never accepts it for you)
            downloading: 12.3 GB of about 55.7 GB (22%), 46 MB/s
            downloading: 12.3 GB of about 55.7 GB (22%), 46 MB/s
            preparing game files (DE's ContentUpdate): 5%
            preparing game files (DE's ContentUpdate): 16%
            Warframe.msi SHA-256 9f94; Authenticode signature NOT checked (no verifier)

            """)
    }
}
