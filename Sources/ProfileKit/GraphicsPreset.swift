import Foundation
import WarzagCore

/// One `Key=Value` line of EE.cfg's `[Windows_Config,/EE/Types/Base/Config]` section.
public struct EEConfigSetting: Codable, Equatable, Sendable {
    public var key: String
    public var value: String

    public init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }
}

/// `Graphics.UpscaleMethod` values Warzag seeds. Warframe also knows UM_DLSS (`PresetCatalog.nvextDefault`) and
/// UM_MFSR; neither is offered.
public enum UpscaleMethod: String, Codable, Sendable, CaseIterable {
    case disabled = "UM_DISABLED"
    case fsr3 = "UM_FSR3"
}

/// `Graphics.UpscaleQuality` values (strings in Warframe.x64.exe).
public enum UpscaleQuality: String, Codable, Sendable, CaseIterable {
    case auto = "UQ_AUTO"
    case ultraQuality = "UQ_ULTRA_QUALITY"
    case quality = "UQ_QUALITY"
    case balanced = "UQ_BALANCED"
    case performance = "UQ_PERFORMANCE"
    case ultraPerformance = "UQ_ULTRA_PERFORMANCE"
    case antiAliasing = "UQ_ANTI_ALIASING"
}

/// Warframe's upscaler (Options > Display > Upscaling) as a new EE.cfg seeds it: FSR 3 or none, never DLSS.
public struct Upscaling: Codable, Equatable, Sendable {
    public var method: UpscaleMethod
    /// nil leaves the level to Warframe.
    public var quality: UpscaleQuality?

    public init(method: UpscaleMethod, quality: UpscaleQuality? = nil) {
        self.method = method
        self.quality = quality
    }

    /// Native resolution with temporal anti-aliasing: no `Graphics.UpscaleMethod` line (Warframe's default is no
    /// upscaling), `Graphics.AntiAliasing=AA_TEMPORAL` instead.
    public static let off = Upscaling(method: .disabled)

    /// Warframe's FSR 3 (`Graphics.UpscaleMethod=UM_FSR3`), at `quality` when one is given.
    public static func fsr3(_ quality: UpscaleQuality? = nil) -> Upscaling {
        Upscaling(method: .fsr3, quality: quality)
    }

    /// The seed lines for this upscaler, in file order.
    var settings: [EEConfigSetting] {
        switch method {
        case .disabled:
            [EEConfigSetting("Graphics.AntiAliasing", "AA_TEMPORAL")]
        case .fsr3:
            [EEConfigSetting("Graphics.UpscaleMethod", UpscaleMethod.fsr3.rawValue)]
                + (quality.map { [EEConfigSetting("Graphics.UpscaleQuality", $0.rawValue)] } ?? [])
        }
    }
}

/// The app's graphics presets (Settings › Graphics): a frame cap, which the app applies (`GraphicsTuning`), plus the
/// upscaler the player sets once in Warframe (Options > Display > Upscaling) and a new EE.cfg starts with. Never DLSS
/// (`PresetCatalog.nvextDefault`). The upscalers and the per-tier recommendation live here so the app's seed and
/// `warzagctl profile` come from one place. The app stores the raw value in State/app-settings.json.
public enum GraphicsChoice: String, Codable, CaseIterable, Sendable {
    case performance
    case balanced
    case quality

    /// Balanced on base and Pro chips, Quality (native Retina) on Max and Ultra chips. Pro chips get Balanced because
    /// their profile is an upscaled Retina image and Quality would render every Retina pixel.
    public static func recommended(for tier: PerformanceTier) -> GraphicsChoice {
        switch tier {
        case .t1, .t2, .t3: .balanced
        case .t4: .quality
        }
    }

    /// The upscaler the preset names and a new EE.cfg seeds: FSR 3 Performance, FSR 3 Balanced, or none (TAA).
    public var upscaling: Upscaling {
        switch self {
        case .performance: .fsr3(.performance)
        case .balanced: .fsr3(.balanced)
        case .quality: .off
        }
    }
}

