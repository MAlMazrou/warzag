import Foundation
import Testing
import RuntimeKit
import WarzagCore
import WarzagTestSupport
import WineKit
@testable import EngineKit

@Suite struct PrefixCreationTests {
    let fixture = EngineFixture()
    var prefix: PrefixService { fixture.engine.prefix }
    var root: String { fixture.prefixRoot }
    var profile: String { root + "/drive_c/users/tenno" }
    let macDriver = MacDriverSettings(retinaMode: false)

    func activeHost() throws -> String { try fixture.engine.runtime.active().host.bundle.plainPath }

    @Test func aNewPrefixGetsEverythingInOrder() async throws {
        try fixture.registerDevelopmentRuntime()
        let report = try await prefix.create(macDriver: macDriver)
        let host = try activeHost()
        let log = fixture.paths.logs.plainPath + "/prefix-n.log"
        #expect(report == PrefixReport(
            prefix: root, channel: .n, runtimeID: try #require(try fixture.engine.runtime.store.load().current?.id),
            created: true, library: fixture.library, identity: .captured,
            replacedFolderLinks: ["Desktop", "Documents", "Downloads", "Music", "Videos"],
            filesInstalled: 7, log: log))

        let vol = #"cmd /c vol C: > C:\windows\temp\warzag-vol-C.txt & vol X: > C:\windows\temp\warzag-vol-X.txt"#
        #expect(fixture.runner.commandLines == [
            "wine wineboot --init",
            "wineserver -w",
            "wine " + vol,
            #"wine reg import C:\windows\temp\warzag-prefix.reg"#,
            #"wine reg import C:\windows\temp\warzag-steam.reg"#,
            "wineserver -w",
        ])
        for command in fixture.runner.commands {
            let environment = try #require(command.environment)
            #expect(environment["WINEPREFIX"] == root)
            #expect(environment["WINEARCH"] == nil && environment["WINEMSYNC"] == nil)
            #expect(environment["NEUTRON_MSYNC"] == "0")
            #expect(environment["WINEDEBUG"] == "-all")
            #expect(environment["SteamDeck"] == "0")
            #expect(environment["WINEDLLPATH"] == nil && environment["WINEDLLPATH_PREPEND"] == nil)
            #expect(environment["DYLD_INSERT_LIBRARIES"] == nil && environment["SteamAppUser"] == nil)
            #expect(environment["SteamAppId"] == nil)
            #expect(command.logFile?.plainPath == log)
            // wineserver is a Unix program: run straight from the bundle, never through wine.
            let program = command.executable.lastPathComponent
            #expect(command.executable.plainPath == host + "/Contents/MacOS/" + program)
        }
        let wineboot = fixture.runner.commands[0]
        #expect(wineboot.environment?["WINEDLLOVERRIDES"] == "mscoree,mshtml=")
        #expect(fixture.runner.commands.dropFirst().allSatisfy { $0.environment?["WINEDLLOVERRIDES"] == nil })
    }

    @Test func placeholdersBridgeFilesAndTheLibraryDrive() async throws {
        try fixture.registerDevelopmentRuntime()
        _ = try await prefix.create(macDriver: macDriver)
        let system32 = root + "/drive_c/windows/system32"
        #expect(fixture.fileSystem.text(at: system32 + "/winemetal.dll") == "dxmt aarch64 winemetal.dll 0.1.0")
        // Wine's own nvapi64 stub is replaced by DXMT's.
        #expect(fixture.fileSystem.text(at: system32 + "/nvapi64.dll") == "dxmt aarch64 nvapi64.dll 0.1.0")
        #expect(fixture.fileSystem.text(at: system32 + "/nvngx.dll") == "dxmt aarch64 nvngx.dll 0.1.0")
        #expect(fixture.fileSystem.text(at: system32 + "/lsteamclient.dll") == "lsteamclient 0.1.0")
        // d3d11/dxgi come from the overlay at run time; no placeholder is copied for them.
        #expect(fixture.fileSystem.text(at: system32 + "/d3d11.dll") == nil)

        let steam = root + "/drive_c/Program Files (x86)/Steam"
        #expect(fixture.fileSystem.text(at: steam + "/steam.exe") == "steam.exe 0.1.0")
        #expect(fixture.fileSystem.text(at: steam + "/steamclient64.dll") == "steamclient64-forwarder.dll 0.1.0")
        #expect(fixture.fileSystem.text(at: steam + "/wz-steamprobe.exe") == "wz-steamprobe.exe 0.1.0")

        #expect(fixture.fileSystem.links[root + "/dosdevices/x:"] == fixture.library)
        #expect(fixture.fileSystem.directoryExists(at: URL(filePath: fixture.library)))
        #expect(try fixture.fileSystem.contentsOfDirectory(at: fixture.layout.windowsTemp).isEmpty)
    }

    @Test func userFoldersBecomeRealFoldersExceptPictures() async throws {
        try fixture.registerDevelopmentRuntime()
        _ = try await prefix.create(macDriver: macDriver)
        for folder in ["Desktop", "Documents", "Downloads", "Music", "Videos"] {
            let url = URL(filePath: "\(profile)/\(folder)")
            #expect(!fixture.fileSystem.isSymbolicLink(at: url))
            #expect(fixture.fileSystem.directoryExists(at: url))
            #expect(fixture.fileSystem.fileExists(at: url.appending(path: PrefixService.keepFileName)))
        }
        #expect(fixture.fileSystem.links[profile + "/Pictures"] == "/Users/tenno/Pictures")
        // The Mac's own folders were never touched (they do not even exist in the fake).
        #expect(!fixture.fileSystem.fileExists(at: URL(filePath: "/Users/tenno/Documents")))
    }

    @Test func theRegistryIsTheTemplatePlusIdentityThenTheBridgesSteamReg() async throws {
        try fixture.registerDevelopmentRuntime()
        _ = try await prefix.create(macDriver: MacDriverSettings(retinaMode: true))
        let imports = fixture.wine.imports
        #expect(imports.count == 2)
        let template = try RegeditFile.parse(imports[0])
        #expect(template.contains(RegistryEntry(hive: .user, key: #"Software\Wine\Mac Driver"#, name: "RetinaMode",
                                                value: .string("y"))))
        #expect(template.contains(RegistryEntry(hive: .user, key: #"Software\Wine\AppDefaults\Launcher.exe\DllOverrides"#,
                                                name: "nvngx", value: .string(""))))
        #expect(template.contains(RegistryEntry(hive: .system, key: #"Software\Microsoft\Cryptography"#,
                                                name: "MachineGuid", value: .string("0246cdda-9597-4817-832b-facf99e960fa"))))
        #expect(template.contains(RegistryEntry(hive: .user, key: #"Software\Wine\Network"#,
                                                name: "UseDnsComputerName", value: .string("N"))))
        #expect(!imports[0].contains("Valve"))
        // steam.reg is imported exactly as the runtime ships it: the one source of Steam keys.
        #expect(imports[1] == EngineFixture.steamReg)
        #expect(fixture.wine.value(in: root, .user, #"Software\Valve\Steam\ActiveProcess"#, "Universe") == .string("Public"))
    }

    @Test func theIdentityIsCapturedAfterTheFirstBootAndPinned() async throws {
        try fixture.registerDevelopmentRuntime()
        _ = try await prefix.create(macDriver: macDriver)
        let identity = try #require(try fixture.engine.identity.load())
        #expect(identity == MachineIdentity(
            machineGuid: "0246cdda-9597-4817-832b-facf99e960fa", computerName: "TENNOS-MAC",
            volumeSerials: ["C": "43000000", "X": "58000000"], windowsUserName: "tenno", capturedAt: fixture.clock.now))
        #expect(fixture.fileSystem.text(at: root + "/drive_c/.windows-serial") == "43000000\n")
        #expect(fixture.fileSystem.text(at: fixture.library + "/.windows-serial") == "58000000\n")

        // Renaming the Mac does not rename the PC Windows programs see.
        fixture.wine.setHostName("RENAMED-MAC")
        _ = try await prefix.runProgram("hello.exe", renderer: RendererOptions(renderer: .wined3d))
        #expect(fixture.wine.value(in: root, .system, MachineIdentity.computerNameKey, "ComputerName") == .string("TENNOS-MAC"))
    }

    @Test func aRebuiltPrefixGetsTheSavedIdentityBack() async throws {
        try fixture.registerDevelopmentRuntime()
        _ = try await prefix.create(macDriver: macDriver)
        let saved = try #require(try fixture.engine.identity.load())

        try fixture.fileSystem.removeItem(at: URL(filePath: root))
        fixture.wine.setHostName("RENAMED-MAC")
        fixture.clock.advance(by: 3600)
        let report = try await prefix.create(macDriver: macDriver)
        #expect(report.created)
        #expect(report.identity == .restored)
        #expect(fixture.wine.boots == 2)
        // The second boot made a new MachineGuid and took the new host name; the vault's values replaced both.
        #expect(fixture.wine.value(in: root, .system, MachineIdentity.cryptographyKey, "MachineGuid")
            == .string(saved.machineGuid))
        #expect(fixture.wine.value(in: root, .system, MachineIdentity.computerNameKey, "ComputerName")
            == .string(saved.computerName))
        #expect(try fixture.engine.identity.load() == saved)
        #expect(fixture.fileSystem.text(at: root + "/drive_c/.windows-serial") == "43000000\n")
        #expect(await prefix.doctor().passed)
    }

    @Test func createIsIdempotent() async throws {
        try fixture.registerDevelopmentRuntime()
        let first = try await prefix.create(macDriver: macDriver)
        let manifest = try #require(try PrefixManifest.load(from: fixture.layout, fileSystem: fixture.fileSystem))
        fixture.clock.advance(by: 60)
        let second = try await prefix.create(macDriver: macDriver)
        #expect(!second.created)
        #expect(second.identity == .restored)
        #expect(second.replacedFolderLinks.isEmpty)
        #expect(fixture.wine.boots == 1)
        // Set up for this runtime already: the boot is a normal session start, Wine's prefix update is not redone.
        #expect(fixture.wine.updates == 1)
        let updated = try #require(try PrefixManifest.load(from: fixture.layout, fileSystem: fixture.fileSystem))
        #expect(updated.createdAt == manifest.createdAt)
        #expect(updated.configuredAt == manifest.configuredAt.addingTimeInterval(60))
        #expect(first.runtimeID == second.runtimeID)
    }

    @Test func theManifestRecordsTheRuntimeAndSettings() async throws {
        try fixture.registerDevelopmentRuntime()
        _ = try await prefix.create(macDriver: MacDriverSettings(retinaMode: true, commandAsControl: true))
        let manifest = try #require(try PrefixManifest.load(from: fixture.layout, fileSystem: fixture.fileSystem))
        let runtime = try #require(try fixture.engine.runtime.store.load().current)
        #expect(manifest == PrefixManifest(
            channel: .n, runtimeID: runtime.id, runtimeVersion: runtime.version, library: fixture.library,
            macDriver: MacDriverOptions(MacDriverSettings(retinaMode: true, commandAsControl: true)),
            createdAt: fixture.clock.now, configuredAt: fixture.clock.now))
    }

    @Test func aChosenLibraryIsKeptByLaterRepairs() async throws {
        try fixture.registerDevelopmentRuntime()
        fixture.fileSystem.addDirectory("/Volumes/Games")
        let library = URL(filePath: "/Volumes/Games/Warframe.noindex", directoryHint: .isDirectory)
        let report = try await prefix.create(library: library, macDriver: macDriver)
        #expect(report.library == library.plainPath)
        #expect(fixture.fileSystem.links[root + "/dosdevices/x:"] == library.plainPath)
        #expect(try await prefix.repair(macDriver: macDriver).library == library.plainPath)
        #expect(fixture.fileSystem.text(at: library.plainPath + "/.windows-serial") == "58000000\n")
        #expect(await prefix.doctor().passed)
    }

    @Test func aLibraryOnAnUnmountedVolumeIsNeverCreatedOnTheStartupDisk() async throws {
        try fixture.registerDevelopmentRuntime()
        let library = URL(filePath: "/Volumes/Games/Warframe.noindex", directoryHint: .isDirectory)
        await #expect(throws: PrefixError.libraryUnavailable(library.plainPath)) {
            _ = try await prefix.create(library: library, macDriver: macDriver)
        }
        #expect(!fixture.fileSystem.fileExists(at: URL(filePath: "/Volumes/Games")))
    }

    @Test func anUnreadableManifestIsRewrittenAndTheMappedLibraryKept() async throws {
        try fixture.registerDevelopmentRuntime()
        fixture.fileSystem.addDirectory("/Volumes/Games")
        let library = "/Volumes/Games/Warframe.noindex"
        _ = try await prefix.create(library: URL(filePath: library), macDriver: macDriver)
        fixture.fileSystem.addFile(PrefixManifest.url(in: fixture.layout).plainPath, "{damaged")
        let before = await prefix.doctor()
        #expect(before.checks.filter { !$0.passed }.map(\.name) == ["manifest"])

        let report = try await prefix.repair(macDriver: macDriver)
        #expect(report.library == library)
        #expect(try PrefixManifest.load(from: fixture.layout, fileSystem: fixture.fileSystem)?.library == library)
        #expect(await prefix.doctor().passed)
    }
}

