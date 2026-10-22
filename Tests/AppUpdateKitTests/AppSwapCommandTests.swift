import Foundation
import Synchronization
import Testing
import WarzagCore
import WarzagTestSupport
@testable import AppUpdateKit

/// The update helper's command line, as Warzag's executable (`--update-swap`) and `warzagctl app swap` both take it,
/// on real scratch folders.
@Suite struct AppSwapCommandTests {
    func command(_ fixture: SwapFixture) -> AppSwapCommand {
        AppSwapCommand(home: nil, installed: fixture.installed.plainPath, staged: fixture.staged.plainPath,
                       version: "0.2.0", build: "413", signer: AppKeys.signer, log: nil)
    }

    func paths(_ fixture: SwapFixture) -> WarzagPaths {
        WarzagPaths(home: fixture.root.appending(path: "home", directoryHint: .isDirectory), userCacheDirectory: nil)
    }

    func record(_ fixture: SwapFixture) -> AppSwapRecord? {
        AppUpdateRecords(paths: paths(fixture), fileSystem: LocalFileSystem()).swapRecord()
    }

    /// The helper as `run` builds it: the fixture's scratch folders, files and a pid that has quit.
    func run(_ command: AppSwapCommand, _ fixture: SwapFixture, signers: Set<String> = [AppKeys.signer],
             runner: RecordingProcessRunner? = nil) async -> AppSwapCommand.Result {
        await command.run(signers: signers, paths: paths(fixture), currentDirectory: fixture.root, output: { _ in }) {
            installed, staged, requirement, log in
            AppSwap(installed: installed, staged: staged, requirement: requirement, bundles: PlistBundleVerifier(),
                    files: fixture.files, processes: ExitingProcess(polls: 0), runner: runner ?? fixture.runner,
                    clock: fixture.clock, log: log)
        }
    }

    @Test func theCommandLineRoundTrips() throws {
        var command = AppSwapCommand(home: "/Users/tenno", installed: "/Applications/Warzag.app",
                                     staged: "/s/Warzag.app", version: "0.2.0", build: "413", signer: AppKeys.signer,
                                     log: "/l/Warzag.log")
        command.waitPID = 77
        command.open = true
        #expect(try AppSwapCommand.parse(command.arguments) == command)
        command.waitPID = nil
        command.open = false
        command.probe = true
        #expect(try AppSwapCommand.parse(command.arguments) == command)
        #expect(command.arguments.last == "--probe")
    }

    @Test(arguments: [
        ([], "app swap needs --installed, --staged, --version, --build and --signer"),
        (["--wait-pid", "x"], "--wait-pid needs a pid"),
        (["--installed"], "--installed needs a value"),
        (["--installed", "--probe"], "--installed needs a value"),
        (["--frobnicate"], "unknown option for app swap: --frobnicate"),
        (["extra"], "unexpected argument for app swap: extra"),
    ])
    func usageErrors(_ arguments: [String], _ message: String) {
        #expect(throws: AppSwapCommand.UsageError(message: message)) { try AppSwapCommand.parse(arguments) }
    }

    @Test func onlyACertificateThisBuildPins() async throws {
        let fixture = try SwapFixture()
        let result = await run(command(fixture), fixture, signers: [String(repeating: "0", count: 64)])
        #expect(result == AppSwapCommand.Result(exitCode: AppSwapExit.rejected,
                                                reason: "\(AppKeys.signer) is not a certificate this build trusts"))
        #expect(build(of: fixture.installed) == "412")
    }

    @Test func theProbeChangesNothingAndRecordsNothing() async throws {
        let fixture = try SwapFixture()
        var probe = command(fixture)
        probe.probe = true
        #expect(await run(probe, fixture) == AppSwapCommand.Result(exitCode: AppSwapExit.replaced))
        #expect(build(of: fixture.installed) == "412")
        #expect(record(fixture) == nil)
    }

    /// After Warzag has quit (`--wait-pid`), the outcome is recorded before the Warzag that reads it opens.
    @Test func afterWarzagQuitTheOutcomeIsRecordedBeforeAnythingOpens() async throws {
        let fixture = try SwapFixture()
        let recordFile = paths(fixture).appUpdates.appending(path: "swap-result.json")
        let recordedWhenOpened = Mutex<[Bool]>([])
        let runner = RecordingProcessRunner { _ in
            recordedWhenOpened.withLock { $0.append(FileManager.default.fileExists(atPath: recordFile.plainPath)) }
            return ProcessOutput(exitCode: 0)
        }
        var swap = command(fixture)
        swap.waitPID = 4242
        swap.open = true
        #expect(await run(swap, fixture, runner: runner) == AppSwapCommand.Result(exitCode: AppSwapExit.replaced))
        #expect(recordedWhenOpened.withLock { $0 } == [true])
        let saved = try #require(record(fixture))
        #expect(saved == AppSwapRecord(version: "0.2.0", build: "413", result: .replaced, reason: nil,
                                       date: fixture.clock.now))
        #expect(build(of: fixture.installed) == "413")
    }

    @Test func aRefusedSwapIsRecordedWithItsReason() async throws {
        let fixture = try SwapFixture()
        fixture.files.failExchange(1)
        var swap = command(fixture)
        swap.waitPID = 4242
        swap.open = true
        let reason = "macOS did not let Warzag replace \(fixture.installed.plainPath): Operation not permitted "
            + "(System Settings > Privacy & Security > App Management must allow Warzag)"
        #expect(await run(swap, fixture) == AppSwapCommand.Result(exitCode: AppSwapExit.refused, reason: reason))
        #expect(record(fixture)?.result == .refused)
        #expect(record(fixture)?.reason == reason)
        // The previous Warzag is opened again.
        #expect(fixture.opened == ["open \(fixture.installed.plainPath)"])
    }

    /// warzagctl's own swap (no `--wait-pid`) answers its caller directly: nothing is recorded.
    @Test func aSwapWithoutAWaitRecordsNothing() async throws {
        let fixture = try SwapFixture()
        #expect(await run(command(fixture), fixture) == AppSwapCommand.Result(exitCode: AppSwapExit.replaced))
        #expect(build(of: fixture.installed) == "413")
        #expect(record(fixture) == nil)
    }

    @Test(arguments: [
        (AppSwapOutcome.replaced(leftover: nil), AppSwapRecord.Result.replaced, String?.none),
        (.rejected("x"), .rejected, "x"), (.untouched("y"), .refused, "y"), (.restored("z"), .refused, "z"),
        (.failed("w", previous: URL(filePath: "/Applications/.Warzag.app.swap-413")), .refused,
         "w; the previous Warzag is at /Applications/.Warzag.app.swap-413"),
        (.stillRunning("Warzag did not quit within 120 s"), .stillRunning, "Warzag did not quit within 120 s"),
    ])
    func everyOutcomeHasItsRecord(_ outcome: AppSwapOutcome, _ result: AppSwapRecord.Result, _ reason: String?) {
        let record = AppSwapRecord(outcome, for: AppRequirement(version: "0.2.0", build: "413",
                                                                signerFingerprint: AppKeys.signer),
                                   at: Date(timeIntervalSince1970: 0))
        #expect(record.result == result)
        #expect(record.reason == reason)
        #expect(record.build == "413" && !record.reported)
    }
}
