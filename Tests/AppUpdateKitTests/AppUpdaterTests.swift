import Foundation
import RuntimeKit
import Synchronization
import Testing
import WarzagCore
import WarzagTestSupport
@testable import AppUpdateKit

/// `AppUpdater` against a scratch home and an installed app in a scratch "Applications" folder, with a fake feed,
/// download, extraction and helper (`helper` answers for the app's probe and for warzagctl's swap).
final class UpdaterFixture: Sendable {
    let root: URL
    let paths: WarzagPaths
    let installedApp: URL
    let feed = URL(string: "https://releases.example.org/Warzag.manifest.json")!
    let http = FakeHTTPClient()
    let downloader = FakeAppDownloader()
    let launcher: RecordingLauncher
    let clock = ManualClock()
    let runner: RecordingProcessRunner

    init(installedBuild: String = "412", helper: @escaping RecordingProcessRunner.Handler = { _ in ProcessOutput(exitCode: 0) })
        throws {
        root = try scratchDirectory("app-updater")
        paths = WarzagPaths(home: root.appending(path: "home", directoryHint: .isDirectory), userCacheDirectory: nil)
        installedApp = try makeApp(at: root.appending(path: "Applications/Warzag.app", directoryHint: .isDirectory),
                                   version: "0.1.0", build: installedBuild)
        runner = RecordingProcessRunner(handler: helper)
        launcher = RecordingLauncher(handler: helper)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func serve(_ manifest: AppManifest) throws {
        http.respond(to: feed, with: try AppKeys.signed(manifest))
    }

    /// `unpacks` makes what the archive holds: Warzag.app as the manifest describes it unless told otherwise.
    func updater(feed: URL?? = nil, installedBuild: String? = nil, location: String? = nil,
                 processes: FakeProcessInspector = FakeProcessInspector(), macOS: String = "26.5.1",
                 fileSystem: any FileSystem = LocalFileSystem(),
                 unpacks: @escaping @Sendable (URL) throws -> Void = { destination in
                     try makeApp(at: destination.appending(path: "Warzag.app"), version: "0.2.0", build: "413")
                 }) -> AppUpdater {
        var installed = InstalledApp.read(installedApp)
        if let installedBuild { installed.build = installedBuild }
        return AppUpdater(
            installed: installed, feed: feed ?? self.feed, trust: AppKeys.trust, paths: paths, macOSVersion: macOS,
            allowsLoopbackHTTP: false, http: http, downloader: downloader, extractor: FakeAppExtractor(make: unpacks),
            bundles: PlistBundleVerifier(), location: FixedLocation(obstacle: location), fileSystem: fileSystem,
            processes: processes, runner: runner, launcher: launcher, clock: clock)
    }

    var stagedApp: URL { paths.appUpdates.appending(path: "staging/Warzag.app") }
    var records: AppUpdateRecords { AppUpdateRecords(paths: paths, fileSystem: LocalFileSystem()) }
    var archive: URL { paths.appUpdates.appending(path: "Warzag-0.2.0-413.zip") }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.plainPath) }

    /// What the helper records once Warzag has quit.
    func record(_ result: AppSwapRecord.Result, reason: String?, build: String = "413") throws {
        try records.save(AppSwapRecord(version: "0.2.0", build: build, result: result, reason: reason, date: clock.now))
    }
}