@Suite struct PrefixFailureTests {
    let fixture = EngineFixture()
    var prefix: PrefixService { fixture.engine.prefix }
    let macDriver = MacDriverSettings(retinaMode: false)

    @Test func nothingRunsWithoutARuntime() async throws {
        await #expect(throws: RuntimeServiceError.noRuntime) { _ = try await prefix.create(macDriver: macDriver) }
        #expect(fixture.runner.commandLines.isEmpty)
        #expect(!fixture.fileSystem.fileExists(at: URL(filePath: fixture.prefixRoot)))
    }

    @Test func anIncompleteRuntimeIsReportedBeforeAnythingRuns() async throws {
        try fixture.registerDevelopmentRuntime()
        let host = try fixture.engine.runtime.active().host
        try fixture.fileSystem.removeItem(at: RuntimeHostLayout(host).steamRegistry)
        await #expect(throws: PrefixError.hostIncomplete(RuntimeHostLayout(host).steamRegistry.plainPath)) {
            _ = try await prefix.create(macDriver: macDriver)
        }
        #expect(!fixture.runner.commandLines.contains { $0.hasPrefix("wine") })
    }

    @Test func repairNeedsAnExistingPrefix() async throws {
        try fixture.registerDevelopmentRuntime()
        await #expect(throws: PrefixError.notCreated(fixture.prefixRoot)) {
            _ = try await prefix.repair(macDriver: macDriver)
        }
    }

    @Test func aFailingToolNamesTheLog() async throws {
        try fixture.registerDevelopmentRuntime()
        fixture.wine.fail { $0.arguments.first == "reg" ? 1 : nil }
        await #expect(throws: PrefixError.toolFailed(command: "reg import warzag-prefix.reg", exitCode: 1,
                                                     log: fixture.paths.logs.plainPath + "/prefix-n.log")) {
            _ = try await prefix.create(macDriver: macDriver)
        }
    }

    @Test func aBootThatLeavesNoPrefixIsReported() async throws {
        try fixture.registerDevelopmentRuntime()
        fixture.wine.fail { $0.arguments == ["wineboot", "--init"] ? 0 : nil }
        await #expect(throws: PrefixError.bootFailed(log: fixture.paths.logs.plainPath + "/prefix-n.log")) {
            _ = try await prefix.create(macDriver: macDriver)
        }
    }

    @Test func anXDriveThatIsNotALinkIsLeftAlone() async throws {
        try fixture.registerDevelopmentRuntime()
        _ = try await prefix.create(macDriver: macDriver)
        let drive = fixture.prefixRoot + "/dosdevices/x:"
        try fixture.fileSystem.removeItem(at: URL(filePath: drive))
        fixture.fileSystem.addFile(drive + "/precious.txt", "keep")
        await #expect(throws: PrefixError.libraryConflict(drive)) { _ = try await prefix.repair(macDriver: macDriver) }
        #expect(fixture.fileSystem.text(at: drive + "/precious.txt") == "keep")
    }

    @Test func anUnreadableVolumeSerialStopsCapture() async throws {
        try fixture.registerDevelopmentRuntime()
        fixture.wine.fail { $0.arguments.first == "cmd" ? 1 : nil }
        await #expect(throws: PrefixError.volumeSerialUnreadable(drive: "C", log: fixture.paths.logs.plainPath + "/prefix-n.log")) {
            _ = try await prefix.create(macDriver: macDriver)
        }
        #expect(try fixture.engine.identity.load() == nil)
    }
}

