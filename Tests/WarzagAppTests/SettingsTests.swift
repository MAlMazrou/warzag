import Foundation
import GameKit
import ProfileKit
import Testing
import WarzagCore
import WarzagTestSupport
import WineKit
@testable import WarzagApp

struct LaunchOptionsTests {
    let home = URL(filePath: "/Users/tenno", directoryHint: .isDirectory)
    let cwd = URL(filePath: "/work", directoryHint: .isDirectory)

    @Test func defaultsAreTheRealHomeAndTheLiveApp() {
        let options = LaunchOptions.parse(environment: [:], arguments: ["Warzag", "-NSDocumentRevisionsDebugMode", "YES"],
                                          defaultHome: home, currentDirectory: cwd)
        #expect(options == LaunchOptions(home: home))
    }

    @Test func environmentAndArgumentsSelectAHomeDemoAndADevelopmentEngine() {
        let options = LaunchOptions.parse(
            environment: ["WARZAG_HOME": "/tmp/wz-home", "WARZAG_DEMO": "1", "WARZAG_DEV_RUNTIME": "build/n/Warzag.app",
                          "WARZAG_SNAPSHOT_DIR": "~/shots", "WARZAG_DEMO_SPEED": "4", "WARZAG_DEMO_AUTOPLAY": "yes"],
            arguments: [], defaultHome: home, currentDirectory: cwd)
        #expect(options.home.plainPath == "/tmp/wz-home")
        #expect(options.isDemo)
        #expect(options.developmentRuntime?.plainPath == "/work/build/n/Warzag.app")
        #expect(options.snapshotDirectory?.plainPath == "/Users/tenno/shots")
        #expect(options.demoSpeed == 4)
        #expect(options.demoAutoPlay)

        let arguments = LaunchOptions.parse(environment: [:], arguments: ["Warzag", "--demo", "--home", "/scratch/h",
                                                                          "--dev-runtime", "/b/Warzag.app"],
                                            defaultHome: home, currentDirectory: cwd)
        #expect(arguments.isDemo)
        #expect(arguments.home.plainPath == "/scratch/h")
        #expect(arguments.developmentRuntime?.plainPath == "/b/Warzag.app")
    }

    /// A demo's simulated setup finishes; in the player's real home it would leave the real app on Home with nothing
    /// installed. Without an explicit home a demo keeps its data in a scratch folder.
    @Test func demoModeNeverUsesTheRealHomeByDefault() {
        let scratch = URL(filePath: "/var/folders/wz/T", directoryHint: .isDirectory)
        let demoRuns: [([String: String], [String])] = [(["WARZAG_DEMO": "1"], ["Warzag"]), ([:], ["Warzag", "--demo"])]
        for (environment, arguments) in demoRuns {
            let options = LaunchOptions.parse(environment: environment, arguments: arguments, defaultHome: home,
                                              currentDirectory: cwd, temporaryDirectory: scratch)
            #expect(options.isDemo)
            #expect(options.home.plainPath == "/var/folders/wz/T/Warzag-Demo")
        }
        let explicit = LaunchOptions.parse(environment: ["WARZAG_DEMO": "1", "WARZAG_HOME": "/tmp/wz-home"],
                                           arguments: [], defaultHome: home, currentDirectory: cwd,
                                           temporaryDirectory: scratch)
        #expect(explicit.home.plainPath == "/tmp/wz-home")
        let live = LaunchOptions.parse(environment: [:], arguments: [], defaultHome: home, currentDirectory: cwd,
                                       temporaryDirectory: scratch)
        #expect(live.home == home)
    }

    @Test func demoOnlyOptionsNeedDemoMode() {
        let options = LaunchOptions.parse(environment: ["WARZAG_SNAPSHOT_DIR": "/s", "WARZAG_DEMO_AUTOPLAY": "1"],
                                          arguments: [], defaultHome: home, currentDirectory: cwd)
        #expect(!options.isDemo)
        #expect(options.snapshotDirectory == nil)
        #expect(!options.demoAutoPlay)
    }
}

