import Foundation
import Testing
import WarzagCore
import WarzagTestSupport
@testable import SteamHostKit

/// Made-up saved accounts. `first` is the one signed in on the "Logged On" line; `second` is the one AutoLogin and the
/// newest timestamp point at.
enum AccountFixture {
    static let firstSteamID64 = "76561198947920049"  // 76561197960265728 + 987654321
    static let secondSteamID64 = "76561198083722517"  // 76561197960265728 + 123456789
    static let persona = "SENTINEL_PERSONA"
    static let accountName = "SENTINEL_ACCOUNT"
    static let pinValues = ["SENTINEL_ALGORITHM", "SENTINEL_HASH", "SENTINEL_SALT"]
    /// Text that must never appear in anything Warzag prints about the account.
    static let secrets = [persona, accountName, firstSteamID64, "987654321"] + pinValues

    /// The current shape: AutoLogin, no MostRecent, and a lowercase "timestamp".
    static let currentShape = """
        "users"
        {
        \t"\(firstSteamID64)"
        \t{
        \t\t"AccountName"\t\t"\(accountName)"
        \t\t"PersonaName"\t\t"\(persona)"
        \t\t"RememberPassword"\t\t"1"
        \t\t"WantsOfflineMode"\t\t"0"
        \t\t"SkipOfflineModeWarning"\t\t"0"
        \t\t"AllowAutoLogin"\t\t"1"
        \t\t"AutoLogin"\t\t"0"
        \t\t"timestamp"\t\t"1792000000"
        \t\t"Algorithm"\t\t"\(pinValues[0])"
        \t\t"Hash"\t\t"\(pinValues[1])"
        \t\t"Salt"\t\t"\(pinValues[2])"
        \t}
        \t"\(secondSteamID64)"
        \t{
        \t\t"AccountName"\t\t"fake_second_account"
        \t\t"PersonaName"\t\t"Second Tenno"
        \t\t"RememberPassword"\t\t"1"
        \t\t"WantsOfflineMode"\t\t"1"
        \t\t"AutoLogin"\t\t"1"
        \t\t"timestamp"\t\t"1792100000"
        \t}
        }
        """

    /// The older shape: MostRecent and AllowAutoLogin, no AutoLogin key, "Timestamp".
    static let olderShape = """
        "users"
        {
        \t"\(firstSteamID64)"
        \t{
        \t\t"AccountName"\t\t"\(accountName)"
        \t\t"PersonaName"\t\t"\(persona)"
        \t\t"RememberPassword"\t\t"1"
        \t\t"MostRecent"\t\t"1"
        \t\t"AllowAutoLogin"\t\t"1"
        \t\t"WantsOfflineMode"\t\t"1"
        \t\t"Timestamp"\t\t"1700000000"
        \t}
        }
        """

    /// A PNG signature and a little more; Steam's real pictures are 184 x 184 RGBA.
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52])
}

@Suite struct LoginUsersTests {
    let fileSystem = InMemoryFileSystem()
    let file = URL(filePath: "/Users/tenno/Library/Application Support/Steam/config/loginusers.vdf")

    func read(_ text: String, includeAccountName: Bool = false) -> [LoginUser]? {
        fileSystem.addFile(file.plainPath, text)
        return LoginUsers.read(file, fileSystem: fileSystem, includeAccountName: includeAccountName)
    }

