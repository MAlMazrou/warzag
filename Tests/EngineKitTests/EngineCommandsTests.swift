import Foundation
import Testing
import RuntimeKit
import WarzagCore
import WarzagTestSupport
import WineKit
@testable import EngineKit
@testable import warzagctl

@Suite struct EngineCommandsTests {
    let fixture = EngineFixture()

    var environment: EngineCLIEnvironment {
        EngineCLIEnvironment(engine: fixture.engine, macDriver: MacDriverSettings(retinaMode: false),
                             appVersion: "0.1.0", macOSVersion: "26.5.1",
                             currentDirectory: URL(filePath: "/Users/tenno/src/warzag", directoryHint: .isDirectory))
    }

    func runtime(_ line: String) async -> CommandResult {
        await EngineCLI.runtime(words(line), environment: environment)
    }

    func prefix(_ line: String) async -> CommandResult {
        await EngineCLI.prefix(words(line), environment: environment)
    }

    func words(_ line: String) -> [String] { line.split(separator: " ").map(String.init) }

    @Test(arguments: [
        ("status", EngineCLI.Arguments(words: ["status"])),
        ("status --json", EngineCLI.Arguments(words: ["status"], flags: ["--json"])),
        ("install --manifest m.json --pubkey AAAA --pack p.aar --reinstall",
         EngineCLI.Arguments(words: ["install"], flags: ["--reinstall"],
                             values: ["--manifest": "m.json", "--pubkey": "AAAA", "--pack": "p.aar"])),
        ("use-local build/n/Warzag.app --home /tmp/h",
         EngineCLI.Arguments(words: ["use-local", "build/n/Warzag.app"], values: ["--home": "/tmp/h"])),
    ])
    func argumentsParse(_ line: String, _ expected: EngineCLI.Arguments) throws {
        #expect(try EngineCLI.Arguments.parse(words(line)) == expected)
    }

    @Test(arguments: [
        ("runtime", "", "runtime needs a subcommand"),
        ("runtime", "frobnicate", "unknown command: runtime frobnicate"),
        ("runtime", "status --verbose", "unknown option: --verbose"),
        ("runtime", "status --library /x", "unknown option for status: --library"),
        ("runtime", "status extra", "unexpected argument: extra"),
        ("runtime", "use-local", "use-local needs the path of a Warzag.app runtime build"),
        ("runtime", "install --pubkey AAAA", "runtime install needs --manifest <file|https-url>"),
        ("prefix", "run --renderer metal -- x.exe", "unknown renderer: metal (dxmt or wined3d)"),
        ("prefix", "run --timeout soon -- x.exe", "--timeout needs a number of seconds"),
        ("runtime", "install --manifest http://x/m.json --pubkey AAAA", "only https URLs are supported: http://x/m.json"),
        ("runtime", "install --manifest", "--manifest needs a value"),
        ("prefix", "create --reinstall", "unknown option for create: --reinstall"),
        ("prefix", "doctor --library x", "unknown option for doctor: --library"),
        ("prefix", "path extra", "unexpected argument: extra"),
        ("prefix", "nuke", "unknown command: prefix nuke"),
    ])
    func usageErrorsExit64(_ group: String, _ line: String, _ message: String) async {
        let result = group == "runtime" ? await runtime(line) : await prefix(line)
        #expect(result.exitCode == 64)
        #expect(result.stderr.hasPrefix("warzagctl: \(message)\n"))
        #expect(result.stdout.isEmpty)
    }

