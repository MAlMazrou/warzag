import Foundation
import Testing
import WarzagCore
import WarzagTestSupport
@testable import ContentKit

@Suite struct LogParserTests {
    let ee = LogParser(kind: .ee)
    let launcher = LogParser(kind: .launcher)
    let preprocess = LogParser(kind: .preprocess)

    @Test func aSteamLoginSessionFromEELog() {
        // Shaped like EE.log from a Steam login under Proton.
        let log = """
            0.124 Sys [Diag]: Process Command-line: -windowMode:2 -shaderCache:1 -graphicsDriver:dx11 -gpuPreference:2 -cluster:public -language:en -clienttype:Steam
            0.125 Sys [Diag]: Build Label: 2026.10.07.12.00/2026.10.07.12.00
            3.210 Sys [Info]: Steam active. IsBicPic=0 IsSteamDeck=0
            9.876 Script [Info]: ThemedMainMenu.lua: SteamLogin
            9.877 Script [Info]: DispatchLogin()
            9.900 Sys [Info]: Logging in as FakeTenno
            11.42 Sys [Info]: Logged in FakeTenno (1a2b3c)
            11.50 Sys [Info]: EntitlementsSteam::CheckEntitlements()
            """
        let events = log.split(separator: "\n").compactMap { ee.event(for: String($0)) }
        #expect(events == [
            .commandLine("-windowMode:2 -shaderCache:1 -graphicsDriver:dx11 -gpuPreference:2 -cluster:public -language:en -clienttype:Steam"),
            .steamActive, .steamLogin, .loggedIn,
        ])
    }

    @Test(arguments: [
        ("12.0 Sys [Error]: Steam does not appear to be running.", ContentEvent.steamNotRunning),
        ("12.0 Sys [Error]: The Steam client appears to be out of date.", .steamOutOfDate),
        ("12.0 Sys [Error]: Failed to initialize Steam.", .steamInitFailed),
        ("12.0 Sys [Error]: Downloaded data was corrupted.", .downloadCorrupted),
        ("12.0 Sys [Error]: Message: /Lotus/Language/Menu/Framework_MustRunFromLauncher", .mustRunFromLauncher),
        ("Failed to create metal view, it seems like your Wine has no exported symbols needed by DXMT.", .metalViewFailed),
        ("Logged in", .loggedIn),
        ("1835.402 Sys [Info]: Executing command: /EE/Editor/ToolMenus/Commands/CmdQuit", .closing),
        ("1836.118 Gfx [Info]: Destroying Graphics Worker Thread", .closing),
        ("Destroying Graphics Worker Thread", .closing),
    ])
    func everyEESignal(_ line: String, _ event: ContentEvent) {
        #expect(ee.event(for: line) == event)
    }

    @Test(arguments: [
        "9.900 Sys [Info]: Logging in as FakeTenno",
        "9.900 Sys [Info]: Not Logged in yet",
        "9.900 Sys [Info]: SteamLoginFailed handler registered",
        "9.900 Sys [Info]: Steam activeness unknown",
        "0.1 Sys [Diag]: Clock frequency: 24000000",
        // Warframe logs these during play too: never "closing".
        "612.004 Sys [Info]: Shutting down context...",
        "612.310 Sys [Info]: Context shutdown complete",
        "9.900 Sys [Info]: Executing command: /EE/Editor/ToolMenus/Commands/CmdQuitConfirm",
        "9.900 Sys [Info]: Executing command: /EE/Editor/ToolMenus/Commands/CmdSave",
        "9.900 Sys [Error]: Failed Executing command: /EE/Editor/ToolMenus/Commands/CmdQuit",
        "9.900 Gfx [Info]: Destroying Graphics Worker Threads",
        "9.900 Gfx [Info]: Creating Graphics Worker Thread",
    ])
    func lookalikesAreNotSignals(_ line: String) {
        #expect(ee.event(for: line) == nil)
    }

    /// EE.log's last lines after a quit from Warframe's menu (timestamps invented, disconnect lines left out): the quit
    /// command and the last step of the shutdown are `closing`, nothing else is.
    @Test func aQuitFromWarframesMenu() {
        let lines = [
            "1835.402 Sys [Info]: Executing command: /EE/Editor/ToolMenus/Commands/CmdQuit",
            "1835.611 Sys [Info]: Shutting down context...",
            "1835.920 Sys [Info]: Context shutdown complete",
            "1835.921 Script [Info]: ThemedMainMenu.lua: *** Main menu -- shutdown ***",
            "1836.004 Sys [Info]: FlashMgrImpl::Shutdown",
            "1836.010 Sys [Info]: InputMgrWin::Shutdown",
            "1836.011 Sys [Info]: DisableTextureStreaming 1",
            "1836.118 Gfx [Info]: Destroying Graphics Worker Thread",
        ]
        #expect(lines.compactMap(ee.event(for:)) == [.closing, .closing])
        // EE.log only: DE's launcher and its ContentUpdate applet (Warframe.x64.exe too) write their own logs.
        #expect(lines.compactMap(launcher.event(for:)).isEmpty)
        #expect(lines.compactMap(preprocess.event(for:)).isEmpty)
    }

    @Test(arguments: [
        ("54.1 Sys [Info]: Downloaded 1234567/55734858184", ContentEvent.launcherDownloaded(downloaded: 1_234_567, total: 55_734_858_184)),
        ("Downloaded 10 / 20", .launcherDownloaded(downloaded: 10, total: 20)),
        ("54.1 Sys [Info]: Preprocess 512/1024 50%", .launcherPreprocess(done: 512, total: 1024)),
        ("54.1 Sys [Info]: The update will be restarted shortly...", .updateRestarting),
        ("54.1 Sys [Error]: Downloaded data was corrupted.", .downloadCorrupted),
        ("Failed to create metal view", .metalViewFailed),
    ])
    func launcherSignals(_ line: String, _ event: ContentEvent) {
        #expect(launcher.event(for: line) == event)
    }

    @Test(arguments: [
        ("2.0 Sys [Info]: 1834 assets to download", ContentEvent.assetsToDownload(1834)),
        ("9.0 Sys [Info]: Wasted cache space: 734003200 bytes (3.5%)", .wastedCacheSpace(bytes: 734_003_200, percent: 3.5)),
        ("9.0 Sys [Info]: Wasted cache space: 1024", .wastedCacheSpace(bytes: 1024, percent: nil)),
        ("4.0 Sys [Error]: Fetch of /Lotus/Foo.bin failed!", .fetchFailed),
        ("9.1 Sys [Info]: Done.", .preprocessDone),
        ("Done.", .preprocessDone),
        ("4.0 Sys [Error]: Downloaded data was corrupted.", .downloadCorrupted),
    ])
    func preprocessSignals(_ line: String, _ event: ContentEvent) {
        #expect(preprocess.event(for: line) == event)
    }

    @Test func rulesOnlyApplyToTheirOwnLog() {
        #expect(preprocess.event(for: "Steam active. IsBicPic=0") == nil)
        #expect(launcher.event(for: "1834 assets to download") == nil)
        #expect(ee.event(for: "Downloaded 10/20") == nil)
        // The applet's byte counter, in its own log too: not one asset.
        #expect(preprocess.event(for: "Downloaded 10/20") == .launcherDownloaded(downloaded: 10, total: 20))
        #expect(ee.event(for: "Done.") == nil)
        #expect(ee.event(for: "Loading cache headers...") == nil)
    }

    @Test func theContentUpdateAppletsLogLines() {
        // Line shapes from a real Preprocess.log: thousands separators, byte counters, and no line per asset.
        let lines = [
            "0.764 Sys [Error]: WINHTTP_OPTION_IPV6_FAST_FALLBACK() failed (ERROR_WINHTTP_INVALID_OPTION)",
            "11.215 Sys [Info]: Downloaded 0/21544",
            "13.4 Sys [Info]: /Lotus/Scripts/Libs/Example.lua is out of date (hash mismatch)",
            "20.968 Sys [Info]: 73,617,644 bytes, 1,628 assets to download",
            "21.288 Sys [Info]: Downloaded 1520265/73617644",
            "23.436 Sys [Info]: Downloaded 66893152/73617644",
            "24.034 Sys [Info]: Done.",
            "24.041 Sys [Info]: /Cache.Windows/B.Font.cache 588,151 / 24,669,198 bytes wasted (2%)",
            "24.041 Sys [Info]: Wasted cache space: 96,723,018 bytes (0%)",
        ]
        let events = lines.compactMap(preprocess.event(for:))
        #expect(events == [
            .launcherDownloaded(downloaded: 0, total: 21_544),
            .assetsToDownload(1_628),
            .launcherDownloaded(downloaded: 1_520_265, total: 73_617_644),
            .launcherDownloaded(downloaded: 66_893_152, total: 73_617_644),
            .preprocessDone,
            .wastedCacheSpace(bytes: 96_723_018, percent: 0),
        ])

        var progress = ContentProgress()
        let fractions = events.map { event -> Double? in
            progress.apply(event)
            return progress.fraction
        }
        #expect(fractions == [0, 0, 1_520_265.0 / 73_617_644, 66_893_152.0 / 73_617_644, 1, 1])
    }

    @Test func theLaunchersBulkDownloadLogsNoCounters() {
        // Launcher.log during the bulk download: rate lines, a summary, then the applet it spawns (mirrored).
        let lines = [
            "Downloading @ 44 MB/s",
            "Downloaded 52,514,328,367 bytes total ~ 44,318,693 B/s",
            "Finished BinariesBP_BULK (1184.9 seconds)",
            #""X:\Warframe.x64.exe" -silent -log:/Preprocess.log -graphicsDriver:dx11 -cluster:public -language:en -applet:/EE/Types/Framework/ContentUpdate"#,
            "22.425 Sys [Info]: Downloaded 28680444/73617644",
        ]
        #expect(lines.compactMap(launcher.event(for:)) == [.launcherDownloaded(downloaded: 28_680_444, total: 73_617_644)])
    }

    @Test(arguments: [("1,628", 1_628), ("96,723,018", 96_723_018), ("42", 42)])
    func groupedNumbers(_ text: String, _ value: Int) {
        #expect(ContentEvent.number(text) == value)
    }

    @Test(arguments: ["", ",", "1.5", "12a"])
    func notNumbers(_ text: String) {
        let parsed: Int? = ContentEvent.number(text)
        #expect(parsed == nil)
    }

    @Test func rulesPutFirstExtendAndOverrideTheBuiltIns() throws {
        // A reworded message for a known signal, a new signal, and two rules that cannot work.
        let json = """
            [
              {"signal": "steamActive", "logs": ["ee"], "contains": "Steam is ready"},
              {"signal": "hotfixNotice", "logs": ["ee"], "pattern": "Hotfix (?<version>[0-9.]+) applied"},
              {"signal": "launcherDownloaded", "logs": ["launcher"], "pattern": "Fetched (?<downloaded>\\\\d+) of (?<total>\\\\d+)"},
              {"signal": "broken", "pattern": "(unclosed"},
              {"signal": "empty"}
            ]
            """
        let first = try JSONDecoder().decode([LogRule].self, from: Data(json.utf8))
        let rules = LogRuleSet.builtIn.extended(with: first)
        let ee = LogParser(kind: .ee, rules: rules)
        #expect(ee.event(for: "1.0 Sys [Info]: Steam is ready") == .steamActive)
        #expect(ee.event(for: "Steam active.") == .steamActive)
        #expect(ee.event(for: "Hotfix 44.1.2 applied") == .other(signal: "hotfixNotice", values: ["version": "44.1.2"]))
        #expect(ee.invalidRules.map(\.signal) == ["broken", "empty"])

        let launcher = LogParser(kind: .launcher, rules: rules)
        #expect(launcher.event(for: "Fetched 5 of 10") == .launcherDownloaded(downloaded: 5, total: 10))
    }

    @Test func knownSignalsWithUnusableValuesFallBackToOther() {
        let rules = LogRuleSet(rules: [LogRule(signal: "assetsToDownload", pattern: "(?<count>many) assets")])
        #expect(LogParser(kind: .preprocess, rules: rules).event(for: "many assets")
            == .other(signal: "assetsToDownload", values: ["count": "many"]))
    }

    @Test func builtInRulesAllCompileAndRoundTrip() throws {
        for kind in LogKind.allCases {
            #expect(LogParser(kind: kind).invalidRules.isEmpty)
        }
        let data = try JSONEncoder().encode(LogRuleSet.builtIn)
        #expect(try JSONDecoder().decode(LogRuleSet.self, from: data) == .builtIn)
        let signals = Set(LogRuleSet.builtIn.rules.map(\.signal))
        #expect(signals == Set(LogSignal.allCases.map(\.rawValue)))
    }

    @Test func monitoringALogAcrossRuns() throws {
        let fileSystem = InMemoryFileSystem()
        let path = "/prefix/drive_c/users/tenno/AppData/Local/Warframe/Preprocess.log"
        var monitor = LogMonitor(url: URL(filePath: path), kind: .preprocess)
        #expect(try monitor.poll(fileSystem).isEmpty)

        fileSystem.append(path, "1.0 Sys [Info]: Loading cache headers...\n1.1 Sys [Info]: 2 assets to download\n")
        #expect(try monitor.poll(fileSystem) == [.assetsToDownload(2)])
        fileSystem.append(path, "1.2 Sys [Info]: Downloaded 100/200\n1.3 Sys [Info]: Downloaded 2")
        #expect(try monitor.poll(fileSystem) == [.launcherDownloaded(downloaded: 100, total: 200)])
        fileSystem.append(path, "00/200\n1.4 Sys [Info]: Done.\n")
        #expect(try monitor.poll(fileSystem) == [.launcherDownloaded(downloaded: 200, total: 200), .preprocessDone])

        fileSystem.addFile(path, "0.1 Sys [Info]: 0 assets to download\n")
        #expect(try monitor.poll(fileSystem) == [.logRestarted, .assetsToDownload(0)])
    }
}