    @Test func theCurrentShapeWithSeveralAccounts() throws {
        let users = try #require(read(AccountFixture.currentShape))
        #expect(users.count == 2)
        let first = try #require(users.first { $0.steamID64 == UInt64(AccountFixture.firstSteamID64) })
        #expect(first.personaName == AccountFixture.persona)
        #expect(first.accountName == nil, "AccountName only on request")
        #expect(first.rememberPassword && first.autoLogin == false)
        let second = try #require(users.last)
        #expect(second.rememberPassword && second.autoLogin == true)
        #expect(read(AccountFixture.currentShape, includeAccountName: true)?.first?.accountName
            == AccountFixture.accountName)
    }

    @Test func theOlderShape() throws {
        let user = try #require(read(AccountFixture.olderShape)?.first)
        #expect(user.rememberPassword && user.autoLogin == nil)
    }

    @Test func thePINKeysAreNeverReadAndEntriesAreRedacted() throws {
        let users = try #require(read(AccountFixture.currentShape, includeAccountName: true))
        var dumped = ""
        dump(users, to: &dumped)
        let mirrored = users.flatMap { Mirror(reflecting: $0).children.map { "\($0.label ?? "") \($0.value)" } }
        for text in [String(describing: users), "\(users)", String(reflecting: users), dumped, mirrored.joined()] {
            for secret in AccountFixture.secrets { #expect(!text.contains(secret), "\(secret)") }
        }
        // The type has no field for them at all.
        let labels = Set(Mirror(reflecting: LoginUser(steamID64: 1, personaName: nil, accountName: nil,
                                                      rememberPassword: false, autoLogin: nil))
            .children.compactMap(\.label))
        #expect(labels.isEmpty)
    }

    @Test func aFileOver64KBTruncatedMissingOrOddGivesNothingUsable() {
        #expect(read(AccountFixture.currentShape + String(repeating: " ", count: 64 * 1024)) == nil)
        #expect(read(String(AccountFixture.currentShape.dropLast(20))) == nil)
        #expect(read("") == nil)
        #expect(read(#""users" { "not-a-steam-id" { "PersonaName" "x" } "1" "2" }"#) == [])
        try? fileSystem.removeItem(at: file)
        #expect(LoginUsers.read(file, fileSystem: fileSystem) == nil)
    }

    @Test func theSavedSignInTruthTable() {
        func hints(_ text: String?, autoLoginUser: Bool) -> SteamLoginHints {
            if let text { fileSystem.addFile(file.plainPath, text) } else { try? fileSystem.removeItem(at: file) }
            return LoginUsers.hints(users: LoginUsers.read(file, fileSystem: fileSystem), autoLoginUserSet: autoLoginUser)
        }
        // AutoLogin in use: the remembered account must be the AutoLogin one.
        #expect(hints(AccountFixture.currentShape, autoLoginUser: true).quietSignInLikely)
        #expect(!hints(AccountFixture.currentShape, autoLoginUser: false).quietSignInLikely)
        let noAutoLogin = AccountFixture.currentShape.replacingOccurrences(of: "\"AutoLogin\"\t\t\"1\"",
                                                                          with: "\"AutoLogin\"\t\t\"0\"")
        #expect(!hints(noAutoLogin, autoLoginUser: true).quietSignInLikely)
        let forgotten = AccountFixture.currentShape.replacingOccurrences(of: "\"RememberPassword\"\t\t\"1\"",
                                                                        with: "\"RememberPassword\"\t\t\"0\"")
        #expect(!hints(forgotten, autoLoginUser: true).quietSignInLikely)
        // The older shape has no AutoLogin: RememberPassword is enough.
        #expect(hints(AccountFixture.olderShape, autoLoginUser: true).quietSignInLikely)
        #expect(!hints(AccountFixture.olderShape.replacingOccurrences(of: "\"RememberPassword\"\t\t\"1\"",
                                                                      with: "\"RememberPassword\"\t\t\"0\""),
                       autoLoginUser: true).quietSignInLikely)
        #expect(hints(nil, autoLoginUser: true) == .none)
    }
}

@Suite struct SteamAccountTests {
    let fileSystem = InMemoryFileSystem()
    let home = URL(filePath: "/Users/tenno", directoryHint: .isDirectory)
    var locations: SteamLocations {
        SteamLocations(home: home, systemApplications: URL(filePath: "/Applications", directoryHint: .isDirectory))
    }
    let process: [Int32: FakeProcessInspector.Entry] = [4242: .init(
        path: "/Users/tenno/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx",
        start: LogFixture.steamStart)]

    var detector: SteamDetector {
        SteamDetector(locations: locations, fileSystem: fileSystem, processes: FakeProcessInspector(process),
                      timeZone: LogFixture.utc)
    }

    var avatar: String { locations.avatarCacheDirectory.appending(path: "\(AccountFixture.firstSteamID64).png").plainPath }

    /// Steam signed in as the first account (the "Logged On" line's), with both accounts saved and pictures cached.
    func signIn(_ state: String = "Logged On", account: String = "[U:1:987654321]") {
        fileSystem.addDirectory("/Applications/Steam.app")
        fileSystem.addFile(locations.registryFile.plainPath, """
            "Registry" { "HKLM" { "Software" { "Valve" { "Steam" { "SteamPID" "4242" } } } }
                         "HKCU" { "Software" { "Valve" { "Steam" { "AutoLoginUser" "fake_second_account" } } } } }
            """)
        fileSystem.addFile(locations.loginUsersFile.plainPath, AccountFixture.currentShape)
        fileSystem.addFile(avatar, AccountFixture.png)
        fileSystem.addFile(locations.avatarCacheDirectory.appending(path: "\(AccountFixture.secondSteamID64).png")
            .plainPath, AccountFixture.png + Data([1]))
        fileSystem.addFile(locations.connectionLog.plainPath, LogFixture.lines([
            (-100, "[Logged On, 0, 341] [U:1:123456789] OK"),
            (5, "[Logging On, 0, 341] \(account) LogOn()"),
            (6, "[\(state), 0, 341] \(account) RecvMsgClientLogOnResponse() : \(account) 'OK'"),
        ]))
    }

