import ContentKit
import Foundation
import Synchronization
import Testing
import WarzagCore
import WarzagTestSupport
import WineKit
@testable import GameKit

/// DE's launcher as a scripted fake: each test says what Launcher.log, the registry, the library and the process do
/// over time, and the real `ContentService` loop runs against it on a scripted clock.
@Suite struct ContentServiceTests {
    @Test func warframesBuildComesFromTheTopOfEELog() {
        let top = "0.141 Sys [Diag]: Build Label: 2026.10.15.13.08 Retail Windows x64 [Stripped]\r\n"
        #expect(ContentService.buildLabel(in: top) == "2026.10.15.13.08")
        #expect(ContentService.buildLabel(in: "0.120 Sys [Info]: Starting\n") == nil)
        #expect(ContentService.buildLabel(in: "Build Label: unknown Retail") == nil)
        #expect(ContentService.buildLabel(in: "Build Label: ") == nil)
    }

    /// taskkill makes the current launcher exit (as WM_CLOSE does) and Wine winds down after it; wineserver -k leaves
    /// the prefix idle in any case.
    static func closingRunner(_ fixture: GameFixture, _ launcher: FakeLauncher) -> RecordingProcessRunner {
        RecordingProcessRunner { command in
            if command.arguments.first == "taskkill" {
                launcher.current?.exit(0)
                fixture.probe.setBusy(nil)
            }
            if command.arguments == ["-k"] { fixture.probe.setBusy(nil) }
            return ProcessOutput(exitCode: 0)
        }
    }

    static let closeCommands = ["wine taskkill /IM Launcher.exe", "wineserver -k"]

    func service(_ fixture: GameFixture, runner: RecordingProcessRunner, launcher: FakeLauncher,
                 configuration: ContentConfiguration = ContentConfiguration()) -> ContentService {
        ContentService(installation: fixture.installation, context: fixture.context(runner: runner, launcher: launcher),
                       configuration: configuration)
    }

    /// A new launcher run's Launcher.log: the file starts over with `lines`.
    static func startLog(_ fixture: GameFixture, _ lines: [String]) {
        fixture.fileSystem.addFile(fixture.launcherLog, "")
        fixture.appendLauncherLog(lines)
    }

    // MARK: - Launcher runs

