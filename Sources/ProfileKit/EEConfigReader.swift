import Foundation
import WarzagCore

/// Warframe's motion blur as the player's EE.cfg last recorded it.
public enum MotionBlurSetting: String, Codable, Sendable {
    case on
    case off
    /// No EE.cfg, no `Graphics.EnableMotionBlur` line in its config section, or a value Warzag does not know.
    case unknown
}

/// Reads one display setting from the player's EE.cfg, and nothing else.
///
/// Warframe applies its per-account settings file at startup over EE.cfg, and mirrors the display settings into EE.cfg's
/// `[Windows_Config,/EE/Types/Base/Config]` section when the player changes them, so EE.cfg says what the player last
/// chose. The per-account file is game data Warzag never reads or writes, and so is EE.cfg apart from its one-time seed
/// (`EEConfigSeed.seedIfAbsent`): this reader never writes. EE.cfg can hold the player's email (Client.Email), so the
/// reader keeps only the value it looks for and logs nothing.
public enum EEConfigReader {
    public static let motionBlurKey = "Graphics.EnableMotionBlur"
    /// EE.cfg is mostly key bindings, a few hundred kilobytes at most; anything past this is not read.
    static let readLimit = 4 << 20

    /// `Graphics.EnableMotionBlur` in the config section (Windows line endings, as Warframe writes them, or Unix).
    public static func motionBlur(in text: String) -> MotionBlurSetting {
        switch value(of: motionBlurKey, in: text) {
        case "1": .on
        case "0": .off
        default: .unknown
        }
    }

    /// The same for the file at `url`; no file, or one that cannot be read, is `.unknown`.
    public static func motionBlur(at url: URL, fileSystem: any FileSystem) -> MotionBlurSetting {
        guard let data = try? fileSystem.read(url, offset: 0, maxLength: readLimit) else { return .unknown }
        return motionBlur(in: String(decoding: data, as: UTF8.self))
    }

    /// The last value `key` has in the config section, trimmed; nil when the section does not set it.
    static func value(of key: String, in text: String) -> String? {
        var inSection = false
        var found: String?
        // "\r\n" is one Character in Swift, and a newline.
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: CharacterSet.whitespaces.union(["\u{FEFF}"]))
            if line.hasPrefix("[") {
                inSection = line.caseInsensitiveCompare(EEConfigSeed.section) == .orderedSame
                continue
            }
            guard inSection, let equals = line.firstIndex(of: "=") else { continue }
            if line[..<equals].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(key) == .orderedSame {
                found = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return found
    }
}