@Suite struct AppUpdaterCheckTests {
    @Test func aBuildWithoutAFeedHasNothingToCheck() async throws {
        let fixture = try UpdaterFixture()
        #expect(try await fixture.updater(feed: .some(nil)).check() == .notConfigured)
        #expect(fixture.http.requests.isEmpty)
        await #expect(throws: AppUpdateFailure.notConfigured) {
            try await fixture.updater(feed: .some(nil)).prepare(build: "413")
        }
    }

    @Test func aHigherBuildIsAvailableAndItsSerialBecomesTheFloor() async throws {
        let fixture = try UpdaterFixture()
        let manifest = AppKeys.manifest(serial: 9)
        try fixture.serve(manifest)
        let updater = fixture.updater()
        #expect(try await updater.check() == .available(manifest))
        #expect(updater.lastAcceptedSerial() == 9)
        #expect(FileManager.default.fileExists(atPath: fixture.paths.appUpdates.appending(path: "manifest.json").plainPath))
    }

    @Test(arguments: ["413", "414", "1000"])
    func theSameOrAnOlderBuildIsUpToDate(_ installed: String) async throws {
        let fixture = try UpdaterFixture()
        let manifest = AppKeys.manifest(build: "413")
        try fixture.serve(manifest)
        #expect(try await fixture.updater(installedBuild: installed).check() == .upToDate(manifest))
    }

    @Test func buildsCompareAsNumbers() async throws {
        let fixture = try UpdaterFixture()
        let manifest = AppKeys.manifest(build: "1000")
        try fixture.serve(manifest)
        #expect(try await fixture.updater(installedBuild: "999").check() == .available(manifest))
    }

    /// An older manifest served again (a replay, or a stale mirror) after a newer one was seen is refused.
    @Test func aReplayedOlderManifestIsRefused() async throws {
        let fixture = try UpdaterFixture()
        try fixture.serve(AppKeys.manifest(build: "414", serial: 20))
        _ = try await fixture.updater().check()
        try fixture.serve(AppKeys.manifest(build: "413", serial: 19))
        await #expect(throws: AppUpdateFailure.rejected("manifest serial 19 is older than 20")) {
            try await fixture.updater().check()
        }
    }

    @Test func refusals() async throws {
        let fixture = try UpdaterFixture()
        fixture.http.respond(to: fixture.feed, with: try AppKeys.signed(AppKeys.manifest(), with: AppKeys.strangerKey))
        await #expect(throws: AppUpdateFailure.rejected("manifest signature does not verify")) {
            try await fixture.updater().check()
        }
        var expired = AppKeys.manifest()
        expired.expires = fixture.clock.now
        try fixture.serve(expired)
        await #expect {
            try await fixture.updater().check()
        } throws: { error in
            if case .unreachable(let detail) = error as? AppUpdateFailure { detail.contains("expired") } else { false }
        }
        fixture.http.fail(fixture.feed, status: 503)
        await #expect(throws: AppUpdateFailure.unreachable("HTTP 503 from releases.example.org")) {
            try await fixture.updater().check()
        }
        let insecure = URL(string: "http://releases.example.org/Warzag.manifest.json")!
        await #expect(throws: AppUpdateFailure.rejected("the app feed must be an https URL, not \(insecure.absoluteString)")) {
            try await fixture.updater(feed: insecure).check()
        }
    }

    @Test func aNewerBuildForANewerMacOS() async throws {
        let fixture = try UpdaterFixture()
        try fixture.serve(AppKeys.manifest(minMacOS: "27.0"))
        await #expect(throws: AppUpdateFailure.requiresNewerMacOS("27.0")) {
            try await fixture.updater(macOS: "26.5.1").check()
        }
        #expect(try await fixture.updater(macOS: "27.0.1").check() == .available(AppKeys.manifest(minMacOS: "27.0")))
    }

    /// After a check, a copy prepared for a build that is not newer than the installed one, and swap copies a failed
    /// swap left next to the installed app, go.
    @Test func leftoversGo() async throws {
        let fixture = try UpdaterFixture()
        try fixture.serve(AppKeys.manifest())
        try await fixture.updater().prepare(build: "413")
        let leftover = fixture.installedApp.deletingLastPathComponent().appending(path: ".Warzag.app.swap-411")
        try makeApp(at: leftover, version: "0.0.9", build: "411")
        // The installed app is build 413 now (installed by hand): the prepared 413 is stale.
        #expect(try await fixture.updater(installedBuild: "413").check() == .upToDate(AppKeys.manifest()))
        #expect(!FileManager.default.fileExists(atPath: leftover.plainPath))
        #expect(!FileManager.default.fileExists(atPath: fixture.stagedApp.plainPath))
        #expect(fixture.updater(installedBuild: "413").prepared() == nil)
    }
}

