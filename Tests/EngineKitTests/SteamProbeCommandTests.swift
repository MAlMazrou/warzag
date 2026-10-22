import Foundation
import Synchronization
import Testing
import RuntimeKit
import SteamHostKit
import WarzagCore
import WarzagTestSupport
import WineKit
@testable import EngineKit
@testable import warzagctl

final class PrintedLines: Sendable {
    private let lines = Mutex<[String]>([])
    func append(_ text: String) { lines.withLock { $0.append(text) } }
    var all: [String] { lines.withLock { $0 } }
}

@Suite struct SteamProbeCommandTests {
    let fixture = EngineFixture()
    let printed = PrintedLines()

    var environment: EngineCLIEnvironment {
        EngineCLIEnvironment(engine: fixture.engine, macDriver: MacDriverSettings(retinaMode: false),
                             appVersion: "0.1.0", macOSVersion: "26.5.1",
                             currentDirectory: URL(filePath: EngineFixture.home, directoryHint: .isDirectory))
    }

    var steamLocations: SteamLocations {
        SteamLocations(home: URL(filePath: EngineFixture.home, directoryHint: .isDirectory),
                       systemApplications: URL(filePath: "/Applications", directoryHint: .isDirectory))
    }

    func context(steamRunning: Bool) -> CommandContext {
        let steam = [Int32(4242): FakeProcessInspector.Entry(
            path: steamLocations.clientDirectory.appending(path: "steam_osx").plainPath, start: Date())]
        return CommandContext(
            paths: fixture.paths, steam: steamLocations, fileSystem: fixture.fileSystem,
            processes: FakeProcessInspector(steamRunning ? steam : [:]),
            system: FakeSystemInfo.mac(chip: "Apple M2", model: "Mac14,15", product: nil, performanceCores: 4,
                                       efficiencyCores: 4, gpuCores: 10, memoryGB: 16),
            inheritedEnvironment: ["HOME": EngineFixture.home],
            currentDirectory: URL(filePath: EngineFixture.home, directoryHint: .isDirectory),
            timeZone: TimeZone(identifier: "UTC")!)
    }

    var output: GameCommands.Output {
        let printed = printed
        return GameCommands.Output(write: { printed.append($0) }, warn: { printed.append($0) })
    }

    func prepare() async {
        fixture.makeHost()
        _ = await EngineCLI.runtime(["use-local", EngineFixture.devHost], environment: environment)
        _ = await EngineCLI.prefix(["create"], environment: environment)
        fixture.fileSystem.addFile(steamLocations.registryFile.plainPath,
                                   #""Registry" { "HKLM" { "Software" { "Valve" { "Steam" { "SteamPID" "4242" } } } } }"#)
    }

    @Test func itSaysFirstThatItRegistersAsWarframeThenRunsSetupsInvocation() async throws {
        await prepare()
        fixture.wine.setProgramResult(ProcessOutput(exitCode: 24))
        let result = await SteamCommands.probe(context(steamRunning: true), engine: fixture.engine, output: output)
        #expect(printed.all == [SteamCommands.probeNotice])
        #expect(SteamCommands.probeNotice.contains("registers with Steam as Warframe (230410) for a moment"))
        #expect(result.exitCode == 1)
        #expect(result.stdout.hasPrefix("wz-steamprobe.exe exited with status 24: the signed-in account does not own "
            + "Warframe"))
        #expect(result.stdout.contains("its JSON line is in ~/Library/"))
        #expect(!result.stdout.contains(EngineFixture.home))

        let probe = try #require(fixture.wine.programs.last)
        #expect(probe.arguments == [#"C:\Program Files (x86)\Steam\wz-steamprobe.exe"#, "--appid", "230410",
                                    "--timeout", "30"])
        #expect(probe.arguments == [SteamProbe.program] + SteamProbe.arguments())
        let environment = probe.environment ?? [:]
        #expect(environment["SteamAppId"] == "230410")
        #expect(environment["STEAM_COMPAT_CLIENT_INSTALL_PATH"] == steamLocations.clientDirectory.plainPath)
        // The probe's own exit is the answer: nothing waits for the prefix to go quiet afterwards.
        #expect(fixture.runner.commands.last?.arguments.first == SteamProbe.program)
    }

    @Test func anOwnedAccountExitsZero() async {
        await prepare()
        fixture.wine.setProgramResult(ProcessOutput(exitCode: 0))
        let result = await SteamCommands.probe(context(steamRunning: true), engine: fixture.engine, output: output)
        #expect(result.exitCode == 0)
        #expect(result.stdout.hasPrefix("wz-steamprobe.exe exited with status 0: the signed-in account owns Warframe\n"))
    }

    @Test func nothingRunsWhileSteamIsNotRunning() async {
        await prepare()
        let before = fixture.runner.commands.count
        let result = await SteamCommands.probe(context(steamRunning: false), engine: fixture.engine, output: output)
        #expect(printed.all == [SteamCommands.probeNotice])
        #expect(result.exitCode == 1)
        #expect(result.stderr == "warzagctl: Steam is not running; start Steam and sign in first (warzagctl never "
            + "starts Steam)\n")
        #expect(fixture.runner.commands.count == before)
    }

    @Test func withoutAPrefixItSaysSo() async {
        fixture.fileSystem.addFile(steamLocations.registryFile.plainPath,
                                   #""Registry" { "HKLM" { "Software" { "Valve" { "Steam" { "SteamPID" "4242" } } } } }"#)
        let result = await SteamCommands.probe(context(steamRunning: true), engine: fixture.engine, output: output)
        #expect(result.exitCode == 1)
        #expect(result.stderr.hasPrefix("warzagctl steam probe: "))
    }

    @Test(arguments: [
        (Int32(0), SteamProbe.Outcome.owned), (24, .notOwned), (23, .signedOut), (20, .steamNotRunning),
        (21, .steamNotRunning), (10, .bridgeFailed(stage: "registry")), (11, .bridgeFailed(stage: "load")),
        (12, .bridgeFailed(stage: "export")), (13, .bridgeFailed(stage: "client")),
        (22, .bridgeFailed(stage: "interfaces")), (25, .timedOut), (2, .failed(exitCode: 2)), (-1, .failed(exitCode: -1)),
    ])
    func exitStatuses(_ exitCode: Int32, _ outcome: SteamProbe.Outcome) {
        #expect(SteamProbe.Outcome(exitCode: exitCode) == outcome)
    }
}
