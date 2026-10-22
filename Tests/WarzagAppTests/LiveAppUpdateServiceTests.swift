import AppUpdateKit
import CryptoKit
import Darwin
import Foundation
import RuntimeKit
import Synchronization
import Testing
import WarzagCore
import WarzagTestSupport
@testable import WarzagApp

/// `LiveAppUpdateService` over AppUpdateKit's updater with a fake feed, download and helper: what the app's model sees
/// (`AppUpdateServicing`) and what Warzag.log says.
@Suite struct LiveAppUpdateServiceTests {
    static let key = Curve25519.Signing.PrivateKey()
    static let signer = String(repeating: "f3", count: 32)
    static let archive = Data("archive".utf8)

    struct PlistVerifier: AppBundleVerifying {
        func verify(_ bundle: URL, against requirement: AppRequirement) throws(AppBundleRejection) {
            let app = InstalledApp.read(bundle)
            guard app.version == requirement.version, app.build == requirement.build else {
                throw .buildMismatch(expected: requirement.build, actual: app.build)
            }
        }
    }

    struct WritingDownloader: PackDownloading {
        func download(_ url: URL, to destination: URL, size: Int64, sha256: String,
                      progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
            try LocalFileSystem().writeAtomically(LiveAppUpdateServiceTests.archive, to: destination)
            progress(DownloadProgress(receivedBytes: size, totalBytes: size))
        }
    }

    struct Unpacker: AppArchiveExtracting {
        func extract(_ archive: URL, into destination: URL) async throws {
            try LiveAppUpdateServiceTests.writeApp(at: destination.appending(path: "Warzag.app"), version: "0.2.0", build: "413")
        }
    }

    struct Location: AppLocationInspecting {
        var obstacle: String?
        func obstacle(replacing bundle: URL) -> String? { obstacle }
    }

    /// The swaps started, and the probes run (each answered by `probe`).
    final class Launches: HelperLaunching {
        let commands = Mutex<[Command]>([])
        let probes = Mutex<[Command]>([])
        let probe: @Sendable (Command) -> ProcessOutput

        init(probe: @escaping @Sendable (Command) -> ProcessOutput = { _ in ProcessOutput(exitCode: 0) }) {
            self.probe = probe
        }

        func launch(_ command: Command) throws -> Int32 {
            commands.withLock { $0.append(command) }
            return 99
        }

        func run(_ command: Command) async throws -> ProcessOutput {
            probes.withLock { $0.append(command) }
            return probe(command)
        }
    }