/// Everything Warzag decides about graphics for one Mac.
public struct GraphicsPreset: Codable, Equatable, Sendable {
    public var tier: PerformanceTier
    public var lowMemory: Bool
    /// Frame cap before power and thermal adjustments (`FramePacing`). Applied by the renderer (DXMT's
    /// `d3d11.preferredMaxFrameRate`), so EE.cfg's own Graphics.MaxFrameRate is left alone: one limiter, not two.
    public var frameRateCap: Int
    /// DXMT_ENABLE_NVEXT: always `PresetCatalog.nvextDefault` (off).
    public var enableNVEXT: Bool
    /// HKCU\Software\Wine\Mac Driver\RetinaMode: native pixels on Pro and Max chips, macOS points elsewhere.
    public var retinaMode: Bool
    /// The upscaler the EE.cfg seed sets.
    public var upscaling: Upscaling
    /// Seed values for a fresh EE.cfg, in file order.
    public var eeConfig: [EEConfigSetting]

    /// The DXMT_CONFIG value for the preset's own cap.
    public var dxmtConfig: String { "d3d11.preferredMaxFrameRate=\(frameRateCap);" }
}

/// Per-tier presets (T1–T4), with an overlay for 8 GB Macs.
public enum PresetCatalog {
    /// DXMT's NVEXT is off on every tier. Warframe's DLSS can never start under Warzag (its NGX loader needs NVIDIA's
    /// signature on _nvngx.dll), so NVEXT would only make the game see an "NVIDIA" GPU. Experiments ask for it
    /// explicitly: `PlayOptions.nvext`, `warzagctl play|env --session --nvext`.
    public static let nvextDefault = false

    /// The preset for `hardware`. Its EE.cfg seed carries `upscaling` (the app passes the player's preset's); nil means
    /// the upscaler of the preset recommended for the tier (`GraphicsChoice.recommended(for:)`), which is what the app
    /// seeds for a player who kept the recommended preset and what `warzagctl profile` shows.
    public static func preset(for hardware: HardwareProfile, upscaling: Upscaling? = nil) -> GraphicsPreset {
        let classification = TierClassifier.classify(hardware)
        var quality = TierQuality.of(classification.tier, memoryGB: hardware.memoryGB)

        if classification.lowMemory {
            quality.textures = "TQ_LOW"
            quality.gpuParticles = "GPQ_LOW"
            if quality.geometry == "GD_HIGH" { quality.geometry = "GD_MEDIUM" }
            // Retina quadruples every render target: an 8 GB Mac renders at points resolution (an upscaler then works
            // from points too).
            quality.retina = false
        }
        let upscaling = upscaling ?? GraphicsChoice.recommended(for: classification.tier).upscaling

        var settings = [
            EEConfigSetting("Graphics.AutoDetectGraphicsSettings", "0"),
            EEConfigSetting("Graphics.WindowMode", "MODE_BORDERLESS"),
            EEConfigSetting("Graphics.VSyncMode", "VSM_ALWAYS_SYNC"),
        ]
        settings += upscaling.settings
        settings += [
            EEConfigSetting("Graphics.ShadowQuality", quality.shadows),
            EEConfigSetting("Graphics.GeometryDetail", quality.geometry),
            EEConfigSetting("Graphics.GPUParticlesQuality", quality.gpuParticles),
        ]
        if let particleSystems = quality.particleSystems {
            settings.append(EEConfigSetting("Graphics.ParticleSysQuality", particleSystems))
        }
        settings += [
            EEConfigSetting("Graphics.TextureQuality", quality.textures),
            EEConfigSetting("Graphics.EnableVolumetricLighting", quality.volumetricLighting ? "1" : "0"),
            EEConfigSetting("Graphics.LocalReflections", quality.localReflections ? "1" : "0"),
            EEConfigSetting("Graphics.SSGI", quality.ssgi ? "1" : "0"),
        ]
        if quality.cinematicEffectsOff { settings.append(EEConfigSetting("Graphics.EnableDOF", "0")) }
        // Motion blur off on every tier (it can smear under Warzag). Like every seed line it only reaches a new
        // profile; EEConfigReader tells Home when a player has it on.
        settings.append(EEConfigSetting(EEConfigReader.motionBlurKey, "0"))
        if quality.cinematicEffectsOff { settings.append(EEConfigSetting("Graphics.EnableGrain", "0")) }

        return GraphicsPreset(
            tier: classification.tier,
            lowMemory: classification.lowMemory,
            frameRateCap: quality.frameRateCap,
            enableNVEXT: nvextDefault,
            retinaMode: quality.retina,
            upscaling: upscaling,
            eeConfig: settings
        )
    }
}

