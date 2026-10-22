import Foundation
import Testing
import WarzagCore
import WarzagTestSupport
import WineKit
@testable import warzagctl

@Suite struct CommandLineParserTests {
    func parse(_ line: String) throws(UsageError) -> ParsedCommandLine {
        try CommandLineParser.parse(line.split(separator: " ").map(String.init))
    }

    @Test(arguments: [
        ("paths", Invocation.paths(json: false)),
        ("paths --json", .paths(json: true)),
        ("doctor", .doctor(json: false)),
        ("doctor --json", .doctor(json: true)),
        ("steam status", .steamStatus(json: false)),
        ("steam status --json", .steamStatus(json: true)),
        ("steam", .steamStatus(json: false)),
        ("steam timeline", .steamTimeline(minutes: 60, follow: false)),
        ("steam timeline --minutes 5 --follow", .steamTimeline(minutes: 5, follow: true)),
        ("steam timeline --follow --minutes 10080", .steamTimeline(minutes: 10080, follow: true)),
        ("steam probe", .steamProbe),
        ("profile", .profile(json: false)),
        ("env --session", .env(EnvOptions(kind: .session))),
        ("env --tool", .env(EnvOptions(kind: .tool))),
        ("env --session --renderer wined3d --no-steam --host /h.app --prefix /p",
         .env(EnvOptions(kind: .session, host: "/h.app", prefix: "/p", renderer: .wined3d, steam: false))),
        ("help", .help), ("--help", .help), ("doctor -h", .help), ("version", .version), ("--version", .version),
    ])
    func validCommandLines(_ line: String, _ invocation: Invocation) throws {
        #expect(try parse(line) == ParsedCommandLine(home: nil, invocation: invocation))
    }

    @Test func homeCanAppearAnywhere() throws {
        #expect(try parse("--home /tmp/h paths") == ParsedCommandLine(home: "/tmp/h", invocation: .paths(json: false)))
        #expect(try parse("paths --home /tmp/h --json") == ParsedCommandLine(home: "/tmp/h", invocation: .paths(json: true)))
    }

    @Test(arguments: [
        ("", "missing command"),
        ("frobnicate", "unknown command: frobnicate"),
        ("steam restart", "unknown command: steam restart"),
        ("steam timeline --minutes x", "--minutes needs a whole number from 1 to 10080"),
        ("steam timeline --minutes 0", "--minutes needs a whole number from 1 to 10080"),
        ("steam timeline --minutes 10081", "--minutes needs a whole number from 1 to 10080"),
        ("steam timeline --minutes", "--minutes needs a value"),
        ("steam timeline --json", "unknown option for steam timeline: --json"),
        ("steam probe --json", "unknown option for steam probe: --json"),
        ("env", "env needs --session or --tool"),
        ("env --session --tool", "use either --session or --tool"),
        ("env --session --renderer metal", "unknown renderer: metal (dxmt or wined3d)"),
        ("env --session --json", "unknown option for env: --json"),
        ("paths --verbose", "unknown option: --verbose"),
        ("env --session --host", "--host needs a value"),
        ("--home", "--home needs a value"),
    ])
    func usageErrors(_ line: String, _ message: String) {
        #expect(throws: UsageError(message: message)) { try parse(line) }
    }
}

@Suite struct CommandsTests {
    let fileSystem = InMemoryFileSystem()
    let utc = TimeZone(identifier: "UTC")!
    var system = FakeSystemInfo.mac(chip: "Apple M2", model: "Mac14,15", product: "MacBook Air (15-inch, M2, 2023)",
                                    performanceCores: 4, efficiencyCores: 4, gpuCores: 10, memoryGB: 24)
    var processes = FakeProcessInspector()

    var context: CommandContext {
        let home = URL(filePath: "/Users/tenno", directoryHint: .isDirectory)
        return CommandContext(
            paths: WarzagPaths(home: home, userCacheDirectory: URL(filePath: "/var/folders/xy/C", directoryHint: .isDirectory)),
            steam: .init(home: home, systemApplications: URL(filePath: "/Applications", directoryHint: .isDirectory)),
            fileSystem: fileSystem, processes: processes, system: system,
            inheritedEnvironment: ["HOME": "/Users/tenno", "USER": "tenno", "DYLD_INSERT_LIBRARIES": "/x.dylib",
                                   "SteamAppUser": "someone"],
            currentDirectory: URL(filePath: "/Users/tenno/src/warzag", directoryHint: .isDirectory),
            timeZone: utc)
    }

    func run(_ line: String) throws -> CommandResult {
        let parsed = try CommandLineParser.parse(line.split(separator: " ").map(String.init))
        return Commands.run(parsed.invocation, in: context)
    }