    @Test func trustShowsWhatThisBuildPins() async throws {
        // The tests run in a debug build: the release key and the DEV key.
        let json = await runtime("trust --json")
        #expect(json.exitCode == 0)
        let report = try #require(try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
        #expect(report["build"] as? String == "debug")
        let keys = try #require(report["manifestKeys"] as? [[String: Any]])
        #expect(keys.compactMap { $0["id"] as? String }.sorted()
            == [RuntimeTrust.releaseKeyID, RuntimeTrust.developmentKeyID].sorted())
        #expect(report["signers"] as? [String] == [RuntimeTrust.projectCertificate])
        let text = await runtime("trust")
        #expect(text.stdout.contains("\(RuntimeTrust.releaseKeyID) (release) \(RuntimeTrust.releasePublicKey)"))
        // What a release build (App/make-app.sh) reports: the release key alone.
        let release = EngineCLI.trustReport(RuntimeTrust.pinned(debugBuild: false), debugBuild: false)
        #expect(release.build == "release")
        #expect(release.manifestKeys == [EngineCLI.TrustReport.Key(id: RuntimeTrust.releaseKeyID, name: "release",
                                                                   publicKey: RuntimeTrust.releasePublicKey)])
    }

    @Test func helpPrintsTheGroupsUsage() async {
        let result = await runtime("--help")
        #expect(result.exitCode == 0)
        #expect(result.stdout == EngineCLI.runtimeUsage + "\n")
        #expect(EngineCommands.prefix.usage == EngineCLI.prefixUsage)
    }

    @Test func statusWithNothingInstalled() async throws {
        let text = await runtime("status")
        #expect(text.exitCode == 0)
        #expect(text.stdout == """
            current   none (warzagctl runtime install, or runtime use-local for a development build)
            previous  none
            serial    no signed manifest accepted yet
            revoked   none

            """)
        let json = await runtime("status --json")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["runtime"])
        #expect((object["runtime"] as? [String: Any])?["current"] == nil)
    }

    @Test func useLocalResolvesRelativePathsAndReportsTheRegistration() async throws {
        fixture.makeHost()
        let result = await runtime("use-local build/n/Warzag.app")
        #expect(result.exitCode == 0)
        let id = "n-dev-" + RuntimeService.timestamp(fixture.clock.now)
        #expect(result.stdout.hasPrefix("registered development runtime \(id) from \(EngineFixture.devHost)\n"))
        #expect(result.stdout.contains("ad-hoc signed, development build"))
        #expect(result.stdout.hasSuffix("development only: this build is not a signed runtime pack\n"))

        let status = await runtime("status")
        #expect(status.stdout.contains("current   \(id) (version 0.1.0-dev."))
        #expect(status.stdout.contains("host      \(fixture.paths.gameHost(.n, version: "0.1.0-dev." + RuntimeService.timestamp(fixture.clock.now)).plainPath)\n"))
    }

    @Test func failuresExit1WithTheReason() async {
        let missing = await runtime("use-local /nowhere/Warzag.app")
        #expect(missing.exitCode == 1)
        #expect(missing.stderr == "warzagctl runtime use-local: not a Warzag runtime host: /nowhere/Warzag.app does not exist\n")
        let rollback = await runtime("rollback")
        #expect(rollback.exitCode == 1)
        #expect(rollback.stderr == "warzagctl runtime rollback: there is no previous runtime to roll back to\n")
        let create = await prefix("create")
        #expect(create.exitCode == 1)
        #expect(create.stderr.hasPrefix("warzagctl prefix create: no engine runtime is installed"))
        let key = await runtime("install --manifest m.json --pubkey !!!")
        #expect(key.stderr == "warzagctl runtime install: the public key must be a base64-encoded 32-byte Ed25519 key\n")
    }

    @Test func installVerifiesAndActivatesASignedPack() async throws {
        let (pack, manifest) = try fixture.pack(version: "0.2.0")
        fixture.fileSystem.addFile("/Users/tenno/src/warzag/dist/manifest.json", try EngineFixture.signed(manifest))
        let key = EngineFixture.publicKey.base64EncodedString()
        let result = await runtime("install --manifest dist/manifest.json --pubkey \(key) --pack \(pack.plainPath)")
        #expect(result.exitCode == 0, "\(result.stderr)")
        #expect(result.stdout.hasPrefix("installed runtime n-0.2.0\n"))

        // Another key cannot vouch for the same manifest.
        let stranger = EngineFixture.strangerKey.publicKey.rawRepresentation.base64EncodedString()
        let forged = await runtime("install --manifest dist/manifest.json --pubkey \(stranger)")
        #expect(forged.exitCode == 1)
        #expect(forged.stderr == "warzagctl runtime install: runtime manifest rejected: manifest signature does not verify\n")

        let (_, next) = try fixture.pack(version: "0.3.0", serial: 43)
        let url = URL(string: "https://runtime.example.org/stable/manifest.json")!
        fixture.http.respond(to: url, with: try EngineFixture.signed(next))
        fixture.http.respond(to: next.url, with: Data("warzag-pack 0.3.0".utf8))
        let remote = await runtime("install --manifest \(url.absoluteString) --pubkey \(key) --json")
        #expect(remote.exitCode == 0, "\(remote.stderr)")
        let status = try WarzagJSON.decoder().decode(RuntimeStatus.self, from: Data(remote.stdout.utf8))
        #expect(status.current?.id == "n-0.3.0")
        #expect(status.previous?.id == "n-0.2.0")
        #expect(status.lastSerial == 43)

        let rollback = await runtime("rollback")
        #expect(rollback.stdout == """
            rolled back to n-0.2.0 (\(fixture.paths.gameHost(.n, version: "0.2.0").plainPath))
            n-0.3.0 will not be installed again automatically

            """)
    }

    @Test func prefixCreateDoctorAndPathEndToEnd() async throws {
        fixture.makeHost()
        _ = await runtime("use-local \(EngineFixture.devHost)")
        let create = await prefix("create")
        #expect(create.exitCode == 0, "\(create.stderr)")
        #expect(create.stdout.contains("prefix    \(fixture.prefixRoot) (created)\n"))
        #expect(create.stdout.contains("identity  captured after the first boot (Identity/identity.json)\n"))
        #expect(create.stdout.hasSuffix("next: warzagctl prefix doctor\n"))

        let doctor = await prefix("doctor")
        #expect(doctor.exitCode == 0)
        #expect(doctor.stdout.hasSuffix("all 11 checks passed\n"))
        #expect(doctor.stdout.split(separator: "\n").filter { $0.hasPrefix("PASS") }.count == 11)

        let json = await prefix("doctor --json")
        let report = try WarzagJSON.decoder().decode(PrefixDoctorReport.self, from: Data(json.stdout.utf8))
        #expect(report.passed)
        #expect(json.stdout.contains(#""passed" : true"#))

        let repair = await prefix("repair --json")
        let repaired = try WarzagJSON.decoder().decode(PrefixReport.self, from: Data(repair.stdout.utf8))
        #expect(repaired.identity == .restored)
        #expect(!repaired.created)

        #expect(await prefix("path").stdout == fixture.prefixRoot + "\n")
        #expect(await prefix("path --json").stdout.contains(#""channel" : "n""#))

        try fixture.fileSystem.removeItem(at: URL(filePath: fixture.prefixRoot + "/drive_c/windows/system32/winemetal.dll"))
        let broken = await prefix("doctor")
        #expect(broken.exitCode == 1)
        #expect(broken.stdout.contains(#"FAIL  dxmt          missing or not the runtime's: C:\windows\system32\winemetal.dll"#))
        #expect(broken.stdout.hasSuffix("1 of 11 checks failed\n"))
    }

    @Test func repairKeepsTheMacDriverSettingsThePrefixWasSetUpWith() async throws {
        fixture.makeHost()
        _ = await runtime("use-local \(EngineFixture.devHost)")
        // A new prefix gets the tier preset (this environment: RetinaMode off).
        #expect(await prefix("create").exitCode == 0)
        let layout = fixture.layout
        #expect(try PrefixManifest.load(from: layout, fileSystem: fixture.fileSystem)?.macDriver.retinaMode == false)

        // The app later sets it up with the player's choices; a repair from the command line must not undo them.
        let chosen = MacDriverSettings(retinaMode: true, optionAsAlt: false, commandAsControl: true)
        _ = try await fixture.engine.prefix.repair(macDriver: chosen)
        let repair = await prefix("repair")
        #expect(repair.exitCode == 0, "\(repair.stderr)")
        #expect(try PrefixManifest.load(from: layout, fileSystem: fixture.fileSystem)?.macDriver.settings == chosen)
        let key = #"Software\Wine\Mac Driver"#
        #expect(fixture.wine.value(in: fixture.prefixRoot, .user, key, "RetinaMode") == .string("y"))
        #expect(fixture.wine.value(in: fixture.prefixRoot, .user, key, "LeftCommandIsCtrl") == .string("y"))
        #expect(fixture.wine.value(in: fixture.prefixRoot, .user, #"Control Panel\Desktop"#, "LogPixels") == .dword(192))
        #expect(await prefix("doctor").exitCode == 0)
    }

    @Test func homeAfterTheCommandWordMovesEverything() async throws {
        fixture.makeHost()
        let other = "/Users/tenno/scratch-home"
        _ = await runtime("use-local \(EngineFixture.devHost) --home \(other)")
        #expect(try fixture.engine.runtime.store.load().current == nil)
        let paths = WarzagPaths(home: URL(filePath: other, directoryHint: .isDirectory), userCacheDirectory: nil)
        #expect(fixture.fileSystem.fileExists(at: paths.activeRuntimePointer))
        #expect(await prefix("path --home \(other)").stdout == paths.prefix(for: .n).plainPath + "\n")
    }
}
