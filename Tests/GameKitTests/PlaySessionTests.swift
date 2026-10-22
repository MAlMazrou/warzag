import ContentKit
import Foundation
import ProfileKit
import Testing
import WarzagCore
import WarzagTestSupport
import WineKit
@testable import GameKit

let macBookAirM2 = HardwareProfile(chip: "Apple M2", modelIdentifier: "Mac14,15",
                                   productName: "MacBook Air (15-inch, M2, 2023)", performanceCores: 4,
                                   efficiencyCores: 4, gpuCores: 10, memoryGB: 24)
let macBookProM3Pro = HardwareProfile(chip: "Apple M3 Pro", modelIdentifier: "Mac15,6", performanceCores: 6,
                                      efficiencyCores: 6, gpuCores: 18, memoryGB: 18)
let steamClient = URL(filePath: "/Users/tenno/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS",
                      directoryHint: .isDirectory)

@Suite struct GameLaunchBuilderTests {
    let fixture = GameFixture()

    func launch(_ options: PlayOptions = PlayOptions(), hardware: HardwareProfile = macBookAirM2) -> GameLaunch {
        GameLaunchBuilder.launch(installation: fixture.installation, options: options, hardware: hardware,
                                 steamClientDirectory: steamClient, inherited: fixture.inherited)
    }

    @Test func aSteamSessionOnAFanlessM2() {
        let launch = launch()
        #expect(launch.application == fixture.host.bundle)
        #expect(launch.executable.plainPath == fixture.host.bundle.plainPath + "/Contents/MacOS/wine")
        #expect(launch.arguments == [
            #"C:\Program Files (x86)\Steam\steam.exe"#, "--cwd", #"X:\"#, #"X:\Warframe.x64.exe"#,
            "-windowMode:2", "-graphicsDriver:dx11", "-gpuPreference:2", "-cluster:public", "-language:en",
            "-clienttype:Steam",
        ])
        #expect(launch.environment == [
            "HOME": "/Users/tenno", "USER": "tenno", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "WINEPREFIX": fixture.prefixPath, "WINEDEBUG": "-all", "SteamDeck": "0",
            "NEUTRON_PRECISE_TIMERS": "1", "NEUTRON_FAST_QPC": "1", "NEUTRON_RAW_MOUSE": "1",
            "NEUTRON_NATIVE_FULLSCREEN": "0", "NEUTRON_RENDER_SCALE": "1", "NEUTRON_MSYNC": "0",
            "WINEDLLPATH_PREPEND": fixture.host.contents.plainPath + "/renderers/dxmt",
            "DXMT_CONFIG": "d3d11.preferredMaxFrameRate=60;",
            "SteamAppId": "230410", "SteamGameId": "230410", "SteamOverlayGameId": "230410",
            "STEAM_COMPAT_APP_ID": "230410", "STEAM_COMPAT_CLIENT_INSTALL_PATH": steamClient.plainPath,
            "WINEDLLOVERRIDES": "steamclient64=n;lsteamclient=b",
        ])
        #expect(launch.renderer == RendererOptions(renderer: .dxmt, frameRateCap: 60, enableNVEXT: false))
    }

    @Test func lowPowerModeOrBatteryHoldsAFanlessMacTo30() {
        var lowPower = macBookAirM2
        lowPower.lowPowerMode = true
        #expect(launch(hardware: lowPower).environment["DXMT_CONFIG"] == "d3d11.preferredMaxFrameRate=30;")
        var battery = macBookAirM2
        battery.powerSource = .battery
        #expect(launch(hardware: battery).environment["DXMT_CONFIG"] == "d3d11.preferredMaxFrameRate=30;")
        var hot = macBookProM3Pro
        hot.thermalState = .critical
        #expect(launch(hardware: hot).environment["DXMT_CONFIG"] == "d3d11.preferredMaxFrameRate=30;")
    }

    /// DLSS can never start under Warzag: NVEXT is off on every tier, on only when asked.
    @Test func nvextOnlyWhenAskedFor() {
        #expect(!PresetCatalog.nvextDefault)
        #expect(!PlayOptions().nvext)
        for hardware in [macBookAirM2, macBookProM3Pro] {
            #expect(launch(hardware: hardware).environment["DXMT_ENABLE_NVEXT"] == nil)
            #expect(!launch(hardware: hardware).renderer.enableNVEXT)
            let asked = launch(PlayOptions(nvext: true), hardware: hardware)
            #expect(asked.environment["DXMT_ENABLE_NVEXT"] == "1" && asked.renderer.enableNVEXT)
        }
        #expect(launch(hardware: macBookProM3Pro).environment["DXMT_CONFIG"] == "d3d11.preferredMaxFrameRate=120;")
    }

    @Test func aWarframeAccountSessionHasNoSteamAnything() {
        let launch = launch(PlayOptions(steam: false, language: "fr"))
        #expect(launch.arguments.last == "-language:fr")
        #expect(!launch.arguments.contains("-clienttype:Steam"))
        #expect(launch.arguments.first == #"C:\Program Files (x86)\Steam\steam.exe"#)
        #expect(launch.environment.keys.filter { $0.lowercased().contains("steam") && $0 != "SteamDeck" }.isEmpty)
        #expect(launch.environment["WINEDLLOVERRIDES"] == nil)
        #expect(!launch.steam)
    }

    @Test func theHUDIsOnlyThereWhenAskedFor() {
        #expect(launch().environment["MTL_HUD_ENABLED"] == nil)
        let hud = launch(PlayOptions(hud: true)).environment
        #expect(hud["MTL_HUD_ENABLED"] == "1" && hud["MTL_HUD_LOG_ENABLED"] == "1")
    }

    @Test func neverTheVariablesSteamSetsForItsOwnLaunches() {
        let environment = launch(PlayOptions(hud: true)).environment
        #expect(environment["SteamClientLaunch"] == nil && environment["SteamAppUser"] == nil)
        #expect(environment["DYLD_INSERT_LIBRARIES"] == nil && environment["WINEDLLPATH"] == nil)
    }
}

@Suite struct PlaySessionTests {
    func session(_ fixture: GameFixture, runner: RecordingProcessRunner = RecordingProcessRunner(),
                 launcher: FakeLauncher = FakeLauncher(), opener: FakeOpener) -> PlaySession {
        let context = fixture.context(runner: runner, launcher: launcher, opener: opener)
        return PlaySession(content: ContentService(installation: fixture.installation, context: context))
    }

    func readyFixture() -> GameFixture {
        let fixture = GameFixture()
        fixture.addHost()
        fixture.addPrefix(eula: Fixtures.eulaHash)
        fixture.addGame()
        return fixture
    }

