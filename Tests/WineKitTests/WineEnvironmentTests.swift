import Foundation
import Testing
import WarzagCore
@testable import WineKit

@Suite struct WineEnvironmentTests {
    let prefix = URL(filePath: "/Users/tenno/Library/Application Support/Warzag/Prefixes/warframe-arm64",
                     directoryHint: .isDirectory)
    let host = GameHost(bundle: URL(filePath: "/Users/tenno/Library/Application Support/Warzag/Runtimes.noindex/n/0.2.0/Warzag.app"),
                        channel: .n)
    let steam = SteamSession(clientDirectory: URL(
        filePath: "/Users/tenno/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/",
        directoryHint: .isDirectory))

    /// Warzag's own environment, polluted with everything that must not reach Wine.
    let inherited = [
        "HOME": "/Users/tenno", "USER": "tenno", "LOGNAME": "tenno", "LANG": "en_US.UTF-8", "TMPDIR": "/var/folders/t/T/",
        "PATH": "/opt/homebrew/bin:/usr/bin", "DYLD_INSERT_LIBRARIES": "/tmp/inject.dylib", "DYLD_LIBRARY_PATH": "/opt/x",
        "WINEDEBUG": "+all", "WINEPREFIX": "/elsewhere", "WINEDLLOVERRIDES": "d3d11=n", "SteamAppId": "1",
        "SteamClientLaunch": "1", "SteamAppUser": "someone", "DXMT_CONFIG": "bogus", "MTL_HUD_ENABLED": "1",
        "SECRET_TOKEN": "hunter2", "NEUTRON_MSYNC": "1", "NEUTRON_RENDER_SCALE": "0.5", "WINEARCH": "win32",
        "WINEMSYNC": "1", "NEUTRON_NATIVE_FULLSCREEN": "1",
    ]

    var common: [String: String] {
        [
            "HOME": "/Users/tenno", "USER": "tenno", "LOGNAME": "tenno", "LANG": "en_US.UTF-8", "TMPDIR": "/var/folders/t/T/",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "WINEPREFIX": "/Users/tenno/Library/Application Support/Warzag/Prefixes/warframe-arm64",
            "WINEDEBUG": "-all", "SteamDeck": "0",
            "NEUTRON_PRECISE_TIMERS": "1", "NEUTRON_FAST_QPC": "1", "NEUTRON_RAW_MOUSE": "1",
            "NEUTRON_NATIVE_FULLSCREEN": "0", "NEUTRON_RENDER_SCALE": "1", "NEUTRON_MSYNC": "0",
        ]
    }

    var steamVariables: [String: String] {
        [
            "SteamAppId": "230410", "SteamGameId": "230410", "SteamOverlayGameId": "230410", "STEAM_COMPAT_APP_ID": "230410",
            "STEAM_COMPAT_CLIENT_INSTALL_PATH": "/Users/tenno/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS",
            "WINEDLLOVERRIDES": "steamclient64=n;lsteamclient=b",
        ]
    }

    /// Neutron's switches are set explicitly, with Warzag's values; WINEARCH and WINEMSYNC are never set.
    @Test func toolRunsGetOnlyTheCommonVariables() {
        #expect(WineEnvironment.toolRun(prefix: prefix, inherited: inherited) == common)
    }

    @Test func steamGameSessionOnDXMTWithNVEXT() {
        let environment = WineEnvironment.gameSession(
            prefix: prefix, host: host, renderer: RendererOptions(renderer: .dxmt, frameRateCap: 60, enableNVEXT: true),
            steam: steam, inherited: inherited)
        let expected = common.merging(steamVariables) { $1 }.merging([
            "WINEDLLPATH_PREPEND": "/Users/tenno/Library/Application Support/Warzag/Runtimes.noindex/n/0.2.0/Warzag.app/Contents/renderers/dxmt",
            "DXMT_CONFIG": "d3d11.preferredMaxFrameRate=60;",
            "DXMT_ENABLE_NVEXT": "1",
        ]) { $1 }
        #expect(environment == expected)
    }

