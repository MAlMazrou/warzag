import Foundation
import Testing
import WarzagCore
import WarzagTestSupport
@testable import SteamHostKit

/// Each check of `SteamSignInPhase.derive`, in its order, directly and through `SteamDetector` with made-up logs.
@Suite struct SteamSignInPhaseTests {
    let start = LogFixture.steamStart
    let app = URL(filePath: "/Applications/Steam.app", directoryHint: .isDirectory)

    func status(installed: Bool = true, client: Bool = true, running: Bool = true,
                connection: SteamConnectionState? = nil) -> SteamStatus {
        SteamStatus(appBundle: installed ? app : nil, clientRuntimeInstalled: client, clientVersion: "1791918634",
                    processID: running ? 4242 : nil, connection: connection)
    }

    func entry(_ state: SteamConnectionState, account: UInt32?, anonymous: Bool = false) -> ConnectionLogEntry {
        ConnectionLogEntry(state: state, at: start.addingTimeInterval(3), anonymous: anonymous, accountID: account)
    }

    func login(_ step: SteamLoginStep, _ reason: SteamLoginReason = .ok, at seconds: TimeInterval = 4)
        -> SteamLoginTransition {
        SteamLoginTransition(step: step, reason: reason, at: start.addingTimeInterval(seconds))
    }

    func derive(_ status: SteamStatus, connection: ConnectionLogSummary? = nil, login: SteamLoginTransition? = nil,
                launch: SteamLaunchRecord? = nil, after seconds: TimeInterval = 30) -> SteamSignInPhase {
        SteamSignInPhase.derive(status: status, processStart: status.running ? start : nil, connection: connection,
                                login: login, launch: launch, now: start.addingTimeInterval(seconds))
    }

    @Test func steamMissingOrNotRunning() {
        #expect(derive(status(installed: false, running: false)) == .notInstalled)
        #expect(derive(status(installed: false)) == .notInstalled)
        #expect(derive(status(running: false)) == .notRunning)
        let record = SteamLaunchRecord(mode: .background, at: start)
        #expect(derive(status(running: false), launch: record, after: 60) == .starting(firstRun: false))
        #expect(derive(status(running: false), launch: record, after: 95) == .notRunning)
        // Steam's first start downloads its client: 5 minutes.
        #expect(derive(status(client: false, running: false), launch: record, after: 240) == .starting(firstRun: true))
        #expect(derive(status(client: false, running: false), launch: record, after: 301) == .notRunning)
    }

    @Test func signedInWinsOverEverythingElse() {
        let signedIn = status(connection: .loggedOn)
        #expect(derive(signedIn) == .signedIn)
        #expect(derive(signedIn, login: login(.waitingForCredentials, .loggedInElsewhere)) == .signedIn)
    }

