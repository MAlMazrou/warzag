import AppUpdateKit
import CryptoKit
import Foundation
import RuntimeKit
import Synchronization
import Testing
import WarzagCore
import WarzagTestSupport
@testable import warzagctl

/// `warzagctl app ...` against an installed app in a scratch Applications folder, a fake feed, download and
/// extraction, and a helper that is recorded rather than run (`app swap` itself runs on real scratch folders).
@Suite struct AppCommandsTests {
    static let key = Curve25519.Signing.PrivateKey()
    static let signer = String(repeating: "f3", count: 32)
    static let trust = ManifestTrust(publicKeys: ["test": key.publicKey.rawRepresentation], signerFingerprints: [signer])
    static let archive = Data("archive".utf8)

    struct PlistVerifier: AppBundleVerifying {
        func verify(_ bundle: URL, against requirement: AppRequirement) throws(AppBundleRejection) {
            let app = InstalledApp.read(bundle)
            guard app.identifier == requirement.bundleIdentifier, app.version == requirement.version,
                  app.build == requirement.build else {
                throw .buildMismatch(expected: requirement.build, actual: app.build)
            }
        }
    }

    struct WritingDownloader: PackDownloading {
        func download(_ url: URL, to destination: URL, size: Int64, sha256: String,
                      progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
            try LocalFileSystem().writeAtomically(AppCommandsTests.archive, to: destination)
            progress(DownloadProgress(receivedBytes: size / 2, totalBytes: size))
            progress(DownloadProgress(receivedBytes: size, totalBytes: size))
        }
    }

    struct Unpacker: AppArchiveExtracting {
        func extract(_ archive: URL, into destination: URL) async throws {
            try AppCommandsTests.makeApp(at: destination.appending(path: "Warzag.app"), version: "0.2.0", build: "413")
        }
    }

    struct Location: AppLocationInspecting {
        var obstacle: String?
        func obstacle(replacing bundle: URL) -> String? { obstacle }
    }

    struct Launcher: HelperLaunching {
        func launch(_ command: Command) throws -> Int32 { 1 }
        func run(_ command: Command) async throws -> ProcessOutput { ProcessOutput(exitCode: 0) }
    }