    func launch(_ fixture: GameFixture) -> GameLaunch {
        GameLaunchBuilder.launch(installation: fixture.installation, options: PlayOptions(), hardware: macBookAirM2,
                                 steamClientDirectory: steamClient, inherited: fixture.inherited)
    }

    static let session = [
        "0.124 Sys [Diag]: Process Command-line: -windowMode:2 -graphicsDriver:dx11 -gpuPreference:2 -cluster:public -language:en -clienttype:Steam",
        "3.210 Sys [Info]: Steam active. IsBicPic=0 IsSteamDeck=0",
        "9.876 Script [Info]: ThemedMainMenu.lua: SteamLogin",
        "9.900 Sys [Info]: Logging in as FakeTenno",
        "11.42 Sys [Info]: Logged in FakeTenno (1a2b3c)",
        "11.50 Sys [Info]: EntitlementsSteam::CheckEntitlements()",
    ]

    @Test func aSessionIsFollowedFromEELogsEndAndCleanedUp() async throws {
        let fixture = readyFixture()
        // The previous session's EE.log is still there and must not be replayed.
        fixture.fileSystem.addFile(fixture.eeLog, "3.2 Sys [Info]: Steam active.\n11.4 Sys [Info]: Logged in OldTenno (9z)\n")
        let clock = fixture.clock
        let opener = FakeOpener { process in
            fixture.probe.setBusy(5150)
            clock.after(5) { fixture.fileSystem.addFile(fixture.eeLog, Self.session.map { $0 + "\r\n" }.joined()) }
            clock.after(600) { process.exit(nil) }
            clock.after(603) { fixture.probe.setBusy(nil) }
        }
        let runner = RecordingProcessRunner()
        let events = Recorder<PlayEvent>()
        let launch = launch(fixture)
        let result = try await session(fixture, runner: runner, opener: opener).run(launch, update: false) {
            events.append($0)
        }
        #expect(result.signals == [.steamActive, .steamLogin, .loggedIn])
        #expect(result.seconds == 600)
        #expect(!result.forcedCleanup)
        #expect(runner.commands.isEmpty)
        #expect(opener.opened == [FakeOpener.Opened(application: fixture.host.bundle, arguments: launch.arguments,
                                                    environment: launch.environment, activates: true)])
        #expect(events.all == [
            .opening, .started(processIdentifier: 7000), .signal(.steamActive), .signal(.steamLogin),
            .signal(.loggedIn), .exited(seconds: 600), .cleanedUp(forced: false),
        ])
        let described = String(describing: events.all) + String(describing: result)
        #expect(!described.contains("FakeTenno") && !described.contains("OldTenno"))
    }

    @Test func whatWineLeavesBehindIsStopped() async throws {
        let fixture = readyFixture()
        let clock = fixture.clock
        let opener = FakeOpener { process in
            fixture.probe.setBusy(5150)
            clock.after(60) { process.exit(nil) }
        }
        let runner = RecordingProcessRunner { command in
            if command.arguments == ["-k"] { fixture.probe.setBusy(nil) }
            return ProcessOutput(exitCode: 0)
        }
        let events = Recorder<PlayEvent>()
        let result = try await session(fixture, runner: runner, opener: opener).run(launch(fixture), update: false) {
            events.append($0)
        }
        #expect(result.forcedCleanup)
        #expect(runner.commandLines == ["wineserver -k"])
        #expect(runner.commands.first?.environment?["WINEPREFIX"] == fixture.prefixPath)
        #expect(events.all.last == .cleanedUp(forced: true))
        // The grace period passed first.
        #expect(clock.elapsed >= 70)
    }

    @Test func problemsInEELogAreSignals() async throws {
        let fixture = readyFixture()
        let clock = fixture.clock
        let opener = FakeOpener { process in
            clock.after(2) {
                fixture.fileSystem.addFile(fixture.eeLog, "2.1 Sys [Error]: Steam does not appear to be running.\n"
                    + "2.2 Sys [Error]: Failed to create metal view, it seems like your Wine has no exported symbols needed by DXMT.\n")
            }
            clock.after(3) { process.exit(nil) }
        }
        let result = try await session(fixture, opener: opener).run(launch(fixture), update: false) { _ in }
        #expect(result.signals == [.steamNotRunning, .metalViewFailed])
        #expect(result.signals.allSatisfy { $0.isError })
        #expect(GameSignal.allCases.filter { !$0.isError } == [.steamActive, .steamLogin, .loggedIn, .closing])
    }

    /// EE.log as Warframe quits from its menu (timestamps invented): `closing` at the quit command and again at the
    /// last step of the shutdown, "Shutting down context..." in between.
    static let quit = [
        "3600.10 Sys [Info]: Executing command: /EE/Editor/ToolMenus/Commands/CmdQuit",
        "3600.30 Sys [Info]: Shutting down context...",
        "3600.62 Sys [Info]: Context shutdown complete",
        "3600.63 Script [Info]: ThemedMainMenu.lua: *** Main menu -- shutdown ***",
        "3600.70 Sys [Info]: FlashMgrImpl::Shutdown",
        "3600.71 Sys [Info]: InputMgrWin::Shutdown",
        "3600.72 Sys [Info]: DisableTextureStreaming 1",
        "3600.80 Gfx [Info]: Destroying Graphics Worker Thread",
    ]

    static func text(_ lines: [String]) -> String { lines.map { $0 + "\r\n" }.joined() }

    static func isHungAtExit(_ event: PlayEvent) -> Bool {
        if case .hungAtExit = event { true } else { false }
    }

    /// The end of Warframe's renderer without a quit command (an update restart, say).
    static let rendererEnd = "600.80 Gfx [Info]: Destroying Graphics Worker Thread"

    /// What runs in a prefix during a session, as Wine's `tasklist /nh /fo csv` prints it, with `images` between Wine's
    /// own programs and the tool itself.
    static func tasklist(_ images: [String]) -> String {
        (["services.exe", "explorer.exe", "winedevice.exe", "plugplay.exe"] + images + ["cmd.exe", "tasklist.exe"])
            .enumerated().map { "\"\($1)\",\"\(52 + 4 * $0)\",\"Console\",\"1\",\"0 K\"\r\n" }.joined()
    }

    static let tasklistLine = #"wine cmd /c tasklist /nh /fo csv > C:\windows\temp\warzag-tasklist.txt"#
    static let game = ["steam.exe", "Warframe.x64.exe"]
    static let launcher = ["steam.exe", "Launcher.exe"]

    static func isTasklist(_ command: Command) -> Bool { command.arguments.starts(with: ["cmd", "/c", "tasklist"]) }

    /// The prefix's Wine tools during a session: tasklist answers with `images()` (written where cmd's redirection
    /// puts it), wineserver -k calls `kill`, or passes its deadline with `killTimesOut`. `runs` gets "tasklist <s>" or
    /// "kill <s>" for each, at the clock's time.
    static func prefixTools(_ fixture: GameFixture, runs: Recorder<String>, images: @escaping @Sendable () -> [String],
                            kill: @escaping @Sendable () -> Void = {},
                            killTimesOut: Bool = false) -> RecordingProcessRunner {
        let clock = fixture.clock
        return RecordingProcessRunner { command in
            if isTasklist(command) {
                runs.append("tasklist \(Int(clock.elapsed))")
                fixture.fileSystem.addFile(fixture.prefixPath + "/drive_c/windows/temp/warzag-tasklist.txt",
                                           tasklist(images()))
            } else if command.arguments == ["-k"] {
                runs.append("kill \(Int(clock.elapsed))")
                if killTimesOut { throw ProcessTimedOut(command: command.description, timeout: command.timeout ?? .zero) }
                kill()
            }
            return ProcessOutput(exitCode: 0)
        }
    }

    /// wineserver -k as it is: every process of the prefix ends, the game host Play opened included.
    static func killer(_ fixture: GameFixture, _ game: Recorder<FakeProcess>) -> @Sendable () -> Void {
        {
            game.all.forEach { $0.exit(nil) }
            fixture.probe.setBusy(nil)
        }
    }

    /// EE.log says Warframe is closing, then one of its threads hangs in pthread_exit and the game never exits. 30 s
    /// after the closing signal, not before, Warzag asks Wine what runs, finds Warframe without DE's launcher and ends
    /// the prefix; the session ends as any other.
    @Test func aGameThatHangsWhileClosingIsEndedAfterTheGracePeriod() async throws {
        #expect(PlayConfiguration().closingGracePeriod == 30)
        let fixture = readyFixture()
        let clock = fixture.clock
        let game = Recorder<FakeProcess>()
        let opener = FakeOpener { process in
            game.append(process)
            fixture.probe.setBusy(5150)
            clock.after(5) { fixture.fileSystem.addFile(fixture.eeLog, Self.text(Self.session)) }
            // The quit; the game never exits by itself.
            clock.after(3600) { fixture.fileSystem.append(fixture.eeLog, Self.text(Self.quit)) }
        }
        let runs = Recorder<String>()
        let runner = Self.prefixTools(fixture, runs: runs, images: { Self.game }, kill: Self.killer(fixture, game))
        let events = Recorder<PlayEvent>()
        let result = try await session(fixture, runner: runner, opener: opener).run(launch(fixture), update: false) {
            events.append($0)
        }
        // The closing signal was read at 3600 s; the poll at 3629 s still waited, the one at 3630 s ended the game.
        #expect(runs.all == ["tasklist 3630", "kill 3630"])
        #expect(runner.commandLines == [Self.tasklistLine, "wineserver -k"])
        #expect(runner.commands.allSatisfy { $0.environment?["WINEPREFIX"] == fixture.prefixPath })
        let tasklist = try #require(runner.commands.first)
        #expect(tasklist.executable == fixture.host.wine && tasklist.timeout == .seconds(120))
        #expect(!fixture.fileSystem.fileExists(at: URL(filePath: fixture.prefixPath + "/drive_c/windows/temp/warzag-tasklist.txt")))
        #expect(result == PlayResult(signals: [.steamActive, .steamLogin, .loggedIn, .closing], seconds: 3630,
                                     forcedCleanup: false, hungAtExit: true))
        #expect(events.all == [
            .opening, .started(processIdentifier: 7000), .signal(.steamActive), .signal(.steamLogin),
            .signal(.loggedIn), .signal(.closing), .hungAtExit(seconds: 30), .exited(seconds: 3630),
            .cleanedUp(forced: false),
        ])
    }

    @Test func theGracePeriodIsTheConfigurationsOwn() async throws {
        let fixture = readyFixture()
        let clock = fixture.clock
        let game = Recorder<FakeProcess>()
        let opener = FakeOpener { process in
            game.append(process)
            clock.after(5) { fixture.fileSystem.addFile(fixture.eeLog, Self.text(Self.quit)) }
        }
        let runs = Recorder<String>()
        let runner = Self.prefixTools(fixture, runs: runs, images: { Self.game }, kill: Self.killer(fixture, game))
        let context = fixture.context(runner: runner, opener: opener)
        let session = PlaySession(content: ContentService(installation: fixture.installation, context: context),
                                  configuration: PlayConfiguration(closingGracePeriod: 90))
        let result = try await session.run(launch(fixture), update: false) { _ in }
        #expect(runs.all == ["tasklist 95", "kill 95"])
        #expect(result.hungAtExit)
    }

    @Test func aGameThatClosesWithinTheGracePeriodIsLeftAlone() async throws {
        let fixture = readyFixture()
        let clock = fixture.clock
        let opener = FakeOpener { process in
            fixture.probe.setBusy(5150)
            clock.after(5) { fixture.fileSystem.addFile(fixture.eeLog, Self.text(Self.session)) }
            clock.after(600) { fixture.fileSystem.append(fixture.eeLog, Self.text(Self.quit)) }
            // Half a second before the grace period ends (the poll at 629 s still sees the game; the next one is at
            // 630 s).
            clock.after(629.5) { process.exit(nil) }
            clock.after(631) { fixture.probe.setBusy(nil) }
        }
        let runner = RecordingProcessRunner()
        let events = Recorder<PlayEvent>()
        let result = try await session(fixture, runner: runner, opener: opener).run(launch(fixture), update: false) {
            events.append($0)
        }
        #expect(runner.commands.isEmpty)
        #expect(result == PlayResult(signals: [.steamActive, .steamLogin, .loggedIn, .closing], seconds: 630,
                                     forcedCleanup: false, hungAtExit: false))
        #expect(!events.all.contains(where: Self.isHungAtExit))
        #expect(events.all.suffix(3) == [.signal(.closing), .exited(seconds: 630), .cleanedUp(forced: false)])
    }

    /// Every EE.log line after the closing signal is a sign of life. A stray closing line in a game that is still being
    /// played (it keeps logging) never gets it ended, and neither does a slow shutdown that is still logging; Wine is
    /// not even asked.
    @Test func aClosingThatKeepsLoggingIsNeverEnded() async throws {
        let fixture = readyFixture()
        let clock = fixture.clock
        let opener = FakeOpener { process in
            fixture.probe.setBusy(5150)
            clock.after(5) { fixture.fileSystem.addFile(fixture.eeLog, Self.text(Self.session)) }
            clock.after(600) { fixture.fileSystem.append(fixture.eeLog, Self.text([Self.rendererEnd])) }
            // A line every 25 s for an hour, each within the grace period of the one before.
            for second in stride(from: 625.0, through: 4200, by: 25) {
                clock.after(second) { fixture.fileSystem.append(fixture.eeLog, "\(Int(second)).00 Sys [Info]: still here\r\n") }
            }
            clock.after(4210) { process.exit(nil) }
            clock.after(4211) { fixture.probe.setBusy(nil) }
        }
        let runner = RecordingProcessRunner()
        let events = Recorder<PlayEvent>()
        let result = try await session(fixture, runner: runner, opener: opener).run(launch(fixture), update: false) {
            events.append($0)
        }
        #expect(runner.commands.isEmpty)
        #expect(!result.hungAtExit)
        #expect(!events.all.contains(where: Self.isHungAtExit))
    }

    /// The grace period counts from Warframe's last EE.log line, not from the closing signal: a shutdown that logged
    /// until 620 s and then hung is ended at 650 s.
    @Test func theGracePeriodCountsFromWarframesLastLine() async throws {
        let fixture = readyFixture()
        let clock = fixture.clock
        let game = Recorder<FakeProcess>()
        let opener = FakeOpener { process in
            game.append(process)
            fixture.probe.setBusy(5150)
            clock.after(5) { fixture.fileSystem.addFile(fixture.eeLog, Self.text(Self.session)) }
            clock.after(600) { fixture.fileSystem.append(fixture.eeLog, Self.text(Self.quit)) }
            clock.after(620) { fixture.fileSystem.append(fixture.eeLog, "620.00 Sys [Info]: still shutting down\r\n") }
        }
        let runs = Recorder<String>()
        let runner = Self.prefixTools(fixture, runs: runs, images: { Self.game }, kill: Self.killer(fixture, game))
        let events = Recorder<PlayEvent>()
        let result = try await session(fixture, runner: runner, opener: opener).run(launch(fixture), update: false) {
            events.append($0)
        }
        #expect(runs.all == ["tasklist 650", "kill 650"])
        #expect(result.hungAtExit)
        #expect(events.all.contains(.hungAtExit(seconds: 50)))
    }

    /// Without the closing signal Warzag only watches: a five-hour session, minimised and silent for hours, with
    /// "Shutting down context..." in the middle (Warframe logs it during play too), is never ended. DE's launcher
    /// writing its log meanwhile is no hand-off either: nothing is closing.
    @Test func aLongSessionWithoutTheClosingSignalIsNeverEnded() async throws {
        let fixture = readyFixture()
        let clock = fixture.clock
        let opener = FakeOpener { process in
            fixture.probe.setBusy(5150)
            clock.after(5) { fixture.fileSystem.addFile(fixture.eeLog, Self.text(Self.session)) }
            clock.after(1200) { fixture.appendLauncherLog(["Current time: Sat Oct 17 21:20:00 2026"]) }
            clock.after(1800) {
                fixture.fileSystem.append(fixture.eeLog, Self.text([
                    "1795.20 Sys [Info]: Shutting down context...", "1795.51 Sys [Info]: Context shutdown complete",
                ]))
            }
            clock.after(5 * 3600) { process.exit(nil) }
            clock.after(5 * 3600 + 2) { fixture.probe.setBusy(nil) }
        }
        let runner = RecordingProcessRunner()
        let events = Recorder<PlayEvent>()
        let result = try await session(fixture, runner: runner, opener: opener).run(launch(fixture), update: false) {
            events.append($0)
        }
        #expect(runner.commands.isEmpty)
        #expect(result == PlayResult(signals: [.steamActive, .steamLogin, .loggedIn], seconds: 5 * 3600,
                                     forcedCleanup: false, hungAtExit: false))
        #expect(!events.all.contains(where: Self.isHungAtExit) && !events.all.contains(.handedOverToLauncher))
    }

    /// A new EE.log after the closing signal is a new run of the game within the session: the wait for the old run's
    /// exit is over, and the game that runs on is left alone.
    @Test func aNewRunOfTheGameEndsTheWaitForTheOldOnesExit() async throws {
        let fixture = readyFixture()
        let clock = fixture.clock
        let opener = FakeOpener { process in
            fixture.probe.setBusy(5150)
            clock.after(5) { fixture.fileSystem.addFile(fixture.eeLog, Self.text(Self.session)) }
            clock.after(600) { fixture.fileSystem.append(fixture.eeLog, Self.text(Self.quit)) }
            clock.after(610) { fixture.fileSystem.addFile(fixture.eeLog, Self.text(Self.session)) }
            clock.after(1200) { process.exit(nil) }
            clock.after(1201) { fixture.probe.setBusy(nil) }
        }
        let runner = RecordingProcessRunner()
        let events = Recorder<PlayEvent>()
        let result = try await session(fixture, runner: runner, opener: opener).run(launch(fixture), update: false) {
            events.append($0)
        }
        #expect(runner.commands.isEmpty)
        #expect(!result.hungAtExit && !events.all.contains(where: Self.isHungAtExit))
        #expect(result.signals
            == [.steamActive, .steamLogin, .loggedIn, .closing, .steamActive, .steamLogin, .loggedIn])
    }

    /// Ending a hung game is tried once: a wineserver -k that passes its deadline is reported and not repeated while
    /// the game runs on (the player still has Quit and Force Quit); the usual cleanup follows its exit.
    @Test func endingAHungGameIsTriedOnceAndAFailureIsReported() async throws {
        let fixture = readyFixture()
        let clock = fixture.clock
        let opener = FakeOpener { process in
            fixture.probe.setBusy(5150)
            clock.after(5) { fixture.fileSystem.addFile(fixture.eeLog, Self.text(Self.quit)) }
            clock.after(300) { process.exit(nil) }
        }
        let runs = Recorder<String>()
        let runner = Self.prefixTools(fixture, runs: runs, images: { Self.game }, killTimesOut: true)
        let events = Recorder<PlayEvent>()
        let result = try await session(fixture, runner: runner, opener: opener).run(launch(fixture), update: false) {
            events.append($0)
        }
        #expect(result.hungAtExit && result.forcedCleanup)
        // Nothing more until the game exits at 300 s; the cleanup after that tries its own wineserver -k.
        #expect(runs.all == ["tasklist 35", "kill 35", "kill 310"])
        let hung = try #require(events.all.firstIndex(of: .hungAtExit(seconds: 30)))
        #expect(events.all[hung + 1] == .warning("wineserver -k did not finish within 60 s and was stopped"))
        #expect(events.all.last == .cleanedUp(forced: true))
    }

    /// Warframe ends its renderer without a quit (an update restart, say) and hands over to DE's launcher, which runs
    /// in the steam.exe shim's job and so keeps the session open while it updates. Launcher.log growing is the
    /// hand-off: the launcher is never ended, and the updated game it starts is a new run.
    @Test func warframeHandingOverToDEsLauncherWhileClosingIsLeftAlone() async throws {
        let fixture = readyFixture()
        let clock = fixture.clock
        let game = Recorder<FakeProcess>()
        let opener = FakeOpener { process in
            game.append(process)
            fixture.probe.setBusy(5150)
            clock.after(5) { fixture.fileSystem.addFile(fixture.eeLog, Self.text(Self.session)) }
            clock.after(600) { fixture.fileSystem.append(fixture.eeLog, Self.text([Self.rendererEnd])) }
            clock.every(5, from: 601, count: 36) { _ in fixture.appendLauncherLog(["Downloading @ 12 MB/s"]) }
            clock.after(780) { fixture.fileSystem.addFile(fixture.eeLog, Self.text(Self.session)) }
            clock.after(1800) { process.exit(nil) }
            clock.after(1801) { fixture.probe.setBusy(nil) }
        }
        let runs = Recorder<String>()
        let runner = Self.prefixTools(fixture, runs: runs, images: { clock.elapsed < 780 ? Self.launcher : Self.game },
                                      kill: Self.killer(fixture, game))
        let events = Recorder<PlayEvent>()
        let result = try await session(fixture, runner: runner, opener: opener).run(launch(fixture), update: false) {
            events.append($0)
        }
        // The launcher wrote every 5 s, so nothing had to be asked, and nothing was ended.
        #expect(runs.all.isEmpty)
        #expect(result == PlayResult(signals: [.steamActive, .steamLogin, .loggedIn, .closing, .steamActive,
                                               .steamLogin, .loggedIn],
                                     seconds: 1800, forcedCleanup: false, hungAtExit: false))
        let closing = try #require(events.all.firstIndex(of: .signal(.closing)))
        #expect(events.all[closing + 1] == .handedOverToLauncher)
        #expect(events.all.filter { $0 == .handedOverToLauncher }.count == 1)
        #expect(!events.all.contains(where: Self.isHungAtExit))
    }

    /// A launcher that writes nothing (its window waiting, a quiet step) is still seen: Launcher.exe in Wine's list is
    /// a hand-off too, and the wait starts over each time, for as long as the launcher runs, even with a
    /// Warframe.x64.exe next to it (the old game still finishing, or DE's ContentUpdate applet, which is one too).
    @Test func aQuietLauncherInThePrefixIsLeftAloneToo() async throws {
        let fixture = readyFixture()
        let clock = fixture.clock
        let game = Recorder<FakeProcess>()
        let opener = FakeOpener { process in
            game.append(process)
            fixture.probe.setBusy(5150)
            clock.after(5) { fixture.fileSystem.addFile(fixture.eeLog, Self.text(Self.session)) }
            clock.after(600) { fixture.fileSystem.append(fixture.eeLog, Self.text(Self.quit)) }
            clock.after(900) { fixture.fileSystem.addFile(fixture.eeLog, Self.text(Self.session)) }
            clock.after(1200) { process.exit(nil) }
            clock.after(1201) { fixture.probe.setBusy(nil) }
        }
        let runs = Recorder<String>()
        let runner = Self.prefixTools(fixture, runs: runs,
                                      images: { clock.elapsed < 900 ? Self.game + ["Launcher.exe"] : Self.game },
                                      kill: Self.killer(fixture, game))
        let events = Recorder<PlayEvent>()
        let result = try await session(fixture, runner: runner, opener: opener).run(launch(fixture), update: false) {
            events.append($0)
        }
        // Every 30 s while the launcher runs; the new run's EE.log at 900 s ends the watch.
        #expect(runs.all == stride(from: 630, through: 870, by: 30).map { "tasklist \($0)" })
        #expect(!result.hungAtExit && !result.forcedCleanup)
        #expect(events.all.filter { $0 == .handedOverToLauncher }.count == 1)
        #expect(!events.all.contains(where: Self.isHungAtExit))
    }

    /// Both at once: Warframe hands over and then hangs at exit itself. While the launcher writes and runs, nothing is
    /// ended; once it has gone and its log has been quiet for the grace period, the Warframe still there is hung.
    @Test func aGameThatHangsAfterHandingOverIsEndedOnceTheLauncherHasGone() async throws {
        let fixture = readyFixture()
        let clock = fixture.clock
        let game = Recorder<FakeProcess>()
        let opener = FakeOpener { process in
            game.append(process)
            fixture.probe.setBusy(5150)
            clock.after(5) { fixture.fileSystem.addFile(fixture.eeLog, Self.text(Self.session)) }
            clock.after(600) { fixture.fileSystem.append(fixture.eeLog, Self.text([Self.rendererEnd])) }
            // DE's launcher writes from 601 s to 696 s, then exits at 700 s; Warframe never does.
            clock.every(5, from: 601, count: 20) { _ in fixture.appendLauncherLog(["Downloading @ 12 MB/s"]) }
        }
        let runs = Recorder<String>()
        let runner = Self.prefixTools(fixture, runs: runs,
                                      images: { clock.elapsed < 700 ? Self.game + ["Launcher.exe"] : Self.game },
                                      kill: Self.killer(fixture, game))
        let events = Recorder<PlayEvent>()
        let result = try await session(fixture, runner: runner, opener: opener).run(launch(fixture), update: false) {
            events.append($0)
        }
        #expect(runs.all == ["tasklist 726", "kill 726"])
        #expect(result.hungAtExit)
        let handedOver = try #require(events.all.firstIndex(of: .handedOverToLauncher))
        let hung = try #require(events.all.firstIndex(of: .hungAtExit(seconds: 126)))
        #expect(handedOver < hung)
    }

    /// A closing after which Warframe has gone, while the session stays open for something else in the shim's job, is
    /// no hang: Wine is asked once, and nothing is ended.
    @Test func aClosingWithoutWarframeLeftIsNotAHang() async throws {
        let fixture = readyFixture()
        let clock = fixture.clock
        let opener = FakeOpener { process in
            fixture.probe.setBusy(5150)
            clock.after(600) { fixture.fileSystem.addFile(fixture.eeLog, Self.text(Self.quit)) }
            clock.after(900) { process.exit(nil) }
            clock.after(901) { fixture.probe.setBusy(nil) }
        }
        let runs = Recorder<String>()
        let runner = Self.prefixTools(fixture, runs: runs, images: { ["steam.exe", "conhost.exe"] })
        let events = Recorder<PlayEvent>()
        let result = try await session(fixture, runner: runner, opener: opener).run(launch(fixture), update: false) {
            events.append($0)
        }
        #expect(runs.all == ["tasklist 630"])
        #expect(!result.hungAtExit && result.seconds == 900)
        #expect(!events.all.contains(where: Self.isHungAtExit) && !events.all.contains(.handedOverToLauncher))
    }

    /// An answer overtaken while Wine was asked is not acted on: here the updated game's EE.log appears during the
    /// tasklist run whose Warframe.x64.exe is that new run, just started by a launcher that has already gone.
    @Test func anAnswerOvertakenByANewRunIsNotActedOn() async throws {
        let fixture = readyFixture()
        let clock = fixture.clock
        let game = Recorder<FakeProcess>()
        let opener = FakeOpener { process in
            game.append(process)
            fixture.probe.setBusy(5150)
            clock.after(600) { fixture.fileSystem.addFile(fixture.eeLog, Self.text(Self.quit)) }
            clock.after(1200) { process.exit(nil) }
            clock.after(1201) { fixture.probe.setBusy(nil) }
        }
        let runs = Recorder<String>()
        let runner = Self.prefixTools(fixture, runs: runs, images: {
            fixture.fileSystem.addFile(fixture.eeLog, Self.text(Self.session))
            return Self.game
        }, kill: Self.killer(fixture, game))
        let result = try await session(fixture, runner: runner, opener: opener).run(launch(fixture), update: false) { _ in }
        #expect(runs.all == ["tasklist 630"])
        #expect(!result.hungAtExit && result.seconds == 1200)
        #expect(result.signals == [.closing, .steamActive, .steamLogin, .loggedIn])
    }

    /// When Wine cannot say what runs (tasklist passed its deadline, or listed nothing), DE's logs decide: quiet since
    /// the closing signal, Warframe hung at exit.
    @Test(arguments: [true, false])
    func withoutAProcessListAQuietClosingIsAHang(_ tasklistTimesOut: Bool) async throws {
        let fixture = readyFixture()
        let clock = fixture.clock
        let game = Recorder<FakeProcess>()
        let opener = FakeOpener { process in
            game.append(process)
            fixture.probe.setBusy(5150)
            clock.after(600) { fixture.fileSystem.addFile(fixture.eeLog, Self.text(Self.quit)) }
        }
        let kills = Recorder<TimeInterval>()
        let kill = Self.killer(fixture, game)
        let runner = RecordingProcessRunner { command in
            if command.arguments == ["-k"] {
                kills.append(clock.elapsed)
                kill()
            } else if tasklistTimesOut {
                throw ProcessTimedOut(command: command.description, timeout: command.timeout ?? .zero)
            }
            // Otherwise tasklist "ran" and wrote nothing.
            return ProcessOutput(exitCode: 0)
        }
        let events = Recorder<PlayEvent>()
        let result = try await session(fixture, runner: runner, opener: opener).run(launch(fixture), update: false) {
            events.append($0)
        }
        #expect(kills.all == [630])
        #expect(result.hungAtExit)
        let problem = tasklistTimesOut
            ? "cmd /c tasklist did not finish within 120 s and was stopped" : "cmd /c tasklist listed no processes"
        let warning = try #require(events.all.firstIndex(of: .warning(problem)))
        #expect(events.all[warning + 1] == .hungAtExit(seconds: 30))
    }

    /// After a hand-off, a closing without a process list ends nothing: Play never ends DE's launcher on a guess.
    @Test func withoutAProcessListAHandOverIsLeftAlone() async throws {
        let fixture = readyFixture()
        let clock = fixture.clock
        let opener = FakeOpener { process in
            fixture.probe.setBusy(5150)
            clock.after(600) { fixture.fileSystem.addFile(fixture.eeLog, Self.text([Self.rendererEnd])) }
            clock.after(601) { fixture.appendLauncherLog(["Current time: Sat Oct 17 22:10:01 2026"]) }
            clock.after(606) { fixture.appendLauncherLog(["Finished BinariesBP_LAUNCHER (0.2 seconds)"]) }
            clock.after(1000) { process.exit(nil) }
            clock.after(1001) { fixture.probe.setBusy(nil) }
        }
        let runner = RecordingProcessRunner { command in
            throw ProcessTimedOut(command: command.description, timeout: command.timeout ?? .zero)
        }
        let events = Recorder<PlayEvent>()
        let result = try await session(fixture, runner: runner, opener: opener).run(launch(fixture), update: false) {
            events.append($0)
        }
        // Asked once, 30 s after the launcher's last line, then the watch was over.
        #expect(runner.commandLines == [Self.tasklistLine])
        #expect(!result.hungAtExit && !result.forcedCleanup)
        #expect(events.all.contains(.handedOverToLauncher))
        #expect(events.all.contains(.warning("cmd /c tasklist did not finish within 120 s and was stopped")))
        #expect(!events.all.contains(where: Self.isHungAtExit))
    }

    /// What Wine's tasklist prints (a fresh prefix with ping running), and what is not a process list.
    @Test func tasklistsAnswerIsReadAsWinePrintsIt() {
        let live = """
            "services.exe","52","Console","1","0 K"\r
            "explorer.exe","84","Console","1","0 K"\r
            "winedevice.exe","128","Console","1","0 K"\r
            "ping.exe","440","Console","1","0 K"\r
            "cmd.exe","480","Console","1","0 K"\r
            "tasklist.exe","492","Console","1","0 K"\r

            """
        #expect(ContentService.imageNames(tasklistCSV: live)
            == ["services.exe", "explorer.exe", "winedevice.exe", "ping.exe", "cmd.exe", "tasklist.exe"])
        #expect(ContentService.imageNames(tasklistCSV: #""Warframe.x64.exe","288","Console","1","1,024 K""#)
            == ["warframe.x64.exe"])
        #expect(ContentService.imageNames(tasklistCSV: #""Steam Helper.exe","300","Console","1","N/A""#)
            == ["steam helper.exe"])
        // A header row, a table, an error, nothing: no list.
        #expect(ContentService.imageNames(tasklistCSV: #""Image Name","PID","Session Name","Session#","Mem Usage""#) == nil)
        #expect(ContentService.imageNames(tasklistCSV: "Warframe.x64.exe   288 Console   1   0 K\r\n") == nil)
        #expect(ContentService.imageNames(tasklistCSV: "ERROR: Invalid syntax.\r\n") == nil)
        #expect(ContentService.imageNames(tasklistCSV: "") == nil)
    }

    @Test func anUpdateRunsFirst() async throws {
        let fixture = readyFixture()
        let clock = fixture.clock
        let launcher = FakeLauncher { _, _ in
            fixture.probe.setBusy(9000)
            clock.after(2) {
                fixture.fileSystem.addFile(fixture.launcherLog, "")
                fixture.appendLauncherLog(Fixtures.launcherStart + Fixtures.eulaAccepted(seconds: 0) + Fixtures.finished)
            }
        }
        let runner = ContentServiceTests.closingRunner(fixture, launcher)
        let opener = FakeOpener { process in clock.after(10) { process.exit(nil) } }
        let events = Recorder<PlayEvent>()
        _ = try await session(fixture, runner: runner, launcher: launcher, opener: opener)
            .run(launch(fixture), update: true) { events.append($0) }
        let all = events.all
        let opening = try #require(all.firstIndex(of: .opening))
        #expect(all[..<opening].allSatisfy { if case .updating = $0 { true } else { false } })
        #expect(all[..<opening].contains(.updating(.complete(seconds: 1214.5))))
        #expect(runner.commandLines == ContentServiceTests.closeCommands)
        #expect(opener.opened.count == 1)
    }

    @Test func noGameStartsWithoutAnUpdate() async throws {
        let fixture = GameFixture()
        fixture.addHost()
        fixture.addPrefix(eula: nil)
        fixture.addGame()
        let clock = fixture.clock
        let launcher = FakeLauncher { _, process in
            fixture.probe.setBusy(9000)
            clock.after(1) { ContentServiceTests.startLog(fixture, Fixtures.launcherStart) }
            clock.after(30) {
                process.exit(0)
                fixture.probe.setBusy(nil)
            }
        }
        let opener = FakeOpener()
        await #expect(throws: PlayError.updateDidNotComplete(.eulaDeclined)) {
            _ = try await session(fixture, launcher: launcher, opener: opener).run(launch(fixture), update: true) { _ in }
        }
        #expect(opener.opened.isEmpty)
    }

    @Test func aPrefixThatIsNotReadyStopsBeforeAnything() async throws {
        let fixture = GameFixture()
        fixture.addHost()
        fixture.addPrefix(eula: Fixtures.eulaHash)
        fixture.addLauncher()
        let launcher = FakeLauncher()
        let opener = FakeOpener()
        await #expect(throws: PlayError.notReady([.gameNotDownloaded])) {
            _ = try await session(fixture, launcher: launcher, opener: opener).run(launch(fixture), update: true) { _ in }
        }
        #expect(launcher.commands.isEmpty && opener.opened.isEmpty)
    }

    @Test func somethingStillRunningInThePrefixBlocksPlay() async throws {
        let fixture = readyFixture()
        fixture.probe.setBusy(808)
        let opener = FakeOpener()
        await #expect(throws: PlayError.notReady([.prefixBusy(wineserver: 808)])) {
            _ = try await session(fixture, opener: opener).run(launch(fixture), update: false) { _ in }
        }
        #expect(opener.opened.isEmpty)
        #expect(fixture.clock.elapsed >= 30)
    }

    @Test func aHostWhoseSignatureNoLongerVerifiesIsNeverStarted() async throws {
        let fixture = readyFixture()
        fixture.signatures.breakSignature()
        let launcher = FakeLauncher()
        let opener = FakeOpener()
        await #expect(throws: PlayError.hostSignatureInvalid("code signature validation failed (OSStatus -67061)")) {
            _ = try await session(fixture, launcher: launcher, opener: opener).run(launch(fixture), update: true) { _ in }
        }
        // Nothing of the host ran: not DE's launcher for the update, not the game.
        #expect(launcher.commands.isEmpty && opener.opened.isEmpty)
        #expect(fixture.signatures.checked == [fixture.host.bundle.plainPath])
    }

    @Test func everySessionChecksTheSignatureFirst() async throws {
        let fixture = readyFixture()
        let opener = FakeOpener { process in fixture.clock.after(2) { process.exit(nil) } }
        _ = try await session(fixture, opener: opener).run(launch(fixture), update: false) { _ in }
        #expect(fixture.signatures.checked == [fixture.host.bundle.plainPath])
    }

    @Test func closingTheGameAsksFirstThenStopsWine() async throws {
        let fixture = readyFixture()
        fixture.probe.setBusy(5150)
        let runner = RecordingProcessRunner { command in
            if command.arguments == ["-k"] { fixture.probe.setBusy(nil) }
            return ProcessOutput(exitCode: 0)
        }
        let problems = await session(fixture, runner: runner, opener: FakeOpener()).closeGame()
        #expect(problems.isEmpty)
        #expect(runner.commandLines
            == ["wine taskkill /IM Warframe.x64.exe", "wine taskkill /IM Launcher.exe", "wineserver -k"])
        #expect(runner.commands.allSatisfy { $0.timeout != nil })
        // A game that closes when asked needs no wineserver -k.
        let polite = readyFixture()
        polite.probe.setBusy(5150)
        let asking = RecordingProcessRunner { command in
            if command.arguments.first == "taskkill" { polite.probe.setBusy(nil) }
            return ProcessOutput(exitCode: 0)
        }
        _ = await session(polite, runner: asking, opener: FakeOpener()).closeGame()
        #expect(!asking.commandLines.contains("wineserver -k"))
    }

    @Test func aHungWineserverKillAfterTheSessionIsReported() async throws {
        let fixture = readyFixture()
        let clock = fixture.clock
        let opener = FakeOpener { process in
            fixture.probe.setBusy(5150)
            clock.after(5) { process.exit(nil) }
        }
        let runner = RecordingProcessRunner { command in
            throw ProcessTimedOut(command: command.description, timeout: command.timeout ?? .zero)
        }
        let events = Recorder<PlayEvent>()
        let result = try await session(fixture, runner: runner, opener: opener).run(launch(fixture), update: false) {
            events.append($0)
        }
        #expect(result.forcedCleanup)
        #expect(events.all.contains(.warning("wineserver -k did not finish within 60 s and was stopped")))
    }

    @Test func cancellingWhileThePrefixWindsDownOpensNothing() async throws {
        let fixture = readyFixture()
        // Something still runs in the prefix after the update: Play waits for it, and is cancelled meanwhile.
        fixture.probe.setBusy(808)
        let opener = FakeOpener()
        let task = Task { try await session(fixture, opener: opener).run(launch(fixture), update: false) { _ in } }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(opener.opened.isEmpty)
    }

    @Test func aHostThatWillNotOpenIsReported() async throws {
        let fixture = readyFixture()
        let opener = FakeOpener(failure: CocoaError(.fileNoSuchFile))
        await #expect(throws: PlayError.self) {
            _ = try await session(fixture, opener: opener).run(launch(fixture), update: false) { _ in }
        }
    }
}