    @Test func aFirstInstallWaitsForTheEULAThenDownloadsAndCloses() async throws {
        let fixture = GameFixture()
        fixture.addHost()
        fixture.addPrefix(eula: nil)
        fixture.addLauncher()
        // The previous run's log ends like a finished run; it must not count for this one.
        fixture.appendLauncherLog(["Current time: Thu Oct 15 10:00:00 2026", "Total time: 5.0 seconds"])
        let clock = fixture.clock
        let library = fixture.libraryPath
        let launcher = FakeLauncher { _, _ in
            fixture.probe.setBusy(9000)
            clock.after(1) { Self.startLog(fixture, Fixtures.launcherStart) }
            // The player reads the EULA for ten minutes, then clicks I AGREE; DE records ReadEula.
            clock.after(600) {
                fixture.setEULA(Fixtures.eulaHash)
                fixture.appendLauncherLog(Fixtures.eulaAccepted(seconds: 598.3))
            }
            clock.every(1, from: 601, count: 1185) { step in
                fixture.appendLauncherLog(["Downloading @ \(step.isMultiple(of: 2) ? 44 : 46) MB/s"])
                fixture.files.addUsage(library, 44_000_000)
            }
            clock.after(1790) {
                fixture.appendLauncherLog(Fixtures.bulkFinished)
                fixture.fileSystem.addFile(fixture.preprocessLog, Fixtures.appletLines.prefix(2).map { $0 + "\r\n" }.joined())
            }
            clock.after(1800) {
                fixture.fileSystem.append(fixture.preprocessLog,
                                          Fixtures.appletLines.dropFirst(2).map { $0 + "\r\n" }.joined())
                fixture.appendLauncherLog(Fixtures.finished)
            }
        }
        let runner = Self.closingRunner(fixture, launcher)
        let states = Recorder<ContentRunState>()
        let outcome = try await service(fixture, runner: runner, launcher: launcher).runLauncher(.install) {
            states.append($0)
        }

        #expect(outcome == .completed(seconds: 1214.5))
        #expect(launcher.commands.count == 1, "ten minutes at the EULA is not a stall")
        #expect(runner.commandLines == Self.closeCommands)
        let all = states.all
        #expect(all.first == .startingLauncher(attempt: 0))
        let eula = all.indices.filter { all[$0] == .needsEULA }
        #expect(eula.count >= 590 && eula.count <= 600)
        let downloading = all.compactMap { state -> Double? in
            guard case .downloading(let thisRun, let onDisk, let expected, let rate) = state else { return nil }
            // A first install: measured against the whole game.
            #expect(expected == ContentConfiguration.defaultExpectedContentBytes)
            #expect(onDisk <= 1185 * 44_000_000 && thisRun == onDisk)
            return rate
        }
        #expect(downloading.count > 1100)
        #expect(Set(downloading.compactMap { $0 }) == [44, 46])
        #expect(all.contains { if case .preprocessing(let fraction?) = $0 { fraction > 0 } else { false } })
        #expect(all.suffix(2) == [.closingLauncher, .complete(seconds: 1214.5)])
        #expect(eula.allSatisfy { $0 < all.firstIndex { if case .downloading = $0 { true } else { false } }! })
        let record = try #require(fixture.fileSystem.text(
            at: "/Users/tenno/Library/Application Support/Warzag/State/content.json"))
        #expect(record.contains(#""mode" : "install""#) && record.contains(#""launcherSeconds" : 1214.5"#))
    }

    @Test func theLaunchersCommandLineAndEnvironment() {
        let fixture = GameFixture()
        let command = service(fixture, runner: RecordingProcessRunner(), launcher: FakeLauncher()).launcherCommand()
        #expect(command.executable == fixture.host.wine)
        #expect(command.arguments == [#"X:\Tools\Launcher.exe"#, "-cluster:public", "-registry:Steam"])
        #expect(command.workingDirectory?.plainPath == fixture.libraryPath + "/Tools")
        #expect(command.logFile?.plainPath == "/Users/tenno/Library/Logs/Warzag/wine-launcher.log")
        #expect(command.environment == [
            "HOME": "/Users/tenno", "USER": "tenno", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "WINEPREFIX": fixture.prefixPath, "WINEDEBUG": "-all", "SteamDeck": "0",
            "NEUTRON_PRECISE_TIMERS": "1", "NEUTRON_FAST_QPC": "1", "NEUTRON_RAW_MOUSE": "1",
            "NEUTRON_NATIVE_FULLSCREEN": "0", "NEUTRON_RENDER_SCALE": "1", "NEUTRON_MSYNC": "0",
            "WINEDLLPATH_PREPEND": fixture.host.contents.plainPath + "/renderers/dxmt",
        ])
    }

    @Test func aHiddenLauncherCommandOnlyAddsTheHideSwitch() {
        let fixture = GameFixture()
        let content = service(fixture, runner: RecordingProcessRunner(), launcher: FakeLauncher())
        var expected = content.launcherCommand().environment ?? [:]
        expected["WARZAG_HIDE_WINDOWS"] = "1"
        #expect(content.launcherCommand(hidden: true).environment == expected)
        #expect(content.launcherCommand(hidden: true).arguments == content.launcherCommand().arguments)
    }

    @Test func aStalledLauncherIsRestartedTwiceThenReportedStuck() async throws {
        let fixture = GameFixture()
        fixture.addHost()
        fixture.addPrefix(eula: Fixtures.eulaHash)
        fixture.addGame()
        let clock = fixture.clock
        let launches = Recorder<TimeInterval>()
        let launcher = FakeLauncher { index, _ in
            launches.append(clock.elapsed)
            fixture.probe.setBusy(Int32(9000 + index))
            // A few lines, then nothing: no log line and no byte on disk.
            clock.after(1) {
                Self.startLog(fixture, Fixtures.launcherStart + Fixtures.eulaAccepted(seconds: 0) + ["Downloading @ 3 MB/s"])
            }
        }
        let runner = Self.closingRunner(fixture, launcher)
        let states = Recorder<ContentRunState>()
        let outcome = try await service(fixture, runner: runner, launcher: launcher).runLauncher(.update) {
            states.append($0)
        }
        #expect(outcome == .stuck(.stalled))
        #expect(launcher.commands.count == 3)
        // The EULA was accepted: the first run is hidden, the restarts show DE's window.
        #expect(launcher.commands.map { $0.environment?["WARZAG_HIDE_WINDOWS"] } == ["1", nil, nil])
        #expect(runner.commandLines == Self.closeCommands + Self.closeCommands + Self.closeCommands)
        #expect(states.all.filter {
            if case .restartingLauncher = $0 { true } else { false }
        } == [.restartingLauncher(attempt: 1, reason: .stalled), .restartingLauncher(attempt: 2, reason: .stalled)])
        #expect(states.all.last == .stuck(.stalled))
        // Each stall is declared 3 minutes after the last sign of life (one second after its launch).
        let times = launches.all
        #expect(times.count == 3 && times[1] - times[0] >= 181 && times[1] - times[0] < 185)
        #expect(!fixture.fileSystem.fileExists(at: URL(filePath: "/Users/tenno/Library/Application Support/Warzag/State/content.json")))
    }

    @Test func chatterIsNotProgressButStepsBytesAndRatesAre() async throws {
        let fixture = GameFixture()
        fixture.addHost()
        fixture.addPrefix(eula: Fixtures.eulaHash)
        fixture.addGame()
        let clock = fixture.clock
        let launches = Recorder<TimeInterval>()
        let launcher = FakeLauncher { index, _ in
            launches.append(clock.elapsed)
            fixture.probe.setBusy(9000)
            clock.after(1) { Self.startLog(fixture, Fixtures.launcherStart + Fixtures.eulaAccepted(seconds: 0)) }
            if index == 0 {
                // A launcher that keeps talking (hashing, HTTP requests, retries) without getting anywhere.
                clock.every(30, from: 30, count: 20) { _ in
                    fixture.appendLauncherLog([#"Hashing X:\Cache.Windows\B.Misc.cache..."#, "HTTP GET /index.txt.lzma",
                                               "Retrying request (2)..."])
                }
            } else {
                // Ten minutes of real progress at a slow pace: a step every two minutes, bytes in between.
                clock.every(120, from: 120, count: 4) { step in fixture.appendLauncherLog(["Finished Step\(step) (1.0 seconds)"]) }
                clock.every(120, from: 60, count: 5) { _ in fixture.files.addUsage(fixture.libraryPath, 1_000_000) }
                clock.after(650) { fixture.appendLauncherLog(Fixtures.finished) }
            }
        }
        let runner = Self.closingRunner(fixture, launcher)
        let outcome = try await service(fixture, runner: runner, launcher: launcher).runLauncher(.update) { _ in }
        #expect(outcome == .completed(seconds: 1214.5))
        #expect(launcher.commands.count == 2)
        // The first launcher was declared stalled 3 minutes after its last real progress (the EULA step's lines).
        let times = launches.all
        #expect(times.count == 2 && times[1] - times[0] >= 181 && times[1] - times[0] < 185)

        // A launcher that keeps saying it downloads nothing has stalled.
        let idle = GameFixture()
        idle.addHost()
        idle.addPrefix(eula: Fixtures.eulaHash)
        idle.addGame()
        let idleClock = idle.clock
        let idleLauncher = FakeLauncher { _, _ in
            idle.probe.setBusy(9000)
            idleClock.after(1) { Self.startLog(idle, Fixtures.launcherStart + Fixtures.eulaAccepted(seconds: 0)) }
            idleClock.every(1, from: 2, count: 400) { _ in idle.appendLauncherLog(["Downloading @ 0 MB/s"]) }
        }
        let idleRunner = Self.closingRunner(idle, idleLauncher)
        let idleOutcome = try await service(idle, runner: idleRunner, launcher: idleLauncher,
                                            configuration: ContentConfiguration(maximumRestarts: 0))
            .runLauncher(.update) { _ in }
        #expect(idleOutcome == .stuck(.stalled))
        #expect(idleClock.elapsed >= 181 && idleClock.elapsed < 190)
    }

    @Test func aLongQuietDefragmentationIsNotAStall() async throws {
        let fixture = GameFixture()
        fixture.addHost()
        fixture.addPrefix(eula: Fixtures.eulaHash)
        fixture.addGame()
        let clock = fixture.clock
        let launcher = FakeLauncher { _, _ in
            fixture.probe.setBusy(9000)
            clock.after(1) {
                Self.startLog(fixture, Fixtures.launcherStart + Fixtures.eulaAccepted(seconds: 0)
                    + ["Process returned 0", "Finished Preprocess (24.7 seconds)"])
            }
            // Ten silent minutes of cache defragmentation.
            clock.after(601) { fixture.appendLauncherLog(["Finished Defrag1 (600.0 seconds)", "Total time: 660.0 seconds"]) }
        }
        let runner = Self.closingRunner(fixture, launcher)
        let states = Recorder<ContentRunState>()
        let outcome = try await service(fixture, runner: runner, launcher: launcher).runLauncher(.update) {
            states.append($0)
        }
        #expect(outcome == .completed(seconds: 660))
        #expect(launcher.commands.count == 1)
        #expect(states.all.contains(.finishing))
    }

    @Test(arguments: [
        ("HTTP GET /index.txt.lzma", false), (#"Hashing X:\Tools\Launcher.exe..."#, false), ("Retrying", false),
        ("Downloading @ 44 MB/s", true), ("Downloading @ 0 MB/s", false), ("", false), ("   ", false),
        ("Finished DirectX (0.3 seconds)", true), ("Current time: now", true), ("Total time: 1.0 seconds", true),
        ("Process returned 0", true), ("11.215 Sys [Info]: Downloaded 0/21544", true),
        ("Downloaded 52,514,328,367 bytes total ~ 44,318,693 B/s", true),
    ])
    func whatCountsAsProgress(_ line: String, _ progress: Bool) {
        let start = Date(timeIntervalSince1970: 1_000)
        var watchdog = StallWatchdog(start: start, librarySize: 100)
        if let event = LogParser(kind: .launcher, rules: LauncherLog.ruleSet).event(for: line).map(LauncherEvent.init) {
            watchdog.observe(event, at: start.addingTimeInterval(100))
        }
        #expect(watchdog.isStalled(at: start.addingTimeInterval(180), timeout: 180) == !progress)
    }

    @Test func theWatchdogCountsOnlyGrowthAndMovingCounters() {
        let start = Date(timeIntervalSince1970: 1_000)
        var watchdog = StallWatchdog(start: start, librarySize: 50_000)
        // A shrinking or unchanged library is not progress, growth past the largest size so far is.
        watchdog.library(40_000, at: start.addingTimeInterval(60))
        watchdog.library(50_000, at: start.addingTimeInterval(90))
        #expect(watchdog.lastProgress == start)
        watchdog.library(50_001, at: start.addingTimeInterval(100))
        #expect(watchdog.lastProgress == start.addingTimeInterval(100))
        // The applet's counter: the same count again is not progress, a higher one or a new counter is.
        watchdog.observeApplet(.launcherDownloaded(downloaded: 10, total: 100), at: start.addingTimeInterval(110))
        watchdog.observeApplet(.launcherDownloaded(downloaded: 10, total: 100), at: start.addingTimeInterval(120))
        #expect(watchdog.lastProgress == start.addingTimeInterval(110))
        watchdog.observeApplet(.launcherDownloaded(downloaded: 0, total: 200), at: start.addingTimeInterval(130))
        #expect(watchdog.lastProgress == start.addingTimeInterval(130))
        watchdog.observeApplet(.fetchFailed, at: start.addingTimeInterval(140))
        watchdog.observeApplet(.wastedCacheSpace(bytes: 1, percent: nil), at: start.addingTimeInterval(140))
        #expect(watchdog.lastProgress == start.addingTimeInterval(130))
        // Paused, nothing is a stall; resuming starts a fresh window.
        watchdog.pause()
        #expect(!watchdog.isStalled(at: start.addingTimeInterval(10_000), timeout: 180))
        watchdog.resume(at: start.addingTimeInterval(10_000))
        #expect(!watchdog.isStalled(at: start.addingTimeInterval(10_179), timeout: 180))
        #expect(watchdog.isStalled(at: start.addingTimeInterval(10_180), timeout: 180))
    }

    @Test func closingDEsWindowAtTheEULAStopsWithoutRestarting() async throws {
        let fixture = GameFixture()
        fixture.addHost()
        fixture.addPrefix(eula: nil)
        fixture.addLauncher()
        let clock = fixture.clock
        let launcher = FakeLauncher { _, process in
            fixture.probe.setBusy(9000)
            clock.after(1) { Self.startLog(fixture, Fixtures.launcherStart) }
            clock.after(45) {
                process.exit(0)
                fixture.probe.setBusy(nil)
            }
        }
        let runner = Self.closingRunner(fixture, launcher)
        let states = Recorder<ContentRunState>()
        let outcome = try await service(fixture, runner: runner, launcher: launcher).runLauncher(.install) {
            states.append($0)
        }
        #expect(outcome == .eulaDeclined)
        #expect(launcher.commands.count == 1)
        #expect(runner.commands.isEmpty)
        #expect(states.all.contains(.needsEULA))
    }

    @Test func aLauncherThatDiesMidDownloadIsStartedAgain() async throws {
        let fixture = GameFixture()
        fixture.addHost()
        fixture.addPrefix(eula: Fixtures.eulaHash)
        fixture.addGame()
        let clock = fixture.clock
        let launcher = FakeLauncher { index, process in
            fixture.probe.setBusy(9000)
            clock.after(1) {
                Self.startLog(fixture, Fixtures.launcherStart + Fixtures.eulaAccepted(seconds: 0) + ["Downloading @ 40 MB/s"])
            }
            if index == 0 {
                clock.after(30) {
                    process.exit(139)
                    fixture.probe.setBusy(nil)
                }
            } else {
                clock.after(10) { fixture.appendLauncherLog(Fixtures.finished) }
            }
        }
        let runner = Self.closingRunner(fixture, launcher)
        let states = Recorder<ContentRunState>()
        let outcome = try await service(fixture, runner: runner, launcher: launcher).runLauncher(.update) {
            states.append($0)
        }
        #expect(outcome == .completed(seconds: 1214.5))
        #expect(launcher.commands.count == 2)
        #expect(states.all.contains(.restartingLauncher(attempt: 1, reason: .exited)))
        // Nothing to close after the crash; only the finished launcher is closed.
        #expect(runner.commandLines == Self.closeCommands)
    }

    @Test func aSelfUpdatingLauncherIsFollowedAcrossItsRestart() async throws {
        let fixture = GameFixture()
        fixture.addHost()
        fixture.addPrefix(eula: Fixtures.eulaHash)
        fixture.addGame()
        let clock = fixture.clock
        let launcher = FakeLauncher { _, process in
            fixture.probe.setBusy(9000)
            clock.after(1) { Self.startLog(fixture, Fixtures.launcherStart) }
            // The launcher replaces itself: the process Warzag started ends, the prefix stays busy.
            clock.after(20) { process.exit(0) }
            clock.after(26) {
                Self.startLog(fixture, Fixtures.launcherStart + Fixtures.eulaAccepted(seconds: 0) + Fixtures.finished)
            }
        }
        let runner = Self.closingRunner(fixture, launcher)
        let outcome = try await service(fixture, runner: runner, launcher: launcher).runLauncher(.update) { _ in }
        #expect(outcome == .completed(seconds: 1214.5))
        #expect(launcher.commands.count == 1)
        #expect(runner.commandLines == Self.closeCommands)
    }

    @Test func aSelfUpdatedLauncherStillGetsItsGracePeriod() async throws {
        let fixture = GameFixture()
        fixture.addHost()
        fixture.addPrefix(eula: Fixtures.eulaHash)
        fixture.addGame()
        let clock = fixture.clock
        let launcher = FakeLauncher { _, process in
            fixture.probe.setBusy(9000)
            clock.after(1) { Self.startLog(fixture, Fixtures.launcherStart) }
            // The launcher replaces itself: the process Warzag started ends, its successor keeps the prefix busy.
            clock.after(20) { process.exit(0) }
            clock.after(26) {
                Self.startLog(fixture, Fixtures.launcherStart + Fixtures.eulaAccepted(seconds: 0) + Fixtures.finished)
            }
        }
        // WM_CLOSE reaches the successor, which takes 4 s to close; Wine then winds down by itself.
        let calls = Recorder<(String, TimeInterval)>()
        let runner = RecordingProcessRunner { command in
            calls.append((command.arguments.first ?? "", clock.elapsed))
            if command.arguments.first == "taskkill" { clock.after(4) { fixture.probe.setBusy(nil) } }
            if command.arguments == ["-k"] { fixture.probe.setBusy(nil) }
            return ProcessOutput(exitCode: 0)
        }
        let outcome = try await service(fixture, runner: runner, launcher: launcher).runLauncher(.update) { _ in }
        #expect(outcome == .completed(seconds: 1214.5))
        let recorded = calls.all
        #expect(recorded.map(\.0) == ["taskkill", "-k"])
        // wineserver -k comes once the successor has closed, not in the same breath as WM_CLOSE.
        #expect(recorded.count == 2 && recorded[1].1 - recorded[0].1 >= 4)
    }

    @Test func aLauncherThatIgnoresWMCloseIsStoppedAfterTheGracePeriod() async throws {
        let fixture = GameFixture()
        fixture.addHost()
        fixture.addPrefix(eula: Fixtures.eulaHash)
        fixture.addGame()
        let clock = fixture.clock
        let launcher = FakeLauncher { _, _ in
            fixture.probe.setBusy(9000)
            clock.after(1) {
                Self.startLog(fixture, Fixtures.launcherStart + Fixtures.eulaAccepted(seconds: 0) + Fixtures.finished)
            }
        }
        let calls = Recorder<(String, TimeInterval)>()
        let runner = RecordingProcessRunner { command in
            calls.append((command.arguments.first ?? "", clock.elapsed))
            if command.arguments == ["-k"] {
                launcher.current?.exit(nil)
                fixture.probe.setBusy(nil)
            }
            return ProcessOutput(exitCode: 0)
        }
        let outcome = try await service(fixture, runner: runner, launcher: launcher).runLauncher(.update) { _ in }
        #expect(outcome == .completed(seconds: 1214.5))
        let recorded = calls.all
        #expect(recorded.map(\.0) == ["taskkill", "-k"])
        let gap = recorded.count == 2 ? recorded[1].1 - recorded[0].1 : 0
        #expect(gap >= 15 && gap < 16.5)
        #expect(launcher.current?.wasTerminated == false)
    }

    @Test func aChangedEULAIsShownEvenThoughReadEulaIsSet() async throws {
        let fixture = GameFixture()
        fixture.addHost()
        fixture.addPrefix(eula: "OLDHASH")
        fixture.addGame()
        let clock = fixture.clock
        let launcher = FakeLauncher { _, _ in
            fixture.probe.setBusy(9000)
            clock.after(1) { Self.startLog(fixture, Fixtures.launcherStart) }
            clock.after(400) {
                fixture.setEULA(Fixtures.eulaHash)
                fixture.appendLauncherLog(Fixtures.eulaAccepted(seconds: 398) + Fixtures.finished)
            }
        }
        let runner = Self.closingRunner(fixture, launcher)
        let states = Recorder<(TimeInterval, ContentRunState)>()
        let outcome = try await service(fixture, runner: runner, launcher: launcher).runLauncher(.update) {
            states.append((clock.elapsed, $0))
        }
        #expect(outcome == .completed(seconds: 1214.5))
        #expect(launcher.commands.count == 1)
        let eulaTimes = states.all.filter { $0.1 == .needsEULA }.map(\.0)
        // Only once the step lingers (3 s); a step that passes at once never flashes the prompt.
        #expect(eulaTimes.first == 4)
        #expect(eulaTimes.count > 390)
    }

    @Test func withoutTheLogsWordTheEULAIsAssumedAfterTwentySeconds() async throws {
        let fixture = GameFixture()
        fixture.addHost()
        fixture.addPrefix(eula: nil)
        fixture.addLauncher()
        let clock = fixture.clock
        let launcher = FakeLauncher { _, process in
            fixture.probe.setBusy(9000)
            // DE reworded its step lines: nothing the rules know.
            clock.after(1) { Self.startLog(fixture, ["Current time: now", "Step ClientIP done"]) }
            clock.after(60) {
                process.exit(0)
                fixture.probe.setBusy(nil)
            }
        }
        let states = Recorder<(TimeInterval, ContentRunState)>()
        let configuration = ContentConfiguration(maximumRestarts: 0)
        let outcome = try await service(fixture, runner: Self.closingRunner(fixture, launcher), launcher: launcher,
                                        configuration: configuration).runLauncher(.install) {
            states.append((clock.elapsed, $0))
        }
        // Its last line came a second after launch: 20 quiet seconds later, said as a guess.
        #expect(states.all.first { $0.1 == .mayNeedEULA }?.0 == 21)
        #expect(!states.all.contains { $0.1 == .needsEULA }, "only the log's word makes it certain")
        // Without the log showing the EULA step, an exit is a crash, not a refusal.
        #expect(outcome == .stuck(.exited))
    }

    @Test func theEULAGuessWaitsWhileTheLauncherIsStillWriting() async throws {
        let fixture = GameFixture()
        fixture.addHost()
        fixture.addPrefix(eula: nil)
        fixture.addLauncher()
        let clock = fixture.clock
        let launcher = FakeLauncher { _, process in
            fixture.probe.setBusy(9000)
            // A slow first start (a self-check under FEX, say): a line every 10 s for two minutes, in words the
            // rules do not know; then it waits.
            clock.after(1) { Self.startLog(fixture, ["Current time: now"]) }
            clock.every(10, from: 10, count: 12) { step in fixture.appendLauncherLog(["Checking part \(step)"]) }
            clock.after(200) {
                process.exit(0)
                fixture.probe.setBusy(nil)
            }
        }
        let states = Recorder<(TimeInterval, ContentRunState)>()
        _ = try await service(fixture, runner: Self.closingRunner(fixture, launcher), launcher: launcher,
                              configuration: ContentConfiguration(maximumRestarts: 0)).runLauncher(.install) {
            states.append((clock.elapsed, $0))
        }
        // The last line came at 120 s; the guess comes 20 s later, never while lines keep coming.
        #expect(states.all.first { $0.1 == .mayNeedEULA }?.0 == 140)
    }

    @Test func theEULAGuessNeedsNoKnownLineOnlyALine() async throws {
        let fixture = GameFixture()
        fixture.addHost()
        fixture.addPrefix(eula: nil)
        fixture.addLauncher()
        let clock = fixture.clock
        let launcher = FakeLauncher { _, process in
            fixture.probe.setBusy(9000)
            // Every line reworded, the first one too: no rule matches anything.
            clock.after(1) { Self.startLog(fixture, ["Launcher 2.0 starting", "Step ClientIP done"]) }
            clock.after(60) {
                process.exit(0)
                fixture.probe.setBusy(nil)
            }
        }
        let states = Recorder<(TimeInterval, ContentRunState)>()
        _ = try await service(fixture, runner: Self.closingRunner(fixture, launcher), launcher: launcher,
                              configuration: ContentConfiguration(maximumRestarts: 0)).runLauncher(.install) {
            states.append((clock.elapsed, $0))
        }
        #expect(states.all.first { $0.1 == .mayNeedEULA }?.0 == 21)
    }

    @Test func waitingAtTheEULAPausesTheWatchdog() async throws {
        let fixture = GameFixture()
        fixture.addHost()
        fixture.addPrefix(eula: nil)
        fixture.addLauncher()
        let clock = fixture.clock
        let launcher = FakeLauncher { _, _ in
            fixture.probe.setBusy(9000)
            // DE reworded its lines: only the guess knows the EULA is up. The player reads it for 8 minutes.
            clock.after(1) { Self.startLog(fixture, ["Current time: now", "Step ClientIP done"]) }
            clock.after(480) {
                fixture.setEULA(Fixtures.eulaHash)
                fixture.appendLauncherLog(["EULA done"] + Fixtures.finished)
            }
        }
        let outcome = try await service(fixture, runner: Self.closingRunner(fixture, launcher), launcher: launcher)
            .runLauncher(.install) { _ in }
        #expect(outcome == .completed(seconds: 1214.5))
        #expect(launcher.commands.count == 1, "the player reading the EULA is not a stall")
    }

    @Test func aGuessedEULAPausesTheWatchdogForTenMinutesAtMost() async throws {
        let fixture = GameFixture()
        fixture.addHost()
        fixture.addPrefix(eula: nil)
        fixture.addLauncher()
        let clock = fixture.clock
        let launcher = FakeLauncher { _, _ in
            fixture.probe.setBusy(9000)
            // Reworded lines, then nothing ever again: a launcher hung at its start looks like one showing its EULA.
            clock.after(1) { Self.startLog(fixture, ["Current time: now", "Step ClientIP done"]) }
        }
        let states = Recorder<(TimeInterval, ContentRunState)>()
        let outcome = try await service(fixture, runner: Self.closingRunner(fixture, launcher), launcher: launcher,
                                        configuration: ContentConfiguration(maximumRestarts: 0)).runLauncher(.install) {
            states.append((clock.elapsed, $0))
        }
        let guessed = states.all.filter { $0.1 == .mayNeedEULA }.map(\.0)
        #expect(guessed.first == 21)
        // Ten minutes of guessing, then the watchdog's three minutes run: the hung launcher is not waited on for ever.
        #expect(guessed.last.map { $0 >= 619 && $0 <= 621 } == true, "\(guessed.last ?? 0)")
        #expect(outcome == .stuck(.stalled))
        #expect(clock.elapsed >= 799 && clock.elapsed <= 803, "\(clock.elapsed)")
        #expect(!states.all.contains { $0.1 == .needsEULA })
    }

    @Test func eachAttemptGuessesAgainButALoggedEULAIsNeverCapped() async throws {
        // A guessed EULA is capped per attempt: after a restart the new launcher gets its own ten minutes.
        let fixture = GameFixture()
        fixture.addHost()
        fixture.addPrefix(eula: nil)
        fixture.addLauncher()
        let clock = fixture.clock
        let launcher = FakeLauncher { _, _ in
            fixture.probe.setBusy(9000)
            clock.after(1) { Self.startLog(fixture, ["Current time: now", "Step ClientIP done"]) }
        }
        let states = Recorder<(TimeInterval, ContentRunState)>()
        let outcome = try await service(fixture, runner: Self.closingRunner(fixture, launcher), launcher: launcher,
                                        configuration: ContentConfiguration(maximumRestarts: 1)).runLauncher(.install) {
            states.append((clock.elapsed, $0))
        }
        #expect(outcome == .stuck(.stalled))
        #expect(launcher.commands.count == 2)
        let restart = try #require(states.all.first { if case .restartingLauncher = $0.1 { true } else { false } }?.0)
        #expect(states.all.contains { $0.1 == .mayNeedEULA && $0.0 > restart + 600 })

        // With the log's own word on the EULA step, the player may read for half an hour: never a stall.
        let logged = GameFixture()
        logged.addHost()
        logged.addPrefix(eula: nil)
        logged.addLauncher()
        let loggedClock = logged.clock
        let reader = FakeLauncher { _, _ in
            logged.probe.setBusy(9000)
            loggedClock.after(1) { Self.startLog(logged, Fixtures.launcherStart) }
            loggedClock.after(1800) {
                logged.setEULA(Fixtures.eulaHash)
                logged.appendLauncherLog(Fixtures.eulaAccepted(seconds: 1798) + Fixtures.finished)
            }
        }
        let readerStates = Recorder<ContentRunState>()
        let readerOutcome = try await service(logged, runner: Self.closingRunner(logged, reader), launcher: reader)
            .runLauncher(.install) { readerStates.append($0) }
        #expect(readerOutcome == .completed(seconds: 1214.5))
        #expect(reader.commands.count == 1, "thirty minutes at a logged EULA is not a stall")
        #expect(readerStates.all.filter { $0 == .needsEULA }.count > 1700)
        #expect(!readerStates.all.contains(.mayNeedEULA))
    }

    @Test func anUpdateCountsItsOwnBytes() async throws {
        let fixture = GameFixture()
        fixture.addHost()
        fixture.addPrefix(eula: Fixtures.eulaHash)
        fixture.addGame()
        fixture.files.setUsage(fixture.libraryPath, 52_000_000_000)
        let clock = fixture.clock
        let launcher = FakeLauncher { _, _ in
            fixture.probe.setBusy(9000)
            clock.after(1) {
                Self.startLog(fixture, Fixtures.launcherStart + Fixtures.eulaAccepted(seconds: 0) + ["Downloading @ 20 MB/s"])
            }
            clock.every(5, from: 5, count: 10) { _ in fixture.files.addUsage(fixture.libraryPath, 100_000_000) }
            clock.after(60) { fixture.appendLauncherLog(Fixtures.finished) }
        }
        let states = Recorder<ContentRunState>()
        _ = try await service(fixture, runner: Self.closingRunner(fixture, launcher), launcher: launcher)
            .runLauncher(.update) { states.append($0) }
        let downloads = states.all.compactMap { state -> (Int64, Int64, Int64?)? in
            guard case .downloading(let thisRun, let onDisk, let expected, _) = state else { return nil }
            return (thisRun, onDisk, expected)
        }
        #expect(!downloads.isEmpty)
        #expect(downloads.allSatisfy { $0.2 == nil && $0.1 - $0.0 == 52_000_000_000 })
        #expect(downloads.last?.0 == 1_000_000_000)
    }

    @Test func aBusyPrefixIsNeverTouched() async throws {
        let fixture = GameFixture()
        fixture.addHost()
        fixture.addPrefix(eula: Fixtures.eulaHash)
        fixture.addGame()
        fixture.probe.setBusy(31337)
        let launcher = FakeLauncher()
        await #expect(throws: ContentError.prefixNotReady([.prefixBusy(wineserver: 31337)])) {
            _ = try await service(fixture, runner: RecordingProcessRunner(), launcher: launcher).runLauncher(.update) { _ in }
        }
        #expect(launcher.commands.isEmpty)
    }

    @Test func anUpdateNeedsAnInstalledGame() async throws {
        let fixture = GameFixture()
        fixture.addHost()
        fixture.addPrefix(eula: Fixtures.eulaHash)
        fixture.addLauncher()
        await #expect(throws: ContentError.notInstalled) {
            _ = try await service(fixture, runner: RecordingProcessRunner(), launcher: FakeLauncher()).update { _ in }
        }
    }

    @Test func cancellingClosesDEsLauncher() async throws {
        let fixture = GameFixture()
        fixture.addHost()
        fixture.addPrefix(eula: Fixtures.eulaHash)
        fixture.addGame()
        let clock = fixture.clock
        let handle = Mutex<Task<LauncherRunOutcome, any Error>?>(nil)
        let launcher = FakeLauncher { _, _ in
            fixture.probe.setBusy(9000)
            clock.after(30) { handle.withLock { $0?.cancel() } }
        }
        let runner = Self.closingRunner(fixture, launcher)
        let service = service(fixture, runner: runner, launcher: launcher)
        let task = Task { try await service.runLauncher(.update) { _ in } }
        handle.withLock { $0 = task }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(runner.commandLines == Self.closeCommands)
    }

    // MARK: - Warframe.msi

    /// What Wine's administrative install leaves in TARGETDIR; nil for any other command.
    static func simulateMsiexec(_ fixture: GameFixture, exitCode: Int32 = 0) -> @Sendable (Command) -> ProcessOutput? {
        let library = fixture.libraryPath
        return { command in
            guard command.arguments.first == "msiexec" else { return nil }
            guard exitCode == 0 else { return ProcessOutput(exitCode: exitCode) }
            let extracted = library + "/LocalAppDataFolder/Warframe/Downloaded/Public"
            fixture.fileSystem.addFile(extracted + "/Tools/Launcher.exe", "new launcher")
            fixture.fileSystem.addFile(extracted + "/Tools/Windows/x64/steam_api64.dll", "PE")
            fixture.fileSystem.addFile(extracted + "/Lotus/Language/EULA_en.rtf", "rtf")
            fixture.fileSystem.addFile(library + "/warzag-Warframe.msi", "package copy")
            return ProcessOutput(exitCode: 0)
        }
    }

    func extractionFixture(msiexecExit: Int32 = 0) -> (GameFixture, RecordingProcessRunner) {
        let fixture = GameFixture()
        fixture.addHost()
        fixture.addPrefix()
        fixture.fileSystem.addFile("/Users/tenno/Downloads/Warframe.msi", "MSI")
        let msiexec = Self.simulateMsiexec(fixture, exitCode: msiexecExit)
        return (fixture, RecordingProcessRunner { msiexec($0) ?? ProcessOutput(exitCode: 0) })
    }

    /// The installer "MSI" as `InstallerSource` hands it over: checked, with its SHA-256.
    static let verifiedInstaller = VerifiedInstaller(
        url: URL(filePath: "/Users/tenno/Downloads/Warframe.msi"), bytes: 3,
        sha256: "f936c64eb2f99967d11cb14160b66ebfd6ce719a7ced875dcfc425e0b7c6aa0a",
        authenticode: .trusted(signer: InstallerExpectations.signer))

    @Test func theInstallerIsUnpackedIntoTheSteamLayout() async throws {
        let (fixture, runner) = extractionFixture()
        try await service(fixture, runner: runner, launcher: FakeLauncher()).extractInstaller(Self.verifiedInstaller)

        #expect(runner.commandLines == [#"wine msiexec /a C:\windows\temp\warzag-Warframe.msi /qn TARGETDIR=X:\"#])
        let environment = try #require(runner.commands.first?.environment)
        #expect(environment["WINEDLLPATH"] == nil && environment["WINEDLLPATH_PREPEND"] == nil)
        #expect(environment["WINEPREFIX"] == fixture.prefixPath && environment["NEUTRON_MSYNC"] == "0")
        let library = fixture.libraryPath
        #expect(fixture.fileSystem.text(at: library + "/Tools/Launcher.exe") == "new launcher")
        #expect(fixture.fileSystem.fileExists(at: URL(filePath: library + "/Tools/Windows/x64/steam_api64.dll")))
        #expect(fixture.fileSystem.fileExists(at: URL(filePath: library + "/Lotus/Language/EULA_en.rtf")))
        #expect(!fixture.fileSystem.fileExists(at: URL(filePath: library + "/LocalAppDataFolder")))
        #expect(!fixture.fileSystem.fileExists(at: URL(filePath: library + "/warzag-Warframe.msi")))
        #expect(!fixture.fileSystem.fileExists(at: URL(filePath: fixture.prefixPath + "/drive_c/windows/temp/warzag-Warframe.msi")))
        #expect(fixture.fileSystem.text(at: "/Users/tenno/Downloads/Warframe.msi") == "MSI")
    }

    @Test func unpackingAgainRepairsToolsAndKeepsTheRest() async throws {
        let (fixture, runner) = extractionFixture()
        let library = fixture.libraryPath
        fixture.fileSystem.addFile(library + "/Tools/Launcher.exe", "damaged")
        fixture.fileSystem.addFile(library + "/Tools/CachePlan.txt", "kept")
        fixture.fileSystem.addFile(library + "/Warframe.x64.exe", "game")
        try await service(fixture, runner: runner, launcher: FakeLauncher()).extractInstaller(Self.verifiedInstaller)
        #expect(fixture.fileSystem.text(at: library + "/Tools/Launcher.exe") == "new launcher")
        #expect(fixture.fileSystem.text(at: library + "/Tools/CachePlan.txt") == "kept")
        #expect(fixture.fileSystem.text(at: library + "/Warframe.x64.exe") == "game")
    }

    @Test func aFailedAdministrativeInstallIsReported() async throws {
        let (fixture, runner) = extractionFixture(msiexecExit: 1603)
        await #expect(throws: ContentError.extractionFailed("msiexec exited with status 1603")) {
            try await service(fixture, runner: runner, launcher: FakeLauncher()).extractInstaller(Self.verifiedInstaller)
        }
        #expect(!fixture.fileSystem.fileExists(at: URL(filePath: fixture.prefixPath + "/drive_c/windows/temp/warzag-Warframe.msi")))
    }

    @Test func aStagedCopyThatIsNotTheVerifiedFileIsRefused() async throws {
        let (fixture, runner) = extractionFixture()
        // The download was replaced after it was checked.
        fixture.fileSystem.addFile("/Users/tenno/Downloads/Warframe.msi", "MSJ")
        await #expect(throws: ContentError.stagedInstallerChanged(
            expected: Self.verifiedInstaller.sha256,
            actual: "4d3fc3ff0e2c132ee18d6bc45722b84b8fc0cbfc8c2d18402458dd65416d62c6")) {
            try await service(fixture, runner: runner, launcher: FakeLauncher()).extractInstaller(Self.verifiedInstaller)
        }
        #expect(runner.commands.isEmpty)
        #expect(!fixture.fileSystem.fileExists(at: URL(filePath: fixture.prefixPath + "/drive_c/windows/temp/warzag-Warframe.msi")))
    }

    @Test func aHungMsiexecIsStoppedAndReported() async throws {
        let (fixture, _) = extractionFixture()
        let runner = RecordingProcessRunner { command in
            if command.arguments.first == "msiexec" {
                throw ProcessTimedOut(command: command.description, timeout: command.timeout ?? .zero)
            }
            return ProcessOutput(exitCode: 0)
        }
        await #expect(throws: ContentError.extractionFailed("msiexec did not finish within 900 s and was stopped")) {
            try await service(fixture, runner: runner, launcher: FakeLauncher()).extractInstaller(Self.verifiedInstaller)
        }
        #expect(runner.commandLines.last == "wineserver -k")
        #expect(fixture.fileSystem.text(at: "/Users/tenno/Library/Logs/Warzag/wine-tools.log")?
            .contains("warzag: msiexec /a did not finish within 900 s and was stopped") == true)
    }

    @Test func cancellingWhileMsiexecRunsStopsThePrefix() async throws {
        let (fixture, _) = extractionFixture()
        // SystemProcessRunner stops msiexec when its task is cancelled and throws CancellationError; what msiexec
        // started may still write into the library. A cancelled task starts nothing, so wineserver -k must come from
        // a task the cancellation does not reach.
        let runner = RecordingProcessRunner { command in
            if Task.isCancelled { throw CancellationError() }
            guard command.arguments.first == "msiexec" else { return ProcessOutput(exitCode: 0) }
            withUnsafeCurrentTask { $0?.cancel() }
            throw CancellationError()
        }
        let service = service(fixture, runner: runner, launcher: FakeLauncher())
        let task = Task { try await service.extractInstaller(Self.verifiedInstaller) }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(runner.commandLines == [#"wine msiexec /a C:\windows\temp\warzag-Warframe.msi /qn TARGETDIR=X:\"#,
                                        "wineserver -k"])
        #expect(fixture.fileSystem.text(at: "/Users/tenno/Library/Logs/Warzag/wine-tools.log")?
            .contains("warzag: cancelled while msiexec /a ran; stopping the prefix") == true)
        #expect(fixture.fileSystem.text(at: "/Users/tenno/Library/Logs/Warzag/wine-tools.log")?
            .contains("could not run") == false, "wineserver -k ran outside the cancelled task")
        #expect(!fixture.fileSystem.fileExists(at: URL(filePath: fixture.prefixPath + "/drive_c/windows/temp/warzag-Warframe.msi")))
    }

    @Test func aRunnerReturningWhileCancelledStillStopsThePrefix() async throws {
        let (fixture, _) = extractionFixture()
        // Cancelled just as msiexec ended: the runner returns its status, but nothing may go on into the library.
        let runner = RecordingProcessRunner { command in
            guard command.arguments.first == "msiexec" else { return ProcessOutput(exitCode: 0) }
            withUnsafeCurrentTask { $0?.cancel() }
            return ProcessOutput(exitCode: 0)
        }
        let service = service(fixture, runner: runner, launcher: FakeLauncher())
        let task = Task { try await service.extractInstaller(Self.verifiedInstaller) }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(runner.commandLines.last == "wineserver -k")
    }

    // MARK: - DirectX 11

    /// A user.reg whose launcher keys have `launcherAPI` / `steamLauncherAPI` as GraphicsAPI (nil: no such value).
    static func registry(launcherAPI: UInt32?, steamLauncherAPI: UInt32? = nil) -> String {
        var text = Fixtures.userReg(eula: Fixtures.eulaHash, launcherOverrides: true, steam: true)
            .replacingOccurrences(of: "\"GraphicsAPI\"=dword:00000000\n", with: "")
        if let launcherAPI {
            text = text.replacingOccurrences(of: "\"Language\"=\"en\"\n",
                                             with: "\"GraphicsAPI\"=dword:\(String(format: "%08x", launcherAPI))\n\"Language\"=\"en\"\n")
        }
        if let steamLauncherAPI {
            text = text.replacingOccurrences(of: "\"ReadCba\"=\"\"\n",
                                             with: "\"GraphicsAPI\"=dword:\(String(format: "%08x", steamLauncherAPI))\n\"ReadCba\"=\"\"\n")
        }
        return text
    }

    /// A runner that records what each reg import was given (the staged file is gone afterwards).
    static func registryRunner(_ fixture: GameFixture, imported: Recorder<String>,
                               exitCode: Int32 = 0) -> RecordingProcessRunner {
        RecordingProcessRunner { command in
            if command.arguments.first == "reg" {
                let staged = fixture.prefixPath + "/drive_c/windows/temp/warzag-directx11.reg"
                imported.append(fixture.fileSystem.text(at: staged) ?? "")
                return ProcessOutput(exitCode: exitCode)
            }
            return ProcessOutput(exitCode: 0)
        }
    }

    @Test func directX11IsWrittenForALauncherThatNeverRan() async throws {
        let fixture = GameFixture()
        fixture.addHost()
        fixture.addPrefix(eula: Fixtures.eulaHash)
        fixture.fileSystem.addFile(fixture.userReg, Self.registry(launcherAPI: nil))
        let imported = Recorder<String>()
        let runner = Self.registryRunner(fixture, imported: imported)
        let wrote = try await service(fixture, runner: runner, launcher: FakeLauncher()).pinDirectX11()
        #expect(wrote)
        #expect(runner.commandLines == [#"wine reg import C:\windows\temp\warzag-directx11.reg"#])
        #expect(runner.commands.first?.timeout == .seconds(120))
        let file = try #require(imported.all.first)
        #expect(file.contains(#"[HKEY_CURRENT_USER\Software\Digital Extremes\Warframe\Launcher]"#))
        #expect(file.contains(#""GraphicsAPI"=dword:00000000"#))
        #expect(!file.contains("SteamLauncher"), "SteamLauncher keeps whatever DE wrote unless it names another API")
        #expect(!fixture.fileSystem.fileExists(at: URL(filePath: fixture.prefixPath + "/drive_c/windows/temp/warzag-directx11.reg")))
    }

    @Test func anotherGraphicsAPIIsChangedBackAndDirectX11IsLeftAlone() async throws {
        let fixture = GameFixture()
        fixture.addHost()
        fixture.addPrefix(eula: Fixtures.eulaHash)
        fixture.fileSystem.addFile(fixture.userReg, Self.registry(launcherAPI: 1, steamLauncherAPI: 2))
        let imported = Recorder<String>()
        let runner = Self.registryRunner(fixture, imported: imported)
        #expect(try await service(fixture, runner: runner, launcher: FakeLauncher()).pinDirectX11())
        let file = try #require(imported.all.first)
        #expect(file.contains(#"[HKEY_CURRENT_USER\Software\Digital Extremes\Warframe\Launcher]"#))
        #expect(file.contains(#"[HKEY_CURRENT_USER\Software\Digital Extremes\Warframe\SteamLauncher]"#))
        #expect(!file.contains("dword:00000001") && !file.contains("dword:00000002"))

        // Already DirectX 11 (the usual case): nothing is written and Wine never runs.
        let pinned = GameFixture()
        pinned.addHost()
        pinned.addPrefix(eula: Fixtures.eulaHash)
        let quiet = RecordingProcessRunner()
        #expect(try await service(pinned, runner: quiet, launcher: FakeLauncher()).pinDirectX11() == false)
        #expect(quiet.commands.isEmpty)
    }

    @Test func aFailedPinThrowsAndAHungOneStopsThePrefix() async throws {
        let fixture = GameFixture()
        fixture.addHost()
        fixture.addPrefix(eula: Fixtures.eulaHash)
        fixture.fileSystem.addFile(fixture.userReg, Self.registry(launcherAPI: nil))
        let failing = Self.registryRunner(fixture, imported: Recorder<String>(), exitCode: 1)
        await #expect(throws: ContentError.directX11NotPinned("reg import exited with status 1")) {
            _ = try await service(fixture, runner: failing, launcher: FakeLauncher()).pinDirectX11()
        }
        let hung = RecordingProcessRunner { command in
            if command.arguments.first == "reg" {
                throw ProcessTimedOut(command: command.description, timeout: command.timeout ?? .zero)
            }
            return ProcessOutput(exitCode: 0)
        }
        await #expect(throws: ContentError.directX11NotPinned("reg import did not finish within 120 s")) {
            _ = try await service(fixture, runner: hung, launcher: FakeLauncher()).pinDirectX11()
        }
        #expect(hung.commandLines.last == "wineserver -k")
    }

    @Test func everyLauncherRunStartsOnDirectX11() async throws {
        let fixture = GameFixture()
        fixture.addHost()
        fixture.addPrefix(eula: nil)
        fixture.addLauncher()
        fixture.fileSystem.addFile(fixture.userReg, Self.registry(launcherAPI: nil))
        let clock = fixture.clock
        let imported = Recorder<String>()
        let order = Recorder<String>()
        let launcher = FakeLauncher { _, process in
            order.append("launcher")
            fixture.probe.setBusy(9000)
            clock.after(1) { Self.startLog(fixture, Fixtures.launcherStart + Fixtures.eulaAccepted(seconds: 0) + Fixtures.finished) }
            _ = process
        }
        let runner = RecordingProcessRunner { command in
            if command.arguments.first == "reg" {
                order.append("reg import")
                imported.append(fixture.fileSystem.text(at: fixture.prefixPath + "/drive_c/windows/temp/warzag-directx11.reg") ?? "")
            }
            if command.arguments.first == "taskkill" {
                launcher.current?.exit(0)
                fixture.probe.setBusy(nil)
            }
            if command.arguments == ["-k"] { fixture.probe.setBusy(nil) }
            return ProcessOutput(exitCode: 0)
        }
        let outcome = try await service(fixture, runner: runner, launcher: launcher).runLauncher(.install) { _ in }
        #expect(outcome == .completed(seconds: 1214.5))
        #expect(order.all == ["reg import", "launcher"], "DirectX 11 before DE's launcher reads its settings")
        #expect(imported.all.first?.contains(#""GraphicsAPI"=dword:00000000"#) == true)
    }

    @Test func aLauncherRunGoesOnWhenThePinFails() async throws {
        let fixture = GameFixture()
        fixture.addHost()
        fixture.addPrefix(eula: Fixtures.eulaHash)
        fixture.addGame()
        fixture.fileSystem.addFile(fixture.userReg, Self.registry(launcherAPI: 1))
        let clock = fixture.clock
        let launcher = FakeLauncher { _, _ in
            fixture.probe.setBusy(9000)
            clock.after(1) { Self.startLog(fixture, Fixtures.launcherStart + Fixtures.eulaAccepted(seconds: 0) + Fixtures.finished) }
        }
        let runner = RecordingProcessRunner { command in
            if command.arguments.first == "reg" { return ProcessOutput(exitCode: 5) }
            if command.arguments.first == "taskkill" {
                launcher.current?.exit(0)
                fixture.probe.setBusy(nil)
            }
            if command.arguments == ["-k"] { fixture.probe.setBusy(nil) }
            return ProcessOutput(exitCode: 0)
        }
        let states = Recorder<ContentRunState>()
        let outcome = try await service(fixture, runner: runner, launcher: launcher).runLauncher(.update) {
            states.append($0)
        }
        #expect(outcome == .completed(seconds: 1214.5))
        #expect(states.all.first == .warning("could not keep DE's launcher on DirectX 11: reg import exited with status 5"))
        #expect(launcher.commands.count == 1)
    }

    @Test func aCancellationDuringTheCloseStillClosesDEsLauncher() async throws {
        let fixture = GameFixture()
        fixture.addHost()
        fixture.addPrefix(eula: Fixtures.eulaHash)
        fixture.addGame()
        let clock = fixture.clock
        let launcher = FakeLauncher { _, _ in
            fixture.probe.setBusy(9000)
            clock.after(1) {
                Self.startLog(fixture, Fixtures.launcherStart + Fixtures.eulaAccepted(seconds: 0) + Fixtures.finished)
            }
        }
        // Like SystemProcessRunner, this runner starts nothing for a cancelled task. Warzag is quitting just as DE's
        // launcher finished: the close must still reach it.
        let runner = RecordingProcessRunner { command in
            if Task.isCancelled { throw CancellationError() }
            if command.arguments.first == "taskkill" {
                launcher.current?.exit(0)
                fixture.probe.setBusy(nil)
            }
            if command.arguments == ["-k"] { fixture.probe.setBusy(nil) }
            return ProcessOutput(exitCode: 0)
        }
        let service = service(fixture, runner: runner, launcher: launcher)
        let run = Task {
            try await service.runLauncher(.update) { state in
                // Reported from the run's own task, right before the close.
                if state == .closingLauncher { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        _ = try? await run.value
        #expect(run.isCancelled)
        #expect(runner.commandLines == Self.closeCommands)
        #expect(launcher.current?.wasTerminated == false, "closed by WM_CLOSE, not left to SIGTERM")
    }

    @Test func aHungTaskkillIsReportedAndTheCloseGoesOn() async throws {
        let fixture = GameFixture()
        fixture.addHost()
        fixture.addPrefix(eula: Fixtures.eulaHash)
        fixture.addGame()
        let clock = fixture.clock
        let launcher = FakeLauncher { _, _ in
            fixture.probe.setBusy(9000)
            clock.after(1) {
                Self.startLog(fixture, Fixtures.launcherStart + Fixtures.eulaAccepted(seconds: 0) + Fixtures.finished)
            }
        }
        let runner = RecordingProcessRunner { command in
            if command.arguments.first == "taskkill" {
                throw ProcessTimedOut(command: command.description, timeout: command.timeout ?? .zero)
            }
            if command.arguments == ["-k"] {
                launcher.current?.exit(nil)
                fixture.probe.setBusy(nil)
            }
            return ProcessOutput(exitCode: 0)
        }
        let states = Recorder<ContentRunState>()
        let outcome = try await service(fixture, runner: runner, launcher: launcher).runLauncher(.update) {
            states.append($0)
        }
        #expect(outcome == .completed(seconds: 1214.5))
        #expect(runner.commandLines == Self.closeCommands)
        #expect(states.all.contains(.warning("taskkill /IM Launcher.exe did not finish within 60 s and was stopped")))
        #expect(runner.commands.allSatisfy { $0.timeout != nil })
    }

    @Test func installUnpacksThenRunsTheLauncher() async throws {
        let (fixture, _) = extractionFixture()
        fixture.setEULA(Fixtures.eulaHash)
        let clock = fixture.clock
        let launcher = FakeLauncher { _, _ in
            fixture.probe.setBusy(9000)
            clock.after(2) {
                Self.startLog(fixture, Fixtures.launcherStart + Fixtures.eulaAccepted(seconds: 0) + Fixtures.finished)
            }
        }
        let msiexec = Self.simulateMsiexec(fixture)
        let runner = RecordingProcessRunner { command in
            if let output = msiexec(command) { return output }
            if command.arguments.first == "taskkill" { launcher.current?.exit(0) }
            if command.arguments == ["-k"] { fixture.probe.setBusy(nil) }
            return ProcessOutput(exitCode: 0)
        }
        let installer = StaticInstaller(url: URL(filePath: "/Users/tenno/Downloads/Warframe.msi"),
                                        sha256: Self.verifiedInstaller.sha256)
        let states = Recorder<ContentRunState>()
        let outcome = try await service(fixture, runner: runner, launcher: launcher)
            .install(installer: installer) { states.append($0) }
        #expect(outcome == .completed(seconds: 1214.5))
        #expect(runner.commandLines == [#"wine msiexec /a C:\windows\temp\warzag-Warframe.msi /qn TARGETDIR=X:\"#]
            + Self.closeCommands)
        #expect(states.all.prefix(2) == [.extractingInstaller, .startingLauncher(attempt: 0)])
    }

    // MARK: - Status

    func statusFixture() -> GameFixture {
        let fixture = GameFixture()
        fixture.addHost()
        fixture.addPrefix(eula: Fixtures.eulaHash)
        return fixture
    }

    func status(_ fixture: GameFixture) -> ContentStatus {
        service(fixture, runner: RecordingProcessRunner(), launcher: FakeLauncher()).status()
    }

    @Test func notInstalledUntilTheGameIsDownloaded() {
        let fixture = statusFixture()
        #expect(status(fixture).state == .notInstalled)
        #expect(status(fixture).reason == "Warframe.msi has not been unpacked into the library yet")
        fixture.addLauncher()
        #expect(status(fixture).reason == "DE's launcher has not downloaded the game yet")
        #expect(status(fixture).launcherPresent && !status(fixture).gamePresent)
    }

    @Test func installedAfterARecentUpdateAndStaleADayLater() async throws {
        let fixture = statusFixture()
        fixture.addGame()
        fixture.files.setUsage(fixture.libraryPath, 53_347_147_776)
        service(fixture, runner: RecordingProcessRunner(), launcher: FakeLauncher()).recordUpdate(mode: .update, seconds: 30)
        var current = status(fixture)
        #expect(current.state == .installed)
        #expect(current.lastUpdate == fixture.clock.now && current.lastUpdateSource == "warzag")
        #expect(current.libraryBytes == 53_347_147_776)
        #expect(current.reason == "the last update finished less than an hour ago")
        try await fixture.clock.sleep(for: .seconds(25 * 3600))
        current = status(fixture)
        #expect(current.state == .needsUpdate)
        #expect(current.reason == "the last update finished 25 hours ago; DE may have released one since")
    }

    @Test func anUnfinishedLauncherRunNeedsAnUpdate() {
        let fixture = statusFixture()
        fixture.addGame()
        service(fixture, runner: RecordingProcessRunner(), launcher: FakeLauncher()).recordUpdate(mode: .update, seconds: 30)
        // An earlier finished run, then a new run in the same file that never got to "Total time:".
        fixture.appendLauncherLog(["Current time: a", "Total time: 30.0 seconds", "Current time: b", "Downloading @ 3 MB/s"])
        #expect(status(fixture).state == .needsUpdate)
        #expect(status(fixture).reason == "the last run of DE's launcher did not finish")
        fixture.appendLauncherLog(["Total time: 99.0 seconds"])
        #expect(status(fixture).state == .installed)
    }

    @Test func aRecordForAnotherLibraryIsIgnored() throws {
        let fixture = statusFixture()
        fixture.addGame()
        let other = """
            {"schema":1,"library":"/Volumes/Other/Warframe.noindex","lastUpdate":"2026-10-16T16:59:09Z","mode":"install"}
            """
        fixture.fileSystem.addFile("/Users/tenno/Library/Application Support/Warzag/State/content.json", other)
        #expect(status(fixture).lastUpdate == nil)
        #expect(status(fixture).reason == "no finished update is recorded")
        // DE's own log still counts when it says the last run finished.
        fixture.appendLauncherLog(Fixtures.launcherStart + Fixtures.finished)
        #expect(status(fixture).state == .installed)
    }

    @Test(arguments: [(0, "less than an hour"), (3600, "1 hour"), (7 * 3600, "7 hours"), (72 * 3600, "3 days")]
        as [(TimeInterval, String)])
    func ages(_ seconds: TimeInterval, _ text: String) {
        #expect(ContentService.ageText(seconds) == text)
    }
}

/// An installer that is already on disk and checked.
struct StaticInstaller: InstallerProviding {
    var url: URL
    var sha256: String

    func installer(progress: @escaping @Sendable (ContentRunState) -> Void) async throws -> VerifiedInstaller {
        VerifiedInstaller(url: url, bytes: 3, sha256: sha256, authenticode: .unavailable("test"))
    }
}