/// Wine writes .update-timestamp before it runs wine.inf, so Wine itself never redoes an update that was cut short.
@Suite struct PrefixResumeTests {
    let fixture = EngineFixture()
    var prefix: PrefixService { fixture.engine.prefix }
    var root: String { fixture.prefixRoot }
    let macDriver = MacDriverSettings(retinaMode: false)

    @Test func aFirstBootCutShortIsRedoneByTheNextCreate() async throws {
        try fixture.registerDevelopmentRuntime()
        fixture.wine.simulateInterruptedFirstBoot(root)
        #expect(fixture.fileSystem.text(at: root + "/" + PrefixService.wineUpdateTimestamp) == fixture.wine.timestampText)

        // The timestamp is current, so wineboot alone would skip the update and the boot would fail.
        let report = try await prefix.create(macDriver: macDriver)
        #expect(report.created)
        #expect(fixture.wine.boots == 1)
        #expect(fixture.wine.updates == 1)
        #expect(fixture.fileSystem.directoryExists(at: URL(filePath: root + "/drive_c/windows/system32")))
        #expect(fixture.fileSystem.links[root + "/drive_c/users/tenno/Pictures"] == "/Users/tenno/Pictures")
        // The interrupted boot's MachineGuid is the identity from now on.
        #expect(try fixture.engine.identity.load()?.machineGuid == "0246cdda-9597-4817-832b-facf99e960fa")
        #expect(await prefix.doctor().passed)
    }

