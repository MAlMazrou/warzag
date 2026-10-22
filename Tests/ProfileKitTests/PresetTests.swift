import Foundation
import Testing
import WarzagCore
import WarzagTestSupport
@testable import ProfileKit

func mac(_ chip: String, _ model: String, product: String? = nil, gpu: Int?, memory: Int,
         lowPower: Bool = false, thermal: ThermalState = .nominal, power: PowerSource = .ac) -> HardwareProfile {
    HardwareProfile(chip: chip, modelIdentifier: model, productName: product, performanceCores: 4, efficiencyCores: 4,
                    gpuCores: gpu, memoryGB: memory, lowPowerMode: lowPower, thermalState: thermal, powerSource: power)
}

@Suite struct PresetTests {
    let m2Air = mac("Apple M2", "Mac14,15", product: "MacBook Air (15-inch, M2, 2023)", gpu: 10, memory: 24)

    func settings(_ preset: GraphicsPreset) -> [String: String] {
        Dictionary(uniqueKeysWithValues: preset.eeConfig.map { ($0.key, $0.value) })
    }

    @Test func fanlessBaseChipT1() {
        let preset = PresetCatalog.preset(for: m2Air)
        #expect(preset.tier == .t1)
        #expect(preset.frameRateCap == 60)
        #expect(preset.dxmtConfig == "d3d11.preferredMaxFrameRate=60;")
        // Points resolution with the recommended Balanced preset's FSR 3, and NVEXT off: Warframe's DLSS cannot start
        // under Warzag.
        #expect(!preset.enableNVEXT)
        #expect(!preset.retinaMode)
        #expect(preset.upscaling == .fsr3(.balanced))
        #expect(preset.eeConfig == [
            EEConfigSetting("Graphics.AutoDetectGraphicsSettings", "0"),
            EEConfigSetting("Graphics.WindowMode", "MODE_BORDERLESS"),
            EEConfigSetting("Graphics.VSyncMode", "VSM_ALWAYS_SYNC"),
            EEConfigSetting("Graphics.UpscaleMethod", "UM_FSR3"),
            EEConfigSetting("Graphics.UpscaleQuality", "UQ_BALANCED"),
            EEConfigSetting("Graphics.ShadowQuality", "SQ_LOW"),
            EEConfigSetting("Graphics.GeometryDetail", "GD_MEDIUM"),
            EEConfigSetting("Graphics.GPUParticlesQuality", "GPQ_LOW"),
            EEConfigSetting("Graphics.ParticleSysQuality", "PQ_MEDIUM"),
            EEConfigSetting("Graphics.TextureQuality", "TQ_MEDIUM"),
            EEConfigSetting("Graphics.EnableVolumetricLighting", "0"),
            EEConfigSetting("Graphics.LocalReflections", "0"),
            EEConfigSetting("Graphics.SSGI", "0"),
            EEConfigSetting("Graphics.EnableDOF", "0"),
            EEConfigSetting("Graphics.EnableMotionBlur", "0"),
            EEConfigSetting("Graphics.EnableGrain", "0"),
        ])
    }

    @Test func activelyCooledBaseChipT2() {
        let preset = PresetCatalog.preset(for: mac("Apple M4", "Mac16,10", product: "Mac mini (2024)", gpu: 10, memory: 16))
        let values = settings(preset)
        #expect(preset.tier == .t2)
        #expect(preset.frameRateCap == 60)
        #expect(values["Graphics.ShadowQuality"] == "SQ_MEDIUM")
        #expect(values["Graphics.GPUParticlesQuality"] == "GPQ_MEDIUM")
        #expect(values["Graphics.TextureQuality"] == "TQ_MEDIUM")
        #expect(!preset.retinaMode)
        // The recommended Balanced preset's upscaler.
        #expect(values["Graphics.UpscaleMethod"] == "UM_FSR3" && values["Graphics.UpscaleQuality"] == "UQ_BALANCED")
    }

    @Test func proChipT3() {
        let preset = PresetCatalog.preset(for: mac("Apple M3 Pro", "Mac15,6", gpu: 18, memory: 18))
        let values = settings(preset)
        #expect(preset.tier == .t3)
        #expect(preset.frameRateCap == 120)
        #expect(preset.retinaMode)
        #expect(!preset.enableNVEXT)
        // Retina upscaled by the recommended Balanced preset's FSR 3.
        #expect(preset.upscaling == .fsr3(.balanced))
        #expect(values["Graphics.UpscaleMethod"] == "UM_FSR3")
        #expect(values["Graphics.UpscaleQuality"] == "UQ_BALANCED")
        #expect(values["Graphics.AntiAliasing"] == nil)
        #expect(values["Graphics.ShadowQuality"] == "SQ_HIGH")
        #expect(values["Graphics.GeometryDetail"] == "GD_HIGH")
        #expect(values["Graphics.TextureQuality"] == "TQ_HIGH")
        #expect(values["Graphics.EnableVolumetricLighting"] == "0")
        // Pro chips seed no depth of field or film grain line (Warframe decides); motion blur is seeded off on every
        // tier, as it can smear under Warzag.
        #expect(values["Graphics.EnableDOF"] == nil && values["Graphics.EnableGrain"] == nil)
        #expect(values["Graphics.EnableMotionBlur"] == "0")
        #expect(settings(PresetCatalog.preset(for: mac("Apple M3 Pro", "Mac15,6", gpu: 14, memory: 16)))["Graphics.TextureQuality"]
            == "TQ_MEDIUM")
    }

    @Test func maxChipT4() {
        let preset = PresetCatalog.preset(for: mac("Apple M4 Max", "Mac16,5", gpu: 40, memory: 48))
        let values = settings(preset)
        #expect(preset.tier == .t4)
        #expect(preset.frameRateCap == 120)
        #expect(preset.retinaMode)
        #expect(values["Graphics.UpscaleMethod"] == nil)
        #expect(values["Graphics.AntiAliasing"] == "AA_TEMPORAL")
        #expect(values["Graphics.GPUParticlesQuality"] == "GPQ_HIGH")
        #expect(values["Graphics.EnableVolumetricLighting"] == "1")
        #expect(values["Graphics.LocalReflections"] == "1")
        #expect(values["Graphics.SSGI"] == "1")
        #expect(values["Graphics.EnableMotionBlur"] == "0")
        #expect(values["Graphics.EnableDOF"] == nil && values["Graphics.EnableGrain"] == nil)
        #expect(preset.eeConfig.last == EEConfigSetting("Graphics.EnableMotionBlur", "0"))
    }

    @Test func eightGigabyteOverlay() {
        let air = PresetCatalog.preset(for: mac("Apple M1", "MacBookAir10,1", gpu: 7, memory: 8))
        #expect(air.lowMemory)
        #expect(settings(air)["Graphics.TextureQuality"] == "TQ_LOW")
        #expect(settings(air)["Graphics.GPUParticlesQuality"] == "GPQ_LOW")

        // A hypothetical 8 GB Pro: geometry drops to medium and Retina goes; FSR 3 then upscales from points, as the
        // app's Balanced preset seeds it.
        let pro = PresetCatalog.preset(for: mac("Apple M3 Pro", "Mac15,6", gpu: 14, memory: 8))
        let values = settings(pro)
        #expect(values["Graphics.GeometryDetail"] == "GD_MEDIUM")
        #expect(values["Graphics.UpscaleQuality"] == "UQ_BALANCED")
        #expect(!pro.retinaMode)
    }

    /// The app's presets: which one each tier recommends and the upscaler each one names. They live here so the app's
    /// seed and `warzagctl profile` agree.
    @Test func eachTierRecommendsAPresetAndEachPresetNamesAnUpscaler() {
        #expect(GraphicsChoice.recommended(for: .t1) == .balanced)
        #expect(GraphicsChoice.recommended(for: .t2) == .balanced)
        // Pro chips render at Retina: their profile is an upscaled image, so Balanced (FSR 3), not native Quality.
        #expect(GraphicsChoice.recommended(for: .t3) == .balanced)
        #expect(GraphicsChoice.recommended(for: .t4) == .quality)
        #expect(GraphicsChoice.performance.upscaling == .fsr3(.performance))
        #expect(GraphicsChoice.balanced.upscaling == .fsr3(.balanced))
        #expect(GraphicsChoice.quality.upscaling == .off)
        // State/app-settings.json stores the raw values.
        #expect(GraphicsChoice.allCases.map(\.rawValue) == ["performance", "balanced", "quality"])
    }

    /// Without an explicit upscaler the seed is the recommended preset's: what the app writes for a player who kept it.
    @Test(arguments: [
        mac("Apple M2", "Mac14,15", gpu: 10, memory: 24),
        mac("Apple M1", "MacBookAir10,1", gpu: 7, memory: 8),
        mac("Apple M4", "Mac16,10", gpu: 10, memory: 16),
        mac("Apple M3 Pro", "Mac15,6", gpu: 18, memory: 18),
        mac("Apple M4 Max", "Mac16,5", gpu: 40, memory: 48),
    ])
    func theDefaultSeedIsTheRecommendedPresets(_ hardware: HardwareProfile) {
        let recommended = GraphicsChoice.recommended(for: hardware.tierClassification.tier)
        #expect(PresetCatalog.preset(for: hardware)
            == PresetCatalog.preset(for: hardware, upscaling: recommended.upscaling))
    }

    /// DLSS can never start under Warzag: no tier turns NVEXT on or seeds UM_DLSS, and Retina comes from the tier alone
    /// (Pro and Max chips with more than 8 GB).
    @Test(arguments: [
        (mac("Apple M2", "Mac14,15", gpu: 10, memory: 8), false),
        (mac("Apple M2", "Mac14,15", gpu: 10, memory: 24), false),
        (mac("Apple M4", "Mac16,10", gpu: 10, memory: 16), false),
        (mac("Apple M3 Pro", "Mac15,6", gpu: 18, memory: 36), true),
        (mac("Apple M2 Ultra", "Mac14,14", gpu: 76, memory: 128), true),
    ])
    func noTierTurnsOnNVEXTOrSeedsDLSS(_ hardware: HardwareProfile, retina: Bool) {
        for upscaling in [nil, Upscaling.off, .fsr3(), .fsr3(.performance), .fsr3(.balanced)] {
            let preset = PresetCatalog.preset(for: hardware, upscaling: upscaling)
            #expect(!preset.enableNVEXT)
            #expect(preset.enableNVEXT == PresetCatalog.nvextDefault)
            #expect(preset.retinaMode == retina)
            #expect(!preset.eeConfig.contains { $0.value.contains("DLSS") })
        }
    }

    @Test func anExplicitUpscalerReplacesTheRecommendedOne() {
        // Balanced on a T1 Mac: FSR 3 Balanced, right after the window settings, and no TAA line.
        let balanced = PresetCatalog.preset(for: m2Air, upscaling: .fsr3(.balanced))
        #expect(balanced.upscaling == .fsr3(.balanced))
        #expect(Array(balanced.eeConfig[3...4]) == [EEConfigSetting("Graphics.UpscaleMethod", "UM_FSR3"),
                                                    EEConfigSetting("Graphics.UpscaleQuality", "UQ_BALANCED")])
        #expect(settings(balanced)["Graphics.AntiAliasing"] == nil)
        #expect(!balanced.retinaMode)
        #expect(settings(PresetCatalog.preset(for: m2Air, upscaling: .fsr3(.performance)))["Graphics.UpscaleQuality"]
            == "UQ_PERFORMANCE")

        // No upscaling on a Pro chip: native Retina with TAA.
        let native = PresetCatalog.preset(for: mac("Apple M3 Pro", "Mac15,6", gpu: 18, memory: 18), upscaling: .off)
        #expect(settings(native)["Graphics.UpscaleMethod"] == nil)
        #expect(settings(native)["Graphics.UpscaleQuality"] == nil)
        #expect(settings(native)["Graphics.AntiAliasing"] == "AA_TEMPORAL")
        #expect(native.retinaMode)

        // An 8 GB Mac stays at points resolution whatever upscaler is asked for.
        let small = PresetCatalog.preset(for: mac("Apple M1", "MacBookAir10,1", gpu: 7, memory: 8),
                                         upscaling: .fsr3(.performance))
        #expect(settings(small)["Graphics.UpscaleMethod"] == "UM_FSR3")
        #expect(!small.retinaMode)
    }

    @Test func sessionGraphicsTurnsOnNVEXTOnlyOnRequest() {
        #expect(SessionGraphics.make(for: m2Air) == SessionGraphics(tier: .t1, frameRateCap: 60, enableNVEXT: false))
        #expect(SessionGraphics.make(for: m2Air, nvext: true).enableNVEXT)
        #expect(!SessionGraphics.make(for: mac("Apple M4 Max", "Mac16,5", gpu: 40, memory: 48)).enableNVEXT)
    }

    @Test func everyPresetTurnsOffAutoDetectFirstAndNeverSetsTheGamesOwnFrameCap() {
        for hardware in [m2Air, mac("Apple M4 Max", "Mac16,5", gpu: 40, memory: 48)] {
            for upscaling in [nil, Upscaling.off, .fsr3(), .fsr3(.balanced)] {
                let preset = PresetCatalog.preset(for: hardware, upscaling: upscaling)
                #expect(preset.eeConfig.first == EEConfigSetting("Graphics.AutoDetectGraphicsSettings", "0"))
                #expect(!preset.eeConfig.contains { $0.key == "Graphics.MaxFrameRate" })
                #expect(Set(preset.eeConfig.map(\.key)).count == preset.eeConfig.count)
            }
        }
    }

    @Test func framePacingRunsCoolWhenItShould() {
        let t1 = PresetCatalog.preset(for: m2Air)
        let t3Mac = mac("Apple M3 Pro", "Mac15,6", gpu: 18, memory: 18, power: .battery)
        let t3 = PresetCatalog.preset(for: t3Mac)
        #expect(FramePacing.frameRateCap(preset: t1, hardware: m2Air) == 60)
        #expect(FramePacing.frameRateCap(preset: t1, hardware: mac("Apple M2", "Mac14,15", gpu: 10, memory: 24, lowPower: true)) == 30)
        #expect(FramePacing.frameRateCap(preset: t1, hardware: mac("Apple M2", "Mac14,15", gpu: 10, memory: 24, thermal: .serious)) == 30)
        #expect(FramePacing.frameRateCap(preset: t1, hardware: mac("Apple M2", "Mac14,15", gpu: 10, memory: 24, thermal: .fair)) == 60)
        #expect(FramePacing.frameRateCap(preset: t1, hardware: mac("Apple M2", "Mac14,15", gpu: 10, memory: 24, power: .battery)) == 30)
        #expect(FramePacing.frameRateCap(preset: t3, hardware: t3Mac) == 120)
        #expect(FramePacing.frameRateCap(preset: t3, hardware: mac("Apple M3 Pro", "Mac15,6", gpu: 18, memory: 18, thermal: .critical)) == 30)
    }
}

