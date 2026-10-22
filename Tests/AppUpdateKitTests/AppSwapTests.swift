import Foundation
import RuntimeKit
import Synchronization
import Testing
import WarzagCore
import WarzagTestSupport
@testable import AppUpdateKit

/// The real disk, with any operation made to fail on request.
final class FlakyFiles: BundleFileOperating {
    private struct State {
        var exchanges = 0
        var failingExchanges: Set<Int> = []
        var failRemovingPrevious = false
        var failCopy = false
    }

    private let base = LocalBundleFiles()
    private let state = Mutex(State())

    /// Fails the n-th exchange (1-based).
    func failExchange(_ number: Int) { state.withLock { _ = $0.failingExchanges.insert(number) } }
    func failRemovingPrevious() { state.withLock { $0.failRemovingPrevious = true } }
    func failCopy() { state.withLock { $0.failCopy = true } }
    var exchanges: Int { state.withLock { $0.exchanges } }

    func exists(_ url: URL) -> Bool { base.exists(url) }

    func copy(_ source: URL, to destination: URL) throws {
        if state.withLock({ $0.failCopy }) { throw POSIXError(.ENOSPC) }
        try base.copy(source, to: destination)
    }

    func exchange(_ first: URL, _ second: URL) throws {
        let fail = state.withLock { state -> Bool in
            state.exchanges += 1
            return state.failingExchanges.contains(state.exchanges)
        }
        if fail { throw POSIXError(.EPERM) }
        try base.exchange(first, second)
    }

    func remove(_ url: URL) throws {
        // The previous Warzag, after an exchange: a swap copy that is not the new build.
        if state.withLock({ $0.failRemovingPrevious }), url.lastPathComponent.contains(".swap-"),
           base.info(of: url).build != "413" {
            throw POSIXError(.EACCES)
        }
        try base.remove(url)
    }

    func info(of bundle: URL) -> (identifier: String?, build: String?) { base.info(of: bundle) }
}

/// The plist verifier, refusing the new build at `refusedPath` (the installed path: a copy that fails in place).
struct RefusingInPlace: AppBundleVerifying {
    var refusedPath: URL

    func verify(_ bundle: URL, against requirement: AppRequirement) throws(AppBundleRejection) {
        if bundle.standardizedFileURL == refusedPath.standardizedFileURL, build(of: bundle) == requirement.build {
            throw .badSignature("nested code changed")
        }
        try PlistBundleVerifier().verify(bundle, against: requirement)
    }
}

/// A process that is alive for its first `polls` looks, then gone; or never gone.
final class ExitingProcess: ProcessInspecting {
    private let remaining: Mutex<Int>

    init(polls: Int) {
        remaining = Mutex(polls)
    }

    func isAlive(_ pid: Int32) -> Bool {
        remaining.withLock { value in
            defer { value -= 1 }
            return value > 0
        }
    }

    func executablePath(of pid: Int32) -> String? { "/Applications/Warzag.app/Contents/MacOS/Warzag" }
    func startDate(of pid: Int32) -> Date? { nil }
    func processIdentifiers() -> [Int32] { [] }
}

final class SwapFixture: Sendable {
    let root: URL
    let installed: URL
    let staged: URL
    let files = FlakyFiles()
    let runner = RecordingProcessRunner()
    let clock = ManualClock()
    private let lines = Mutex<[String]>([])

    init(installedIdentifier: String = AppManifest.bundleIdentifier) throws {
        root = try scratchDirectory("app-swap")
        installed = try makeApp(at: root.appending(path: "Applications/Warzag.app", directoryHint: .isDirectory),
                                identifier: installedIdentifier, version: "0.1.0", build: "412")
        staged = try makeApp(at: root.appending(path: "home/Library/Caches/Warzag/AppUpdate.noindex/staging/Warzag.app",
                                                directoryHint: .isDirectory), version: "0.2.0", build: "413")
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var log: [String] { lines.withLock { $0 } }

    func swap(bundles: (any AppBundleVerifying)? = nil, processes: any ProcessInspecting = FakeProcessInspector())
        -> AppSwap {
        AppSwap(installed: installed, staged: staged,
                requirement: AppRequirement(version: "0.2.0", build: "413", signerFingerprint: AppKeys.signer),
                bundles: bundles ?? PlistBundleVerifier(), files: files, processes: processes, runner: runner,
                clock: clock, log: { line in self.lines.withLock { $0.append(line) } })
    }

    var swapCopy: URL { root.appending(path: "Applications/.Warzag.app.swap-413", directoryHint: .isDirectory) }
    var exists: (URL) -> Bool { { FileManager.default.fileExists(atPath: $0.plainPath) } }
    var opened: [String] { runner.commandLines }
}

@Suite struct AppSwapProbeTests {
    @Test func theProbeExchangesThereAndBack() throws {
        let fixture = try SwapFixture()
        try fixture.swap().probe()
        #expect(build(of: fixture.installed) == "412")
        #expect(build(of: fixture.swapCopy) == "413")
        #expect(fixture.files.exchanges == 2)
        // The checked copy stays where the player can drag it from.
        #expect(build(of: fixture.staged) == "413")
        #expect(fixture.log.last?.contains("can be replaced") == true)
    }

