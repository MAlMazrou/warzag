import Foundation
import Testing
import WarzagCore
import WarzagTestSupport
@testable import ProfileKit

/// An EE.cfg as Warframe leaves it once the player has changed display settings: Windows line endings, mostly key
/// bindings, and the config section the game mirrors the display settings into. A real one also holds Client.Email;
/// this one holds nothing personal.
func warframeEEConfig(motionBlur: String?, lineEnding: String = "\r\n") -> String {
    var lines = ["+nowarning", "+version=5", "[KeyBindings,/EE/Types/Input/KeyBindings]", "+nowarning",
                 "[LotusWindows_KeyBindings,/Lotus/Types/Input/KeyBindings]", "+nowarning"]
    lines += ["_Ability1=,1", "_Ability2=,2", "_Ability3=,3", "_Ability4=,4", "_Crouch=,LeftControl", "_Fire=,Mouse1",
              "_Jump=,Space", "_Melee=,E", "_Reload=,R", "_UseSpecial=,X"]
    lines += (1...300).map { "_Binding\($0)=,Key\($0 % 26)" }
    lines += [EEConfigSeed.section, "+nowarning", "Audio.MasterVolume=0.8", "Graphics.AutoDetectGraphicsSettings=0",
              "Graphics.EnableDOF=0"]
    if let motionBlur { lines.append("Graphics.EnableMotionBlur=\(motionBlur)") }
    lines += ["Graphics.ShadowQuality=SQ_LOW", "Graphics.UpscaleMethod=UM_FSR3", "Graphics.UpscaleQuality=UQ_BALANCED",
              "Graphics.VSyncMode=VSM_ALWAYS_SYNC", "Graphics.WindowMode=MODE_BORDERLESS"]
    return lines.joined(separator: lineEnding) + lineEnding
}

@Suite struct EEConfigReaderTests {
    let fileSystem = InMemoryFileSystem()
    let eeConfig = URL(filePath: "/prefix/drive_c/users/tenno/AppData/Local/Warframe/EE.cfg")

    @Test func motionBlurAsThePlayerLastChoseIt() {
        #expect(EEConfigReader.motionBlur(in: warframeEEConfig(motionBlur: "1")) == .on)
        #expect(EEConfigReader.motionBlur(in: warframeEEConfig(motionBlur: "0")) == .off)
        // Never changed in the game, and not in Warzag's seed: the per-account settings decide, unseen.
        #expect(EEConfigReader.motionBlur(in: warframeEEConfig(motionBlur: nil)) == .unknown)
        #expect(EEConfigReader.motionBlur(in: warframeEEConfig(motionBlur: "maybe")) == .unknown)
        #expect(EEConfigReader.motionBlur(in: "") == .unknown)
    }

    @Test func unixLineEndingsSpacesAndAByteOrderMarkAreFine() {
        #expect(EEConfigReader.motionBlur(in: warframeEEConfig(motionBlur: "1", lineEnding: "\n")) == .on)
        #expect(EEConfigReader.motionBlur(in: "\u{FEFF}\(EEConfigSeed.section)\r\n Graphics.EnableMotionBlur = 1 \r\n")
            == .on)
        // The last line wins, as when the game appends a changed value.
        #expect(EEConfigReader.motionBlur(in: warframeEEConfig(motionBlur: "1") + "Graphics.EnableMotionBlur=0\r\n")
            == .off)
    }

    @Test func onlyTheConfigSectionCounts() {
        let elsewhere = ["+nowarning", "[LotusWindows_KeyBindings,/Lotus/Types/Input/KeyBindings]",
                         "Graphics.EnableMotionBlur=1", EEConfigSeed.section, "Graphics.ShadowQuality=SQ_LOW",
                         "[Another_Config,/EE/Types/Base/Config]", "Graphics.EnableMotionBlur=1"]
        #expect(EEConfigReader.motionBlur(in: elsewhere.joined(separator: "\r\n")) == .unknown)
    }

    @Test func theFileIsReadNeverWritten() throws {
        #expect(EEConfigReader.motionBlur(at: eeConfig, fileSystem: fileSystem) == .unknown)
        let text = warframeEEConfig(motionBlur: "1")
        fileSystem.addFile(eeConfig.plainPath, text)
        #expect(EEConfigReader.motionBlur(at: eeConfig, fileSystem: fileSystem) == .on)
        #expect(fileSystem.text(at: eeConfig.plainPath) == text)
    }

    @Test(arguments: [
        mac("Apple M2", "Mac14,15", gpu: 10, memory: 24),
        mac("Apple M1", "MacBookAir10,1", gpu: 7, memory: 8),
        mac("Apple M4", "Mac16,10", gpu: 10, memory: 16),
        mac("Apple M3 Pro", "Mac15,6", gpu: 18, memory: 18),
        mac("Apple M4 Max", "Mac16,5", gpu: 40, memory: 48),
    ])
    func aSeededEECfgHasMotionBlurOff(_ hardware: HardwareProfile) throws {
        let preset = PresetCatalog.preset(for: hardware)
        #expect(try EEConfigSeed.seedIfAbsent(at: eeConfig, preset: preset, fileSystem: fileSystem))
        #expect(EEConfigReader.motionBlur(at: eeConfig, fileSystem: fileSystem) == .off)
    }
}
