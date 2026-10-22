import Foundation
import Testing
import WarzagCore
import WarzagTestSupport
@testable import SteamHostKit

/// Made-up Steam log lines in Steam's own formats.
enum LogFixture {
    static let utc = TimeZone(identifier: "UTC")!
    /// 2026-10-16 18:00:00 UTC.
    static let steamStart = Date(timeIntervalSince1970: 1_792_173_600)

    static func at(_ seconds: TimeInterval) -> Date { steamStart.addingTimeInterval(seconds) }

    /// "[2026-10-16 18:00:05]" for 5 seconds after `steamStart`.
    static func stamp(_ seconds: Int) -> String {
        let total = 18 * 3600 + seconds
        return String(format: "[2026-10-16 %02d:%02d:%02d]", total / 3600 % 24, total / 60 % 60, total % 60)
    }

    static func lines(_ entries: [(Int, String)], ending: String = "\r\n") -> String {
        entries.map { "\(stamp($0.0)) \($0.1)\(ending)" }.joined()
    }
}

@Suite struct ConnectionLogEntryTests {
    let fileSystem = InMemoryFileSystem()
    let log = URL(filePath: "/home/Library/Application Support/Steam/logs/connection_log.txt")

    func entry(_ rest: String) -> ConnectionLogEntry? {
        ConnectionLog.entry(in: ArraySlice(Array("\(LogFixture.stamp(6)) \(rest)".utf8)), at: LogFixture.at(6))
    }

    @Test func theAccountIsTheBracketRightAfterTheState() throws {
        let signedIn = try #require(entry("[Logged On, 0, 341] [U:1:987654321] RecvMsgClientLogOnResponse() : 'OK'"))
        #expect(signedIn.state == .loggedOn)
        #expect(signedIn.accountID == 987_654_321)
        #expect(signedIn.carriesAccount && !signedIn.anonymous)
        #expect(signedIn.at == LogFixture.at(6))

        let waiting = try #require(entry("[Connecting, 0, 0] [U:1:0] CCMInterface::Connect()"))
        #expect(waiting.accountID == nil && waiting.anonymous && !waiting.carriesAccount)

        // Elsewhere on the line, an account bracket names nobody.
        let later = try #require(entry("[Logged On, 0, 341] RecvMsgClientLogOnResponse() : [U:1:987654321] 'OK'"))
        #expect(later.accountID == nil && !later.anonymous)
    }

    @Test(arguments: [
        "[Logged On, 0, 341] [U:1:12345678901] OK",  // 11 digits
        "[Logged On, 0, 341] [U:1:4294967296] OK",  // above UInt32.max
        "[Logged On, 0, 341] [U:1:98765x321] OK",  // letters
        "[Logged On, 0, 341] [U:1:] OK",  // no digits
        "[Logged On, 0, 341] [U:1:987654321 OK",  // no closing bracket
        "[Logged On, 0, 341] U:1:987654321 OK",  // no bracket
        "[Logged On, 0, 341]  [U:1:987654321] OK",  // not right after the state
        "[Logged On, 0, 341] [A:1:987654321] OK",  // not an individual account
        "[Logged On, 0, 341x] [U:1:987654321] OK",  // a state block that does not close cleanly
        "[Logged On, 0, 341] [U:1:987654321",  // cut off
    ])
    func anythingElseMeansNoAccount(_ rest: String) throws {
        let parsed = try #require(entry(rest))
        #expect(parsed.state == .loggedOn)
        #expect(parsed.accountID == nil && !parsed.anonymous)
    }

    @Test func theLargestAccountNumberIsAccepted() {
        #expect(entry("[Logged On, 0, 341] [U:1:4294967295] OK")?.accountID == UInt32.max)
        #expect(entry("[Logged On,0,0] [U:1:1]")?.accountID == 1)
    }