    static func writeApp(at url: URL, version: String, build: String) throws {
        let contents = url.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
            <key>CFBundleExecutable</key><string>Warzag</string>
            <key>CFBundleIdentifier</key><string>com.warzag.app</string>
            <key>CFBundleShortVersionString</key><string>\(version)</string>
            <key>CFBundleVersion</key><string>\(build)</string>
            </dict></plist>
            """.utf8).write(to: contents.appending(path: "Info.plist"))
    }

    final class Scratch: Sendable {
        let root: URL
        let paths: WarzagPaths
        let log: AppLog
        let http = FakeHTTPClient()
        let feed = URL(string: "https://releases.example.org/Warzag.manifest.json")!
        let runner: RecordingProcessRunner
        let launches = Launches()

        init(helper: @escaping RecordingProcessRunner.Handler = { _ in ProcessOutput(exitCode: 0) }) throws {
            root = try temporaryDirectory("live-app-update")
            paths = WarzagPaths(home: root.appending(path: "home", directoryHint: .isDirectory), userCacheDirectory: nil)
            log = AppLog(directory: paths.logs)
            runner = RecordingProcessRunner(handler: helper)
            try LiveAppUpdateServiceTests.writeApp(at: root.appending(path: "Applications/Warzag.app"), version: "0.1.0",
                                                   build: "412")
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func serve(build: String = "413", expires: TimeInterval = 86_400) throws {
            let manifest = AppManifest(
                serial: 3, expires: ManualClock().now.addingTimeInterval(expires), version: "0.2.0", build: build,
                minMacOS: "15.0", url: URL(string: "https://releases.example.org/Warzag-0.2.0.zip")!,
                size: Int64(archive.count), sha256: SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined(),
                signerFingerprint: signer, releaseNotes: URL(string: "https://releases.example.org/v0.2.0"))
            http.respond(to: feed, with: try SignedManifest.sign(manifest, keyId: "test", with: key).encoded())
        }

        func service(location: String? = nil) -> LiveAppUpdateService {
            let installed = InstalledApp.read(root.appending(path: "Applications/Warzag.app"))
            let updater = AppUpdater(
                installed: installed, feed: feed,
                trust: ManifestTrust(publicKeys: ["test": key.publicKey.rawRepresentation], signerFingerprints: [signer]),
                paths: paths, macOSVersion: "26.5.1", allowsLoopbackHTTP: false, http: http,
                downloader: WritingDownloader(), extractor: Unpacker(), bundles: PlistVerifier(),
                location: Location(obstacle: location), fileSystem: LocalFileSystem(), processes: FakeProcessInspector(),
                runner: runner, launcher: launches, clock: ManualClock())
            return LiveAppUpdateService(updater: updater, log: log)
        }

        var logText: String { (try? String(contentsOf: paths.logs.appending(path: "Warzag.log"), encoding: .utf8)) ?? "" }
    }

    @Test func theRunningVersionIsTheInstalledApps() throws {
        let scratch = try Scratch()
        #expect(scratch.service().currentVersion() == AppVersion(version: "0.1.0", build: "412"))
    }

    @Test func checkOffersTheNewerWarzagAndSaysSoInTheLog() async throws {
        let scratch = try Scratch()
        try scratch.serve()
        let found = try await scratch.service().check()
        #expect(found == .available(AppUpdateOffer(version: "0.2.0", build: "413", bytes: 7,
                                                   releaseNotes: URL(string: "https://releases.example.org/v0.2.0"))))
        #expect(scratch.logText.contains("update: Warzag 0.2.0 (build 413) is available, 7 bytes"))
        try scratch.serve(build: "412")
        #expect(try await scratch.service().check() == .upToDate)
        #expect(scratch.logText.contains("update: Warzag 0.1.0 (build 412) is up to date (the feed offers build 412)"))
    }

    @Test func failuresBecomeTheContractsErrorsAndALogLine() async throws {
        let scratch = try Scratch()
        scratch.http.fail(scratch.feed, status: 500)
        await #expect(throws: AppUpdateError.unreachable("HTTP 500 from releases.example.org")) {
            try await scratch.service().check()
        }
        #expect(scratch.logText.contains("update: checking for a newer Warzag failed: the update feed could not be reached"))
        scratch.http.respond(to: scratch.feed, with: Data("not a manifest".utf8))
        await #expect(throws: AppUpdateError.rejected("manifest envelope is not valid JSON")) {
            try await scratch.service().check()
        }
    }

    @Test func prepareThenInstallHandsOverToTheNewWarzag() async throws {
        let scratch = try Scratch()
        try scratch.serve()
        let service = scratch.service()
        guard case .available(let offer) = try await service.check() else {
            Issue.record("expected an offer")
            return
        }
        #expect(service.preparedCopy() == nil)
        let received = Mutex<[Int64]>([])
        try await service.prepare(offer) { bytes, _ in received.withLock { $0.append(bytes) } }
        #expect(received.withLock { $0 } == [7])
        let staged = scratch.paths.appUpdates.appending(path: "staging/Warzag.app")
        #expect(service.preparedCopy()?.plainPath == staged.plainPath)
        try await service.installPreparedUpdate()
        // The new Warzag's own executable probed, then was started to wait for this very process.
        let probe = try #require(scratch.launches.probes.withLock { $0 }.first)
        #expect(probe.executable.plainPath == staged.appending(path: "Contents/MacOS/Warzag").plainPath)
        #expect(probe.arguments.first == AppSwapCommand.appFlag && probe.arguments.last == "--probe")
        let started = try #require(scratch.launches.commands.withLock { $0 }.first)
        #expect(started.executable == probe.executable)
        #expect(started.arguments.suffix(3) == ["--wait-pid", "\(getpid())", "--open"])
        #expect(started.arguments.contains(scratch.paths.logs.appending(path: "Warzag.log").plainPath))
        #expect(scratch.runner.commands.isEmpty)
        #expect(scratch.logText.contains("update: Warzag 0.2.0 (build 413) downloaded and checked"))
        #expect(scratch.logText.contains("update: the new Warzag's helper takes over once Warzag 0.1.0 (build 412) has quit"))
    }

    /// The previous Warzag, opened again after a swap that failed once it had quit, learns why once; installing that
    /// build again says so at once instead of quitting.
    @Test func aSwapThatFailedAfterQuittingIsToldOnce() async throws {
        let scratch = try Scratch()
        try scratch.serve()
        let service = scratch.service()
        try await service.prepare(AppUpdateOffer(version: "0.2.0", build: "413", bytes: 7)) { _, _ in }
        #expect(service.lastInstallResult() == nil)
        let reason = "macOS did not let Warzag replace \(scratch.root.plainPath)/Applications/Warzag.app: Operation not "
            + "permitted (System Settings > Privacy & Security > App Management must allow Warzag)"
        let record = AppSwapRecord(version: "0.2.0", build: "413", result: .refused, reason: reason,
                                   date: ManualClock().now)
        try WarzagJSON.encoder().encode(record).write(to: scratch.paths.appUpdates.appending(path: "swap-result.json"))
        #expect(service.lastInstallResult() == .cannotReplace(reason))
        #expect(service.lastInstallResult() == nil)
        #expect(service.preparedCopy() != nil)
        await #expect(throws: AppUpdateError.cannotReplace(reason)) { try await service.installPreparedUpdate() }
        #expect(scratch.launches.probes.withLock { $0 }.isEmpty)
        #expect(scratch.logText.contains("update: the last update did not replace Warzag 0.1.0 (build 412): Warzag could "
            + "not replace itself: macOS did not let Warzag replace"))
    }

    /// Warzag's executable is the update helper only when the flag comes first; then it never starts the app.
    @Test func theUpdateHelperIsAskedForByItsFlagFirst() async {
        #expect(UpdateHelper.isRequested(by: ["/Applications/Warzag.app/Contents/MacOS/Warzag", "--update-swap", "--probe"]))
        #expect(!UpdateHelper.isRequested(by: ["/Applications/Warzag.app/Contents/MacOS/Warzag"]))
        #expect(!UpdateHelper.isRequested(by: ["Warzag", "--home", "/tmp/x", "--update-swap"]))
        // It blocks its thread as the entry point does, so not one of Swift's cooperative pool.
        func helper(_ arguments: [String], signers: Set<String>) async -> Int32 {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(returning: UpdateHelper.run(["Warzag", "--update-swap"] + arguments,
                                                                    signers: signers))
                }
            }
        }
        // A command line it does not take, and a certificate the build does not pin, change nothing.
        #expect(await helper(["--installed", "/nonexistent/Warzag.app"], signers: [Self.signer]) == 64)
        #expect(await helper(["--installed", "/nonexistent/Warzag.app", "--staged", "/nonexistent/staged/Warzag.app",
                              "--version", "0.2.0", "--build", "413", "--signer", Self.signer], signers: [])
            == AppSwapExit.rejected)
    }

    /// Where Warzag cannot replace itself, nothing is started and the checked copy stays for the player to drag.
    @Test func cannotReplaceKeepsTheCopy() async throws {
        let scratch = try Scratch()
        try scratch.serve()
        let service = scratch.service(location: "the volume holding Warzag.app is read-only")
        try await service.prepare(AppUpdateOffer(version: "0.2.0", build: "413", bytes: 7)) { _, _ in }
        await #expect(throws: AppUpdateError.cannotReplace("the volume holding Warzag.app is read-only")) {
            try await service.installPreparedUpdate()
        }
        #expect(scratch.launches.commands.withLock { $0 }.isEmpty)
        #expect(service.preparedCopy() != nil)
        #expect(scratch.logText.contains("update: installing the new Warzag failed: Warzag could not replace itself"))
    }

    @Test(arguments: [
        (AppUpdateFailure.notConfigured, AppUpdateError.notConfigured),
        (.unreachable("a"), .unreachable("a")), (.rejected("b"), .rejected("b")),
        (.requiresNewerMacOS("27.0"), .requiresNewerMacOS("27.0")), (.cannotReplace("c"), .cannotReplace("c")),
        (.gameRunning, .gameRunning),
    ])
    func everyReasonMapsCaseForCase(_ failure: AppUpdateFailure, _ error: AppUpdateError) {
        #expect(AppUpdateError(failure) == error)
        #expect(failure.description == error.description)
    }

    @Test func aBuildWithoutAFeedOffersNothingAndKeepsNoCopy() async throws {
        let unconfigured = UnconfiguredAppUpdates()
        #expect(try await unconfigured.check() == .notConfigured)
        #expect(unconfigured.preparedCopy() == nil)
        #expect(unconfigured.lastInstallResult() == nil)
        #expect(AppFeed.url(in: ["WarzagAppManifestURL": "https://example.org/Warzag.manifest.json"]) != nil)
        #expect(AppFeed.url(in: ["WarzagRuntimeManifestURL": "https://example.org/runtime.json"]) == nil)
    }
}