@Suite struct AppUpdaterPrepareTests {
    @Test func prepareDownloadsUnpacksAndChecks() async throws {
        let fixture = try UpdaterFixture()
        try fixture.serve(AppKeys.manifest())
        let updater = fixture.updater()
        _ = try await updater.check()
        let progress = ProgressLog()
        let prepared = try await updater.prepare(build: "413") { progress.add($0, $1) }
        #expect(prepared.requirement == AppRequirement(version: "0.2.0", build: "413", signerFingerprint: AppKeys.signer))
        #expect(prepared.releaseNotes == URL(string: "https://releases.example.org/v0.2.0"))
        #expect(build(of: fixture.stagedApp) == "413")
        #expect(updater.prepared() == prepared)
        #expect(progress.last == [7, 7])
        #expect(fixture.downloader.urls == [URL(string: "https://releases.example.org/Warzag-0.2.0.zip")!])
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.appUpdates.appending(path: "Warzag-0.2.0-413.zip").plainPath))
        #expect(build(of: fixture.installedApp) == "412")
    }

    @Test func aCopyAlreadyPreparedIsKept() async throws {
        let fixture = try UpdaterFixture()
        try fixture.serve(AppKeys.manifest())
        try await fixture.updater().prepare(build: "413")
        try await fixture.updater().prepare(build: "413")
        #expect(fixture.downloader.urls.count == 1)
    }

    @Test func prepareFetchesTheManifestWhenNoCheckRan() async throws {
        let fixture = try UpdaterFixture()
        try fixture.serve(AppKeys.manifest())
        #expect(try await fixture.updater().prepare(build: "413").build == "413")
        #expect(fixture.http.requests == [fixture.feed])
    }

    @Test func anOfferThatChangedIsRefused() async throws {
        let fixture = try UpdaterFixture()
        try fixture.serve(AppKeys.manifest(build: "414", serial: 8))
        await #expect(throws: AppUpdateFailure.rejected("the release page now offers build 414, not 413; check again")) {
            try await fixture.updater().prepare(build: "413")
        }
    }

    @Test func aDamagedDownloadIsRejected() async throws {
        let fixture = try UpdaterFixture()
        try fixture.serve(AppKeys.manifest())
        fixture.downloader.data = Data("archivf".utf8)
        await #expect {
            try await fixture.updater().prepare(build: "413")
        } throws: { error in
            if case .rejected(let detail) = error as? AppUpdateFailure { detail.contains("SHA-256 mismatch") } else { false }
        }
        fixture.downloader.failure = URLError(.notConnectedToInternet)
        await #expect {
            try await fixture.updater().prepare(build: "413")
        } throws: { error in
            if case .unreachable = error as? AppUpdateFailure { true } else { false }
        }
    }

    @Test(arguments: [
        ("nothing", "it must hold exactly Warzag.app, not nothing"),
        ("two", "it must hold exactly Warzag.app, not Other.app, Warzag.app"),
        ("other bundle id", "the app is com.example.other, not com.warzag.app"),
        ("older build", "the app is build 412, not 413"),
        ("other version", "the app is version 0.3.0, not 0.2.0"),
        ("broken", "the code signature does not validate: a sealed resource is missing or invalid"),
    ])
    func whatTheArchiveHoldsMustBeTheManifestsApp(_ variant: String, _ reason: String) async throws {
        let fixture = try UpdaterFixture()
        try fixture.serve(AppKeys.manifest())
        let updater = fixture.updater { destination in
            let app = destination.appending(path: "Warzag.app")
            switch variant {
            case "nothing": break
            case "two":
                try makeApp(at: app, version: "0.2.0", build: "413")
                try makeApp(at: destination.appending(path: "Other.app"), version: "0.2.0", build: "413")
            case "other bundle id": try makeApp(at: app, identifier: "com.example.other", version: "0.2.0", build: "413")
            case "older build": try makeApp(at: app, version: "0.2.0", build: "412")
            case "other version": try makeApp(at: app, version: "0.3.0", build: "413")
            default:
                try makeApp(at: app, version: "0.2.0", build: "413")
                try Data().write(to: app.appending(path: "Contents/broken"))
            }
        }
        await #expect(throws: AppUpdateFailure.rejected(variant.hasPrefix("nothing") || variant == "two"
            ? "could not unpack the update: \(reason)" : reason)) {
            try await updater.prepare(build: "413")
        }
        #expect(updater.prepared() == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.stagedApp.deletingLastPathComponent().plainPath))
        #expect(!fixture.exists(fixture.archive))
    }
}