    @Test func aRuntimeUpdateCutShortIsRedoneByRepair() async throws {
        try fixture.registerDevelopmentRuntime()
        _ = try await prefix.create(macDriver: macDriver)
        fixture.clock.advance(by: 60)
        try fixture.registerDevelopmentRuntime(version: "0.2.0")
        fixture.wine.simulateRuntimeUpdate()
        fixture.wine.simulateInterruptedUpdate(root)

        _ = try await prefix.repair(macDriver: macDriver)
        #expect(fixture.wine.updates == 2)
        #expect(fixture.fileSystem.text(at: root + "/drive_c/windows/system32/nvapi64.dll") == "dxmt aarch64 nvapi64.dll 0.2.0")
        #expect(fixture.fileSystem.text(at: root + "/" + PrefixService.wineUpdateTimestamp) == fixture.wine.timestampText)
        #expect(await prefix.doctor().passed)

        // The prefix now names the active runtime: the next repair is a normal session start again.
        _ = try await prefix.repair(macDriver: macDriver)
        #expect(fixture.wine.updates == 2)
    }
}

@Suite struct PrefixRepairAndDoctorTests {
    let fixture = EngineFixture()
    var prefix: PrefixService { fixture.engine.prefix }
    var root: String { fixture.prefixRoot }
    let macDriver = MacDriverSettings(retinaMode: false)

