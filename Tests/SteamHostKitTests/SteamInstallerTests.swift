import Foundation
import Testing
import WarzagCore
import WarzagTestSupport
@testable import SteamHostKit

/// The installer runs only against a recording runner: nothing is mounted, verified or copied for real.
@Suite struct SteamInstallerTests {
    let fileSystem = InMemoryFileSystem()
    let locations = SteamLocations(home: URL(filePath: "/Users/tenno", directoryHint: .isDirectory),
                                   systemApplications: URL(filePath: "/Applications", directoryHint: .isDirectory))
    let work = URL(filePath: "/Users/tenno/Library/Caches/Warzag/steam-installer", directoryHint: .isDirectory)
    let akamai = SteamInstaller.installerURLs[0]
    let cloudflare = SteamInstaller.installerURLs[1]
    let requirement = "=anchor apple generic and certificate leaf[subject.OU] = MXGJJ98X76"

    /// Simulates hdiutil, codesign and ditto on the in-memory file system.
    func runner(codesignExit: Int32 = 0, attachExit: Int32 = 0, detachExit: Int32 = 0) -> RecordingProcessRunner {
        let fileSystem = fileSystem
        return RecordingProcessRunner { command in
            let args = command.arguments
            switch (command.executable.lastPathComponent, args.first) {
            case ("hdiutil", "attach"):
                if attachExit == 0, let index = args.firstIndex(of: "-mountpoint") {
                    fileSystem.addDirectory(args[index + 1] + "/Steam.app/Contents/MacOS")
                }
                return ProcessOutput(exitCode: attachExit, stderr: Data("hdiutil: attach failed - corrupt image\n".utf8))
            case ("hdiutil", "detach"):
                return ProcessOutput(exitCode: detachExit)
            case ("codesign", _):
                return ProcessOutput(exitCode: codesignExit, stderr: Data("test-requirement: code failed to satisfy\n".utf8))
            case ("ditto", _):
                fileSystem.addDirectory(args[1] + "/Contents/MacOS")
                return ProcessOutput(exitCode: 0)
            default:
                return ProcessOutput(exitCode: 1)
            }
        }
    }

    func installer(_ runner: RecordingProcessRunner, http: FakeHTTPClient) -> SteamInstaller {
        SteamInstaller(locations: locations, workDirectory: work, http: http, runner: runner, fileSystem: fileSystem)
    }

    func http() -> FakeHTTPClient {
        let http = FakeHTTPClient(fileSystem: fileSystem)
        http.respond(to: akamai, with: Data("dmg".utf8))
        return http
    }

    @Test func installsIntoApplicationsAfterVerifyingValvesSignature() async throws {
        fileSystem.addDirectory("/Applications")
        let runner = runner()
        let installed = try await installer(runner, http: http()).install()

        #expect(installed.plainPath == "/Applications/Steam.app")
        #expect(fileSystem.directoryExists(at: installed))
        let commands = runner.commands.map { [$0.executable.plainPath] + $0.arguments }
        #expect(commands.count == 5)
        let attach = commands[0]
        #expect(Array(attach.prefix(6)) == ["/usr/bin/hdiutil", "attach", "-nobrowse", "-noautoopen", "-readonly", "-mountpoint"])
        let mountPoint = attach[6]
        #expect(mountPoint.hasPrefix(work.plainPath + "/mount-"))
        #expect(attach[7] == work.plainPath + "/steam.dmg")
        #expect(commands[1] == ["/usr/bin/codesign", "--verify", "--deep", "--strict", "-R", requirement, mountPoint + "/Steam.app"])
        #expect(commands[2].first == "/usr/bin/ditto")
        #expect(commands[2][1] == mountPoint + "/Steam.app")
        let staged = commands[2][2]
        #expect(staged.hasPrefix("/Applications/.warzag-steam-") && staged.hasSuffix("/Steam.app"))
        #expect(commands[3] == ["/usr/bin/codesign", "--verify", "--deep", "--strict", "-R", requirement, staged])
        #expect(commands[4] == ["/usr/bin/hdiutil", "detach", mountPoint])

        #expect(try fileSystem.contentsOfDirectory(at: URL(filePath: "/Applications")).map(\.lastPathComponent) == ["Steam.app"])
        #expect(!fileSystem.fileExists(at: work.appending(path: "steam.dmg")))
        #expect(!fileSystem.fileExists(at: URL(filePath: mountPoint)))
    }

    /// Cancelled while ditto copies (Warzag quitting): the runner stops ditto and throws, and a cancelled task starts no
    /// process, as SystemProcessRunner behaves. The image must still be detached.
    @Test func aCancelledCopyStillDetachesTheImage() async throws {
        fileSystem.addDirectory("/Applications")
        let fileSystem = fileSystem
        let runner = RecordingProcessRunner { command in
            if Task.isCancelled { throw CancellationError() }
            let args = command.arguments
            switch (command.executable.lastPathComponent, args.first) {
            case ("hdiutil", "attach"):
                if let index = args.firstIndex(of: "-mountpoint") {
                    fileSystem.addDirectory(args[index + 1] + "/Steam.app/Contents/MacOS")
                }
                return ProcessOutput(exitCode: 0)
            case ("ditto", _):
                withUnsafeCurrentTask { $0?.cancel() }
                throw CancellationError()
            default:
                return ProcessOutput(exitCode: 0)
            }
        }
        let installer = installer(runner, http: http())
        let task = Task { try await installer.install() }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let attach = try #require(runner.commands.first?.arguments)
        let mountPoint = try #require(attach.firstIndex(of: "-mountpoint").map { attach[$0 + 1] })
        #expect(runner.commandLines.last == "hdiutil detach \(mountPoint)")
        #expect(!fileSystem.fileExists(at: URL(filePath: mountPoint)))
        #expect(!fileSystem.directoryExists(at: URL(filePath: "/Applications/Steam.app")))
    }