    @Test func theLatestEntrySinceSteamStartedWithCRLFAndOlderLinesIgnored() throws {
        let id = "[\(FakeIdentity.accountID)]"
        fileSystem.addFile(log.plainPath, LogFixture.lines([
            (-300, "[Logged On, 0, 341] \(id) RecvMsgClientLogOnResponse() : \(id) 'OK'"),
            (-200, "[Logged Off, 0, 0] \(id) LogOff() as \(FakeIdentity.accountName)"),
            (2, "[Connecting, 0, 0] [U:1:0] CCMInterface::Connect()"),
            (5, "[Logging On, 0, 341] \(id) LogOn()"),
            (6, "[Logged On, 0, 341] \(id) RecvMsgClientLogOnResponse() : \(id) 'OK'"),
            (7, "\(id) a line without a state"),
        ]))
        let latest = try #require(try ConnectionLog.lastEntry(in: log, since: LogFixture.steamStart,
                                                              fileSystem: fileSystem, timeZone: LogFixture.utc))
        #expect(latest.state == .loggedOn && latest.accountID == 987_654_321 && latest.at == LogFixture.at(6))
        #expect(try ConnectionLog.lastState(in: log, since: LogFixture.steamStart, fileSystem: fileSystem,
                                            timeZone: LogFixture.utc) == .loggedOn)
        // Restarted an hour later: nothing logged since.
        #expect(try ConnectionLog.lastEntry(in: log, since: LogFixture.at(3600), fileSystem: fileSystem,
                                            timeZone: LogFixture.utc) == nil)
    }

    @Test func aSummarySaysWhetherThisRunEverHadAnAccount() throws {
        let id = "[\(FakeIdentity.accountID)]"
        // Signed in before this run; since it started only anonymous lines, as at Steam's sign-in screen.
        var entries: [(Int, String)] = [(-60, "[Logged On, 0, 341] \(id) OK")]
        for second in stride(from: 2, to: 400, by: 2) {
            entries.append((second, "[Connecting, 0, 0] [U:1:0] CCMInterface::Connect()"))
            entries.append((second, "[0,0] SetSteamID( [U:1:0] )"))
        }
        fileSystem.addFile(log.plainPath, LogFixture.lines(entries))
        func summary(chunkSize: Int = 64 * 1024, byteLimit: UInt64 = ConnectionLog.summaryByteLimit) throws
            -> ConnectionLogSummary {
            try ConnectionLog.summary(in: log, since: LogFixture.steamStart, fileSystem: fileSystem,
                                      timeZone: LogFixture.utc, chunkSize: chunkSize, byteLimit: byteLimit)
        }
        var result = try summary(chunkSize: 1000)
        #expect(result.onlyAnonymous)
        #expect(result.latest?.state == .connecting && result.latest?.anonymous == true)
        #expect(result.latest?.at == LogFixture.at(398))

        // A line naming an account since the start: not only anonymous, whichever line is the latest.
        fileSystem.append(log.plainPath, LogFixture.lines([(401, "[Logging On, 0, 341] \(id) LogOn()"),
                                                           (402, "[Connecting, 0, 0] [U:1:0] retry")]))
        result = try summary()
        #expect(!result.onlyAnonymous)
        #expect(result.latest?.anonymous == true)

        // Only the newest bytes are read: a run that logged that much without an account has had none.
        fileSystem.addFile(log.plainPath,
                           LogFixture.lines([(1, "[Logging On, 0, 341] \(id) LogOn()")] + entries.dropFirst()))
        #expect(try summary(byteLimit: 4096).onlyAnonymous)
        #expect(try !summary().onlyAnonymous)

        // Nothing since the start: no latest entry, not "only anonymous".
        fileSystem.addFile(log.plainPath, LogFixture.lines([(-60, "[Connecting, 0, 0] [U:1:0] x")]))
        #expect(try summary() == ConnectionLogSummary(latest: nil, onlyAnonymous: false))
    }

    @Test func entriesNeverPrintTheAccount() throws {
        let parsed = try #require(entry("[Logged On, 0, 341] [U:1:987654321] OK"))
        var dumped = ""
        dump(parsed, to: &dumped)
        let mirror = Mirror(reflecting: parsed).children.map { "\($0.label ?? "") \($0.value)" }.joined()
        for text in [String(describing: parsed), "\(parsed)", String(reflecting: parsed), dumped, mirror] {
            #expect(!text.contains("987654321"), "\(text)")
            #expect(!text.contains(FakeIdentity.steamID64))
            #expect(text.contains("Logged On"))
        }
    }
}