struct AppSettingsTests {
    let paths = WarzagPaths(home: URL(filePath: "/home", directoryHint: .isDirectory), userCacheDirectory: nil)

    @Test func settingsRoundTrip() throws {
        let fileSystem = InMemoryFileSystem()
        let store = AppSettingsStore(paths: paths, fileSystem: fileSystem)
        #expect(store.load() == AppSettings())
        var settings = AppSettings()
        settings.graphics = .balanced
        settings.performanceHUD = true
        settings.developmentRuntimePath = "/build/n/Warzag.app"
        try store.save(settings)
        #expect(store.load() == settings)
        #expect(store.url.plainPath == "/home/Library/Application Support/Warzag/State/app-settings.json")
    }

    @Test func missingKeysTakeDefaultsAndAnUnreadableFileGivesDefaults() throws {
        let fileSystem = InMemoryFileSystem()
        let store = AppSettingsStore(paths: paths, fileSystem: fileSystem)
        fileSystem.addFile(store.url.plainPath, #"{"schema": 1, "graphics": "quality"}"#)
        var expected = AppSettings()
        expected.graphics = .quality
        #expect(store.load() == expected)
        // A key this build does not know changes nothing.
        fileSystem.addFile(store.url.plainPath, #"{"schema": 1, "graphics": "quality", "future": true}"#)
        #expect(store.load() == expected)
        fileSystem.addFile(store.url.plainPath, "not json")
        #expect(store.load() == AppSettings())
        fileSystem.addFile(store.url.plainPath, #"{"schema": 99}"#)
        #expect(store.load() == AppSettings())
    }

    @Test func hidingWhilePlayingIsOnByDefaultAndRemembered() throws {
        let fileSystem = InMemoryFileSystem()
        let store = AppSettingsStore(paths: paths, fileSystem: fileSystem)
        #expect(AppSettings().hideWhilePlaying)
        // A file from before the setting existed keeps it on.
        fileSystem.addFile(store.url.plainPath, #"{"schema": 1, "welcomed": true}"#)
        #expect(store.load().hideWhilePlaying)
        var settings = AppSettings()
        settings.hideWhilePlaying = false
        try store.save(settings)
        #expect(!store.load().hideWhilePlaying)
        #expect(fileSystem.text(at: store.url.plainPath)?.contains(#""hideWhilePlaying" : false"#) == true)
    }

    @Test func automaticUpdateChecksAreOnByDefaultAndRemembered() throws {
        let fileSystem = InMemoryFileSystem()
        let store = AppSettingsStore(paths: paths, fileSystem: fileSystem)
        #expect(AppSettings().checkForUpdatesAutomatically)
        #expect(AppSettings().lastUpdateCheck == nil)
        // A file from before the setting existed keeps it on.
        fileSystem.addFile(store.url.plainPath, #"{"schema": 1, "welcomed": true}"#)
        #expect(store.load().checkForUpdatesAutomatically)
        #expect(store.load().lastUpdateCheck == nil)
        var settings = AppSettings()
        settings.checkForUpdatesAutomatically = false
        settings.lastUpdateCheck = Date(timeIntervalSince1970: 1_792_000_000)
        try store.save(settings)
        #expect(store.load() == settings)
        let text = fileSystem.text(at: store.url.plainPath) ?? ""
        #expect(text.contains(#""checkForUpdatesAutomatically" : false"#))
        #expect(text.contains(#""lastUpdateCheck" : "2026-10-14T17:46:40Z""#))
    }

    @Test func theLaunchsDevelopmentEngineWinsOverTheSettingsOne() {
        var settings = AppSettings()
        settings.developmentRuntimePath = "/settings/Warzag.app"
        let box = SettingsBox(settings, launchDevelopmentRuntime: URL(filePath: "/env/Warzag.app"))
        #expect(box.engine.developmentRuntime?.plainPath == "/env/Warzag.app")
        #expect(SettingsBox(settings).engine.developmentRuntime?.plainPath == "/settings/Warzag.app")
        #expect(SettingsBox(AppSettings()).engine == EngineConfiguration(developmentRuntime: nil))
    }
}

struct GraphicsTuningTests {
    let m2 = m2Air

    private func hardware(chip: String = "Apple M2", model: String = "Mac14,15", lowPower: Bool = false,
                          battery: Bool = false) -> HardwareProfile {
        var hardware = HardwareProfile(chip: chip, modelIdentifier: model, performanceCores: 4, efficiencyCores: 4,
                                       gpuCores: 10, memoryGB: 24)
        hardware.lowPowerMode = lowPower
        hardware.powerSource = battery ? .battery : .ac
        return hardware
    }

    @Test func eachTierGetsItsRecommendedPreset() {
        #expect(GraphicsChoice.recommended(for: .t1) == .balanced)
        #expect(GraphicsChoice.recommended(for: .t2) == .balanced)
        // Pro chips render at Retina: their profile is an upscaled image, so Balanced (FSR 3), not native Quality.
        #expect(GraphicsChoice.recommended(for: .t3) == .balanced)
        #expect(GraphicsChoice.recommended(for: .t4) == .quality)
        var settings = AppSettings()
        #expect(settings.graphics(for: .t1) == .balanced)
        settings.graphics = .quality
        #expect(settings.graphics(for: .t1) == .quality)
    }

    @Test func presetsMapToFrameCaps() {
        #expect(GraphicsTuning.frameRateCap(.performance, tier: .t1) == 60)
        #expect(GraphicsTuning.frameRateCap(.balanced, tier: .t2) == 60)
        #expect(GraphicsTuning.frameRateCap(.quality, tier: .t1) == 30)
        #expect(GraphicsTuning.frameRateCap(.quality, tier: .t2) == 60)
        #expect(GraphicsTuning.frameRateCap(.performance, tier: .t3) == 120)
        #expect(GraphicsTuning.frameRateCap(.quality, tier: .t4) == 60)
    }

    @Test func aMacThatShouldRunCoolIsCappedAt30() {
        #expect(GraphicsTuning.sessionFrameRateCap(.performance, hardware: hardware()) == 60)
        #expect(GraphicsTuning.sessionFrameRateCap(.performance, hardware: hardware(lowPower: true)) == 30)
        #expect(GraphicsTuning.sessionFrameRateCap(.performance, hardware: hardware(battery: true)) == 30)
        // An actively cooled Pro chip on battery keeps its cap.
        #expect(GraphicsTuning.sessionFrameRateCap(.performance, hardware: hardware(chip: "Apple M3 Pro", model: "Mac15,6",
                                                                                     battery: true)) == 120)
    }

    /// A preset is a frame cap plus the upscaler the player sets once in Warframe: FSR 3 or none, never DLSS.
    @Test func presetsSuggestFSR3OrNoUpscaling() {
        #expect(GraphicsChoice.performance.upscaling == .fsr3(.performance))
        #expect(GraphicsChoice.balanced.upscaling == .fsr3(.balanced))
        #expect(GraphicsChoice.quality.upscaling == .off)
        #expect(L10n.upscalingName(.balanced) == "FSR 3 Balanced")
        #expect(L10n.graphicsDescription(L10n.upscalingName(.performance), "60") == "FSR 3 Performance · up to 60 fps")
        #expect(L10n.graphicsDescription(L10n.upscalingName(.quality), "30") == "No upscaling · up to 30 fps")
        #expect(L10n.graphicsFootnote.contains("Options › Display › Upscaling"))
        #expect(GraphicsChoice.allCases.allSatisfy { !L10n.graphicsDescription(L10n.upscalingName($0), "60").contains("DLSS") })
    }

    @Test func aNewEECfgStartsWithThePresetsUpscaler() {
        func seed(_ choice: GraphicsChoice) -> [String: String] {
            Dictionary(uniqueKeysWithValues: GraphicsTuning.seedPreset(choice, hardware: hardware()).eeConfig.map {
                ($0.key, $0.value)
            })
        }
        #expect(seed(.performance)["Graphics.UpscaleMethod"] == "UM_FSR3")
        #expect(seed(.performance)["Graphics.UpscaleQuality"] == "UQ_PERFORMANCE")
        #expect(seed(.balanced)["Graphics.UpscaleMethod"] == "UM_FSR3")
        #expect(seed(.balanced)["Graphics.UpscaleQuality"] == "UQ_BALANCED")
        #expect(seed(.balanced)["Graphics.AntiAliasing"] == nil)
        #expect(seed(.quality)["Graphics.UpscaleMethod"] == nil)
        #expect(seed(.quality)["Graphics.AntiAliasing"] == "AA_TEMPORAL")
        for choice in GraphicsChoice.allCases {
            let preset = GraphicsTuning.seedPreset(choice, hardware: hardware())
            #expect(!preset.enableNVEXT && !preset.retinaMode)
            #expect(!preset.eeConfig.contains { $0.value.contains("DLSS") })
        }
    }

    /// `warzagctl profile` renders the recommended preset's seed (ProfileKit's default): for a player who kept that
    /// preset the app writes exactly it, on every tier.
    @Test func theAppSeedsWhatWarzagctlProfileShows() {
        for hardware in [hardware(), hardware(chip: "Apple M4", model: "Mac16,10"),
                         hardware(chip: "Apple M3 Pro", model: "Mac15,6"),
                         hardware(chip: "Apple M4 Max", model: "Mac16,5")] {
            let recommended = AppSettings().graphics(for: hardware.tierClassification.tier)
            #expect(GraphicsTuning.seedPreset(recommended, hardware: hardware) == PresetCatalog.preset(for: hardware))
        }
        #expect(GraphicsTuning.seedPreset(.performance, hardware: hardware()) != PresetCatalog.preset(for: hardware()))
    }

    @Test func theLaunchGetsThePresetsCapInDXMTConfigAndNoNVEXT() {
        let installation = GameInstallation(
            host: GameHost(bundle: URL(filePath: "/home/Runtimes.noindex/n/0.2.0/Warzag.app", directoryHint: .isDirectory),
                           channel: .n),
            prefix: PrefixLayout(root: URL(filePath: "/home/Prefixes/warframe-arm64", directoryHint: .isDirectory),
                                 windowsUserName: "tenno"),
            library: URL(filePath: "/home/Library/Warframe.noindex", directoryHint: .isDirectory))
        let built = GameLaunchBuilder.launch(
            installation: installation, options: GraphicsTuning.playOptions(steam: true, hud: false), hardware: hardware(),
            steamClientDirectory: URL(filePath: "/Steam/MacOS", directoryHint: .isDirectory), inherited: [:])
        #expect(built.environment["DXMT_ENABLE_NVEXT"] == nil)
        #expect(!built.renderer.enableNVEXT)
        #expect(built.environment["DXMT_CONFIG"] == "d3d11.preferredMaxFrameRate=60;")

        let quality = GraphicsTuning.apply(.quality, hardware: hardware(), to: built)
        #expect(quality.renderer.frameRateCap == 30)
        #expect(quality.environment["DXMT_CONFIG"] == "d3d11.preferredMaxFrameRate=30;")
        #expect(quality.environment["DXMT_ENABLE_NVEXT"] == nil)
        #expect(quality.arguments == built.arguments)
        #expect(quality.environment["SteamAppId"] == "230410")

        let hud = GameLaunchBuilder.launch(
            installation: installation, options: GraphicsTuning.playOptions(steam: false, hud: true), hardware: hardware(),
            steamClientDirectory: URL(filePath: "/Steam/MacOS", directoryHint: .isDirectory), inherited: [:])
        #expect(hud.environment["MTL_HUD_ENABLED"] == "1")
        #expect(hud.environment["SteamAppId"] == nil)
    }
}
