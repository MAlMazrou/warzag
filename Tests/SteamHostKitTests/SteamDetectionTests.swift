import Foundation
import Testing
import WarzagCore
import WarzagTestSupport
@testable import SteamHostKit

/// Made-up identifiers. They appear in the fake log lines and must never show up in anything Warzag produces.
enum FakeIdentity {
    static let accountID = "U:1:987654321"
    static let steamID64 = "76561198947920049"
    static let accountName = "fake_tenno_account"
    static let serverAddress = "192.0.2.44:27017"
    static let all = [accountID, steamID64, accountName, serverAddress, "987654321"]
}

func connectionLog(_ entries: [(String, String)]) -> String {
    entries.map { time, rest in "[\(time)] \(rest)\r\n" }.joined()
}

@Suite struct ConnectionLogTests {
    let utc = TimeZone(identifier: "UTC")!
    let fileSystem = InMemoryFileSystem()
    let log = URL(filePath: "/home/Library/Application Support/Steam/logs/connection_log.txt")

    /// 2026-10-16 18:00:00 UTC.
    let steamStart = Date(timeIntervalSince1970: 1_792_173_600)

    var realisticLog: String {
        let id = "[\(FakeIdentity.accountID)]"
        return "\r\n" + connectionLog([
            ("2026-10-16 17:55:00", "[Logged On, 0, 341] \(id) RecvMsgClientLogOnResponse() : \(id) 'OK'"),
            ("2026-10-16 17:59:00", "[Logged Off, 0, 0] \(id) LogOff() as \(FakeIdentity.accountName)"),
            ("2026-10-16 18:00:01", "Client version: 1788652215"),
            ("2026-10-16 18:00:01", "Log session started"),
            ("2026-10-16 18:00:02", "[0,0] SetSteamID( [U:1:0] )"),
            ("2026-10-16 18:00:03", "[Connecting, 0, 0] \(id) CCMInterface::Connect() to \(FakeIdentity.serverAddress)"),
            ("2026-10-16 18:00:04", "[Connected, 0, 341] \(id) Connected to \(FakeIdentity.serverAddress)"),
            ("2026-10-16 18:00:05", "[Logging On, 0, 341] \(id) LogOn() steamid \(FakeIdentity.steamID64)"),
            ("2026-10-16 18:00:06", "[Logged On, 0, 341] \(id) RecvMsgClientLogOnResponse() : \(id) 'OK'"),
            ("2026-10-16 18:00:07", "\(id) Some trailing line without a state"),
        ])
    }

    func lastState(_ text: String, since: Date?, chunkSize: Int = 64 * 1024) throws -> SteamConnectionState? {
        fileSystem.addFile(log.plainPath, text)
        return try ConnectionLog.lastState(in: log, since: since, fileSystem: fileSystem, timeZone: utc, chunkSize: chunkSize)
    }

    @Test func theLatestTokenSinceSteamStartedWins() throws {
        #expect(try lastState(realisticLog, since: steamStart) == .loggedOn)
    }

    @Test func tokensFromBeforeSteamStartedDoNotCount() throws {
        let text = connectionLog([
            ("2026-10-16 17:55:00", "[Logged On, 0, 341] [\(FakeIdentity.accountID)] OK"),
            ("2026-10-16 18:00:01", "Log session started"),
        ])
        #expect(try lastState(text, since: steamStart) == nil)
        #expect(try lastState(text, since: nil) == .loggedOn)
    }

    @Test func aLineFromTheSecondSteamStartedStillCounts() throws {
        let text = connectionLog([("2026-10-16 18:00:00", "[Logged On, 0, 1] [\(FakeIdentity.accountID)] OK")])
        #expect(try lastState(text, since: steamStart.addingTimeInterval(0.7)) == .loggedOn)
    }

    @Test func signingOutIsTheLatestState() throws {
        let text = realisticLog + connectionLog([
            ("2026-10-16 18:30:00", "[Logging Off, 0, 341] [\(FakeIdentity.accountID)] LogOff()"),
            ("2026-10-16 18:30:01", "[Logged Off, 0, 0] [\(FakeIdentity.accountID)] Logged off"),
        ])
        let state = try #require(try lastState(text, since: steamStart))
        #expect(state == .loggedOff)
        #expect(!state.isSignedIn)
    }