@Suite struct LoginStateLogTests {
    let fileSystem = InMemoryFileSystem()
    let log = URL(filePath: "/home/Library/Application Support/Steam/logs/steamui_login.txt")

    func transition(_ rest: String) -> SteamLoginTransition? {
        LoginStateLog.transition(in: ArraySlice(Array("\(LogFixture.stamp(9)) \(rest)".utf8)), at: LogFixture.at(9))
    }

    func last(since: Date? = LogFixture.steamStart) throws -> SteamLoginTransition? {
        try LoginStateLog.lastTransition(in: log, since: since, fileSystem: fileSystem, timeZone: LogFixture.utc)
    }

    @Test func theBracketBeforeTheMarkerIsTheOldStateAndIsIgnored() {
        #expect(transition("[ Success ] SetLoginState: WaitingForCredentials - Logged In Elsewhere")
            == SteamLoginTransition(step: .waitingForCredentials, reason: .loggedInElsewhere, at: LogFixture.at(9)))
        #expect(transition("[ WaitingForLibraryReady ] SetLoginState: Success - OK")?.step == .success)
        #expect(transition("[ None ] SetLoginState: WaitingForCredentials - OK")?.reason == .ok)
    }

    @Test(arguments: [
        ("SetLoginState: WaitingForNetwork - OK", SteamLoginStep.waitingForNetwork, SteamLoginReason.ok),
        ("SetLoginState: WaitingForServerResponse - OK", .waitingForServerResponse, .ok),
        ("SetLoginState: WaitingForLibraryReady - OK", .waitingForLibraryReady, .ok),
        ("SetLoginState: None - OK", .none, .ok),
        ("SetLoginState: WaitingForCredentials - Invalid Password", .waitingForCredentials, .other),
        ("SetLoginState: WaitingForCredentials - Code 84 (rate limit)", .waitingForCredentials, .other),
        ("SetLoginState: WaitingForCredentials", .waitingForCredentials, .other),
        ("SetLoginState: WaitingForSteamGuardOnPhone - OK", .other, .ok),
        ("[ x ] SetLoginState:   Success   - logged in elsewhere", .success, .loggedInElsewhere),
    ])
    func stepsAndReasons(_ rest: String, _ step: SteamLoginStep, _ reason: SteamLoginReason) {
        let parsed = transition(rest)
        #expect(parsed?.step == step)
        #expect(parsed?.reason == reason)
    }

    @Test(arguments: [
        "SetLoginState WaitingForCredentials - OK",  // no colon
        "SetLoginState: - OK",  // no step
        "SetLoginState: Waiting4Credentials - OK",  // not a word of letters
        "Something else entirely",
        "",
    ])
    func linesWithoutATransition(_ rest: String) {
        #expect(transition(rest) == nil)
    }

    @Test func aLineWithoutSteamsTimestampNeverCounts() throws {
        fileSystem.addFile(log.plainPath, "SetLoginState: Success - OK\n2026-10-16 18:00:09 SetLoginState: Success - OK\n")
        #expect(try last() == nil)
    }

    @Test func theLatestTransitionSinceSteamStarted() throws {
        fileSystem.addFile(log.plainPath, LogFixture.lines([
            (-90, "[ Success ] SetLoginState: WaitingForCredentials - Logged In Elsewhere"),
            (3, "[ None ] SetLoginState: WaitingForNetwork - OK"),
            (4, "steamui: some other line"),
            (5, "[ WaitingForNetwork ] SetLoginState: WaitingForServerResponse - OK"),
            (8, "[ WaitingForServerResponse ] SetLoginState: Success - OK"),
            (8, "a line about something else"),
        ]))
        #expect(try last() == SteamLoginTransition(step: .success, reason: .ok, at: LogFixture.at(8)))
        #expect(try last(since: LogFixture.at(-120))?.step == .success)
        // Started after all of it: nothing since.
        #expect(try last(since: LogFixture.at(60)) == nil)
        let recent = try LoginStateLog.transitions(in: log, since: nil, limit: 3, fileSystem: fileSystem,
                                                   timeZone: LogFixture.utc)
        #expect(recent.map(\.step) == [.waitingForNetwork, .waitingForServerResponse, .success])
        #expect(recent.map(\.description) == ["WaitingForNetwork - OK", "WaitingForServerResponse - OK", "Success - OK"])
        #expect(try LoginStateLog.transitions(in: log, since: nil, limit: 0, fileSystem: fileSystem).isEmpty)
    }

    @Test func aLastLineStillBeingWrittenIsLeftForLater() throws {
        fileSystem.addFile(log.plainPath, LogFixture.lines([(3, "[ None ] SetLoginState: Success - OK")])
            + "\(LogFixture.stamp(9)) [ Success ] SetLoginState: WaitingForCre")
        #expect(try last()?.step == .success)
        fileSystem.append(log.plainPath, "dentials - Logged In Elsewhere\r\n")
        #expect(try last()?.reason == .loggedInElsewhere)
        // A whole file that is one unfinished line.
        fileSystem.addFile(log.plainPath, "\(LogFixture.stamp(9)) [ None ] SetLoginState: Success - OK")
        #expect(try last() == nil)
    }

    @Test(arguments: [1, 5, 40, 4096])
    func chunkBoundariesDoNotMatter(_ chunkSize: Int) throws {
        fileSystem.addFile(log.plainPath, LogFixture.lines([
            (3, "[ None ] SetLoginState: WaitingForNetwork - OK"),
            (9, "[ Success ] SetLoginState: WaitingForCredentials - Logged In Elsewhere"),
        ]) + "\(LogFixture.stamp(10)) unfinished")
        let found = try LoginStateLog.lastTransition(in: log, since: LogFixture.steamStart, fileSystem: fileSystem,
                                                     timeZone: LogFixture.utc, chunkSize: chunkSize)
        #expect(found?.reason == .loggedInElsewhere)
    }

    @Test func aMissingLogIsAnError() {
        #expect(throws: (any Error).self) { try last() }
    }
}