    @Test func theLoggedOnAccountWinsOverAutoLoginAndTheNewestTimestamp() throws {
        signIn()
        let status = detector.status()
        let account = try #require(detector.account(for: status))
        #expect(account.displayName == AccountFixture.persona)
        #expect(account.steamID64 == UInt64(AccountFixture.firstSteamID64))
        #expect(account.avatarPNG() == AccountFixture.png)
        #expect(detector.account(for: status, name: .signInName)?.displayName == AccountFixture.accountName)
        #expect(detector.loginHints() == SteamLoginHints(quietSignInLikely: true))
    }

    @Test func signedOutGivesNoAccountEvenWithAnEntryAndAPicture() {
        signIn("Logged Off")
        #expect(detector.account(for: detector.status()) == nil)
        signIn(account: "[U:1:0]")
        #expect(detector.status().signedIn)
        #expect(detector.account(for: detector.status()) == nil, "no account on the Logged On line")
        // Not running any more, or a status from before a restart.
        signIn()
        let status = detector.status()
        let quit = SteamDetector(locations: locations, fileSystem: fileSystem, processes: FakeProcessInspector(),
                                 timeZone: LogFixture.utc)
        #expect(quit.account(for: status) == nil)
    }

    @Test func anAccountSteamKeepsNoEntryForHasNoName() throws {
        signIn(account: "[U:1:555]")
        let account = try #require(detector.account(for: detector.status()))
        #expect(account.displayName == nil)
        #expect(account.avatarPNG() == nil)
        // The right account, but loginusers.vdf is being rewritten: no name (the app keeps the last good one).
        signIn()
        fileSystem.addFile(locations.loginUsersFile.plainPath, "\"users\" {")
        #expect(try #require(detector.account(for: detector.status())).displayName == nil)
    }

    @Test func thePictureMustBeAPNGOfAtMost2MB() throws {
        signIn()
        let account = try #require(detector.account(for: detector.status()))
        #expect(account.avatarPNG() != nil)
        fileSystem.addFile(avatar, Data("GIF89a not a png".utf8))
        #expect(account.avatarPNG() == nil)
        var large = AccountFixture.png
        large.append(Data(count: 3 * 1024 * 1024))
        fileSystem.addFile(avatar, large)
        #expect(account.avatarPNG() == nil)
        var limit = AccountFixture.png
        limit.append(Data(count: SteamAccount.avatarByteLimit - AccountFixture.png.count))
        fileSystem.addFile(avatar, limit)
        #expect(account.avatarPNG()?.count == SteamAccount.avatarByteLimit)
        try fileSystem.removeItem(at: URL(filePath: avatar))
        #expect(account.avatarPNG() == nil)
    }

    @Test func theAccountIsRedactedEverywhereButItsDisplayName() throws {
        signIn()
        let account = try #require(detector.account(for: detector.status()))
        var dumped = ""
        dump(account, to: &dumped)
        let mirror = Mirror(reflecting: account)
        let texts = [String(describing: account), "\(account)", String(reflecting: account), dumped,
                     mirror.children.map { "\($0.label ?? "") \($0.value)" }.joined(), "\(Optional(account) as Any)"]
        for text in texts {
            for secret in AccountFixture.secrets { #expect(!text.contains(secret), "\(text)") }
        }
        #expect(String(describing: account) == "<redacted>")
        #expect(mirror.children.isEmpty)
    }

    @Test(arguments: [
        ("Tenno", "Tenno"),
        ("  Tenno\n\tPrime  ", "Tenno Prime"),
        ("Ten\u{0007}no\u{001B}", "Tenno"),
        ("\u{202E}onneT\u{202C}", "onneT"),
        ("\u{2066}Tenno\u{2069} \u{202A}x\u{202B}\u{202D}", "Tenno x"),
        ("line\u{2028}two\u{2029}three\u{0085}four", "line two three four"),
        ("مرحبا ✓ 🧑‍🚀", "مرحبا ✓ 🧑‍🚀"),
        ("\n\t \u{202E}", nil),
        ("", nil),
    ] as [(String, String?)])
    func theNameCleaner(_ raw: String, _ cleaned: String?) {
        #expect(SteamAccount.clean(raw) == cleaned)
    }

    @Test func aLongNameIsCutAtTheEnd() {
        let cleaned = SteamAccount.clean(String(repeating: "A", count: 63) + " " + String(repeating: "B", count: 100))
        #expect(cleaned == String(repeating: "A", count: 63))
        #expect(SteamAccount.clean(String(repeating: "x", count: 500))?.count == SteamAccount.longestName)
    }
}
