import Foundation
import Testing
import WarzagCore
import WarzagTestSupport
import WineKit
@testable import GameKit

/// Opt-in (`WARZAG_LIVE_HOST=/path/to/Warzag.app swift test --filter LiveHostTests`): boots a throwaway prefix with
/// the real runtime host and opens it through LaunchServices. A console batch file stands in for the game, so nothing
/// contacts Steam or DE.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["WARZAG_LIVE_HOST"] != nil))
struct LiveHostTests {
    static var host: GameHost {
        let bundle = URL(filePath: ProcessInfo.processInfo.environment["WARZAG_LIVE_HOST"] ?? "/nonexistent",
                         directoryHint: .isDirectory)
        return (try? GameHost.detect(bundle: bundle, fileSystem: LocalFileSystem())) ?? GameHost(bundle: bundle, channel: .n)
    }

    let runner = SystemProcessRunner()
    let inherited = ProcessInfo.processInfo.environment

    /// wineboot without the Mono and Gecko dialogs, with the DXMT overlay so its placeholders are copied.
    func bootPrefix(in root: URL) async throws -> URL {
        let host = Self.host
        let prefix = root.appending(path: "prefix", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        var environment = WineEnvironment.toolRun(prefix: prefix, inherited: inherited)
        environment["WINEDLLOVERRIDES"] = "mscoree,mshtml="
        environment["WINEDLLPATH_PREPEND"] = host.rendererDirectory(.dxmt)?.plainPath
        let log = root.appending(path: "wine.log")
        let boot = try await runner.run(Command(executable: host.wine, arguments: ["wineboot", "--init"],
                                                environment: environment, logFile: log))
        #expect(boot.succeeded)
        _ = try await runner.run(Command(executable: host.wineserver, arguments: ["-w"],
                                         environment: WineEnvironment.toolRun(prefix: prefix, inherited: inherited),
                                         logFile: log))
        return prefix
    }

    @Test func theProbeFindsARealWineserver() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = try await bootPrefix(in: root)
        let probe = WineserverLockProbe()
        #expect(probe.wineserver(for: prefix) == nil)
        let environment = WineEnvironment.toolRun(prefix: prefix, inherited: inherited)
        let server = try FoundationProcessLauncher().launch(Command(
            executable: Self.host.wineserver, arguments: ["-f", "-p30"], environment: environment))
        var owner: Int32?
        for _ in 0..<100 where owner == nil {
            try await Task.sleep(for: .milliseconds(100))
            owner = probe.wineserver(for: prefix)
        }
        #expect(owner == server.processIdentifier)
        _ = try await runner.run(WineTool.wineserverKill.command(host: Self.host, prefix: prefix, inherited: inherited))
        _ = await server.waitForExit()
        #expect(probe.wineserver(for: prefix) == nil)
    }

    @Test func playOpensTheHostThroughLaunchServicesAndFollowsTheSession() async throws {
        let host = Self.host
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let prefixURL = try await bootPrefix(in: root)
        let user = GameInstallation.windowsUserName(inPrefix: prefixURL, fileSystem: LocalFileSystem(), fallback: NSUserName())
        let installation = GameInstallation(host: host, prefix: PrefixLayout(root: prefixURL, windowsUserName: user),
                                            library: root.appending(path: "library", directoryHint: .isDirectory))
        let manager = FileManager.default
        let library = installation.library

        // The prefix side of the Steam bridge, as bridge/install-prefix.sh puts it there.
        let bridge = host.contents.appending(path: "share/warzag/bridge")
        let steam = installation.prefix.steamDirectory
        try manager.createDirectory(at: steam, withIntermediateDirectories: true)
        try LocalGameFiles().copyItem(at: bridge.appending(path: "steam.exe"), to: steam.appending(path: "steam.exe"))
        try LocalGameFiles().copyItem(at: bridge.appending(path: "steamclient64-forwarder.dll"),
                                      to: steam.appending(path: "steamclient64.dll"))
        try LocalGameFiles().copyItem(at: host.builtinWindowsDLLs.appending(path: "lsteamclient.dll"),
                                      to: installation.system32.appending(path: "lsteamclient.dll"))
        try LocalGameFiles().copyItem(at: bridge.appending(path: "steam.reg"),
                                      to: installation.prefix.windowsTemp.appending(path: "warzag-steam.reg"))
        let imported = try await runner.run(WineTool.regImport(windowsPath: #"C:\windows\temp\warzag-steam.reg"#)
            .command(host: host, prefix: prefixURL, inherited: inherited, logFile: root.appending(path: "wine.log")))
        #expect(imported.succeeded)
        _ = try await runner.run(Command(executable: host.wineserver, arguments: ["-w"],
                                         environment: WineEnvironment.toolRun(prefix: prefixURL, inherited: inherited)))

        // X: is the library; its "game" is a batch file that reports what it got and writes an EE.log line.
        try manager.createDirectory(at: library, withIntermediateDirectories: true)
        try manager.createSymbolicLink(atPath: installation.prefix.libraryDrive.plainPath,
                                       withDestinationPath: library.plainPath)
        manager.createFile(atPath: installation.gameExecutable.plainPath, contents: Data("placeholder".utf8))
        try manager.createDirectory(at: installation.prefix.warframeAppData, withIntermediateDirectories: true)
        try [
            "@echo off",
            #"echo %SteamAppId%,%SteamGameId%,%WINEDLLPATH_PREPEND%,%CD%> X:\warzag-live.txt"#,
            #"echo 3.210 Sys [Info]: Steam active. IsBicPic=0 IsSteamDeck=0>> "%LOCALAPPDATA%\Warframe\EE.log""#,
            "ping -n 3 127.0.0.1 > nul",
        ].joined(separator: "\r\n").appending("\r\n")
            .write(to: library.appending(path: "stand-in.cmd"), atomically: true, encoding: .utf8)

        let context = GameContext.live(paths: WarzagPaths(home: root), inheritedEnvironment: inherited)
        let content = ContentService(installation: installation, context: context)
        #expect(content.inspector.issues(for: .play(steam: true, renderer: .dxmt)).isEmpty)

        var launch = GameLaunchBuilder.launch(installation: installation, options: PlayOptions(),
                                              hardware: HardwareProfile.detect(),
                                              steamClientDirectory: root.appending(path: "no-steam-client"),
                                              inherited: inherited)
        // Same steam.exe chain and environment; the stand-in replaces X:\Warframe.x64.exe and its arguments.
        launch.arguments = Array(launch.arguments.prefix(3)) + [#"C:\windows\system32\cmd.exe"#, "/c", #"X:\stand-in.cmd"#]
        let events = Recorder<PlayEvent>()
        let session = PlaySession(content: content, configuration: PlayConfiguration(
            pollInterval: .milliseconds(200), cleanupGracePeriod: 15, activates: false, idleTimeout: 30))
        let result = try await session.run(launch, update: false) { events.append($0) }

        let report = try String(contentsOf: library.appending(path: "warzag-live.txt"), encoding: .utf8)
        #expect(report == "230410,230410,\(host.contents.plainPath)/renderers/dxmt,X:\\\r\n")
        #expect(result.signals == [.steamActive])
        #expect(result.seconds >= 1)
        #expect(events.all.contains { if case .started = $0 { true } else { false } })
        #expect(WineserverLockProbe().wineserver(for: prefixURL) == nil)
        print("live play session: \(events.all)")
    }
}