@Suite struct BootstrapLogTests {
    let fileSystem = InMemoryFileSystem()
    let log = URL(filePath: "/home/Library/Application Support/Steam/logs/bootstrap_log.txt")
    let client = "'/Users/\(FakeIdentity.accountName)/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx'"

    func silently(since: Date? = LogFixture.steamStart) throws -> Bool? {
        try BootstrapLog.startedSilently(in: log, since: since, fileSystem: fileSystem, timeZone: LogFixture.utc)
    }

    @Test func theLatestStartSinceSteamStartedSaysWhetherItWasSilent() throws {
        fileSystem.addFile(log.plainPath, LogFixture.lines([
            (-600, "Startup - updater built Oct 13 2026 00:00:00"),
            (-600, "Startup - Steam Client launched with: \(client)"),
            (-30, "Shutdown"),
            (0, "Startup - updater built Oct 13 2026 00:00:00"),
            (0, "Startup - Steam Client launched with: \(client) '-silent'"),
            (1, "Verifying installation..."),
        ]))
        #expect(try silently() == true)
        #expect(try silently(since: LogFixture.at(-700)) == true)  // the latest start wins
        #expect(try silently(since: LogFixture.at(-5)) == true)
        #expect(try silently(since: LogFixture.at(5)) == nil)  // nothing since a later start
        fileSystem.append(log.plainPath, LogFixture.lines([(500, "Shutdown"),
                                                           (510, "Startup - Steam Client launched with: \(client)")]))
        #expect(try silently(since: LogFixture.at(505)) == false)
    }

