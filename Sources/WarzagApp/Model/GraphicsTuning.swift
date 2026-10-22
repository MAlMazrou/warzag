import Foundation
import GameKit
import ProfileKit
import WarzagCore
import WineKit

/// What a graphics preset means for one session: a frame cap here, the upscaler in ProfileKit's `GraphicsChoice`.
///
/// Presets use the game's FSR 3, never DLSS, and DXMT's NVEXT stays off (`PresetCatalog.nvextDefault`). The cap is
/// DXMT's own limiter (`d3d11.preferredMaxFrameRate`), which `FramePacing` may lower to 30 fps. Quality caps T1 at
/// 30 fps: rendering every pixel cannot hold 60 fps on a fanless base chip, and 30 paces evenly on a 60 Hz panel.
///
/// The upscaler is Warframe's own per-account setting, applied at startup over EE.cfg. Warzag seeds it only in a new
/// EE.cfg; otherwise the app names the choice and the player sets it once in Options › Display › Upscaling.
enum GraphicsTuning {
    static func frameRateCap(_ choice: GraphicsChoice, tier: PerformanceTier) -> Int {
        let tierCap = tier >= .t3 ? 120 : 60
        switch choice {
        case .performance, .balanced: return tierCap
        case .quality: return tier == .t1 ? 30 : 60
        }
    }

    /// The one-time EE.cfg seed for a new profile: the tier preset with the chosen preset's upscaler.
    static func seedPreset(_ choice: GraphicsChoice, hardware: HardwareProfile) -> GraphicsPreset {
        PresetCatalog.preset(for: hardware, upscaling: choice.upscaling)
    }

    /// The cap the game gets now: the preset's, unless the Mac should run cool (`FramePacing`).
    static func sessionFrameRateCap(_ choice: GraphicsChoice, hardware: HardwareProfile) -> Int {
        var preset = PresetCatalog.preset(for: hardware)
        preset.frameRateCap = frameRateCap(choice, tier: hardware.tierClassification.tier)
        return FramePacing.frameRateCap(preset: preset, hardware: hardware)
    }

    /// The player's options for `GameLaunchBuilder`. No preset asks for NVEXT (`PresetCatalog.nvextDefault`).
    static func playOptions(steam: Bool, hud: Bool) -> PlayOptions {
        PlayOptions(steam: steam, hud: hud, renderer: .dxmt)
    }

    /// Replaces the frame cap `GameLaunchBuilder` derived from the tier with the preset's (DXMT_CONFIG for DXMT), since
    /// GameKit's `PlayOptions` has no frame-cap input.
    static func apply(_ choice: GraphicsChoice, hardware: HardwareProfile, to launch: GameLaunch) -> GameLaunch {
        var launch = launch
        let cap = sessionFrameRateCap(choice, hardware: hardware)
        launch.renderer.frameRateCap = cap
        switch launch.renderer.renderer {
        case .dxmt:
            if let config = launch.renderer.dxmtConfig.rendered {
                launch.environment["DXMT_CONFIG"] = config
            } else {
                launch.environment["DXMT_CONFIG"] = nil
            }
        case .wined3d:
            break
        }
        return launch
    }
}