    @Test func neverAnythingButWarzag() throws {
        let fixture = try SwapFixture(installedIdentifier: "com.example.notes")
        #expect(throws: AppSwapFailure.cannotReplace("\(fixture.installed.plainPath) is com.example.notes, not com.warzag.app")) {
            try fixture.swap().probe()
        }
        #expect(!fixture.exists(fixture.swapCopy))
        #expect(fixture.files.exchanges == 0)
    }

    @Test func aStagedCopyThatFailsItsCheckChangesNothing() throws {
        let fixture = try SwapFixture()
        try Data().write(to: fixture.staged.appending(path: "Contents/broken"))
        #expect {
            try fixture.swap().probe()
        } throws: { error in
            (error as? AppSwapFailure)?.exitCode == AppSwapExit.rejected
        }
        #expect(!fixture.exists(fixture.swapCopy))
        #expect(build(of: fixture.installed) == "412")
    }

    /// EPERM on a bundle that is not locked is App Management's answer: the reason says where the player can allow it.
    @Test func aFolderMacOSWillNotChangeIsFoundBeforeTheAppQuits() throws {
        let fixture = try SwapFixture()
        fixture.files.failExchange(1)
        #expect(throws: AppSwapFailure.cannotReplace(
            "macOS did not let Warzag replace \(fixture.installed.plainPath): Operation not permitted "
                + "(System Settings > Privacy & Security > App Management must allow Warzag)")) {
            try fixture.swap().probe()
        }
        #expect(!fixture.exists(fixture.swapCopy))
        #expect(build(of: fixture.installed) == "412")
    }

    /// A locked bundle refuses with EPERM too, but that is the lock, not App Management.
    @Test func aLockedAppIsNotAnAppManagementRefusal() throws {
        let fixture = try SwapFixture()
        #expect(chflags(fixture.installed.plainPath, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(fixture.installed.plainPath, 0) }
        #expect(throws: AppSwapFailure.cannotReplace(
            "macOS did not let Warzag replace \(fixture.installed.plainPath): Operation not permitted")) {
            try fixture.swap().probe()
        }
        #expect(build(of: fixture.installed) == "412")
    }

    /// If the second exchange fails, the checked new Warzag is in place early; the swap then finds it there.
    @Test func aProbeWhoseSecondExchangeFailsLeavesTheNewAppInPlace() async throws {
        let fixture = try SwapFixture()
        fixture.files.failExchange(2)
        try fixture.swap().probe()
        #expect(build(of: fixture.installed) == "413")
        #expect(build(of: fixture.swapCopy) == "412")
        #expect(await fixture.swap().run(waitingFor: nil, reopen: false) == .replaced(leftover: nil))
        #expect(!fixture.exists(fixture.swapCopy))
    }
}

@Suite struct AppSwapRunTests {
    @Test func probeThenSwapReplacesAndOpensTheNewApp() async throws {
        let fixture = try SwapFixture()
        try fixture.swap().probe()
        #expect(await fixture.swap().run(waitingFor: nil, reopen: true) == .replaced(leftover: nil))
        #expect(build(of: fixture.installed) == "413")
        #expect(!fixture.exists(fixture.swapCopy))
        #expect(fixture.opened == ["open \(fixture.installed.plainPath)"])
        #expect(fixture.log.last == "update: replaced \(fixture.installed.plainPath) with Warzag 0.2.0 (build 413)")
    }

    @Test func withoutAProbeTheSwapPlacesItsOwnCopy() async throws {
        let fixture = try SwapFixture()
        #expect(await fixture.swap().run(waitingFor: nil, reopen: false) == .replaced(leftover: nil))
        #expect(build(of: fixture.installed) == "413")
        #expect(fixture.opened.isEmpty)
        #expect(build(of: fixture.staged) == "413")
    }