    @Test(arguments: [1, 7, 33, 64, 1000])
    func chunkBoundariesDoNotMatter(_ chunkSize: Int) throws {
        #expect(try lastState(realisticLog, since: steamStart, chunkSize: chunkSize) == .loggedOn)
    }

    @Test func aLongLogIsScannedFromTheEnd() throws {
        var text = ""
        for second in 0..<3000 {
            let time = String(format: "2026-10-16 18:%02d:%02d", 10 + second / 60 % 50, second % 60)
            text += "[\(time)] [Connecting, 0, 0] [\(FakeIdentity.accountID)] retry \(second)\r\n"
        }
        text += connectionLog([("2026-10-16 19:00:00", "[Logged On, 0, 341] [\(FakeIdentity.accountID)] OK")])
        #expect(try lastState(text, since: steamStart, chunkSize: 4096) == .loggedOn)
    }

    @Test(arguments: [
        ("[2026-10-16 18:00:06] [Logged On, 0, 341] [U:1:987654321] OK", "Logged On"),
        ("[2026-10-16 18:00:06] [Logging Off,0,0]", "Logging Off"),
        ("[2026-10-16 18:00:06] [Connecting, 0, 0]\r", "Connecting"),
        ("[2026-10-16 18:00:06] [Some Future State, 1]", "Some Future State"),
    ])
    func stateTokens(_ line: String, _ token: String) {
        #expect(ConnectionLog.entry(in: ArraySlice(Array(line.utf8)), at: steamStart)?.state.rawValue == token)
    }

    @Test(arguments: [
        "[2026-10-16 18:00:02] [0,0] SetSteamID( [U:1:0] )",
        "[2026-10-16 18:00:02] [U:1:987654321] RecvMsgClientLogOnResponse()",
        "[2026-10-16 18:00:01] Client version: 1788652215",
        "[2026-10-16 18:00:01] [Logged On] no comma",
        "[2026-10-16 18:00:01] [ Logged On, 0]",
        "[2026-10-16 18:00:01] [Logged On 76561198947920049, 0]",
        "[2026-10-16 18:00:01] [ThisTokenIsFarTooLongToBeAnyStateSteamWouldEverLog, 0]",
        "Logged On, 0, 341",
        "",
    ])
    func linesWithoutAStateToken(_ line: String) {
        #expect(ConnectionLog.entry(in: ArraySlice(Array(line.utf8)), at: steamStart) == nil)
    }

    @Test func timestampsAreReadInTheGivenTimeZone() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Dubai")!
        let line = ArraySlice(Array("[2026-10-16 22:00:00] [Connected, 0, 1]".utf8))
        #expect(LogTimestamp.parse(line, calendar: calendar) == steamStart)
        #expect(LogTimestamp.parse(ArraySlice(Array("[2026-1x-16 22:00:00]".utf8)), calendar: calendar) == nil)
    }

    @Test func extractedStatesNeverCarryIdentifiers() throws {
        let state = try #require(try lastState(realisticLog, since: steamStart))
        let encoded = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        for text in [state.rawValue, state.description, String(describing: state), encoded] {
            for identifier in FakeIdentity.all { #expect(!text.contains(identifier)) }
        }
    }
}

@Suite struct SteamDetectorTests {
    let fileSystem = InMemoryFileSystem()
    let home = URL(filePath: "/Users/tenno", directoryHint: .isDirectory)
    let utc = TimeZone(identifier: "UTC")!
    let steamStart = Date(timeIntervalSince1970: 1_792_173_600)
    var locations: SteamLocations {
        SteamLocations(home: home, systemApplications: URL(filePath: "/Applications", directoryHint: .isDirectory))
    }

    func detector(_ processes: [Int32: FakeProcessInspector.Entry] = [:]) -> SteamDetector {
        SteamDetector(locations: locations, fileSystem: fileSystem, processes: FakeProcessInspector(processes), timeZone: utc)
    }