    @Test func waitingForCredentials() {
        #expect(derive(status(connection: .loggedOff), login: login(.waitingForCredentials, .loggedInElsewhere))
            == .needsCredentials(.loggedInElsewhere))
        #expect(derive(status(), login: login(.waitingForCredentials)) == .needsCredentials(.ok))
        #expect(derive(status(), login: login(.waitingForCredentials, .other), after: 2) == .needsCredentials(.other))
        // Even while the connection lines name the account (the sign-out happened in this run).
        let named = ConnectionLogSummary(latest: entry(.loggedOff, account: 7), onlyAnonymous: false)
        #expect(derive(status(), connection: named, login: login(.waitingForCredentials, .loggedInElsewhere))
            == .needsCredentials(.loggedInElsewhere))
    }

    @Test(arguments: [SteamLoginStep.waitingForNetwork, .waitingForServerResponse, .waitingForLibraryReady, .success])
    func stepsThatMoveByThemselves(_ step: SteamLoginStep) {
        #expect(derive(status(connection: .connected), login: login(step, at: 12))
            == .signingIn(step: step, since: start.addingTimeInterval(12)))
    }

    @Test func aConnectionLineNamingAnAccountIsSigningIn() {
        let logging = ConnectionLogSummary(latest: entry(.loggingOn, account: 987_654_321), onlyAnonymous: false)
        #expect(derive(status(connection: .loggingOn), connection: logging) == .signingIn(step: nil, since: nil))
        #expect(derive(status(connection: .loggingOn), connection: logging, login: login(.none))
            == .signingIn(step: nil, since: nil))
    }

    @Test func onlyAnonymousLinesForMoreThan20Seconds() {
        let anonymous = ConnectionLogSummary(latest: entry(.connecting, account: nil, anonymous: true),
                                             onlyAnonymous: true)
        #expect(derive(status(connection: .connecting), connection: anonymous, after: 21) == .needsCredentials(.ok))
        #expect(derive(status(connection: .connecting), connection: anonymous, after: 15) == .starting(firstRun: false))
        #expect(derive(status(connection: .connecting), connection: anonymous, login: login(.none), after: 400)
            == .needsCredentials(.ok))
    }

    @Test func startingThenUnknown() {
        #expect(derive(status(), after: 10) == .starting(firstRun: false))
        #expect(derive(status(), after: 89) == .starting(firstRun: false))
        #expect(derive(status(), after: 90) == .unknown)
        #expect(derive(status(client: false), after: 200) == .starting(firstRun: true))
        // A format Warzag does not know: unknown, never a guess.
        #expect(derive(status(connection: SteamConnectionState(rawValue: "Somewhere New")),
                       login: login(.other), after: 120) == .unknown)
        // A start of Warzag's in flight cannot be this process's when the process is older than the limit.
        let record = SteamLaunchRecord(mode: .background, at: start.addingTimeInterval(100))
        #expect(derive(status(), launch: record, after: 120) == .unknown)
        // Unknown start time: the start in flight decides.
        let unknownStart = SteamSignInPhase.derive(status: status(), processStart: nil, connection: nil, login: nil,
                                                   launch: record, now: start.addingTimeInterval(120))
        #expect(unknownStart == .starting(firstRun: false))
    }

    @Test func tokensAreFixed() {
        #expect(SteamSignInPhase.needsCredentials(.loggedInElsewhere).description
            == "needs credentials (logged in elsewhere)")
        #expect(SteamSignInPhase.signingIn(step: .waitingForServerResponse, since: nil).description
            == "signing in (WaitingForServerResponse)")
        #expect(SteamSignInPhase.starting(firstRun: true).description == "starting (first run)")
        #expect(SteamSignInPhase.signedIn.isSignedIn && !SteamSignInPhase.signingIn(step: nil, since: nil).isSignedIn)
    }
}

@Suite struct SteamDetectorPhaseTests {
    let fileSystem = InMemoryFileSystem()
    var locations: SteamLocations {
        SteamLocations(home: URL(filePath: "/Users/tenno", directoryHint: .isDirectory),
                       systemApplications: URL(filePath: "/Applications", directoryHint: .isDirectory))
    }
    let steam: [Int32: FakeProcessInspector.Entry] = [4242: .init(
        path: "/Users/tenno/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx",
        start: LogFixture.steamStart)]

    func detector(running: Bool = true) -> SteamDetector {
        SteamDetector(locations: locations, fileSystem: fileSystem,
                      processes: FakeProcessInspector(running ? steam : [:]), timeZone: LogFixture.utc)
    }

    func install() {
        fileSystem.addDirectory("/Applications/Steam.app")
        fileSystem.addFile(locations.steamClientLibrary.plainPath, "dylib")
        fileSystem.addFile(locations.registryFile.plainPath,
                           #""Registry" { "HKLM" { "Software" { "Valve" { "Steam" { "SteamPID" "4242" } } } } }"#)
    }

    func phase(after seconds: TimeInterval, running: Bool = true, launch: SteamLaunchRecord? = nil) -> SteamSignInPhase {
        let detector = self.detector(running: running)
        return detector.phase(for: detector.status(), launch: launch, now: LogFixture.at(seconds))
    }

    @Test func aBackgroundStartThatWaitsForCredentialsAfterLoggedInElsewhere() {
        install()
        fileSystem.addFile(locations.connectionLog.plainPath, LogFixture.lines([
            (3, "[Logging On, 0, 341] [U:1:987654321] LogOn()"),
            (6, "[Logged On, 0, 341] [U:1:987654321] OK"),
        ]))
        fileSystem.addFile(locations.loginStateLog.plainPath, LogFixture.lines([
            (-50, "[ Success ] SetLoginState: WaitingForCredentials - Logged In Elsewhere"),
            (5, "[ WaitingForServerResponse ] SetLoginState: Success - OK"),
        ]))
        fileSystem.addFile(locations.bootstrapLog.plainPath, LogFixture.lines([
            (0, "Startup - Steam Client launched with: '/Users/tenno/x/steam_osx' '-silent'"),
        ]))
        #expect(phase(after: 30) == .signedIn)
        #expect(detector().startedSilently() == true)

        // Signed out elsewhere in this run.
        fileSystem.append(locations.connectionLog.plainPath, LogFixture.lines([
            (600, "[Logged Off, 0, 0] [U:1:987654321] LogOff()"),
        ]))
        fileSystem.append(locations.loginStateLog.plainPath, LogFixture.lines([
            (600, "[ Success ] SetLoginState: WaitingForCredentials - Logged In Elsewhere"),
        ]))
        #expect(phase(after: 610) == .needsCredentials(.loggedInElsewhere))

        // Steam quit; a start of Warzag's is in flight.
        #expect(phase(after: 700, running: false) == .notRunning)
        #expect(phase(after: 700, running: false, launch: SteamLaunchRecord(mode: .withSignInWindow, at: LogFixture.at(690)))
            == .starting(firstRun: false))
        #expect(detector(running: false).startedSilently() == nil)
    }

