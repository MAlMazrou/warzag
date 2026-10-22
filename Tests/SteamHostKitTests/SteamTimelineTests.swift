import Foundation
import Testing
import WarzagCore
import WarzagTestSupport
@testable import SteamHostKit

/// `warzagctl steam timeline`'s merge, on made-up logs that carry made-up IDs, names and paths: none may come out.
@Suite struct SteamTimelineTests {
    let fileSystem = InMemoryFileSystem()
    let locations = SteamLocations(home: URL(filePath: "/Users/tenno", directoryHint: .isDirectory),
                                   systemApplications: URL(filePath: "/Applications", directoryHint: .isDirectory))
    let warzagLog = URL(filePath: "/Users/tenno/Library/Logs/Warzag/Warzag.log")

    var timeline: SteamTimeline {
        SteamTimeline(locations: locations, warzagLog: warzagLog, fileSystem: fileSystem, timeZone: LogFixture.utc)
    }

    /// Warzag.log's own format: an ISO 8601 time in UTC, then the message.
    func warzag(_ seconds: Int, _ message: String) -> String {
        "\(LogFixture.at(TimeInterval(seconds)).formatted(.iso8601)) \(message)\n"
    }

    /// A short session: Play, a 230410 registration and a "Logged In Elsewhere" sign-out in the same second.
    func writeSession() {
        let id = "[\(FakeIdentity.accountID)]"
        let path = "'/Users/\(FakeIdentity.accountName)/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx'"
        fileSystem.addFile(locations.bootstrapLog.plainPath, LogFixture.lines([
            (-4000, "Startup - Steam Client launched with: \(path)"),
            (0, "Startup - Steam Client launched with: \(path) '-silent'"),
            (1, "Verifying installation..."),
        ]))
        fileSystem.addFile(locations.connectionLog.plainPath, LogFixture.lines([
            (2, "[Connecting, 0, 0] [U:1:0] CCMInterface::Connect() to \(FakeIdentity.serverAddress)"),
            (3, "[Connecting, 0, 0] [U:1:0] CCMInterface::Connect() to \(FakeIdentity.serverAddress)"),
            (5, "[Logging On, 0, 341] \(id) LogOn() \(FakeIdentity.steamID64)"),
            (6, "[Logged On, 0, 341] \(id) RecvMsgClientLogOnResponse() : \(id) 'OK' as \(FakeIdentity.accountName)"),
            (61, "[Logged Off, 0, 0] \(id) LogOff()"),
        ]))
        fileSystem.addFile(locations.loginStateLog.plainPath, LogFixture.lines([
            (6, "[ WaitingForServerResponse ] SetLoginState: Success - OK"),
            (61, "[ Success ] SetLoginState: WaitingForCredentials - Logged In Elsewhere"),
        ]))
        fileSystem.addFile(locations.gameProcessLog.plainPath, LogFixture.lines([
            (20, #"AppID 306130 adding PID 5150 as a tracked process "/Users/tenno/Library/x/eso64.exe""#),
            (59, #"Game process added : AppID 230410 "C:\Users\tenno\Warframe.x64.exe", ProcID 4242, IP 0.0.0.0:0"#),
            (61, #"Game process removed: AppID 230410 "C:\Users\tenno\Warframe.x64.exe", ProcID 4242"#),
            (70, "Something Steam has not logged before"),
        ]))
        fileSystem.addFile(warzagLog.plainPath, warzag(-10, "setup: ready to play")
            + warzag(58, "play: start (Steam, balanced)")
            + warzag(60, "play: failed: /Users/\(FakeIdentity.accountName)/Library/x is missing")
            + warzag(62, "play: wineserver -k for /Users/tenno/Library/Application Support/Warzag/Prefixes/x")
            + warzag(63, "steam: hid Steam after sign-in (1 app)")
            + warzag(64, "play: a Steam ID \(FakeIdentity.steamID64) in a line")
            + warzag(65, "app: quit"))
    }

    @Test func oneListOfFixedTokensOldestFirst() {
        writeSession()
        let events = timeline.events(since: LogFixture.at(-60))
        #expect(events.map(\.text) == [
            "steam: started (-silent: yes)",
            "connection: Connecting (no account)",
            "connection: Logging On (account)",
            "connection: Logged On (account)",
            "login: Success - OK",
            "game: another app added",
            "warzag: play: start (Steam, balanced)",
            "game: Warframe (230410) added",
            "warzag: play: failed",
            "connection: Logged Off (account)",
            "login: WaitingForCredentials - Logged In Elsewhere",
            "game: Warframe (230410) removed",
            "warzag: play (details left out)",
            "warzag: steam: hid Steam after sign-in (1 app)",
            "warzag: play (details left out)",
        ])
        #expect(events.first?.at == LogFixture.at(0))
        // Older than the window: left out.
        #expect(!events.contains { $0.text == "warzag: setup: ready to play" })
        #expect(timeline.events(since: LogFixture.at(63)).map(\.text) == [
            "warzag: steam: hid Steam after sign-in (1 app)", "warzag: play (details left out)",
        ])
    }

    @Test func nothingPersonalComesOut() {
        writeSession()
        let text = SteamTimeline.render(timeline.events(since: LogFixture.at(-5000)), relativeTo: LogFixture.at(120))
        for secret in FakeIdentity.all + ["/Users", "tenno", "306130", "eso64", "5150", "4242", "0.0.0.0"] {
            #expect(!text.contains(secret), "\(secret)")
        }
        #expect(text.contains("steam: started (-silent: no)"))
    }

    @Test func renderingTimesFromNowAndTheGapToTheEventBefore() {
        let events = [
            SteamTimelineEvent(at: LogFixture.at(0), source: .bootstrap, text: "steam: started (-silent: yes)"),
            SteamTimelineEvent(at: LogFixture.at(2), source: .connection, text: "connection: Connecting (no account)"),
            SteamTimelineEvent(at: LogFixture.at(127), source: .login, text: "login: Success - OK"),
            SteamTimelineEvent(at: LogFixture.at(4000), source: .warzag, text: "warzag: play: start (Steam, balanced)"),
        ]
        func line(_ when: String, _ gap: String, _ text: String) -> String {
            when.padding(toLength: 10, withPad: " ", startingAt: 0) + gap.padding(toLength: 8, withPad: " ", startingAt: 0)
                + text + "\n"
        }
        #expect(SteamTimeline.render(events, relativeTo: LogFixture.at(3700)) == [
            line("-1:01:40", "", "steam: started (-silent: yes)"),
            line("-1:01:38", "+2s", "connection: Connecting (no account)"),
            line("-59:33", "+2m05s", "login: Success - OK"),
            line("+5:00", "+1h04m", "warzag: play: start (Steam, balanced)"),
        ].joined())
        #expect(SteamTimeline.render(Array(events.suffix(1)), relativeTo: LogFixture.at(4000), after: LogFixture.at(3999))
            == line("+0:00", "+1s", "warzag: play: start (Steam, balanced)"))
    }

    @Test(arguments: [
        (#"Game process added : AppID 230410 "x", ProcID 1, IP 0.0.0.0:0"#, true, true),
        (#"Game process removed: AppID 230410 "x", ProcID 1"#, true, false),
        (#"AppID 230410 adding PID 77 as a tracked process "x""#, true, true),
        ("AppID 230410 no longer tracking PID 77, exit code 0", true, false),
        (#"Game process added : AppID 2304100 "x""#, false, true),
        ("AppID 570 no longer tracking PID 1, exit code 0", false, false),
    ])
    func gameProcessLines(_ message: String, _ warframe: Bool, _ added: Bool) {
        let line = ArraySlice(Array("\(LogFixture.stamp(0)) \(message)".utf8))
        #expect(GameProcessLog.event(in: line) == GameProcessLog.Event(warframe: warframe, added: added))
    }

    @Test(arguments: [
        "Game process updated : AppID 230410 \"x\", ProcID 1",
        "AppID 230410 state changed : Fully Installed,App Running,",
        "Game process added : no app id",
        "Game process added : AppID 12345678901",
    ])
    func otherGameProcessLines(_ message: String) {
        #expect(GameProcessLog.event(in: ArraySlice(Array("\(LogFixture.stamp(0)) \(message)".utf8))) == nil)
    }

    @Test func followingReportsOnlyWhatIsWrittenFromNowOn() throws {
        writeSession()
        // An unfinished line when following starts: reported once it is whole, never twice.
        fileSystem.append(locations.loginStateLog.plainPath, "\(LogFixture.stamp(80)) [ None ] SetLoginState: Waiting")
        var follower = timeline.follower()
        let history = timeline.events(since: LogFixture.at(-60), before: follower)
        follower.continueAfter(history)
        #expect(history.last?.text == "warzag: play (details left out)")
        #expect(follower.poll().isEmpty)

        fileSystem.append(locations.loginStateLog.plainPath, "ForNetwork - OK\r\n")
        fileSystem.append(locations.connectionLog.plainPath, LogFixture.lines([
            (81, "[Logged Off, 0, 0] [U:1:987654321] again"),  // the state it ended on: not repeated
            (82, "[Connecting, 0, 0] [U:1:0] x"),
        ]))
        fileSystem.append(warzagLog.plainPath, warzag(83, "play: start (Steam, balanced)"))
        #expect(follower.poll().map(\.text) == [
            "login: WaitingForNetwork - OK",
            "connection: Connecting (no account)",
            "warzag: play: start (Steam, balanced)",
        ])
        #expect(follower.poll().isEmpty)

        // Rotated (a new file) and a log that did not exist before: read from their start.
        fileSystem.addFile(locations.connectionLog.plainPath, LogFixture.lines([(90, "[Logged On, 0, 1] [U:1:5] x")]))
        #expect(follower.poll().map(\.text) == ["connection: Logged On (account)"])
        try fileSystem.removeItem(at: locations.gameProcessLog)
        var fresh = timeline.follower()
        fileSystem.addFile(locations.gameProcessLog.plainPath,
                           LogFixture.lines([(91, #"Game process added : AppID 230410 "x""#)]))
        #expect(fresh.poll().map(\.text) == ["game: Warframe (230410) added"])
    }

    @Test func noLogsNoEvents() {
        #expect(timeline.events(since: LogFixture.at(-60)).isEmpty)
        var follower = timeline.follower()
        #expect(follower.poll().isEmpty)
    }
}