    func environment(_ output: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: output.split(separator: "\n").map { line in
            let parts = line.split(separator: "=", maxSplits: 1)
            return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
        })
    }

    @Test func pathsAsTextAndJSON() throws {
        let text = try run("paths").stdout
        let lines = text.split(separator: "\n")
        #expect(lines.count == 13)
        #expect(lines[0] == "applicationSupport  /Users/tenno/Library/Application Support/Warzag")
        #expect(text.contains("setupState          /Users/tenno/Library/Application Support/Warzag/State/setup.json\n"))
        let json = try JSONDecoder().decode([String: String].self, from: Data(try run("paths --json").stdout.utf8))
        #expect(json["dxmtCache"] == "/var/folders/xy/C/dxmt/Warframe.x64.exe")
        #expect(json.count == 13)
    }

    @Test func sessionEnvironmentBeforeAnyRuntimeIsInstalled() throws {
        // Nothing installed: the development host.
        let result = try run("env --session")
        #expect(result.exitCode == 0)
        #expect(result.stderr == "warzagctl: no runtime installed; showing the environment for /Users/tenno/src/warzag/build/n/Warzag.app\n")
        let lines = result.stdout.split(separator: "\n").map(String.init)
        #expect(lines == lines.sorted())
        // No DXMT_ENABLE_NVEXT: NVEXT is off on every tier, as for `warzagctl play` (ProfileKit's SessionGraphics).
        #expect(environment(result.stdout) == [
            "DXMT_CONFIG": "d3d11.preferredMaxFrameRate=60;",
            "HOME": "/Users/tenno",
            "NEUTRON_FAST_QPC": "1",
            "NEUTRON_MSYNC": "0",
            "NEUTRON_NATIVE_FULLSCREEN": "0",
            "NEUTRON_PRECISE_TIMERS": "1",
            "NEUTRON_RAW_MOUSE": "1",
            "NEUTRON_RENDER_SCALE": "1",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "STEAM_COMPAT_APP_ID": "230410",
            "STEAM_COMPAT_CLIENT_INSTALL_PATH": "/Users/tenno/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS",
            "SteamAppId": "230410",
            "SteamDeck": "0",
            "SteamGameId": "230410",
            "SteamOverlayGameId": "230410",
            "USER": "tenno",
            "WINEDEBUG": "-all",
            "WINEDLLOVERRIDES": "steamclient64=n;lsteamclient=b",
            "WINEDLLPATH_PREPEND": "/Users/tenno/src/warzag/build/n/Warzag.app/Contents/renderers/dxmt",
            "WINEPREFIX": "/Users/tenno/Library/Application Support/Warzag/Prefixes/warframe-arm64",
        ])
        // NVEXT only for an experiment that asks for it.
        #expect(environment(try run("env --session --nvext").stdout)["DXMT_ENABLE_NVEXT"] == "1")
    }

    @Test func aHostSaysWhichChannelItIs() throws {
        fileSystem.addFile("/H.app/Contents/Info.plist", """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>WarzagRuntimeChannel</key><string>n</string></dict></plist>
            """)
        let n = try run("env --session --host /H.app")
        #expect(n.stderr.isEmpty)
        #expect(environment(n.stdout)["WINEPREFIX"] == "/Users/tenno/Library/Application Support/Warzag/Prefixes/warframe-arm64")
        #expect(environment(n.stdout)["NEUTRON_MSYNC"] == "0")
        fileSystem.addFile("/H.app/Contents/Info.plist", """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>WarzagRuntimeChannel</key><string>x</string></dict></plist>
            """)
        let other = try run("env --session --host /H.app")
        #expect(other.exitCode == 1)
        #expect(other.stderr == "warzagctl: Info.plist's WarzagRuntimeChannel is \"x\", not n\n")
    }

    @Test func sessionEnvironmentUsesTheActiveRuntime() throws {
        let paths = context.paths
        fileSystem.addDirectory(paths.gameHost(.n, version: "0.1.0").appending(path: "Contents/MacOS").plainPath)
        fileSystem.addFile(paths.activeRuntimePointer.plainPath, """
            {"schema":1,"current":{"id":"n-0.1.0","version":"0.1.0","channel":"n","signerFingerprint":"ab"},
             "revoked":[],"rolledBack":[]}
            """)
        let result = try run("env --session")
        #expect(result.stderr.isEmpty)
        #expect(environment(result.stdout)["WINEDLLPATH_PREPEND"]
            == paths.gameHost(.n, version: "0.1.0").plainPath + "/Contents/renderers/dxmt")
        // What Wine gets is inside the .noindex store, out of Spotlight.
        #expect(environment(result.stdout)["WINEDLLPATH_PREPEND"]?.hasPrefix(
            "/Users/tenno/Library/Application Support/Warzag/Runtimes.noindex/n/0.1.0/Warzag.app/") == true)
    }

    @Test func sessionVariants() throws {
        let wined3d = environment(try run("env --session --renderer wined3d --no-steam --host /H.app --prefix /P").stdout)
        #expect(wined3d["WINEDLLPATH_PREPEND"] == nil)
        #expect(wined3d["DXMT_CONFIG"] == nil)
        #expect(wined3d["WINEPREFIX"] == "/P")
        #expect(wined3d.keys.filter { $0.lowercased().contains("steam") && $0 != "SteamDeck" }.isEmpty)
        #expect(wined3d["WINEDLLOVERRIDES"] == nil)

        var hot = self
        hot.system.thermalState = .serious
        #expect(environment(try hot.run("env --session").stdout)["DXMT_CONFIG"] == "d3d11.preferredMaxFrameRate=30;")
    }

    @Test func toolEnvironment() throws {
        #expect(environment(try run("env --tool").stdout) == [
            "HOME": "/Users/tenno", "USER": "tenno", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "WINEPREFIX": "/Users/tenno/Library/Application Support/Warzag/Prefixes/warframe-arm64",
            "WINEDEBUG": "-all", "SteamDeck": "0",
            "NEUTRON_PRECISE_TIMERS": "1", "NEUTRON_FAST_QPC": "1", "NEUTRON_RAW_MOUSE": "1",
            "NEUTRON_NATIVE_FULLSCREEN": "0", "NEUTRON_RENDER_SCALE": "1", "NEUTRON_MSYNC": "0",
        ])
    }

    @Test func steamStatusForASignedInSteam() throws {
        var signedIn = self
        let start = Date(timeIntervalSince1970: 1_792_173_600)
        signedIn.processes = FakeProcessInspector([4242: .init(path: "/S/steam_osx", start: start)])
        fileSystem.addDirectory("/Applications/Steam.app")
        let steam = context.steam
        fileSystem.addFile(steam.steamClientLibrary.plainPath, "dylib")
        fileSystem.addFile(steam.packageDirectory.appending(path: "steam_client_osx.manifest").plainPath,
                           #""osx" { "version" "1788652215" }"#)
        fileSystem.addFile(steam.registryFile.plainPath,
                           #""Registry" { "HKLM" { "Software" { "Valve" { "Steam" { "SteamPID" "4242" } } } } }"#)
        fileSystem.addFile(steam.connectionLog.plainPath,
                           "[2026-10-16 18:00:06] [Logged On, 0, 341] [U:1:987654321] OK 76561198947920049\r\n")

        let text = try signedIn.run("steam status").stdout
        #expect(text == """
            installed  yes (/Applications/Steam.app)
            client     1788652215 (steamclient.dylib present)
            running    yes (pid 4242)
            signed in  yes

            """)
        let json = try signedIn.run("steam status --json").stdout
        #expect(json.contains(#""signedIn" : true"#))
        for identifier in ["987654321", "76561198947920049"] {
            #expect(!text.contains(identifier) && !json.contains(identifier))
        }
    }

    @Test func steamStatusWhenSteamIsMissing() throws {
        #expect(try run("steam status").stdout == """
            installed  no
            client     unknown version (steamclient.dylib missing)
            running    no
            signed in  no (Steam is not running)

            """)
    }

    @Test func doctorOnAHealthyMac() throws {
        let result = try run("doctor")
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("  chip     Apple M2 (4 performance + 4 efficiency cores, 10-core GPU)\n"))
        #expect(result.stdout.contains("  tier     T1 — Apple M2: base chip, fanless\n"))
        #expect(result.stdout.contains("  setup           not started\n"))
        #expect(result.stdout.contains("  library volume  apfs, case-insensitive, 500 GB free\n"))
        #expect(result.stdout.contains("warning: Steam is not installed"))
        #expect(!result.stdout.contains("problem:"))
        let json = try JSONSerialization.jsonObject(with: Data(try run("doctor --json").stdout.utf8)) as? [String: Any]
        #expect((json?["tier"] as? [String: Any])?["tier"] as? String == "T1")
    }

    @Test func doctorReportsHardProblems() throws {
        var intel = self
        intel.system.integers["hw.optional.arm64"] = 0
        intel.system.operatingSystemVersion = OperatingSystemVersion(majorVersion: 14, minorVersion: 7, patchVersion: 0)
        fileSystem.setVolume(VolumeInfo(availableCapacity: 20_000_000_000, isCaseSensitive: true, isLocal: true, format: "apfs"))
        let result = try intel.run("doctor")
        #expect(result.exitCode == 1)
        #expect(result.stdout.contains("problem: Warzag needs an Apple silicon Mac\n"))
        #expect(result.stdout.contains("problem: Warzag needs macOS 15.0 or later (this Mac has 14.7)\n"))
        #expect(result.stdout.contains("problem: the library volume is case-sensitive"))
        #expect(result.stdout.contains("warning: only 20 GB free"))
    }

    @Test func doctorNoticesSetupProgress() throws {
        try SetupStateStore(paths: context.paths, fileSystem: fileSystem).save(.initial)
        #expect(try run("doctor").stdout.contains("  setup           in progress\n"))
        fileSystem.addFile(context.paths.setupStateFile.plainPath, "garbage")
        #expect(try run("doctor").stdout.contains("setup.json is unreadable"))
        // Diagnostics never change anything on disk.
        #expect(fileSystem.text(at: context.paths.setupStateFile.plainPath) == "garbage")
    }

    @Test func profileShowsThePresetAndTheSeed() throws {
        var lowPower = self
        lowPower.system.isLowPowerModeEnabled = true
        let text = try lowPower.run("profile").stdout
        #expect(text.contains("tier         T1 — Apple M2: base chip, fanless\n"))
        #expect(text.contains("frame cap    30 fps now (preset 60 fps)\n"))
        #expect(text.contains("DXMT_CONFIG  d3d11.preferredMaxFrameRate=30;\n"))
        #expect(text.contains(
            "upscaling    FSR 3 (UQ_BALANCED): the Balanced preset, recommended for this Mac\n"))
        #expect(text.contains("RetinaMode   no\n"))
        #expect(text.contains("NVEXT        off (it would only give Warframe an NVIDIA identity; DLSS is unavailable in "
            + "Warframe)\n"))
        #expect(text.contains("  Graphics.AutoDetectGraphicsSettings=0\n"))
        #expect(!text.contains("UM_DLSS"))
        #expect(!text.contains("\r"))
        let json = try JSONSerialization.jsonObject(with: Data(try lowPower.run("profile --json").stdout.utf8)) as? [String: Any]
        #expect(json?["sessionFrameRateCap"] as? Int == 30)
        #expect(json?["recommendedPreset"] as? String == "balanced")
    }

    /// The seed block is what the app writes for a player who kept the recommended preset
    /// (LiveGameService.seedProfile): that preset's upscaler.
    @Test(arguments: [
        ("Apple M2", "Mac14,15", "Balanced",
         "FSR 3 (UQ_BALANCED)", ["Graphics.UpscaleMethod=UM_FSR3", "Graphics.UpscaleQuality=UQ_BALANCED"]),
        ("Apple M4", "Mac16,10", "Balanced",
         "FSR 3 (UQ_BALANCED)", ["Graphics.UpscaleMethod=UM_FSR3", "Graphics.UpscaleQuality=UQ_BALANCED"]),
        ("Apple M3 Pro", "Mac15,6", "Balanced",
         "FSR 3 (UQ_BALANCED)", ["Graphics.UpscaleMethod=UM_FSR3", "Graphics.UpscaleQuality=UQ_BALANCED"]),
        ("Apple M4 Max", "Mac16,5", "Quality",
         "none (native resolution, temporal anti-aliasing)", ["Graphics.AntiAliasing=AA_TEMPORAL"]),
    ])
    func profileSeedsTheRecommendedPresetsUpscaler(chip: String, model: String, preset: String, upscaling: String,
                                                   lines: [String]) throws {
        var mac = self
        mac.system = FakeSystemInfo.mac(chip: chip, model: model, product: nil, performanceCores: 4, efficiencyCores: 4,
                                        gpuCores: 10, memoryGB: 24)
        let text = try mac.run("profile").stdout
        #expect(text.contains("upscaling    \(upscaling): the \(preset) preset, recommended for this Mac\n"))
        #expect(text.contains("EE.cfg seed (written once, only if the player has no EE.cfg; with the \(preset) "
            + "preset's upscaler unless the player chose another preset in the app):\n"))
        for line in lines { #expect(text.contains("  \(line)\n")) }
        let seed = text.components(separatedBy: "EE.cfg seed").last ?? ""
        #expect(seed.components(separatedBy: "\n").filter { $0.contains("Upscale") || $0.contains("AntiAliasing") }
            == lines.map { "  \($0)" })
    }

    @Test func helpAndVersion() throws {
        let help = try run("help").stdout
        #expect(help.hasPrefix("usage: warzagctl"))
        #expect(help.contains("runtime use-local <Warzag.app>") && help.contains("runtime trust [--json]"))
        #expect(try run("version").stdout == "warzagctl \(Commands.version)\n")
    }
}