    @Test func fallsBackToTheUsersApplicationsFolder() async throws {
        fileSystem.addDirectory("/Applications")
        fileSystem.makeReadOnly("/Applications")
        let installed = try await installer(runner(), http: http()).install()
        #expect(installed.plainPath == "/Users/tenno/Applications/Steam.app")
        #expect(fileSystem.directoryExists(at: installed))
        #expect(!fileSystem.directoryExists(at: URL(filePath: "/Applications/Steam.app")))
    }

    @Test func anExistingSteamIsLeftAlone() async throws {
        fileSystem.addDirectory("/Applications/Steam.app")
        let runner = runner()
        let http = http()
        let installed = try await installer(runner, http: http).install()
        #expect(installed.plainPath == "/Applications/Steam.app")
        #expect(runner.commands.isEmpty)
        #expect(http.requests.isEmpty)
    }

    @Test func usesTheSecondCDNWhenTheFirstFails() async throws {
        fileSystem.addDirectory("/Applications")
        let http = FakeHTTPClient(fileSystem: fileSystem)
        http.fail(akamai, status: 503)
        http.respond(to: cloudflare, with: Data("dmg".utf8))
        _ = try await installer(runner(), http: http).install()
        #expect(http.requests == [akamai, cloudflare])
    }

    @Test func failsCleanlyWhenNoCDNAnswers() async {
        let http = FakeHTTPClient(fileSystem: fileSystem)
        let runner = runner()
        await #expect(throws: SteamInstallError.self) { _ = try await installer(runner, http: http).install() }
        #expect(runner.commands.isEmpty)
    }

    @Test func aBadSignatureStopsTheInstallAndStillDetaches() async {
        fileSystem.addDirectory("/Applications")
        let runner = runner(codesignExit: 3)
        await #expect(throws: SteamInstallError.signatureRejected("test-requirement: code failed to satisfy")) {
            _ = try await installer(runner, http: http()).install()
        }
        #expect(runner.commandLines.map { $0.split(separator: " ").prefix(2).joined(separator: " ") }
            == ["hdiutil attach", "codesign --verify", "hdiutil detach"])
        #expect(!fileSystem.fileExists(at: URL(filePath: "/Applications/Steam.app")))
    }

    @Test func aFailedAttachIsReported() async {
        let runner = runner(attachExit: 1)
        await #expect(throws: SteamInstallError.attachFailed("hdiutil: attach failed - corrupt image")) {
            _ = try await installer(runner, http: http()).install()
        }
        #expect(runner.commands.count == 1)
    }

    @Test func aStuckDetachIsForced() async throws {
        fileSystem.addDirectory("/Applications")
        let runner = runner(detachExit: 16)
        _ = try await installer(runner, http: http()).install()
        let detaches = runner.commands.filter { $0.arguments.first == "detach" }.map(\.arguments)
        #expect(detaches.count == 2)
        #expect(detaches[1].prefix(2) == ["detach", "-force"])
    }

    @Test func bothStartModesUseTheDetectedPathAndOnlyTheBackgroundOneIsSilent() async throws {
        let app = URL(filePath: "/Users/tenno/Applications/Steam.app", directoryHint: .isDirectory)
        #expect(SteamLauncher.command(app: app, mode: .background)
            == Command("/usr/bin/open", ["-g", "-a", "/Users/tenno/Applications/Steam.app", "--args", "-silent"]))
        #expect(SteamLauncher.command(app: app, mode: .withSignInWindow)
            == Command("/usr/bin/open", ["-a", "/Users/tenno/Applications/Steam.app"]))
        for mode in SteamStartMode.allCases {
            let arguments = SteamLauncher.command(app: app, mode: mode).arguments
            #expect(!arguments.contains("Steam") && !arguments.contains("-j") && !arguments.contains("-n"))
        }

        let runner = RecordingProcessRunner()
        try await SteamLauncher(runner: runner).launch(app: app, mode: .withSignInWindow)
        #expect(runner.commandLines == ["open -a /Users/tenno/Applications/Steam.app"])

        let failing = RecordingProcessRunner { _ in
            ProcessOutput(exitCode: 1, stderr: Data("The application cannot be opened.\n".utf8))
        }
        await #expect(throws: SteamLaunchError(reason: "The application cannot be opened.")) {
            try await SteamLauncher(runner: failing).launch(app: app, mode: .background)
        }
        // The reason goes to Warzag.log: Steam.app, never its path in the home folder.
        let naming = RecordingProcessRunner { _ in
            ProcessOutput(exitCode: 1, stderr: Data("The application /Users/tenno/Applications/Steam.app is damaged.\n".utf8))
        }
        await #expect(throws: SteamLaunchError(reason: "The application Steam.app is damaged.")) {
            try await SteamLauncher(runner: naming).launch(app: app, mode: .withSignInWindow)
        }
    }

    @Test func aStartIsInFlightFor90SecondsAndFiveMinutesOnAFirstRun() {
        let record = SteamLaunchRecord(mode: .background, at: Date(timeIntervalSince1970: 1_792_000_000))
        #expect(record.isInFlight(at: record.at.addingTimeInterval(89), clientInstalled: true))
        #expect(!record.isInFlight(at: record.at.addingTimeInterval(90), clientInstalled: true))
        #expect(record.isInFlight(at: record.at.addingTimeInterval(299), clientInstalled: false))
        #expect(!record.isInFlight(at: record.at.addingTimeInterval(300), clientInstalled: false))
        #expect(!record.isInFlight(at: record.at.addingTimeInterval(-5), clientInstalled: true))
    }
}
