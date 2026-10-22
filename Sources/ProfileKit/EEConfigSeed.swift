import Foundation
import WarzagCore

/// The one-time EE.cfg seed: written only when the player has no EE.cfg yet, so it is equivalent to the player choosing
/// settings once. An existing EE.cfg is never touched. EE.cfg can hold the player's email (Client.Email), so the only
/// value Warzag reads back is the motion blur setting (`EEConfigReader`), and nothing from the file is ever logged.
public enum EEConfigSeed {
    public static let header = ["+nowarning", "+version=5"]
    public static let section = "[Windows_Config,/EE/Types/Base/Config]"

    /// EE.cfg text with Windows line endings.
    public static func render(_ settings: [EEConfigSetting]) -> String {
        let lines = header + [section] + settings.map { "\($0.key)=\($0.value)" }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Writes `preset`'s settings to `url` unless a file is already there. Returns whether it wrote.
    @discardableResult
    public static func seedIfAbsent(at url: URL, preset: GraphicsPreset, fileSystem: any FileSystem) throws -> Bool {
        try fileSystem.createExclusively(Data(render(preset.eeConfig).utf8), at: url)
    }
}
