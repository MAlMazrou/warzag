import Foundation
import WarzagCore

/// One saved account of loginusers.vdf, limited to an allowlist of keys: never the PIN keys (Algorithm, Hash, Salt),
/// and AccountName (the sign-in name) only when asked for. Package-internal, with a redacted description and mirror;
/// what leaves SteamHostKit is a `SteamAccount` (redacted) or `SteamLoginHints` (a boolean).
package struct LoginUser: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    package var steamID64: UInt64
    /// PersonaName: the profile name other players see.
    package var personaName: String?
    /// AccountName, only when `LoginUsers.read(includeAccountName: true)`.
    package var accountName: String?
    package var rememberPassword: Bool
    /// nil: the block has no AutoLogin key (the older MostRecent shape).
    package var autoLogin: Bool?

    package var description: String { "<redacted>" }
    package var debugDescription: String { "<redacted>" }
    package var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// What Steam's saved accounts say about signing in, as a boolean only (no value leaves the reader).
public struct SteamLoginHints: Equatable, Sendable, Codable {
    /// Steam can probably sign in by itself: registry.vdf's AutoLoginUser is set and loginusers.vdf has an account with
    /// RememberPassword = 1 (and AutoLogin = 1 when the file uses AutoLogin at all). Only Steam's own logs say whether
    /// it worked; the keys' meaning is inferred.
    public var quietSignInLikely: Bool

    public init(quietSignInLikely: Bool) {
        self.quietSignInLikely = quietSignInLikely
    }

    public static let none = SteamLoginHints(quietSignInLikely: false)
}

/// The allowlisted reader of ~/Library/Application Support/Steam/config/loginusers.vdf, on top of `VDF.parse`:
///
///     "users" { "<SteamID64>" { "AccountName" "…" "PersonaName" "…" "RememberPassword" "1" "AutoLogin" "1" … } }
///
/// The file is at most 64 KB (a few saved accounts are about 1 KB); a larger one, or one that is not KeyValues (being
/// rewritten), gives nil.
package enum LoginUsers {
    package static let byteLimit = 64 * 1024

    package static func read(_ url: URL, fileSystem: any FileSystem, includeAccountName: Bool = false) -> [LoginUser]? {
        guard let size = try? fileSystem.attributes(of: url).size, size <= UInt64(byteLimit),
              let data = try? fileSystem.read(url, offset: 0, maxLength: byteLimit + 1), data.count <= byteLimit,
              let root = try? VDF.parse(data), let users = root["users"]?.objectValue else { return nil }
        return users.entries.compactMap { entry in
            guard let block = entry.value.objectValue, let steamID64 = UInt64(entry.key) else { return nil }
            func flag(_ key: String) -> Bool? { block[key]?.stringValue.map { $0.trimmingCharacters(in: .whitespaces) == "1" } }
            return LoginUser(
                steamID64: steamID64,
                personaName: block["PersonaName"]?.stringValue,
                accountName: includeAccountName ? block["AccountName"]?.stringValue : nil,
                rememberPassword: flag("RememberPassword") ?? false,
                autoLogin: flag("AutoLogin"))
        }
    }

    /// Saved sign-in is likely when AutoLoginUser is set and an account has RememberPassword = 1, and also
    /// AutoLogin = 1 when any account has an AutoLogin key.
    package static func hints(users: [LoginUser]?, autoLoginUserSet: Bool) -> SteamLoginHints {
        let users = users ?? []
        let usesAutoLogin = users.contains { $0.autoLogin != nil }
        let remembered = users.contains { $0.rememberPassword && (!usesAutoLogin || $0.autoLogin == true) }
        return SteamLoginHints(quietSignInLikely: autoLoginUserSet && remembered)
    }
}