    func failing(_ report: PrefixDoctorReport) -> [String] { report.checks.filter { !$0.passed }.map(\.name) }

    @Test func aFreshPrefixPassesEveryCheck() async throws {
        try fixture.registerDevelopmentRuntime()
        _ = try await prefix.create(macDriver: macDriver)
        let report = await prefix.doctor()
        #expect(report.checks.map(\.name) == PrefixService.checkNames)
        #expect(failing(report).isEmpty)
        #expect(report.passed)
        #expect(report.lines.allSatisfy { $0.hasPrefix("PASS  ") })
        #expect(report.lines[4] == "PASS  dxmt          3 files match the runtime")
        #expect(report.lines[5] == "PASS  lsteamclient  1 file matches the runtime")
        #expect(report.checks.first { $0.name == "steam" }?.detail == "10 values from the bridge's steam.reg")
        // Identity values are never printed.
        let text = report.lines.joined(separator: "\n")
        #expect(!text.contains("0246cdda") && !text.contains("TENNOS-MAC"))
    }

    @Test func aRuntimeUpdateIsDetectedAndRepairedWithoutRecreatingThePrefix() async throws {
        try fixture.registerDevelopmentRuntime()
        _ = try await prefix.create(macDriver: macDriver)
        fixture.fileSystem.addFile(fixture.layout.eeConfig.plainPath, "player settings")

        // A newer runtime, whose first session start updated the prefix and put Wine's stubs back.
        fixture.clock.advance(by: 60)
        let next = try fixture.registerDevelopmentRuntime(version: "0.2.0")
        fixture.wine.simulateRuntimeUpdate()
        _ = try await fixture.engine.runner.run(Command(
            executable: try fixture.engine.runtime.active().host.wine, arguments: ["wineboot", "--init"],
            environment: WineEnvironment.toolRun(prefix: fixture.layout.root)))
        let before = await prefix.doctor()
        #expect(failing(before) == ["manifest", "dxmt", "lsteamclient", "bridge"])
        #expect(before.checks.first { $0.name == "manifest" }?.detail.contains("warzagctl prefix repair") == true)

        let report = try await prefix.repair(macDriver: macDriver)
        #expect(!report.created)
        #expect(report.runtimeID == next.current?.id)
        #expect(fixture.wine.boots == 1)
        #expect(fixture.fileSystem.text(at: root + "/drive_c/windows/system32/nvapi64.dll") == "dxmt aarch64 nvapi64.dll 0.2.0")
        #expect(fixture.fileSystem.text(at: fixture.layout.eeConfig.plainPath) == "player settings")
        #expect(failing(await prefix.doctor()).isEmpty)
    }