/// A full disk is "not enough free disk space", worth trying again later (`unreachable`), never a rejection, and
/// never costs the verified archive.
@Suite struct AppUpdaterDiskSpaceTests {
    @Test func aFullDiskIsFoundBeforeTheDownload() async throws {
        let fixture = try UpdaterFixture()
        try fixture.serve(AppKeys.manifest())
        let updater = fixture.updater(fileSystem: CapacityFileSystem(available: 50_000_000))
        // 7 bytes to download, about three times that unpacked, and the 100 MB margin.
        await #expect(throws: AppUpdateFailure.unreachable("not enough free disk space: the update needs about 100 MB on "
            + "the volume holding \(fixture.paths.appUpdates.plainPath), and 50 MB are free")) {
            try await updater.prepare(build: "413")
        }
        #expect(fixture.downloader.urls.isEmpty)
        // A volume that does not say how much is free is not held up.
        try await fixture.updater(fileSystem: CapacityFileSystem(available: nil)).prepare(build: "413")
        #expect(fixture.downloader.urls.count == 1)
    }

    /// Unpacking that runs out of space keeps the archive that passed its size and SHA-256: once space is freed, the
    /// next try unpacks it without a new download.
    @Test func aDiskThatFillsWhileUnpackingKeepsTheArchive() async throws {
        let fixture = try UpdaterFixture()
        try fixture.serve(AppKeys.manifest())
        let stale = fixture.paths.appUpdates.appending(path: "Warzag-0.1.9-411.zip")
        try LocalFileSystem().writeAtomically(Data("older".utf8), to: stale)
        let full = fixture.updater { _ in
            throw AppArchiveError(reason: "ditto: Warzag.app/Contents/MacOS/Warzag: No space left on device",
                                  isOutOfSpace: true)
        }
        await #expect(throws: AppUpdateFailure.unreachable("not enough free disk space: could not unpack the update: "
            + "ditto: Warzag.app/Contents/MacOS/Warzag: No space left on device")) {
            try await full.prepare(build: "413")
        }
        #expect(fixture.exists(fixture.archive))
        #expect(full.prepared() == nil)
        #expect(!fixture.exists(stale))
        let progress = ProgressLog()
        try await fixture.updater().prepare(build: "413") { progress.add($0, $1) }
        #expect(fixture.downloader.urls.count == 1)
        #expect(progress.last == [7, 7])
        #expect(build(of: fixture.stagedApp) == "413")
        #expect(!fixture.exists(fixture.archive))
    }

    @Test func aDownloadThatRunsOutOfSpaceIsNotEnoughSpace() async throws {
        let fixture = try UpdaterFixture()
        try fixture.serve(AppKeys.manifest())
        fixture.downloader.failure = CocoaError(.fileWriteOutOfSpace)
        await #expect {
            try await fixture.updater().prepare(build: "413")
        } throws: { error in
            if case .unreachable(let detail) = error as? AppUpdateFailure {
                detail.hasPrefix("not enough free disk space: ")
            } else { false }
        }
    }

    static let errors: [(any Error, Bool)] = [
        (POSIXError(.ENOSPC), true), (POSIXError(.EDQUOT), true), (CocoaError(.fileWriteOutOfSpace), true),
        (NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
                 userInfo: [NSUnderlyingErrorKey: POSIXError(.ENOSPC) as NSError]), true),
        (AppArchiveError(reason: "No space left on device", isOutOfSpace: true), true),
        (AppArchiveError(reason: "Couldn't read PKZip signature"), false), (POSIXError(.EACCES), false),
        (URLError(.notConnectedToInternet), false),
    ]

    @Test(arguments: errors)
    func outOfSpaceHoweverTheErrorCarriesIt(_ error: any Error, _ expected: Bool) {
        #expect(AppUpdater.isOutOfSpace(error) == expected)
    }

    /// ditto exits 1 whatever went wrong: its message tells a full disk from a damaged archive. On a full volume it
    /// says so first, then that it could not read the archive.
    @Test(arguments: [
        ("ditto: /x/Warzag.app/Contents/MacOS/Warzag: No space left on device", true),
        ("ditto: /x/Warzag.app/Contents/MacOS/Warzag: No space left on device\nditto: Couldn't read pkzip signature.",
         true),
        ("ditto: /x/Warzag.app: Disc quota exceeded", true),
        ("ditto: Couldn't read PKZip signature", false),
    ])
    func dittoSaysWhenTheDiskIsFull(_ message: String, _ outOfSpace: Bool) async {
        let runner = RecordingProcessRunner { _ in ProcessOutput(exitCode: 1, stderr: Data("\(message)\n".utf8)) }
        await #expect(throws: AppArchiveError(reason: message, isOutOfSpace: outOfSpace)) {
            try await DittoArchiveExtractor(runner: runner).extract(URL(filePath: "/x.zip"), into: URL(filePath: "/x"))
        }
    }
}