/// What one game session gets from the profile: the renderer's frame cap (the preset's, lowered by `FramePacing` when
/// the Mac should run cool) and whether DXMT turns on NVEXT, which only an explicit request does. `warzagctl env
/// --session` and `warzagctl play` take it from here; the app replaces the cap with the player's preset's
/// (`GraphicsTuning`).
public struct SessionGraphics: Codable, Equatable, Sendable {
    public var tier: PerformanceTier
    public var frameRateCap: Int
    public var enableNVEXT: Bool

    public init(tier: PerformanceTier, frameRateCap: Int, enableNVEXT: Bool) {
        self.tier = tier
        self.frameRateCap = frameRateCap
        self.enableNVEXT = enableNVEXT
    }

    /// `nvext` is that explicit request (`PlayOptions.nvext`, `warzagctl play|env --session --nvext`): an NVIDIA
    /// identity for experiments (`PresetCatalog.nvextDefault`).
    public static func make(for hardware: HardwareProfile, nvext: Bool = PresetCatalog.nvextDefault) -> SessionGraphics {
        let preset = PresetCatalog.preset(for: hardware)
        return SessionGraphics(tier: preset.tier, frameRateCap: FramePacing.frameRateCap(preset: preset, hardware: hardware),
                               enableNVEXT: nvext)
    }
}

/// The per-tier choices before the 8 GB overlay is applied.
struct TierQuality {
    var shadows: String
    var geometry: String
    var gpuParticles: String
    var particleSystems: String?
    var textures: String
    var volumetricLighting: Bool
    var localReflections: Bool
    var ssgi: Bool
    /// true seeds depth of field and film grain off; false seeds no line for either, so Warframe decides. Motion blur
    /// is seeded off on every tier.
    var cinematicEffectsOff: Bool
    var retina: Bool
    var frameRateCap: Int

    /// The upscaler is not a tier choice: it is the recommended app preset's (`GraphicsChoice.recommended(for:)`).
    static func of(_ tier: PerformanceTier, memoryGB: Int) -> TierQuality {
        switch tier {
        case .t1:
            // Fanless base chips: thermals and bandwidth bound; points resolution.
            TierQuality(shadows: "SQ_LOW", geometry: "GD_MEDIUM", gpuParticles: "GPQ_LOW", particleSystems: "PQ_MEDIUM",
                        textures: "TQ_MEDIUM", volumetricLighting: false, localReflections: false, ssgi: false,
                        cinematicEffectsOff: true, retina: false, frameRateCap: 60)
        case .t2:
            // T1 plus medium shadows and GPU particles.
            TierQuality(shadows: "SQ_MEDIUM", geometry: "GD_MEDIUM", gpuParticles: "GPQ_MEDIUM",
                        particleSystems: "PQ_MEDIUM", textures: "TQ_MEDIUM", volumetricLighting: false,
                        localReflections: false, ssgi: false, cinematicEffectsOff: true, retina: false,
                        frameRateCap: 60)
        case .t3:
            // Pro chips: Medium/High mix at Retina, upscaled by Warframe's FSR 3. Volumetric lighting and screen-space
            // reflections stay off.
            TierQuality(shadows: "SQ_HIGH", geometry: "GD_HIGH", gpuParticles: "GPQ_MEDIUM", particleSystems: nil,
                        textures: memoryGB >= 18 ? "TQ_HIGH" : "TQ_MEDIUM", volumetricLighting: false,
                        localReflections: false, ssgi: false, cinematicEffectsOff: false, retina: true,
                        frameRateCap: 120)
        case .t4:
            // Max/Ultra: High preset at native Retina.
            TierQuality(shadows: "SQ_HIGH", geometry: "GD_HIGH", gpuParticles: "GPQ_HIGH", particleSystems: nil,
                        textures: "TQ_HIGH", volumetricLighting: true, localReflections: true, ssgi: true,
                        cinematicEffectsOff: false, retina: true, frameRateCap: 120)
        }
    }
}

/// Session-time frame cap: the preset's cap, lowered when the Mac should run cool.
public enum FramePacing {
    /// The "cool" cap: an even divisor of 60 Hz, so pacing stays smooth on non-ProMotion panels.
    public static let coolCap = 30

    public static func frameRateCap(preset: GraphicsPreset, hardware: HardwareProfile) -> Int {
        let runCool = hardware.lowPowerMode
            || hardware.thermalState >= .serious
            || (preset.tier == .t1 && hardware.powerSource == .battery)
        return runCool ? min(preset.frameRateCap, coolCap) : preset.frameRateCap
    }
}