    @Test func dxmtWithoutCapOrNVEXTSetsNeither() {
        let environment = WineEnvironment.gameSession(prefix: prefix, host: host, renderer: RendererOptions(renderer: .dxmt),
                                                      steam: steam, inherited: inherited)
        #expect(environment["DXMT_CONFIG"] == nil)
        #expect(environment["DXMT_ENABLE_NVEXT"] == nil)
        #expect(environment["WINEDLLPATH_PREPEND"]?.hasSuffix("/Contents/renderers/dxmt") == true)
    }

    @Test func wined3dHasNoOverlay() {
        let environment = WineEnvironment.gameSession(
            prefix: prefix, host: host, renderer: RendererOptions(renderer: .wined3d, frameRateCap: 60, enableNVEXT: true),
            steam: nil, inherited: inherited)
        #expect(environment == common)
    }

    @Test func warframeAccountSessionsCarryNoSteamVariables() {
        let environment = WineEnvironment.gameSession(
            prefix: prefix, host: host, renderer: RendererOptions(renderer: .dxmt, frameRateCap: 60), steam: nil,
            inherited: inherited)
        let expected = common.merging([
            "WINEDLLPATH_PREPEND": "/Users/tenno/Library/Application Support/Warzag/Runtimes.noindex/n/0.2.0/Warzag.app/Contents/renderers/dxmt",
            "DXMT_CONFIG": "d3d11.preferredMaxFrameRate=60;",
        ]) { $1 }
        #expect(environment == expected)
    }

    @Test(arguments: Renderer.allCases)
    func forbiddenAndLeakyVariablesNeverAppear(_ renderer: Renderer) {
        for session in [steam, nil] {
            let environment = WineEnvironment.gameSession(
                prefix: prefix, host: host, renderer: RendererOptions(renderer: renderer, frameRateCap: 60, enableNVEXT: true),
                steam: session, inherited: inherited)
            #expect(WineEnvironment.forbiddenKeys.isDisjoint(with: environment.keys))
            #expect(!environment.keys.contains { $0.hasPrefix("DYLD_") || $0.hasPrefix("MTL_") })
            #expect(environment["SECRET_TOKEN"] == nil)
            #expect(environment["WINEDEBUG"] == "-all")
            #expect(environment["WINEPREFIX"] == prefix.plainPath)
            #expect(environment["WINEARCH"] == nil && environment["WINEMSYNC"] == nil)
            // Neutron's switches only ever come from Warzag, with Warzag's values.
            #expect(environment.filter { $0.key.hasPrefix("NEUTRON_") } == WineEnvironment.neutronDefaults)
        }
    }

    @Test func diagnosticsCanAskForWineDebugChannels() {
        #expect(WineEnvironment.toolRun(prefix: prefix, wineDebug: "+loaddll")["WINEDEBUG"] == "+loaddll")
    }

    @Test func dxmtConfigStrings() {
        #expect(DXMTConfig().rendered == nil)
        #expect(DXMTConfig(preferredMaxFrameRate: 40).rendered == "d3d11.preferredMaxFrameRate=40;")
        #expect(DXMTConfig(preferredMaxFrameRate: 60, customVendorID: "0x10DE").rendered
            == "d3d11.preferredMaxFrameRate=60;dxgi.customVendorId=10de;")
    }

    @Test(arguments: [("0x10DE", "10de"), ("10de", "10de"), ("10DE", "10de"), ("DE", "00de"), ("0X1002", "1002")])
    func vendorIDsAreFourLowercaseHexDigits(_ input: String, _ expected: String) {
        #expect(DXMTConfig.normalizedVendorID(input) == expected)
    }

    @Test(arguments: ["", "0x", "0x12345", "nvidia", "10dz"])
    func invalidVendorIDsAreDropped(_ input: String) {
        #expect(DXMTConfig.normalizedVendorID(input) == nil)
        #expect(DXMTConfig(customVendorID: input).customVendorID == nil)
    }

    @Test func gameHostLayoutUsesWinesARM64Names() {
        let base = "/Users/tenno/Library/Application Support/Warzag/Runtimes.noindex/n/0.2.0/Warzag.app"
        #expect(host.wine.plainPath == base + "/Contents/MacOS/wine")
        #expect(host.wineserver.plainPath == base + "/Contents/MacOS/wineserver")
        #expect(host.rendererDirectory(.dxmt)?.plainPath == base + "/Contents/renderers/dxmt")
        #expect(host.rendererDirectory(.wined3d) == nil)
        #expect(host.rendererWindowsDLLs(.dxmt)?.plainPath == base + "/Contents/renderers/dxmt/aarch64-windows")
        #expect(host.builtinWindowsDLLs.plainPath == base + "/Contents/lib/wine/aarch64-windows")
    }
}