@Suite struct PowerAdvisorTests {
    /// A MacBook Air M2 by default, with a battery (`battery`: its charge in percent, nil for a desktop) and an adapter
    /// that says how many watts it supplies (`watts`, nil: none, or it does not say).
    func system(lowPower: Bool = false, power: PowerSource = .ac, thermal: ThermalState = .nominal,
                watts: Int? = nil, battery: Int? = nil) -> FakeSystemInfo {
        var system = FakeSystemInfo.mac(chip: "Apple M2", model: "Mac14,15", product: nil, performanceCores: 4,
                                        efficiencyCores: 4, gpuCores: 10, memoryGB: 24)
        system.isLowPowerModeEnabled = lowPower
        system.powerSource = power
        system.thermalState = thermal
        system.powerAdapterWatts = watts
        system.batteryPercent = battery
        return system
    }

    @Test func aPluggedInCoolMacNeedsNoAdvice() {
        #expect(PowerAdvisor(system: system()).advice(for: .t1).isEmpty)
        #expect(PowerAdvisor(system: system(thermal: .fair)).advice(for: .t1).isEmpty)
    }

    @Test func lowPowerModeIsCalledOut() {
        let advice = PowerAdvisor(system: system(lowPower: true)).advice(for: .t3)
        #expect(advice.map(\.kind) == [.lowPowerMode])
        #expect(advice[0].message.contains("System Settings > Battery") && advice[0].message.contains("30 fps"))
    }

