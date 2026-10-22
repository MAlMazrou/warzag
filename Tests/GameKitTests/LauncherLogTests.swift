import ContentKit
import Foundation
import Testing
@testable import GameKit

@Suite struct LauncherLogTests {
    let parser = LogParser(kind: .launcher, rules: LauncherLog.ruleSet)

    func events(_ lines: [String]) -> [LauncherEvent] {
        lines.compactMap(parser.event(for:)).map(LauncherEvent.init)
    }

    @Test func everyLauncherLineShape() {
        #expect(events([
            "Current time: Fri Oct 16 20:38:54 2026 [UTC Fri Oct 16 16:38:54 2026]",
            "Downloading @ 44 MB/s",
            "Finished BinariesBP_BULK (1184.9 seconds)",
            "Downloaded 52,514,328,367 bytes total ~ 44,318,693 B/s",
            #""X:\Warframe.x64.exe" -silent -log:/Preprocess.log -graphicsDriver:dx11 -cluster:public -language:en -applet:/EE/Types/Framework/ContentUpdate"#,
            "22.425 Sys [Info]: Downloaded 28680444/73617644",
            "Process returned 0",
            "Finished Preprocess (24.7 seconds)",
            "Total time: 1214.5 seconds",
            "54.1 Sys [Info]: The update will be restarted shortly...",
            "54.1 Sys [Error]: Downloaded data was corrupted.",
        ]) == [
            .runStarted, .rate(megabytesPerSecond: 44), .phaseFinished("BinariesBP_BULK", seconds: 1184.9),
            .bytesTotal(52_514_328_367), .appletStarted,
            .content(.launcherDownloaded(downloaded: 28_680_444, total: 73_617_644)),
            .appletExited(code: 0), .phaseFinished("Preprocess", seconds: 24.7), .totalTime(seconds: 1214.5),
            .content(.updateRestarting), .content(.downloadCorrupted),
        ])
    }

    @Test func mirroredEngineLinesAreNotLauncherSteps() {
        // The applet's own log is mirrored into Launcher.log with engine timestamps; none of it is a launcher step.
        #expect(events([
            "0.167 Sys [Diag]: Process Command-line: -silent -log:/Preprocess.log -graphicsDriver:dx11 -cluster:public -language:en -applet:/EE/Types/Framework/ContentUpdate",
            "0.177 Sys [Diag]: Current time: Fri Oct 16 20:58:45 2026 [UTC: Fri Oct 16 16:58:45 2026]",
            "9.785 Sys [Info]: Finished load of Flyweight batch (1) [0.00s and 0 frames at 3 ms/frame avg, 4 ms/update peak], 1/1/1, 5 item(s), 0k total so far, 0.00% utilization",
            "9.944 Sys [Info]: Startup time: 9.94s",
            "24.168 Sys [Info]: Copied 120,934,425 bytes at 8.14 MB/s",
            "Sys [Info]: All smart pointers were destroyed!",
            "HTTP GET /Warframe.x64.exe.AF84E6612C009ECEF51ABC23814BA7E2.lzma",
            #"Hashing X:\Tools\Launcher.exe..."#,
        ]).isEmpty)
    }

    @Test func aWholeFirstInstallMovesThroughEveryPhase() {
        var state = LauncherLogState()
        var phases: [LauncherPhase] = [state.phase]
        func feed(_ lines: [String]) {
            for event in events(lines) { state.apply(event) }
            phases.append(state.phase)
        }
        feed(Array(Fixtures.launcherStart.prefix(5)))
        #expect(!state.reachedEULAStep)
        feed(Array(Fixtures.launcherStart.dropFirst(5)))
        #expect(state.atEULAStep)
        feed(Fixtures.eulaAccepted(seconds: 31.5) + ["Downloading @ 19 MB/s"])
        #expect(state.megabytesPerSecond == 19)
        feed(["Downloaded 37,773,807 bytes total ~ 17,734,181 B/s", "Finished BinariesBP_DEFAULT (2.2 seconds)"])
        #expect(state.megabytesPerSecond == nil)
        feed(["Downloading @ 44 MB/s", "Downloading @ 49 MB/s"])
        feed(Fixtures.bulkFinished)
        #expect(state.bytesDownloaded == 52_514_328_367 + 37_773_807)
        feed(Fixtures.appletLines)
        feed(Array(Fixtures.finished.dropLast()))
        #expect(state.appletExitCode == 0)
        feed(Array(Fixtures.finished.suffix(1)))
        #expect(state.isComplete && state.totalSeconds == 1214.5)
        #expect(phases == [.starting, .starting, .eula, .downloading, .downloading, .downloading, .preprocessing,
                           .preprocessing, .finishing, .complete])
        #expect(state.finishedSteps.prefix(9) == ["ClientIP", "Platform", "PickDirectory", "Firewall", "GameRunning",
                                                  "BinariesBP_CEF", "BinariesBP_LAUNCHER", "EULA", "DirectX"])
    }

    @Test func theAppletsCountersGiveThePreprocessFraction() {
        var state = LauncherLogState()
        let preprocess = LogParser(kind: .preprocess)
        state.apply(.appletStarted)
        for line in Fixtures.appletLines.prefix(2) {
            if let event = preprocess.event(for: line) { state.applyApplet(event) }
        }
        #expect(state.applet.fraction == 1_520_265.0 / 73_617_644)
        state.applyApplet(.downloadCorrupted)
        #expect(state.corruptionReported)
    }

    @Test func aNewRunOrAReplacedLogStartsOver() {
        var state = LauncherLogState()
        for event in events(Fixtures.launcherStart + Fixtures.eulaAccepted(seconds: 0)) { state.apply(event) }
        #expect(state.eulaFinished)
        state.apply(.runStarted)
        #expect(state == { var fresh = LauncherLogState(); fresh.apply(.runStarted); return fresh }())
        for event in events(Fixtures.launcherStart) { state.apply(event) }
        state.apply(.content(.logRestarted))
        #expect(state.finishedSteps.isEmpty && state.phase == .starting)
    }

    @Test func rulesAllCompile() {
        #expect(parser.invalidRules.isEmpty)
        #expect(Set(LauncherLog.rules.map(\.signal)) == Set(LauncherLog.Signal.allCases.map(\.rawValue)))
    }
}