    @discardableResult
    static func makeApp(at url: URL, identifier: String = "com.warzag.app", version: String, build: String,
                        feed: String? = nil) throws -> URL {
        let contents = url.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        let feedEntry = feed.map { "<key>WarzagAppManifestURL</key><string>\($0)</string>" } ?? ""
        try Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>\(identifier)</string>
            <key>CFBundleShortVersionString</key><string>\(version)</string>
            <key>CFBundleVersion</key><string>\(build)</string>\(feedEntry)
            </dict></plist>
            """.utf8).write(to: contents.appending(path: "Info.plist"))
        return url
    }

    final class Scratch: Sendable {
        let root: URL
        let app: URL
        let feed = URL(string: "https://releases.example.org/Warzag.manifest.json")!
        let http = FakeHTTPClient()
        let runner: RecordingProcessRunner
        let printed = Mutex("")
        let asked = Mutex<[String]>([])

        init(feedInPlist: Bool = true, helper: @escaping RecordingProcessRunner.Handler = { _ in
            ProcessOutput(exitCode: 0, stdout: Data("update: replaced\n".utf8))
        }) throws {
            root = URL(filePath: FileManager.default.temporaryDirectory
                .appending(path: "warzag-app-commands-\(UUID().uuidString)").plainPath, directoryHint: .isDirectory)
            app = try AppCommandsTests.makeApp(at: root.appending(path: "Applications/Warzag.app"), version: "0.1.0",
                                               build: "412", feed: feedInPlist ? feed.absoluteString : nil)
            runner = RecordingProcessRunner(handler: helper)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func serve(build: String = "413", serial: UInt64 = 5) throws {
            let manifest = AppManifest(
                serial: serial, expires: ManualClock().now.addingTimeInterval(86_400), version: "0.2.0", build: build,
                minMacOS: "15.0", url: URL(string: "https://releases.example.org/Warzag-0.2.0.zip")!,
                size: Int64(archive.count), sha256: SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined(),
                signerFingerprint: signer)
            http.respond(to: feed, with: try SignedManifest.sign(manifest, keyId: "test", with: key).encoded())
        }

        var context: CommandContext {
            let home = root.appending(path: "home", directoryHint: .isDirectory)
            return CommandContext(
                paths: WarzagPaths(home: home, userCacheDirectory: nil), steam: .init(home: home),
                fileSystem: LocalFileSystem(), processes: FakeProcessInspector(),
                system: FakeSystemInfo.mac(chip: "Apple M2", model: "Mac14,15", product: nil, performanceCores: 4,
                                           efficiencyCores: 4, gpuCores: 10, memoryGB: 24),
                inheritedEnvironment: [:], currentDirectory: root, timeZone: TimeZone(identifier: "UTC")!)
        }

        func dependencies(location: String? = nil, interactive: Bool = false, answer: Bool = false,
                          executable: URL? = nil) -> AppCommands.Dependencies {
            let http = http
            let runner = runner
            return AppCommands.Dependencies(
                updater: { installed, feed, paths in
                    AppUpdater(installed: installed, feed: feed, trust: AppCommandsTests.trust, paths: paths,
                               macOSVersion: "26.5.1", allowsLoopbackHTTP: true, http: http,
                               downloader: WritingDownloader(), extractor: Unpacker(), bundles: PlistVerifier(),
                               location: Location(obstacle: location), fileSystem: LocalFileSystem(),
                               processes: FakeProcessInspector(), runner: runner, launcher: Launcher(),
                               clock: ManualClock())
                },
                swap: { installed, staged, requirement, log in
                    AppSwap(installed: installed, staged: staged, requirement: requirement, bundles: PlistVerifier(),
                            files: LocalBundleFiles(), processes: FakeProcessInspector(), runner: runner,
                            clock: ManualClock(), log: log)
                },
                executable: executable ?? app.appending(path: "Contents/Helpers/warzagctl"),
                signers: [AppCommandsTests.signer], fileSystem: LocalFileSystem(), isInteractive: interactive,
                ask: { question in
                    self.asked.withLock { $0.append(question) }
                    return answer
                })
        }

        func run(_ line: String, _ dependencies: AppCommands.Dependencies? = nil) async -> CommandResult {
            let output = GameCommands.Output(write: { text in self.printed.withLock { $0 += text } }, warn: { _ in })
            return await AppCommands.run(line.split(separator: " ").map(String.init), context,
                                         dependencies: dependencies ?? self.dependencies(), output: output)
        }

        var stagedApp: URL { root.appending(path: "home/Library/Caches/Warzag/AppUpdate.noindex/staging/Warzag.app") }
        var swapRecord: URL { root.appending(path: "home/Library/Caches/Warzag/AppUpdate.noindex/swap-result.json") }
    }

    // MARK: Command line

    @Test(arguments: [
        ("", "app needs status, check or update"),
        ("frobnicate", "unknown command: app frobnicate"),
        ("status --yes", "unknown option for app status: --yes"),
        ("check --open", "unknown option for app check: --open"),
        ("update --probe", "unknown option for app update: --probe"),
        ("update --feed", "--feed needs a value"),
        ("swap --wait-pid x", "--wait-pid needs a pid"),
        ("status extra", "unexpected argument for app status: extra"),
    ])
    func usageErrors(_ line: String, _ message: String) async throws {
        let scratch = try Scratch()
        let result = await scratch.run(line)
        #expect(result.exitCode == 64)
        #expect(result.stderr.hasPrefix("warzagctl: \(message)\n"))
    }

    @Test func theAppIsTheOneThisWarzagctlShipsInUnlessToldOtherwise() async throws {
        let scratch = try Scratch()
        let development = scratch.dependencies(executable: URL(filePath: "/Users/tenno/src/warzag/.build/debug/warzagctl"))
        let refused = await scratch.run("status", development)
        #expect(refused.exitCode == 64)
        #expect(refused.stderr.contains("this warzagctl does not ship in a Warzag.app; pass --app <Warzag.app>"))
        let named = await scratch.run("status --app \(scratch.app.plainPath)", development)
        #expect(named.exitCode == 0)
        #expect(named.stdout.contains("version   0.1.0 (build 412)"))
        let missing = await scratch.run("status --app /nonexistent/Warzag.app", development)
        #expect(missing.stderr.contains("no app at /nonexistent/Warzag.app"))
    }

    // MARK: status

    @Test func statusSaysWhereAndWhat() async throws {
        let scratch = try Scratch()
        let text = await scratch.run("status")
        #expect(text.exitCode == 0)
        #expect(text.stdout.contains("app       \(scratch.app.plainPath)\n"))
        #expect(text.stdout.contains("location  can replace itself\n"))
        #expect(text.stdout.contains("feed      https://releases.example.org/Warzag.manifest.json\n"))
        #expect(text.stdout.contains("serial    no app manifest accepted yet\n"))
        #expect(text.stdout.contains("prepared  none\n"))
        let blocked = await scratch.run("status", scratch.dependencies(location: "it is on a disk image"))
        #expect(blocked.stdout.contains("location  cannot replace itself: it is on a disk image\n"))
        let json = try JSONDecoder().decode(AppCommands.StatusReport.self.Decoded.self,
                                            from: Data(await scratch.run("status --json").stdout.utf8))
        #expect(json.build == "412" && json.replaceable && json.prepared == nil)
    }

    // MARK: check

    @Test func checkFindsANewerWarzag() async throws {
        let scratch = try Scratch()
        try scratch.serve()
        let result = await scratch.run("check")
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("installed  Warzag 0.1.0 (build 412)\n"))
        #expect(result.stdout.contains("latest     Warzag 0.2.0 (build 413), 0 MB, macOS 15.0 or later\n"))
        #expect(result.stdout.hasSuffix("next: warzagctl app update\n"))
        let json = await scratch.run("check --json")
        #expect(json.stdout.contains(#""result" : "available""#))
        #expect(await scratch.run("status").stdout.contains("serial    5\n"))
    }

    @Test func checkWhenUpToDateOrWithoutAFeed() async throws {
        let scratch = try Scratch()
        try scratch.serve(build: "412")
        #expect(await scratch.run("check").stdout == "Warzag 0.1.0 (build 412) is up to date (the feed offers build 412)\n")
        let bare = try Scratch(feedInPlist: false)
        let none = await bare.run("check")
        #expect(none.exitCode == 1)
        #expect(none.stderr.contains("this build has no update feed"))
        // --feed stands in for the Info.plist key (here a loopback feed, as a development build takes it).
        let local = URL(string: "http://127.0.0.1:8123/Warzag.manifest.json")!
        bare.http.respond(to: local, with: Data("{}".utf8))
        let rejected = await bare.run("check --feed \(local.absoluteString)")
        #expect(rejected.stderr == "warzagctl app check: the update was rejected: manifest envelope is not valid JSON\n")
        let insecure = await bare.run("check --feed http://releases.example.org/f.json")
        #expect(insecure.exitCode == 64)
    }

    @Test func checkFailuresAreOneLine() async throws {
        let scratch = try Scratch()
        scratch.http.fail(scratch.feed, status: 404)
        let result = await scratch.run("check")
        #expect(result.exitCode == 1)
        #expect(result.stderr == "warzagctl app check: the update feed could not be reached: HTTP 404 from releases.example.org\n")
    }

    // MARK: update

    @Test func updateAsksFirst() async throws {
        let scratch = try Scratch()
        try scratch.serve()
        let unattended = await scratch.run("update")
        #expect(unattended.exitCode == 1)
        #expect(unattended.stderr.contains("pass --yes to replace"))
        let declined = await scratch.run("update", scratch.dependencies(interactive: true, answer: false))
        #expect(declined.stdout == "nothing was changed\n")
        #expect(scratch.asked.withLock { $0 } == ["Replace \(scratch.app.plainPath) with Warzag 0.2.0 (build 413)? [y/N] "])
        #expect(scratch.runner.commands.isEmpty)
    }

    @Test func updateDownloadsChecksAndHandsTheSwapToTheNewWarzagctl() async throws {
        let scratch = try Scratch()
        try scratch.serve()
        let result = await scratch.run("update --yes --open")
        #expect(result.exitCode == 0, "\(result.stderr)")
        #expect(result.stdout == "update: replaced\ninstalled Warzag 0.2.0 (build 413) in \(scratch.app.plainPath)\n")
        let printed = scratch.printed.withLock { $0 }
        #expect(printed.contains("available: Warzag 0.2.0 (build 413), 0 MB\n"))
        #expect(printed.contains("downloaded and checked: Warzag 0.2.0 (build 413)"))
        let helper = try #require(scratch.runner.commands.first)
        #expect(helper.executable.plainPath == scratch.stagedApp.appending(path: "Contents/Helpers/warzagctl").plainPath)
        #expect(helper.arguments.prefix(2) == ["app", "swap"])
        #expect(helper.arguments.contains("--open"))
        #expect(!helper.arguments.contains("--wait-pid"))
        let log = helper.arguments.drop { $0 != "--log" }.dropFirst().first
        #expect(log == scratch.root.appending(path: "home/Library/Logs/Warzag/Warzag.log").plainPath)
    }

    @Test func whereWarzagCannotReplaceItselfTheCheckedCopyIsNamed() async throws {
        let scratch = try Scratch()
        try scratch.serve()
        let result = await scratch.run("update --yes", scratch.dependencies(location: "it runs from a disk image"))
        #expect(result.exitCode == 1)
        #expect(result.stderr == "warzagctl app update: Warzag could not replace itself: it runs from a disk image\n"
            + "the checked new Warzag is at \(scratch.stagedApp.plainPath): drag it into Applications\n")
    }

    // MARK: swap

    @Test func swapNeedsEverythingAndOnlyPinnedSigners() async throws {
        let scratch = try Scratch()
        #expect(await scratch.run("swap --installed /a").exitCode == 64)
        let stranger = await scratch.run("swap --installed /a --staged /b --version 0.2.0 --build 413 --signer "
            + String(repeating: "0", count: 64))
        #expect(stranger.exitCode == AppSwapExit.rejected)
        #expect(stranger.stderr.contains("is not a certificate this build trusts"))
    }

    @Test func swapProbesThenReplacesAndLogs() async throws {
        let scratch = try Scratch()
        let staged = try Self.makeApp(at: scratch.stagedApp, version: "0.2.0", build: "413")
        let log = scratch.root.appending(path: "home/Library/Logs/Warzag/Warzag.log")
        let common = "swap --installed \(scratch.app.plainPath) --staged \(staged.plainPath) --version 0.2.0 --build 413 "
            + "--signer \(Self.signer) --log \(log.plainPath)"
        let probe = await scratch.run(common + " --probe")
        #expect(probe.exitCode == 0, "\(probe.stderr)")
        #expect(InstalledApp.read(scratch.app).build == "412")
        let swap = await scratch.run(common)
        #expect(swap.exitCode == 0, "\(swap.stderr)")
        #expect(InstalledApp.read(scratch.app).build == "413")
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines.last?.hasSuffix("update: replaced \(scratch.app.plainPath) with Warzag 0.2.0 (build 413)") == true)
        #expect(scratch.printed.withLock { $0 }.contains("update: replaced"))
        // Without --wait-pid the caller is told directly: nothing is recorded.
        #expect(!FileManager.default.fileExists(atPath: scratch.swapRecord.plainPath))
    }

    /// With --wait-pid (Warzag has quit), how the swap ended is recorded under --home for the Warzag that opens next.
    @Test func swapAfterWarzagQuitRecordsHowItEnded() async throws {
        let scratch = try Scratch()
        let staged = try Self.makeApp(at: scratch.stagedApp, version: "0.2.0", build: "413")
        let result = await scratch.run("swap --installed \(scratch.app.plainPath) --staged \(staged.plainPath) --version "
            + "0.2.0 --build 413 --signer \(Self.signer) --wait-pid 4242")
        #expect(result.exitCode == 0, "\(result.stderr)")
        let record = try WarzagJSON.decoder().decode(AppSwapRecord.self, from: Data(contentsOf: scratch.swapRecord))
        #expect(record.result == .replaced && record.build == "413" && record.reason == nil)
    }

    @Test func swapRefusesToReplaceAnotherApp() async throws {
        let scratch = try Scratch()
        let notes = try Self.makeApp(at: scratch.root.appending(path: "Applications/Notes.app"),
                                     identifier: "com.example.notes", version: "1.0", build: "9")
        let staged = try Self.makeApp(at: scratch.stagedApp, version: "0.2.0", build: "413")
        let result = await scratch.run("swap --installed \(notes.plainPath) --staged \(staged.plainPath) --version 0.2.0 "
            + "--build 413 --signer \(Self.signer)")
        #expect(result.exitCode == AppSwapExit.refused)
        #expect(result.stderr.contains("is com.example.notes, not com.warzag.app"))
        #expect(InstalledApp.read(notes).build == "9")
    }
}

extension AppCommands.StatusReport {
    /// The JSON as warzagctl prints it.
    struct Decoded: Decodable {
        var build: String
        var replaceable: Bool
        var prepared: [String: String]?
    }
}