@Suite struct AppUpdaterInstallTests {
    func prepared(_ fixture: UpdaterFixture) async throws -> AppUpdater {
        try fixture.serve(AppKeys.manifest())
        let updater = fixture.updater()
        try await updater.prepare(build: "413")
        return updater
    }

    /// The app: the new copy's own executable, not its warzagctl, probes first and then starts on its own to wait for
    /// the app to quit, so macOS sees Warzag itself make both.
    @Test func theAppHandsOverToTheNewWarzagItself() async throws {
        let fixture = try UpdaterFixture()
        let updater = try await prepared(fixture)
        let log = fixture.paths.logs.appending(path: "Warzag.log")
        try await updater.install(.afterExit(pid: 777), log: log)
        let executable = fixture.stagedApp.appending(path: "Contents/MacOS/Warzag").plainPath
        let common = ["--update-swap", "--home", fixture.paths.home.plainPath, "--installed",
                      fixture.installedApp.plainPath, "--staged", fixture.stagedApp.plainPath, "--version", "0.2.0",
                      "--build", "413", "--signer", AppKeys.signer, "--log", log.plainPath]
        #expect(fixture.launcher.runs.map(\.executable.plainPath) == [executable])
        #expect(fixture.launcher.runs.first?.arguments == common + ["--probe"])
        #expect(fixture.launcher.commands.map(\.executable.plainPath) == [executable])
        #expect(fixture.launcher.commands.first?.arguments == common + ["--wait-pid", "777", "--open"])
        #expect(fixture.runner.commands.isEmpty)
        // Nothing was swapped by the updater itself.
        #expect(build(of: fixture.installedApp) == "412")
    }

    @Test func warzagctlSwapsAtOnceAndForgetsThePreparedCopy() async throws {
        let fixture = try UpdaterFixture(helper: { _ in ProcessOutput(exitCode: 0, stdout: Data("replaced\n".utf8)) })
        let updater = try await prepared(fixture)
        #expect(try await updater.install(.now(reopen: true), log: nil) == "replaced\n")
        let swap = try #require(fixture.runner.commands.first)
        #expect(swap.executable.plainPath == fixture.stagedApp.appending(path: "Contents/Helpers/warzagctl").plainPath)
        #expect(swap.arguments.prefix(2) == ["app", "swap"])
        #expect(swap.arguments.suffix(1) == ["--open"])
        #expect(fixture.launcher.commands.isEmpty && fixture.launcher.runs.isEmpty)
        #expect(updater.prepared() == nil)
    }

