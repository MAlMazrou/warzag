import Foundation

/// Why a step of Warzag's own update failed. The app maps each case to its `AppUpdateError` (one sentence for the
/// player, `description` for Warzag.log); warzagctl prints `description`.
public enum AppUpdateFailure: Error, Equatable, Sendable, CustomStringConvertible {
    /// This build names no app feed (App/make-app.sh --update-url).
    case notConfigured
    /// The feed or the archive could not be reached or read (network, HTTP status, a manifest that expired before the
    /// release page re-signed it), or there is not enough free disk space for it ("not enough free disk space: ..."):
    /// worth trying again later.
    case unreachable(String)
    /// The feed or the archive failed a check (signature, kind, serial, version, digest, bundle identity, code
    /// signature): nothing was installed.
    case rejected(String)
    /// The new Warzag needs a newer macOS than this Mac runs.
    case requiresNewerMacOS(String)
    /// Warzag cannot replace itself where it is (outside an Applications folder, App Translocation, a read-only
    /// volume, a folder this user may not change, macOS refused the change, the helper's swap failed once Warzag had
    /// quit). The checked copy stays in `WarzagPaths.appUpdates/staging` for the player to drag into Applications.
    case cannotReplace(String)
    /// Warframe or DE's launcher runs from an engine copy: updates wait until it has closed.
    case gameRunning

    public var description: String {
        switch self {
        case .notConfigured: "this build has no update feed"
        case .unreachable(let detail): "the update feed could not be reached: \(detail)"
        case .rejected(let detail): "the update was rejected: \(detail)"
        case .requiresNewerMacOS(let version): "the update needs macOS \(version) or later"
        case .cannotReplace(let detail): "Warzag could not replace itself: \(detail)"
        case .gameRunning: "Warframe is running"
        }
    }
}