    /// Log In started Steam, which signed in; Log Out made it quit and restart itself, and its sign-in window was closed,
    /// so Steam quit again. Its shutdown lines say Warzag's start is over: Steam is off, not starting.
    @Test func aStartThatSteamHasShutDownSinceIsOver() {
        install()
        let record = SteamLaunchRecord(mode: .background, at: LogFixture.at(0))
        fileSystem.addFile(locations.bootstrapLog.plainPath, LogFixture.lines([
            (-300, "Shutdown"),
            (0, "Startup - Steam Client launched with: '/Users/tenno/x/steam_osx' '-silent'"),
            (14, "Shutdown"),
            (15, "Startup - Steam Client launched with: '/Users/tenno/x/steam_osx'"),
            (26, "Shutdown"),
        ]))
        #expect(phase(after: 30, running: false, launch: record) == .notRunning)

        // Only a shutdown from before the start: it is still in flight.
        fileSystem.addFile(locations.bootstrapLog.plainPath, LogFixture.lines([
            (-300, "Shutdown"),
            (0, "Startup - Steam Client launched with: '/Users/tenno/x/steam_osx' '-silent'"),
        ]))
        #expect(phase(after: 30, running: false, launch: record) == .starting(firstRun: false))

        // Log In restarting Steam with its sign-in window: the old Steam's shutdown, then the new start, still starting.
        fileSystem.addFile(locations.bootstrapLog.plainPath, LogFixture.lines([
            (2, "Shutdown"),
            (4, "Startup - Steam Client launched with: '/Users/tenno/x/steam_osx'"),
        ]))
        #expect(phase(after: 6, running: false, launch: record) == .starting(firstRun: false))

        // No log at all: the start is in flight until its time is up.
        fileSystem.addFile(locations.bootstrapLog.plainPath, "")
        #expect(phase(after: 30, running: false, launch: record) == .starting(firstRun: false))
        #expect(phase(after: 95, running: false, launch: record) == .notRunning)
    }

    @Test func steamAtItsSignInScreenWithNothingButAnonymousLines() {
        install()
        fileSystem.addFile(locations.connectionLog.plainPath, LogFixture.lines((1...30).map {
            ($0 * 2, "[Connecting, 0, 0] [U:1:0] CCMInterface::Connect()")
        }))
        #expect(phase(after: 10) == .starting(firstRun: false))
        #expect(phase(after: 61) == .needsCredentials(.ok))
    }

    @Test func unreadableLogsFallBackToStartingThenUnknown() {
        install()
        #expect(phase(after: 30) == .starting(firstRun: false))
        #expect(phase(after: 3600) == .unknown)
        fileSystem.addFile(locations.connectionLog.plainPath, Data([0xFF, 0xFE, 0x00, 0x0A]))
        fileSystem.addFile(locations.loginStateLog.plainPath, Data(repeating: 0x41, count: 5000))
        #expect(phase(after: 3600) == .unknown)
        #expect(detector().startedSilently() == nil)
    }

    @Test func notInstalled() {
        #expect(phase(after: 1, running: false) == .notInstalled)
    }
}