@Suite struct EEConfigSeedTests {
    let fileSystem = InMemoryFileSystem()
    let eeConfig = URL(filePath: "/prefix/drive_c/users/tenno/AppData/Local/Warframe/EE.cfg")
    let preset = PresetCatalog.preset(for: mac("Apple M2", "Mac14,15", gpu: 10, memory: 24))

    @Test func renderedWithWindowsLineEndings() {
        let text = EEConfigSeed.render([EEConfigSetting("Graphics.AutoDetectGraphicsSettings", "0"),
                                        EEConfigSetting("Graphics.VSyncMode", "VSM_ALWAYS_SYNC")])
        #expect(text == "+nowarning\r\n+version=5\r\n[Windows_Config,/EE/Types/Base/Config]\r\n"
            + "Graphics.AutoDetectGraphicsSettings=0\r\nGraphics.VSyncMode=VSM_ALWAYS_SYNC\r\n")
    }

    @Test func seededOnlyWhenAbsent() throws {
        #expect(try EEConfigSeed.seedIfAbsent(at: eeConfig, preset: preset, fileSystem: fileSystem))
        let seeded = try #require(fileSystem.text(at: eeConfig.plainPath))
        #expect(seeded == EEConfigSeed.render(preset.eeConfig))
        #expect(seeded.contains("Graphics.TextureQuality=TQ_MEDIUM\r\n"))

        let richer = PresetCatalog.preset(for: mac("Apple M4 Max", "Mac16,5", gpu: 40, memory: 48))
        #expect(try !EEConfigSeed.seedIfAbsent(at: eeConfig, preset: richer, fileSystem: fileSystem))
        #expect(fileSystem.text(at: eeConfig.plainPath) == seeded)
    }

    @Test func aPlayersOwnSettingsAreNeverTouched() throws {
        let players = "+nowarning\r\n[Windows_Config,/EE/Types/Base/Config]\r\nGraphics.ShadowQuality=SQ_ULTRA\r\n"
        fileSystem.addFile(eeConfig.plainPath, players)
        #expect(try !EEConfigSeed.seedIfAbsent(at: eeConfig, preset: preset, fileSystem: fileSystem))
        #expect(fileSystem.text(at: eeConfig.plainPath) == players)
    }
}