    @Test func driftIsReportedPerItem() async throws {
        try fixture.registerDevelopmentRuntime()
        _ = try await prefix.create(macDriver: macDriver)
        let profile = root + "/drive_c/users/tenno"
        for folder in ["Desktop", "Documents"] {
            try fixture.fileSystem.removeItem(at: URL(filePath: profile + "/" + folder))
            fixture.fileSystem.addLink(profile + "/" + folder, to: "/Users/tenno/" + folder)
        }
        try fixture.fileSystem.removeItem(at: URL(filePath: root + "/drive_c/Program Files (x86)/Steam/steam.exe"))
        fixture.wine.setValue(in: root, .user, #"Software\Valve\Steam"#, "SteamPath", .string(#"C:\Steam"#))
        fixture.wine.setValue(in: root, .user, #"Software\Wine\Mac Driver"#, "RetinaMode", .string("y"))
        fixture.wine.setValue(in: root, .system, MachineIdentity.cryptographyKey, "MachineGuid",
                              .string("11111111-2222-3333-4444-555555555555"))
        fixture.fileSystem.addFile(fixture.library + "/.windows-serial", "DEADBEEF\n")

        let report = await prefix.doctor()
        #expect(failing(report) == ["bridge", "registry", "steam", "folders", "identity"])
        func detail(_ name: String) -> String { report.checks.first { $0.name == name }?.detail ?? "" }
        #expect(detail("bridge") == #"missing or not the runtime's: C:\Program Files (x86)\Steam\steam.exe"#)
        #expect(detail("registry") == #"missing or different: HKCU\Software\Wine\Mac Driver\RetinaMode"#)
        #expect(detail("steam") == #"missing or different: HKCU\Software\Valve\Steam\SteamPath"#)
        #expect(detail("folders") == "Desktop links into the Mac home; Documents links into the Mac home")
        #expect(detail("identity") == "differs from Identity/identity.json: MachineGuid, X: volume serial (warzagctl prefix repair)")

        _ = try await prefix.repair(macDriver: macDriver)
        #expect(failing(await prefix.doctor()).isEmpty)
    }

    @Test func commandAsControlCanBeTurnedOffAgain() async throws {
        try fixture.registerDevelopmentRuntime()
        _ = try await prefix.create(macDriver: MacDriverSettings(retinaMode: false, commandAsControl: true))
        let key = #"Software\Wine\Mac Driver"#
        #expect(fixture.wine.value(in: root, .user, key, "LeftCommandIsCtrl") == .string("y"))

        // Off is written as "n": leaving the value out would keep the old "y".
        _ = try await prefix.repair(macDriver: MacDriverSettings(retinaMode: false, commandAsControl: false))
        #expect(fixture.wine.value(in: root, .user, key, "LeftCommandIsCtrl") == .string("n"))
        #expect(fixture.wine.value(in: root, .user, key, "RightCommandIsCtrl") == .string("n"))
        #expect(await prefix.doctor().passed)

        fixture.wine.setValue(in: root, .user, key, "RightCommandIsCtrl", .string("y"))
        #expect(failing(await prefix.doctor()) == ["registry"])
    }

    @Test func aMissingPrefixFailsEveryPrefixCheck() async throws {
        try fixture.registerDevelopmentRuntime()
        let report = await prefix.doctor()
        #expect(failing(report) == Array(PrefixService.checkNames.dropFirst()))
        #expect(report.checks[1].detail == "no prefix at \(root) (warzagctl prefix create)")
    }

    @Test func withoutARuntimeTheHostChecksFail() async throws {
        try fixture.registerDevelopmentRuntime()
        _ = try await prefix.create(macDriver: macDriver)
        let current = try #require(try fixture.engine.runtime.store.load().current)
        try fixture.fileSystem.removeItem(at: fixture.paths.runtimeVersionDirectory(.n, version: current.version))
        let report = await prefix.doctor()
        #expect(failing(report) == ["runtime", "dxmt", "lsteamclient", "bridge", "steam"])
    }

    @Test func anIdentityWithoutTheXDriveGetsItOnRepair() async throws {
        try fixture.registerDevelopmentRuntime()
        _ = try await prefix.create(macDriver: macDriver)
        var identity = try #require(try fixture.engine.identity.load())
        identity.volumeSerials["X"] = nil
        try fixture.engine.identity.save(identity)
        try fixture.fileSystem.removeItem(at: URL(filePath: fixture.library + "/.windows-serial"))

        _ = try await prefix.repair(macDriver: macDriver)
        let repaired = try #require(try fixture.engine.identity.load())
        #expect(repaired.volumeSerials == ["C": "43000000", "X": "58000000"])
        #expect(repaired.machineGuid == identity.machineGuid)
        #expect(fixture.runner.commandLines.last { $0.contains("cmd") }
            == #"wine cmd /c vol X: > C:\windows\temp\warzag-vol-X.txt"#)
    }

    @Test func programsRunWithTheSessionEnvironment() async throws {
        try fixture.registerDevelopmentRuntime()
        _ = try await prefix.create(macDriver: macDriver)
        let host = try fixture.engine.runtime.active().host
        _ = try await prefix.runProgram("/Users/tenno/src/warzag/build/pe/wz-d3d11-smoke.exe",
                                        arguments: ["--frames", "60"],
                                        renderer: RendererOptions(renderer: .dxmt, enableNVEXT: true))
        let command = try #require(fixture.wine.programs.last)
        #expect(command.executable == host.wine)
        #expect(command.arguments == ["/Users/tenno/src/warzag/build/pe/wz-d3d11-smoke.exe", "--frames", "60"])
        let environment = try #require(command.environment)
        #expect(environment["WINEDLLPATH_PREPEND"] == host.contents.plainPath + "/renderers/dxmt")
        #expect(environment["DXMT_ENABLE_NVEXT"] == "1")
        #expect(environment["WINEDLLPATH"] == nil)
        #expect(environment["WINEPREFIX"] == root)
        #expect(environment["SteamAppId"] == nil)
        #expect(command.logFile?.plainPath == fixture.paths.logs.plainPath + "/prefix-n.log")
    }
}

@Suite struct PrefixFilesTests {
    @Test func theFilesAndWhereTheyGo() {
        let host = GameHost(bundle: URL(filePath: "/N/Warzag.app", directoryHint: .isDirectory), channel: .n)
        let layout = PrefixLayout(root: URL(filePath: "/P", directoryHint: .isDirectory), windowsUserName: "tenno")
        let files = PrefixFiles.all(host: host, layout: layout)
        let pairs = files.map { "\($0.group.rawValue): \($0.source.plainPath) -> \(layout.windowsPath(for: $0.destination) ?? "?")" }
        #expect(pairs == [
            #"dxmt: /N/Warzag.app/Contents/renderers/dxmt/aarch64-windows/winemetal.dll -> C:\windows\system32\winemetal.dll"#,
            #"dxmt: /N/Warzag.app/Contents/renderers/dxmt/aarch64-windows/nvapi64.dll -> C:\windows\system32\nvapi64.dll"#,
            #"dxmt: /N/Warzag.app/Contents/renderers/dxmt/aarch64-windows/nvngx.dll -> C:\windows\system32\nvngx.dll"#,
            #"lsteamclient: /N/Warzag.app/Contents/lib/wine/aarch64-windows/lsteamclient.dll -> C:\windows\system32\lsteamclient.dll"#,
            #"bridge: /N/Warzag.app/Contents/share/warzag/bridge/steam.exe -> C:\Program Files (x86)\Steam\steam.exe"#,
            #"bridge: /N/Warzag.app/Contents/share/warzag/bridge/steamclient64-forwarder.dll -> C:\Program Files (x86)\Steam\steamclient64.dll"#,
            #"bridge: /N/Warzag.app/Contents/share/warzag/bridge/wz-steamprobe.exe -> C:\Program Files (x86)\Steam\wz-steamprobe.exe"#,
        ])
    }
}