    @Test func nothingIsStartedWhereWarzagCannotReplaceItself() async throws {
        let fixture = try UpdaterFixture()
        _ = try await prepared(fixture)
        let blocked = fixture.updater(location: "/Volumes/Warzag/Warzag.app is not in an Applications folder")
        await #expect(throws: AppUpdateFailure.cannotReplace("/Volumes/Warzag/Warzag.app is not in an Applications folder")) {
            try await blocked.install(.afterExit(pid: 777), log: nil)
        }
        #expect(fixture.launcher.runs.isEmpty)
        #expect(fixture.launcher.commands.isEmpty)
        // The checked copy stays for the player to drag into Applications.
        #expect(blocked.prepared() != nil)
        #expect(build(of: blocked.stagedApp) == "413")
    }

    @Test func notWhileTheGameRuns() async throws {
        let fixture = try UpdaterFixture()
        _ = try await prepared(fixture)
        let wine = fixture.paths.runtimes.appending(path: "n/0.2.0/Warzag.app/Contents/MacOS/wine").plainPath
        let playing = fixture.updater(processes: FakeProcessInspector([90: .init(path: wine, start: nil)]))
        await #expect(throws: AppUpdateFailure.gameRunning) { try await playing.install(.afterExit(pid: 777), log: nil) }
        #expect(fixture.launcher.runs.isEmpty)
    }

    @Test func warzagctlRefusesWhileTheInstalledWarzagRuns() async throws {
        let fixture = try UpdaterFixture()
        _ = try await prepared(fixture)
        let running = fixture.installedApp.appending(path: "Contents/MacOS/Warzag").plainPath
        let updater = fixture.updater(processes: FakeProcessInspector([55: .init(path: running, start: nil)]))
        await #expect(throws: AppUpdateFailure.cannotReplace(
            "Warzag is running from \(fixture.installedApp.plainPath) (pid 55); quit it first")) {
            try await updater.install(.now(reopen: false), log: nil)
        }
        #expect(fixture.runner.commands.isEmpty)
    }

    /// The app's helper writes its reason as its last line; warzagctl's prefixes it.
    @Test(arguments: [
        (Int32(65), "the downloaded Warzag failed its check: x", AppUpdateFailure.rejected("the downloaded Warzag failed its check: x")),
        (Int32(1), "warzagctl app swap: macOS did not let Warzag replace /Applications/Warzag.app: Operation not permitted",
         AppUpdateFailure.cannotReplace("macOS did not let Warzag replace /Applications/Warzag.app: Operation not permitted")),
        (Int32(137), "", AppUpdateFailure.cannotReplace("the update helper exited with status 137")),
    ])
    func aProbeThatFailsLeavesTheAppRunning(_ status: Int32, _ message: String, _ expected: AppUpdateFailure) async throws {
        let fixture = try UpdaterFixture(helper: { _ in
            ProcessOutput(exitCode: status, stderr: message.isEmpty ? Data() : Data("\(message)\n".utf8))
        })
        let updater = try await prepared(fixture)
        await #expect(throws: expected) { try await updater.install(.afterExit(pid: 777), log: nil) }
        #expect(fixture.launcher.commands.isEmpty)
    }

    @Test func aHelperThatCannotStartIsCannotReplace() async throws {
        let fixture = try UpdaterFixture()
        let updater = try await prepared(fixture)
        fixture.launcher.fail(with: POSIXError(.EPERM))
        await #expect {
            try await updater.install(.afterExit(pid: 777), log: nil)
        } throws: { error in
            if case .cannotReplace(let detail) = error as? AppUpdateFailure {
                detail.hasPrefix("could not start Warzag's update helper")
            } else { false }
        }
    }

    @Test func aPreparedCopyThatChangedIsDropped() async throws {
        let fixture = try UpdaterFixture()
        let updater = try await prepared(fixture)
        try Data().write(to: fixture.stagedApp.appending(path: "Contents/broken"))
        await #expect {
            try await updater.install(.afterExit(pid: 777), log: nil)
        } throws: { error in
            if case .rejected(let detail) = error as? AppUpdateFailure { detail.hasPrefix("the prepared copy no longer") }
            else { false }
        }
        #expect(updater.prepared() == nil)
        #expect(fixture.launcher.runs.isEmpty)
    }

    @Test func nothingPreparedNothingInstalled() async throws {
        let fixture = try UpdaterFixture()
        await #expect(throws: AppUpdateFailure.rejected("no update is prepared (check and download it first)")) {
            try await fixture.updater().install(.afterExit(pid: 777), log: nil)
        }
    }
}

