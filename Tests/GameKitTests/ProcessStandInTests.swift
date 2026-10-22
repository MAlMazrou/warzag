import Foundation
import Synchronization
import Testing
import WarzagCore
import WarzagTestSupport
import WineKit
@testable import GameKit

@Suite struct WineserverLockProbeNamingTests {
    @Test func theServerDirectoryIsNamedAsWineNamesIt() {
        #expect(WineserverLockProbe.serverDirectoryName(device: 0x0100_0010, inode: 0x2a) == "server-1000010-2a")
        // wineserver prints (unsigned long long)st_dev, and dev_t is a signed 32-bit number on macOS: a device number
        // with the top bit set is sign-extended. Zero-extending it would look in a directory no server uses.
        #expect(WineserverLockProbe.serverDirectoryName(device: dev_t(bitPattern: 0x8000_0012), inode: 0x7fff_ffff_ffff)
            == "server-ffffffff80000012-7fffffffffff")
    }
}

/// Real processes, real files and the real clock, with stand-ins for Wine and DE's launcher (no Wine, no DE code).
@Suite(.serialized) struct ProcessStandInTests {
    @Test func aChildProcessLogsToItsFileAndReportsItsExit() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appending(path: "logs/out.log")
        let process = try FoundationProcessLauncher().launch(Command(
            "/bin/sh", ["-c", "echo out; echo err >&2; exit 3"], environment: ["PATH": "/usr/bin:/bin"], logFile: log))
        #expect(process.processIdentifier > 0)
        #expect(await process.waitForExit() == 3)
        #expect(!process.isRunning)
        #expect(try String(contentsOf: log, encoding: .utf8) == "out\nerr\n")
        // A second waiter gets the same answer.
        #expect(await process.waitForExit() == 3)
    }

    @Test func terminateEndsAChild() async throws {
        let process = try FoundationProcessLauncher().launch(Command("/bin/sleep", ["30"]))
        #expect(process.isRunning)
        process.terminate()
        #expect(await process.waitForExit() == SIGTERM)
    }

    @Test func aProcessWarzagDidNotStartIsWatchedToItsEnd() async throws {
        let child = try FoundationProcessLauncher().launch(Command("/bin/sleep", ["0.3"]))
        let watched = WatchedProcess(processIdentifier: child.processIdentifier)
        #expect(watched.isRunning)
        #expect(await watched.waitForExit() == nil)
        #expect(!watched.isRunning)
        // Already gone when the watch starts.
        #expect(!WatchedProcess(processIdentifier: child.processIdentifier).isRunning)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
    func theProbeSeesWhoHoldsTheWineserverLock() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let prefix = directory.appending(path: "prefix", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let probe = WineserverLockProbe(serverRoot: directory.appending(path: "wine-uid", directoryHint: .isDirectory))
        #expect(probe.wineserver(for: prefix) == nil)

        // Wine's naming: device and inode of the prefix directory, in hex.
        let attributes = try FileManager.default.attributesOfItem(atPath: prefix.plainPath)
        let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let server = try #require(probe.serverDirectory(for: prefix))
        #expect(server.lastPathComponent == "server-\(String(device, radix: 16))-\(String(inode, radix: 16))")
        try FileManager.default.createDirectory(at: server, withIntermediateDirectories: true)
        let lock = server.appending(path: "lock")
        FileManager.default.createFile(atPath: lock.plainPath, contents: nil)
        #expect(probe.wineserver(for: prefix) == nil, "an unlocked lock file is a server that has exited")

        // What wineserver does for its whole life: a write lock on the lock file's first byte.
        let holder = try FoundationProcessLauncher().launch(Command("/usr/bin/python3", [
            "-I", "-c",
            "import fcntl,sys,time; f=open(sys.argv[1],'r+'); fcntl.lockf(f, fcntl.LOCK_EX, 1, 0); time.sleep(30)",
            lock.plainPath,
        ]))
        var owner: Int32?
        for _ in 0..<100 where owner == nil {
            try await Task.sleep(for: .milliseconds(50))
            owner = probe.wineserver(for: prefix)
        }
        #expect(owner == holder.processIdentifier)
        holder.terminate()
        _ = await holder.waitForExit()
        #expect(probe.wineserver(for: prefix) == nil)
    }

    /// Captures the processes it starts, so the fake `wineserver -k` can end them as the real one would.
    final class CapturingLauncher: ProcessLaunching {
        let inner = FoundationProcessLauncher()
        let started = Mutex<[any RunningProcess]>([])

        func launch(_ command: Command) throws -> any RunningProcess {
            let process = try inner.launch(command)
            started.withLock { $0.append(process) }
            return process
        }
    }

    /// Plays the Wine loader running DE's launcher: notes how it was started, writes Launcher.log the way DE's
    /// launcher does (a new file, CRLF lines, then "Total time:"), and idles until it is closed.
    static let standInWine = """
        #!/bin/sh
        { printf 'cwd=%s\\n' "$(pwd -P)"; for a in "$@"; do printf 'arg=%s\\n' "$a"; done; env | sort; } > "$WINEPREFIX/../started.txt"
        log="$WINEPREFIX/drive_c/users/tenno/AppData/Local/Warframe/Launcher.log"
        : > "$log"
        for line in "Current time: Fri Oct 16 23:00:00 2026" "Finished BinariesBP_LAUNCHER (0.2 seconds)" \\
                    "Finished EULA (0.0 seconds)" "Finished DirectX (0.3 seconds)" "Downloading @ 40 MB/s"; do
            printf '%s\\r\\n' "$line" >> "$log"
            sleep 0.1
        done
        printf '%s\\r\\n' "Process returned 0" "Finished Preprocess (1.5 seconds)" "Total time: 2.0 seconds" >> "$log"
        exec sleep 30

        """

    @Test func aStandInLauncherIsStartedWatchedAndClosed() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default
        let host = GameHost(bundle: root.appending(path: "Warzag.app", directoryHint: .isDirectory), channel: .n)
        let prefix = root.appending(path: "prefix", directoryHint: .isDirectory)
        let library = root.appending(path: "library", directoryHint: .isDirectory)
        try manager.createDirectory(at: host.contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        try manager.createDirectory(at: host.contents.appending(path: "renderers/dxmt/aarch64-windows"),
                                    withIntermediateDirectories: true)
        try Self.standInWine.write(to: host.wine, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: host.wine.plainPath)
        manager.createFile(atPath: host.wineserver.plainPath, contents: nil)
        for path in ["drive_c/windows/system32/winemetal.dll", "drive_c/windows/system32/nvapi64.dll",
                     "drive_c/windows/system32/nvngx.dll", "system.reg"] {
            try manager.createDirectory(at: prefix.appending(path: path).deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
            manager.createFile(atPath: prefix.appending(path: path).plainPath, contents: Data("x".utf8))
        }
        try manager.createDirectory(at: prefix.appending(path: "drive_c/users/tenno/AppData/Local/Warframe"),
                                    withIntermediateDirectories: true)
        try Fixtures.userReg(eula: Fixtures.eulaHash, launcherOverrides: true, steam: true)
            .write(to: prefix.appending(path: "user.reg"), atomically: true, encoding: .utf8)
        try manager.createDirectory(at: library.appending(path: "Tools"), withIntermediateDirectories: true)
        manager.createFile(atPath: library.appending(path: "Tools/Launcher.exe").plainPath, contents: Data("PE".utf8))
        manager.createFile(atPath: library.appending(path: "Warframe.x64.exe").plainPath, contents: Data("PE".utf8))
        try manager.createDirectory(at: prefix.appending(path: "dosdevices"), withIntermediateDirectories: true)
        try manager.createSymbolicLink(atPath: prefix.appending(path: "dosdevices/x:").plainPath,
                                       withDestinationPath: library.plainPath)
        // The previous run's log, finished: must not end this run before it starts.
        try "Current time: yesterday\r\nTotal time: 9.0 seconds\r\n"
            .write(to: prefix.appending(path: "drive_c/users/tenno/AppData/Local/Warframe/Launcher.log"),
                   atomically: true, encoding: .utf8)

        let launcher = CapturingLauncher()
        let runner = RecordingProcessRunner { command in
            if command.arguments == ["-k"] { launcher.started.withLock { $0 }.forEach { $0.terminate() } }
            return ProcessOutput(exitCode: 0)
        }
        let context = GameContext(
            fileSystem: LocalFileSystem(), files: LocalGameFiles(), runner: runner, launcher: launcher,
            opener: FakeOpener(), probe: WineserverLockProbe(serverRoot: root.appending(path: "wine-uid")),
            hostSignatures: FakeHostSignatures(), clock: SystemClock(),
            inheritedEnvironment: ["HOME": "/Users/tenno", "USER": "tenno", "DYLD_INSERT_LIBRARIES": "/evil.dylib"],
            logDirectory: root.appending(path: "Logs", directoryHint: .isDirectory),
            stateDirectory: root.appending(path: "State", directoryHint: .isDirectory))
        let installation = GameInstallation(host: host, prefix: PrefixLayout(root: prefix, windowsUserName: "tenno"),
                                            library: library)
        let configuration = ContentConfiguration(stallTimeout: 10, pollInterval: .milliseconds(50),
                                                 sizeSampleInterval: 0.1, registryPollInterval: 0.1,
                                                 closeGracePeriod: 0.3)
        let service = ContentService(installation: installation, context: context, configuration: configuration)
        #expect(service.inspector.issues(for: .runLauncher).isEmpty)

        let states = Recorder<ContentRunState>()
        let outcome = try await service.runLauncher(.update) { states.append($0) }
        #expect(outcome == .completed(seconds: 2.0))
        // An update: its own size is unknown, so progress is what the library gained since the launcher started.
        #expect(states.all.contains(.downloading(bytesThisRun: 0, bytesOnDisk: LocalGameFiles().diskUsage(of: library),
                                                 expectedBytes: nil, megabytesPerSecond: 40)))
        #expect(runner.commandLines == ["wine taskkill /IM Launcher.exe", "wineserver -k"])
        #expect(launcher.started.withLock { $0 }.allSatisfy { !$0.isRunning })

        // How the stand-in was started: X:\Tools\Launcher.exe from the library's Tools folder, DXMT, no Steam.
        let started = try String(contentsOf: root.appending(path: "started.txt"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        // `pwd -P` is the physical path (/private/var/...), which Foundation's resolvingSymlinksInPath() would hide.
        let tools = try #require(realpath(library.appending(path: "Tools").plainPath, nil))
        defer { free(tools) }
        #expect(started.first == "cwd=" + String(cString: tools))
        #expect(Array(started.dropFirst().prefix(3)) == [#"arg=X:\Tools\Launcher.exe"#, "arg=-cluster:public",
                                                         "arg=-registry:Steam"])
        let environment = Set(started.dropFirst(4))
        for expected in ["WINEPREFIX=\(prefix.plainPath)", "NEUTRON_MSYNC=0", "WINEDEBUG=-all",
                         "SteamDeck=0", "WINEDLLPATH_PREPEND=\(host.contents.plainPath)/renderers/dxmt",
                         "HOME=/Users/tenno", "USER=tenno"] {
            #expect(environment.contains(expected), "\(expected)")
        }
        #expect(!environment.contains { $0.hasPrefix("SteamAppId=") || $0.hasPrefix("DYLD_") || $0.hasPrefix("WINEDLLPATH=") })
        #expect(manager.fileExists(atPath: root.appending(path: "Logs/wine-launcher.log").plainPath))
        let record = try String(contentsOf: root.appending(path: "State/content.json"), encoding: .utf8)
        #expect(record.contains(#""mode" : "update""#))
    }
}