    func installSteam(pid: String = "4242", version: String = "1788652215") {
        fileSystem.addDirectory("/Applications/Steam.app/Contents")
        fileSystem.addFile(locations.steamClientLibrary.plainPath, Data([0xCA, 0xFE]))
        fileSystem.addFile(locations.packageDirectory.appending(path: "steam_client_osx.manifest").plainPath, """
            "osx"
            {
            \t"version"\t\t"\(version)"
            \t"ostype"\t\t"macos1015"
            \t"tenfoot_images_all" { "file" "x.zip" "size" "1" }
            }
            """)
        fileSystem.addFile(locations.registryFile.plainPath, """
            "Registry" { "HKLM" { "Software" { "Valve" { "Steam" { "SteamPID" "\(pid)" "ClientLauncherType" "0" } } } }
                         "HKCU" { "Software" { "Valve" { "Steam" { "AutoLoginUser" "\(FakeIdentity.accountName)" } } } } }
            """)
        fileSystem.addFile(locations.connectionLog.plainPath, connectionLog([
            ("2026-10-16 18:00:05", "[Logging On, 0, 341] [\(FakeIdentity.accountID)] LogOn() \(FakeIdentity.steamID64)"),
            ("2026-10-16 18:00:06", "[Logged On, 0, 341] [\(FakeIdentity.accountID)] OK as \(FakeIdentity.accountName)"),
        ]))
    }

    var steamProcess: [Int32: FakeProcessInspector.Entry] {
        [4242: .init(path: "/Users/tenno/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx",
                     start: steamStart)]
    }