@Suite struct WineToolTests {
    let host = GameHost(bundle: URL(filePath: "/N/Warzag.app"), channel: .n)
    let prefix = URL(filePath: "/P/warframe-arm64", directoryHint: .isDirectory)
    let inherited = ["HOME": "/Users/tenno", "DYLD_INSERT_LIBRARIES": "/x.dylib"]
    var toolEnvironment: [String: String] { WineEnvironment.toolRun(prefix: prefix, inherited: inherited) }

    @Test func winebootDoesNotStopOnMonoOrGeckoPrompts() {
        let command = WineTool.wineboot.command(host: host, prefix: prefix, inherited: inherited)
        #expect(command.executable.plainPath == "/N/Warzag.app/Contents/MacOS/wine")
        #expect(command.arguments == ["wineboot", "--init"])
        #expect(command.environment == toolEnvironment.merging(["WINEDLLOVERRIDES": "mscoree,mshtml="]) { $1 })
        #expect(command.environment?["NEUTRON_MSYNC"] == "0")
    }

    @Test func registryImportUsesAWindowsPath() {
        let layout = PrefixLayout(root: prefix, windowsUserName: "tenno")
        let file = layout.windowsTemp.appending(path: "warzag-template.reg")
        let path = try! #require(layout.windowsPath(for: file))
        let command = WineTool.regImport(windowsPath: path).command(host: host, prefix: prefix, inherited: inherited)
        #expect(command.arguments == ["reg", "import", #"C:\windows\temp\warzag-template.reg"#])
        #expect(command.environment == toolEnvironment)
    }

    @Test func administrativeInstallOfDEsInstaller() {
        let log = URL(filePath: "/Users/tenno/Library/Logs/Warzag/msiexec.log")
        let command = WineTool.msiexecAdministrative(package: #"C:\windows\temp\Warframe.msi"#, targetDirectory: #"X:\"#)
            .command(host: host, prefix: prefix, inherited: inherited, logFile: log)
        #expect(command.arguments == ["msiexec", "/a", #"C:\windows\temp\Warframe.msi"#, "/qn", #"TARGETDIR=X:\"#])
        #expect(command.logFile == log)
        #expect(command.environment?["SteamAppId"] == nil)
    }

    @Test func stoppingThePrefix() {
        let command = WineTool.wineserverKill.command(host: host, prefix: prefix, inherited: inherited)
        #expect(command.executable.plainPath == "/N/Warzag.app/Contents/MacOS/wineserver")
        #expect(command.arguments == ["-k"])
        #expect(command.environment == toolEnvironment)
        let wait = WineTool.wineserverWait.command(host: host, prefix: prefix, inherited: inherited)
        #expect(wait.executable == command.executable && wait.arguments == ["-w"])
        let close = WineTool.taskkill(imageName: "Launcher.exe").command(host: host, prefix: prefix)
        #expect(close.executable.plainPath == "/N/Warzag.app/Contents/MacOS/wine")
        #expect(close.arguments == ["taskkill", "/IM", "Launcher.exe"])
        #expect(WineTool.cmd(["vol", "C:"]).command(host: host, prefix: prefix).arguments == ["cmd", "/c", "vol", "C:"])
    }

    @Test(arguments: [
        (WineTool.wineboot, 600), (.regImport(windowsPath: #"C:\x.reg"#), 120),
        (.msiexecAdministrative(package: "p", targetDirectory: "t"), 900), (.cmd(["vol"]), 120),
        (.taskkill(imageName: "Launcher.exe"), 60), (.wineserverWait, 300), (.wineserverKill, 60),
    ] as [(WineTool, Int64)])
    func everyToolRunHasADeadline(_ tool: WineTool, _ seconds: Int64) {
        #expect(tool.command(host: host, prefix: prefix).timeout == .seconds(seconds))
        #expect(tool.command(host: host, prefix: prefix, timeout: .seconds(5)).timeout == .seconds(5))
    }
}