    @Test func batteryMeansThirtyOnlyOnFanlessMacs() {
        let fanless = PowerAdvisor(system: system(power: .battery)).advice(for: .t1)
        #expect(fanless.map(\.kind) == [.battery] && fanless[0].message.contains("30 fps"))
        let pro = PowerAdvisor(system: system(power: .battery)).advice(for: .t3)
        #expect(pro.map(\.kind) == [.battery] && !pro[0].message.contains("30 fps"))
    }

    @Test func everythingAtOnce() {
        let advice = PowerAdvisor(system: system(lowPower: true, power: .battery, thermal: .serious)).advice(for: .t1)
        #expect(advice.map(\.kind) == [.lowPowerMode, .battery, .thermal])
        #expect(advice[2].message.contains("serious"))
        #expect(advice.map(\.frameRateCap) == [30, 30, 30])
        #expect(advice[2].thermalState == .serious)
    }

    /// An 8 W adapter cannot keep up: the battery drains while playing.
    @Test func aWeakChargerIsCalledOutWithItsWatts() {
        let advice = PowerAdvisor(system: system(watts: 8, battery: 64)).advice(for: .t1)
        #expect(advice == [PowerAdvice(kind: .weakCharger, adapterWatts: 8, recommendedWatts: 30)])
        #expect(advice[0].message == "The charger supplies only 8 W. Warframe needs about 20-30 W, so the battery drains "
            + "while you play and the Mac slows down when it gets low. Use the Mac's own charger (30 W or more).")
        #expect(PowerAdvisor(system: system(watts: 29, battery: 64)).advice(for: .t3).map(\.kind) == [.weakCharger])
    }

    @Test func aStrongChargerUnknownWattsAndDesktopsGetNoChargerAdvice() {
        #expect(PowerAdvisor(system: system(watts: 30, battery: 64)).advice(for: .t1).isEmpty)
        #expect(PowerAdvisor(system: system(watts: 96, battery: 64)).advice(for: .t1).isEmpty)
        #expect(PowerAdvisor(system: system(watts: nil, battery: 64)).advice(for: .t1).isEmpty)
        // A Mac mini says nothing about a battery: no charger or battery advice, whatever it reports.
        #expect(PowerAdvisor(system: system(watts: 8, battery: nil)).advice(for: .t2).isEmpty)
    }

    @Test func aLowBatteryIsCalledOutWithItsCharge() {
        let unplugged = PowerAdvisor(system: system(power: .battery, battery: 15)).advice(for: .t3)
        #expect(unplugged == [PowerAdvice(kind: .battery), PowerAdvice(kind: .lowBattery, batteryPercent: 15)])
        #expect(unplugged[1].message.hasPrefix("The battery is at 15%."))
        #expect(PowerAdvisor(system: system(power: .battery, battery: 20)).advice(for: .t3).map(\.kind) == [.battery])
        #expect(PowerAdvisor(system: system(power: .battery, battery: 19)).advice(for: .t3).map(\.kind)
            == [.battery, .lowBattery])
    }

    @Test func aWeakChargerAndANearlyEmptyBatteryBothSpeak() {
        let advice = PowerAdvisor(system: system(power: .ac, watts: 8, battery: 7)).advice(for: .t1)
        #expect(advice.map(\.kind) == [.weakCharger, .lowBattery])
        #expect(advice[1].batteryPercent == 7)
    }

    /// A battery under 20% is called out whatever the charger: under a game's load even a 30 W or stronger adapter may
    /// not keep up.
    @Test func aLowBatteryIsCalledOutWhateverTheCharger() {
        #expect(PowerAdvisor(system: system(power: .ac, watts: 70, battery: 12)).advice(for: .t1)
            == [PowerAdvice(kind: .lowBattery, batteryPercent: 12)])
        // A Pro chip on a 60 W adapter: enough for no charger advice, not enough to skip the battery's.
        #expect(PowerAdvisor(system: system(power: .ac, watts: 60, battery: 15)).advice(for: .t3).map(\.kind)
            == [.lowBattery])
        // An adapter that does not say its wattage gets no charger advice; the battery still gets its own.
        #expect(PowerAdvisor(system: system(power: .ac, watts: nil, battery: 12)).advice(for: .t1).map(\.kind)
            == [.lowBattery])
        #expect(PowerAdvisor(system: system(power: .ac, watts: 70, battery: 20)).advice(for: .t1).isEmpty)
    }

    @Test func batteryAdviceCarriesTheCapOnlyWhereFramePacingLowersIt() {
        #expect(PowerAdvisor(system: system(power: .battery)).advice(for: .t1) == [PowerAdvice(kind: .battery, frameRateCap: 30)])
        #expect(PowerAdvisor(system: system(power: .battery)).advice(for: .t4) == [PowerAdvice(kind: .battery)])
    }
}