    @Test func nothingInstalled() {
        let status = detector().status()
        #expect(status == SteamStatus(appBundle: nil, clientRuntimeInstalled: false, clientVersion: nil,
                                      processID: nil, connection: nil))
        #expect(!status.installed && !status.running && !status.signedIn)
    }

    @Test func installedRunningAndSignedIn() {
        installSteam()
        let status = detector(steamProcess).status()
        #expect(status.installed)
        #expect(status.appBundle?.plainPath == "/Applications/Steam.app")
        #expect(status.clientRuntimeInstalled)
        #expect(status.clientVersion == "1788652215")
        #expect(status.running)
        #expect(status.processID == 4242)
        #expect(status.connection == .loggedOn)
        #expect(status.signedIn)
    }

    /// Steam 1791918634 writes steam_client_signed-2_osx.manifest and leaves the old manifest behind.
    @Test func theClientVersionIsTheHighestAcrossTheClientManifests() {
        installSteam()
        let package = locations.packageDirectory
        fileSystem.addFile(package.appending(path: "steam_client_signed-2_osx.manifest").plainPath,
                           #""osx" { "version" "1791918634" "ostype" "macos1015" }"#)
        fileSystem.addFile(package.appending(path: "steam_client_publicbeta_osx.manifest").plainPath,
                           #""osx" { "version" "999" }"#)
        // Not the client's manifests: another package's, and a copy that is no manifest name.
        fileSystem.addFile(package.appending(path: "steamui_osx.manifest").plainPath, #""osx" { "version" "9999999999" }"#)
        fileSystem.addFile(package.appending(path: "steam_client_osx.manifest.old").plainPath,
                           #""osx" { "version" "9999999998" }"#)
        #expect(detector().clientVersion() == "1791918634")
        #expect(detector(steamProcess).status().clientVersion == "1791918634")
    }

    @Test func aManifestWithoutANumericVersionCountsOnlyWithoutANumericOne() {
        let package = locations.packageDirectory
        fileSystem.addFile(package.appending(path: "steam_client_osx.manifest").plainPath, #""osx" { "version" "beta-7" }"#)
        #expect(detector().clientVersion() == "beta-7")
        fileSystem.addFile(package.appending(path: "steam_client_signed-2_osx.manifest").plainPath,
                           #""osx" { "version" "12" }"#)
        #expect(detector().clientVersion() == "12")
        // Being rewritten (truncated), empty, or far too large for a manifest: skipped.
        fileSystem.addFile(package.appending(path: "steam_client_a_osx.manifest").plainPath, #""osx" { "version" "13""#)
        fileSystem.addFile(package.appending(path: "steam_client_b_osx.manifest").plainPath, #""osx" { "version" "" }"#)
        fileSystem.addFile(package.appending(path: "steam_client_c_osx.manifest").plainPath,
                           #""osx" { "version" "14" }"# + String(repeating: " ", count: 1 << 20))
        #expect(detector().clientVersion() == "12")
    }

    @Test func withoutAPackageFolderThereIsNoVersion() {
        #expect(detector().clientVersion() == nil)
        fileSystem.addDirectory(locations.packageDirectory.plainPath)
        #expect(detector().clientVersion() == nil)
    }

    @Test func steamInTheUsersApplicationsFolder() {
        fileSystem.addDirectory("/Users/tenno/Applications/Steam.app")
        #expect(detector().status().appBundle?.plainPath == "/Users/tenno/Applications/Steam.app")
    }

    @Test func installedButNotRunning() {
        installSteam()
        let status = detector().status()
        #expect(status.installed && !status.running && !status.signedIn)
        #expect(status.connection == nil)
    }

    @Test func aReusedPidIsNotSteam() {
        installSteam()
        let status = detector([4242: .init(path: "/usr/bin/some_other_tool", start: steamStart)]).status()
        #expect(!status.running)
        #expect(!status.signedIn)
    }

    @Test(arguments: ["0", "-1", "", "not a pid"])
    func unusablePids(_ pid: String) {
        installSteam(pid: pid)
        #expect(detector([0: .init(path: "/x/steam_osx", start: nil), -1: .init(path: "/x/steam_osx", start: nil)])
            .status().running == false)
    }

    @Test func signedInBeforeThisSteamStartedDoesNotCount() {
        installSteam()
        let restarted = [Int32(4242): FakeProcessInspector.Entry(path: steamProcess[4242]!.path,
                                                                 start: steamStart.addingTimeInterval(3600))]
        let status = detector(restarted).status()
        #expect(status.running)
        #expect(status.connection == nil)
        #expect(!status.signedIn)
    }

    @Test func statusJSONUsesPlainPathsAndRoundTrips() throws {
        installSteam()
        let status = detector(steamProcess).status()
        let data = try JSONEncoder().encode(status)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["appBundle"] as? String == "/Applications/Steam.app")
        #expect(object["signedIn"] as? Bool == true)
        #expect(object["connection"] as? String == "Logged On")
        #expect(try JSONDecoder().decode(SteamStatus.self, from: data) == status)
    }

    @Test func statusOutputNeverContainsIdentifiers() throws {
        installSteam()
        let status = detector(steamProcess).status()
        let json = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)
        for text in [json, String(describing: status)] {
            for identifier in FakeIdentity.all { #expect(!text.contains(identifier), "\(identifier)") }
        }
    }

    @Test func locationLayout() {
        #expect(locations.clientDirectory.plainPath
            == "/Users/tenno/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS")
        #expect(locations.registryFile.plainPath == "/Users/tenno/Library/Application Support/Steam/registry.vdf")
        #expect(locations.connectionLog.plainPath
            == "/Users/tenno/Library/Application Support/Steam/logs/connection_log.txt")
        #expect(locations.packageDirectory.plainPath.hasSuffix("Contents/MacOS/package"))
        let support = "/Users/tenno/Library/Application Support/Steam/"
        #expect(locations.loginUsersFile.plainPath == support + "config/loginusers.vdf")
        #expect(locations.avatarCacheDirectory.plainPath == support + "config/avatarcache")
        #expect(locations.loginStateLog.plainPath == support + "logs/steamui_login.txt")
        #expect(locations.bootstrapLog.plainPath == support + "logs/bootstrap_log.txt")
        #expect(locations.gameProcessLog.plainPath == support + "logs/gameprocess_log.txt")
        #expect(SteamLocations.isClientManifest("steam_client_osx.manifest"))
        #expect(SteamLocations.isClientManifest("steam_client_signed-2_osx.manifest"))
        #expect(!SteamLocations.isClientManifest("steamui_osx.manifest"))
        #expect(!SteamLocations.isClientManifest("steam_client_osx.manifest.old"))
        #expect(locations.applicationCandidates.map(\.plainPath)
            == ["/Applications/Steam.app", "/Users/tenno/Applications/Steam.app"])
    }
}
