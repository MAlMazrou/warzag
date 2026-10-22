import Foundation
import Synchronization
import Testing
import WarzagCore
import WarzagTestSupport
@testable import warzagctl

/// A clock whose sleeps run the next step of a script (Steam writing a line while warzagctl follows) and then
/// return at once.
final class ScriptedSleepClock: WallClock {
    private let state: Mutex<(now: Date, steps: [@Sendable () -> Void])>

    init(now: Date, steps: [@Sendable () -> Void]) {
        state = Mutex((now, steps))
    }

    var now: Date { state.withLock { $0.now } }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        let step = state.withLock { state -> (@Sendable () -> Void)? in
            state.now = state.now.addingTimeInterval(Double(duration.components.seconds))
            return state.steps.isEmpty ? nil : state.steps.removeFirst()
        }
        step?()
    }
}

final class OutputRecorder: Sendable {
    private let lines = Mutex<[String]>([])
    var text: String { lines.withLock { $0.joined() } }

    var output: GameCommands.Output {
        GameCommands.Output(write: { text in self.lines.withLock { $0.append(text) } },
                            warn: { text in self.lines.withLock { $0.append("warn: " + text) } })
    }
}

@Suite struct SteamTimelineCommandTests {
    let fileSystem = InMemoryFileSystem()
    let utc = TimeZone(identifier: "UTC")!
    /// 2026-10-16 18:00:00 UTC.
    let start = Date(timeIntervalSince1970: 1_792_173_600)

    var context: CommandContext {
        let home = URL(filePath: "/Users/tenno", directoryHint: .isDirectory)
        return CommandContext(
            paths: WarzagPaths(home: home, userCacheDirectory: URL(filePath: "/var/folders/xy/C", directoryHint: .isDirectory)),
            steam: .init(home: home, systemApplications: URL(filePath: "/Applications", directoryHint: .isDirectory)),
            fileSystem: fileSystem, processes: FakeProcessInspector(), system: FakeSystemInfo.mac(
                chip: "Apple M2", model: "Mac14,15", product: nil, performanceCores: 4, efficiencyCores: 4,
                gpuCores: 10, memoryGB: 16),
            inheritedEnvironment: ["HOME": "/Users/tenno"],
            currentDirectory: URL(filePath: "/Users/tenno", directoryHint: .isDirectory), timeZone: utc)
    }

    var logs: URL { context.steam.logsDirectory }

    /// A rendered line: the time from now in 10 columns, the gap to the line before in 8, the tokens.
    func line(_ when: String, _ gap: String, _ text: String) -> String {
        when.padding(toLength: 10, withPad: " ", startingAt: 0) + gap.padding(toLength: 8, withPad: " ", startingAt: 0)
            + text + "\n"
    }

    func stamp(_ seconds: Int) -> String {
        let total = 18 * 3600 + seconds
        return String(format: "[2026-10-16 %02d:%02d:%02d]", total / 3600 % 24, total / 60 % 60, total % 60)
    }

    @Test func theLastHourAsTokensTimedFromNow() async {
        fileSystem.addFile(logs.appending(path: "bootstrap_log.txt").plainPath,
                           "\(stamp(-7200)) Startup - Steam Client launched with: '/Users/tenno/x/steam_osx'\n"
                           + "\(stamp(0)) Startup - Steam Client launched with: '/Users/tenno/x/steam_osx' '-silent'\n")
        fileSystem.addFile(logs.appending(path: "steamui_login.txt").plainPath,
                           "\(stamp(61)) [ Success ] SetLoginState: WaitingForCredentials - Logged In Elsewhere\r\n")
        fileSystem.addFile(context.paths.logs.appending(path: "Warzag.log").plainPath,
                           "\(start.addingTimeInterval(59).formatted(.iso8601)) play: start (Steam, balanced)\n")
        let clock = ManualClock(now: start.addingTimeInterval(120))
        let result = await SteamCommands.timeline(minutes: 60, follow: false, context, output: OutputRecorder().output,
                                                  clock: clock)
        #expect(result.exitCode == 0)
        #expect(result.stdout == "Steam timeline, the last 60 min (times from now; fixed tokens only, no IDs, names or "
            + "paths)\n" + line("-2:00", "", "steam: started (-silent: yes)")
            + line("-1:01", "+59s", "warzag: play: start (Steam, balanced)")
            + line("-0:59", "+2s", "login: WaitingForCredentials - Logged In Elsewhere"))
        #expect(clock.sleeps.isEmpty)

        let none = await SteamCommands.timeline(minutes: 1, follow: false, context, output: OutputRecorder().output,
                                                clock: ManualClock(now: start.addingTimeInterval(4000)))
        #expect(none.stdout.hasSuffix("  nothing logged\n"))
    }

    @Test func followPrintsWhatSteamWritesFromNowOn() async {
        let connection = logs.appending(path: "connection_log.txt").plainPath
        let gameProcess = logs.appending(path: "gameprocess_log.txt").plainPath
        fileSystem.addFile(connection, "\(stamp(6)) [Logged On, 0, 341] [U:1:987654321] OK\n")
        let fileSystem = fileSystem
        let stamp = self.stamp
        let clock = ScriptedSleepClock(now: start.addingTimeInterval(10), steps: [
            { fileSystem.append(gameProcess, "\(stamp(11)) Game process added : AppID 230410 \"x\", ProcID 77\n") },
            {},
            {
                fileSystem.append(connection, "\(stamp(13)) [Logged Off, 0, 0] [U:1:987654321] LogOff()\n")
            },
        ])
        let recorder = OutputRecorder()
        let result = await SteamCommands.timeline(minutes: 5, follow: true, context, output: recorder.output,
                                                  clock: clock, polls: 3)
        #expect(result == CommandResult())
        #expect(recorder.text == "Steam timeline, the last 5 min (times from now; fixed tokens only, no IDs, names or "
            + "paths)\n" + line("-0:04", "", "connection: Logged On (account)") + "following (Ctrl-C ends it)\n"
            + line("+0:01", "+5s", "game: Warframe (230410) added")
            + line("+0:03", "+2s", "connection: Logged Off (account)"))
        #expect(!recorder.text.contains("987654321") && !recorder.text.contains("77"))
    }
}