    @Test(arguments: [
        ("Startup - Steam Client launched with: '/a b/steam_osx' '-silent'", true),
        ("Startup - Steam Client launched with: /x/steam_osx -silent -nofriendsui", true),
        ("Startup - Steam Client launched with: \"/x/steam_osx\" \"-SILENT\"", true),
        ("Startup - Steam Client launched with: '/x/steam_osx' '-silentmode'", false),
        ("Startup - Steam Client launched with: '/Users/-silent/steam_osx'", false),
        ("Startup - Steam Client launched with: '/x/steam_osx' '-gamepadui'", false),
    ])
    func theSilentFlag(_ message: String, _ silent: Bool) {
        let line = ArraySlice(Array("\(LogFixture.stamp(0)) \(message)".utf8))
        #expect(BootstrapLog.event(in: line) == .started(silent: silent))
    }

    @Test func shutdownAndOtherLines() {
        func event(_ message: String) -> BootstrapLog.Event? {
            BootstrapLog.event(in: ArraySlice(Array("\(LogFixture.stamp(0)) \(message)".utf8)))
        }
        #expect(event("Shutdown") == .shutdown)
        #expect(event("Startup - updater built Oct 13 2026") == nil)
        #expect(event("Verifying installation...") == nil)
        #expect(BootstrapLog.event(in: ArraySlice(Array("Shutdown".utf8))) == nil)
    }
}

@Suite struct LogLinesTests {
    let fileSystem = InMemoryFileSystem()
    let log = URL(filePath: "/logs/x.txt")

    func text(_ lines: [ArraySlice<UInt8>]) -> [String] { lines.map { String(decoding: $0, as: UTF8.self) } }

    @Test func forwardReadsCompleteLinesAndRemembersWhereItStopped() throws {
        fileSystem.addFile(log.plainPath, "one\r\ntwo\nthr")
        var (lines, position) = try LogLines.forward(in: log, from: nil, fileSystem: fileSystem)
        #expect(text(lines) == ["one", "two"])
        #expect(position.offset == 9)
        fileSystem.append(log.plainPath, "ee\nfour\n")
        (lines, position) = try LogLines.forward(in: log, from: position, fileSystem: fileSystem)
        #expect(text(lines) == ["three", "four"])
        (lines, position) = try LogLines.forward(in: log, from: position, fileSystem: fileSystem)
        #expect(lines.isEmpty)

        // Replaced (a new file) or truncated: from the start again.
        fileSystem.addFile(log.plainPath, "new\n")
        (lines, position) = try LogLines.forward(in: log, from: position, fileSystem: fileSystem)
        #expect(text(lines) == ["new"])
        fileSystem.truncate(log.plainPath, to: "")
        fileSystem.append(log.plainPath, "x\n")
        (lines, _) = try LogLines.forward(in: log, from: position, fileSystem: fileSystem)
        #expect(text(lines) == ["x"])
    }

    @Test func forwardFarBehindReadsOnlyTheNewestWholeLines() throws {
        fileSystem.addFile(log.plainPath, (0..<100).map { "line \($0)\n" }.joined())
        let (lines, position) = try LogLines.forward(in: log, from: nil, fileSystem: fileSystem, maximumBytes: 30)
        #expect(text(lines) == ["line 97", "line 98", "line 99"])
        #expect(position.offset == UInt64(fileSystem.data(at: log.plainPath)!.count))
    }

    @Test func backwardStopsWhereTheCallerSaysAndWithinItsLimit() throws {
        fileSystem.addFile(log.plainPath, (0..<50).map { "line \($0)\r\n" }.joined())
        var seen: [String] = []
        try LogLines.backward(in: log, fileSystem: fileSystem, chunkSize: 7) { line in
            seen.append(String(decoding: line, as: UTF8.self))
            return seen.count < 4
        }
        #expect(seen == ["", "line 49", "line 48", "line 47"])
        seen = []
        try LogLines.backward(in: log, fileSystem: fileSystem, chunkSize: 10, byteLimit: 25) { line in
            seen.append(String(decoding: line, as: UTF8.self))
            return true
        }
        #expect(seen.count < 6)
        #expect(seen.contains("line 49"))
    }
}