/// prepared.json is a note in Warzag's caches, which anything running as this user can write: nothing is checked
/// against it, run from the copy it names or offered to the player unless the manifest the last check kept, verified
/// again with the build's pins, describes it exactly.
@Suite struct AppUpdaterPreparedNoteTests {
    func prepared(_ fixture: UpdaterFixture) async throws -> AppUpdater {
        try fixture.serve(AppKeys.manifest())
        let updater = fixture.updater()
        try await updater.prepare(build: "413")
        return updater
    }

    func rewriteNote(_ fixture: UpdaterFixture, _ change: (inout PreparedApp) -> Void) throws {
        let note = fixture.paths.appUpdates.appending(path: "prepared.json")
        var prepared = try WarzagJSON.decoder().decode(PreparedApp.self, from: Data(contentsOf: note))
        change(&prepared)
        try WarzagJSON.encoder().encode(prepared).write(to: note)
    }

    /// The case the plist check alone would let through: a note naming a certificate the build does not pin, for a
    /// copy that is otherwise the manifest's Warzag.
    @Test func aNoteNamingAnUnpinnedSignerIsRejectedAndNothingRuns() async throws {
        let fixture = try UpdaterFixture()
        let updater = try await prepared(fixture)
        try rewriteNote(fixture) { $0.requirement.signerFingerprint = String(repeating: "ab", count: 32) }
        #expect(updater.prepared() == nil)
        await #expect(throws: AppUpdateFailure.rejected("the prepared update is not the one the app manifest describes; "
            + "check again")) {
            try await updater.install(.afterExit(pid: 777), log: nil)
        }
        #expect(fixture.launcher.runs.isEmpty && fixture.launcher.commands.isEmpty)
        #expect(fixture.runner.commands.isEmpty)
        // The copy it named goes with it.
        #expect(!fixture.exists(fixture.stagedApp))
    }

    @Test func aNoteForAnotherIdentityIsRejected() async throws {
        let fixture = try UpdaterFixture()
        let updater = try await prepared(fixture)
        try rewriteNote(fixture) { $0.requirement.bundleIdentifier = "com.example.other" }
        await #expect(throws: AppUpdateFailure.rejected("the prepared update is not the one the app manifest describes; "
            + "check again")) {
            try await updater.install(.now(reopen: false), log: nil)
        }
        #expect(fixture.runner.commands.isEmpty)
    }

    @Test func withoutAKeptManifestNothingPreparedIsActedOn() async throws {
        let fixture = try UpdaterFixture()
        let updater = try await prepared(fixture)
        try FileManager.default.removeItem(at: fixture.paths.appUpdates.appending(path: "manifest.json"))
        #expect(updater.prepared() == nil)
        await #expect(throws: AppUpdateFailure.rejected("no app manifest describes the prepared update; check again")) {
            try await updater.install(.afterExit(pid: 777), log: nil)
        }
        #expect(fixture.launcher.runs.isEmpty)
    }

    @Test func aKeptManifestThatNoLongerVerifiesIsRejected() async throws {
        let fixture = try UpdaterFixture()
        let updater = try await prepared(fixture)
        try AppKeys.signed(AppKeys.manifest(), with: AppKeys.strangerKey)
            .write(to: fixture.paths.appUpdates.appending(path: "manifest.json"))
        await #expect(throws: AppUpdateFailure.rejected("manifest signature does not verify")) {
            try await updater.install(.afterExit(pid: 777), log: nil)
        }
        #expect(fixture.launcher.runs.isEmpty)
        #expect(!fixture.exists(fixture.stagedApp))
    }

    /// An expired manifest is the release page's to renew: the checked copy stays until a check brings a fresh one.
    @Test func anExpiredManifestKeepsTheCopyUntilTheNextCheck() async throws {
        let fixture = try UpdaterFixture()
        let updater = try await prepared(fixture)
        fixture.clock.advance(by: 31 * 86_400)
        await #expect {
            try await updater.install(.afterExit(pid: 777), log: nil)
        } throws: { error in
            if case .unreachable(let detail) = error as? AppUpdateFailure { detail.contains("expired") } else { false }
        }
        #expect(fixture.launcher.runs.isEmpty)
        #expect(build(of: fixture.stagedApp) == "413")
    }
}

