import Foundation
import WarzagCore

/// Which of the account's names the card shows. The default is the profile name other players see: the sign-in name is
/// half of the player's sign-in details and would end up on screen and in screenshots.
public enum SteamDisplayName: Sendable {
    /// PersonaName.
    case profileName
    /// AccountName.
    case signInName
}

/// The account signed in to Steam, for the Home card: a display name and Steam's cached picture, read only while
/// Steam is signed in (`SteamDetector.account(for:)`).
///
/// Personal data, held in memory only: not Codable; `description`, `debugDescription` and the mirror print
/// `<redacted>`; the SteamID64, and with it the picture's file name, is package-internal. It never becomes part of
/// `SteamStatus`, Warzag.log, diagnostics, window titles or notifications.
public struct SteamAccount: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    /// The name cleaned for one line (`clean`); nil when Steam keeps no entry for the account, or nothing is left.
    public let displayName: String?
    package let steamID64: UInt64
    /// config/avatarcache/<SteamID64>.png.
    package let avatarFile: URL
    private let fileSystem: any FileSystem

    package init(displayName: String?, steamID64: UInt64, avatarFile: URL, fileSystem: any FileSystem) {
        self.displayName = displayName
        self.steamID64 = steamID64
        self.avatarFile = avatarFile
        self.fileSystem = fileSystem
    }

    /// Steam's cached picture is 184 x 184 pixels, a few tens of KB; anything over this is not it.
    public static let avatarByteLimit = 2 * 1024 * 1024
    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// Steam's cached picture as PNG data: nil when it is missing, over 2 MB or not a PNG (the card then shows the
    /// generic picture). Read when asked, never kept by SteamHostKit.
    public func avatarPNG() -> Data? {
        guard let size = try? fileSystem.attributes(of: avatarFile).size, size <= UInt64(Self.avatarByteLimit),
              let data = try? fileSystem.read(avatarFile, offset: 0, maxLength: Self.avatarByteLimit + 1),
              data.count <= Self.avatarByteLimit, data.starts(with: Self.pngSignature) else { return nil }
        return data
    }

    /// SteamID64 of the individual account `[U:1:N]`.
    package static func steamID64(accountID: UInt32) -> UInt64 {
        76_561_197_960_265_728 + UInt64(accountID)
    }

    public static func == (lhs: SteamAccount, rhs: SteamAccount) -> Bool {
        lhs.displayName == rhs.displayName && lhs.steamID64 == rhs.steamID64 && lhs.avatarFile == rhs.avatarFile
    }

    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }

    // MARK: The name cleaner

    /// Longest name kept (Steam allows 32 characters); the card cuts what does not fit at the end itself.
    public static let longestName = 64

    /// A name fit for one line: control characters removed (line breaks and tabs become a space), bidirectional
    /// overrides and isolates (U+202A–U+202E, U+2066–U+2069) removed, as are line and paragraph separators; runs of
    /// spaces become one, the ends are trimmed and at most `longestName` characters kept. Nil when nothing is left.
    public static func clean(_ name: String) -> String? {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in name.unicodeScalars {
            let value = scalar.value
            if (0x202A...0x202E).contains(value) || (0x2066...0x2069).contains(value) { continue }
            let separates = [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029].contains(value)
                || (scalar.properties.isWhitespace && scalar.properties.generalCategory != .control)
            if separates {
                pendingSpace = !scalars.isEmpty
                continue
            }
            if scalar.properties.generalCategory == .control { continue }
            if pendingSpace {
                scalars.append(" ")
                pendingSpace = false
            }
            scalars.append(scalar)
        }
        let cleaned = String(String(scalars).prefix(longestName)).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
    }
}