    @Test func itWaitsForTheAppToQuit() async throws {
        let fixture = try SwapFixture()
        #expect(await fixture.swap(processes: ExitingProcess(polls: 3)).run(waitingFor: 4242, reopen: false)
            == .replaced(leftover: nil))
        #expect(fixture.clock.sleeps.count == 3)
    }

    @Test func anAppThatDoesNotQuitKeepsItsCopy() async throws {
        let fixture = try SwapFixture()
        try fixture.swap().probe()
        let outcome = await fixture.swap(processes: ExitingProcess(polls: .max)).run(waitingFor: 4242, reopen: true)
        #expect(outcome == .stillRunning("Warzag did not quit within 120 s"))
        #expect(outcome.exitCode == AppSwapExit.refused)
        #expect(build(of: fixture.installed) == "412")
        #expect(!fixture.exists(fixture.swapCopy))
        // It still runs: nothing is opened.
        #expect(fixture.opened.isEmpty)
    }

    /// The outcome is handed over (to be recorded) before the Warzag that reads it is opened.
    @Test func theOutcomeIsReportedBeforeAnythingOpens() async throws {
        let fixture = try SwapFixture()
        let opensBeforeTheReport = Mutex<[Int]>([])
        var swap = fixture.swap()
        swap.report = { _ in opensBeforeTheReport.withLock { $0.append(fixture.runner.commands.count) } }
        #expect(await swap.run(waitingFor: nil, reopen: true) == .replaced(leftover: nil))
        #expect(opensBeforeTheReport.withLock { $0 } == [0])
        #expect(fixture.opened == ["open \(fixture.installed.plainPath)"])
    }

    @Test func aNewAppThatFailsInPlaceIsSwappedBack() async throws {
        let fixture = try SwapFixture()
        let outcome = await fixture.swap(bundles: RefusingInPlace(refusedPath: fixture.installed))
            .run(waitingFor: nil, reopen: true)
        #expect(outcome == .restored("the new Warzag failed its check in place: the code signature does not validate: "
            + "nested code changed"))
        #expect(build(of: fixture.installed) == "412")
        #expect(!fixture.exists(fixture.swapCopy))
        // The previous Warzag is opened again.
        #expect(fixture.opened == ["open \(fixture.installed.plainPath)"])
    }

    @Test func anExchangeThatFailsChangesNothing() async throws {
        let fixture = try SwapFixture()
        fixture.files.failExchange(1)
        let outcome = await fixture.swap().run(waitingFor: nil, reopen: true)
        #expect(outcome == .untouched("macOS did not let Warzag replace \(fixture.installed.plainPath): "
            + "Operation not permitted (System Settings > Privacy & Security > App Management must allow Warzag)"))
        #expect(build(of: fixture.installed) == "412")
        #expect(!fixture.exists(fixture.swapCopy))
        #expect(fixture.opened == ["open \(fixture.installed.plainPath)"])
    }

    @Test func whenTheWayBackFailsThePreviousAppWaitsNextToIt() async throws {
        let fixture = try SwapFixture()
        fixture.files.failExchange(2)
        let outcome = await fixture.swap(bundles: RefusingInPlace(refusedPath: fixture.installed))
            .run(waitingFor: nil, reopen: false)
        guard case .failed(_, let previous) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(previous.standardizedFileURL == fixture.swapCopy.standardizedFileURL)
        #expect(build(of: fixture.swapCopy) == "412")
        #expect(outcome.exitCode == AppSwapExit.refused)
    }

    @Test func aPreviousAppThatCannotBeRemovedIsALeftover() async throws {
        let fixture = try SwapFixture()
        fixture.files.failRemovingPrevious()
        let outcome = await fixture.swap().run(waitingFor: nil, reopen: false)
        #expect(outcome == .replaced(leftover: fixture.swapCopy))
        #expect(build(of: fixture.installed) == "413")
        #expect(build(of: fixture.swapCopy) == "412")
    }

    @Test func aCopyThatCannotBeMadeChangesNothing() async throws {
        let fixture = try SwapFixture()
        fixture.files.failCopy()
        let outcome = await fixture.swap().run(waitingFor: nil, reopen: false)
        #expect(outcome == .untouched("could not copy the new Warzag next to \(fixture.installed.plainPath): "
            + "No space left on device"))
        #expect(build(of: fixture.installed) == "412")
        #expect(outcome.exitCode == AppSwapExit.refused)
    }

    @Test func aStagedCopyThatFailsItsCheckIsARejection() async throws {
        let fixture = try SwapFixture()
        try Data().write(to: fixture.staged.appending(path: "Contents/broken"))
        let outcome = await fixture.swap().run(waitingFor: nil, reopen: false)
        #expect(outcome.exitCode == AppSwapExit.rejected)
        #expect(build(of: fixture.installed) == "412")
    }

    @Test func neverReplacesAnotherApp() async throws {
        let fixture = try SwapFixture(installedIdentifier: "com.example.notes")
        let outcome = await fixture.swap().run(waitingFor: nil, reopen: false)
        #expect(outcome == .untouched("\(fixture.installed.plainPath) is com.example.notes, not com.warzag.app"))
        #expect(build(of: fixture.installed) == "412")
    }

    /// renamex_np's RENAME_SWAP on folders: both names keep a whole bundle.
    @Test func theExchangeIsOneStep() throws {
        let fixture = try SwapFixture()
        let other = try makeApp(at: fixture.root.appending(path: "Applications/.other", directoryHint: .isDirectory),
                                version: "9.9", build: "999")
        try LocalBundleFiles().exchange(other, fixture.installed)
        #expect(build(of: fixture.installed) == "999")
        #expect(build(of: other) == "412")
        #expect(throws: POSIXError.self) {
            try LocalBundleFiles().exchange(fixture.root.appending(path: "missing"), fixture.installed)
        }
    }
}