/// Once Warzag has quit, the helper records how its swap ended; the Warzag that opens next learns it from there.
@Suite struct AppUpdaterSwapRecordTests {
    func prepared(_ fixture: UpdaterFixture) async throws -> AppUpdater {
        try fixture.serve(AppKeys.manifest())
        let updater = fixture.updater()
        try await updater.prepare(build: "413")
        return updater
    }

    static let refusal = "macOS did not let Warzag replace /Applications/Warzag.app: Operation not permitted"

    /// Said once; and that build is not tried again by quitting: the checked copy is the player's to drag.
    @Test func aSwapRefusedAfterWarzagQuitIsSaidOnceAndNotTriedAgain() async throws {
        let fixture = try UpdaterFixture()
        let updater = try await prepared(fixture)
        try fixture.record(.refused, reason: Self.refusal)
        #expect(updater.takeSwapFailure() == .cannotReplace(Self.refusal))
        #expect(updater.takeSwapFailure() == nil)
        await #expect(throws: AppUpdateFailure.cannotReplace(Self.refusal)) {
            try await updater.install(.afterExit(pid: 777), log: nil)
        }
        #expect(fixture.launcher.runs.isEmpty && fixture.launcher.commands.isEmpty)
        #expect(updater.prepared() != nil)
        // warzagctl, which swaps while the player watches, may try it.
        try await updater.install(.now(reopen: false), log: nil)
        #expect(fixture.runner.commands.count == 1)
    }

    /// A newer build is a new try.
    @Test func aRefusalOfAnotherBuildIsNoHindrance() async throws {
        let fixture = try UpdaterFixture()
        let updater = try await prepared(fixture)
        try fixture.record(.refused, reason: Self.refusal, build: "412")
        try await updater.install(.afterExit(pid: 777), log: nil)
        #expect(fixture.launcher.commands.count == 1)
        #expect(fixture.records.swapRecord() == nil)
    }

    /// A copy the helper refused goes, so the next prepare downloads it again.
    @Test func aCopyTheHelperRejectedGoes() async throws {
        let fixture = try UpdaterFixture()
        let updater = try await prepared(fixture)
        try fixture.record(.rejected, reason: "the downloaded Warzag failed its check: x")
        #expect(updater.takeSwapFailure() == .rejected("the downloaded Warzag failed its check: x"))
        #expect(updater.prepared() == nil)
        #expect(!fixture.exists(fixture.stagedApp))
        #expect(updater.takeSwapFailure() == nil)
    }

    @Test func aWarzagThatDidNotQuitInTimeMayTryAgain() async throws {
        let fixture = try UpdaterFixture()
        let updater = try await prepared(fixture)
        try fixture.record(.stillRunning, reason: "Warzag did not quit within 120 s")
        #expect(updater.takeSwapFailure() == .cannotReplace("Warzag did not quit within 120 s"))
        try await updater.install(.afterExit(pid: 777), log: nil)
        #expect(fixture.launcher.runs.count == 1 && fixture.launcher.commands.count == 1)
        // The old record made way for the new try's.
        #expect(fixture.records.swapRecord() == nil)
    }

    /// The new Warzag opens after a replacement: nothing to say, and the copy it came from goes.
    @Test func aReplacementIsNothingToSay() async throws {
        let fixture = try UpdaterFixture()
        _ = try await prepared(fixture)
        try fixture.record(.replaced, reason: nil)
        let running = fixture.updater(installedBuild: "413")
        #expect(running.takeSwapFailure() == nil)
        #expect(fixture.records.swapRecord() == nil)
        #expect(!fixture.exists(fixture.stagedApp))
    }

    @Test func clearingThePreparedCopyClearsItsRecord() async throws {
        let fixture = try UpdaterFixture()
        _ = try await prepared(fixture)
        try fixture.record(.refused, reason: Self.refusal)
        fixture.records.clearPrepared()
        #expect(fixture.records.swapRecord() == nil)
    }
}

final class ProgressLog: Sendable {
    private let values = Mutex<[[Int64]]>([])
    func add(_ received: Int64, _ total: Int64) { values.withLock { $0.append([received, total]) } }
    var last: [Int64]? { values.withLock { $0.last } }
}
