import Foundation

// MARK: - Warzag's own updates

/// The running Warzag's version, from its Info.plist.
struct AppVersion: Equatable, Sendable {
    /// CFBundleShortVersionString, for example "0.1.0": what the player reads.
    var version: String
    /// CFBundleVersion, for example "124": the build number, which orders releases.
    var build: String
}

extension AppVersion {
    /// From a bundle's Info.plist; "0" for a key it lacks (a test runner's bundle).
    init(bundle: Bundle) {
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}

/// A newer Warzag the release page offers: a signed app manifest that passed every check.
struct AppUpdateOffer: Equatable, Sendable {
    var version: String
    var build: String
    /// The download's size.
    var bytes: Int64
    /// The release's page (its notes), when the manifest names one.
    var releaseNotes: URL?
}

/// What a check for a newer Warzag found.
enum AppUpdateCheck: Equatable, Sendable {
    /// This build names no update feed (App/make-app.sh without `--update-url`): there is nothing to check.
    case notConfigured
    case upToDate
    case available(AppUpdateOffer)
}

/// Why a step of Warzag's own update failed. `description` goes to Warzag.log; the UI shows one sentence per case.
enum AppUpdateError: Error, Equatable, Sendable, CustomStringConvertible {
    /// This build names no update feed.
    case notConfigured
    /// The feed or the download could not be reached or read (network, HTTP status), or there is not enough free disk
    /// space for it (the detail starts "not enough free disk space"): worth trying again later.
    case unreachable(String)
    /// The feed or the download failed a check (signature, expiry, kind, version, digest, bundle identity, code
    /// signature): nothing was installed.
    case rejected(String)
    /// The offer needs a newer macOS than this Mac runs.
    case requiresNewerMacOS(String)
    /// Warzag cannot replace itself where it is (outside an Applications folder, a read-only volume, macOS refused
    /// the change): the player installs the downloaded copy by hand.
    case cannotReplace(String)
    /// Warframe or DE's launcher is running: updates wait until it has closed.
    case gameRunning

    var description: String {
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

/// Warzag's own updates: check the signed app feed, download and verify a newer Warzag, then replace the installed app
/// and reopen it. Every method throws `AppUpdateError` only.
protocol AppUpdateServicing: Sendable {
    /// The running Warzag's version.
    func currentVersion() -> AppVersion
    /// Fetches and verifies the app feed.
    func check() async throws -> AppUpdateCheck
    /// Downloads the offer and verifies it (size, digest, bundle identity, version, code signature with the pinned
    /// project certificate), staged where the installed app is not touched yet.
    func prepare(_ offer: AppUpdateOffer,
                 progress: @escaping @Sendable (_ received: Int64, _ total: Int64) -> Void) async throws
    /// Replaces the installed Warzag with the prepared one and arranges for the new one to open once this process
    /// has quit; the caller then quits.
    func installPreparedUpdate() async throws
    /// The checked new Warzag `prepare` left in Warzag's caches; nil when none is prepared. After `cannotReplace`, this
    /// is the copy the player drags into Applications.
    func preparedCopy() -> URL?
    /// Why the last install failed after the previous Warzag quit (the Warzag that opens then is the previous one, and
    /// learns it only here). Ask once at launch; nil when the install replaced Warzag, when there was none, or once
    /// reported. After `cannotReplace`, `installPreparedUpdate` throws it again for that build instead of quitting.
    func lastInstallResult() -> AppUpdateError?
    /// The running Warzag's CHANGELOG.md, which App/make-app.sh copies into Contents/Resources (What's New in Warzag);
    /// nil without one (`swift run`, tests).
    func changelog() -> String?
}

extension AppUpdateServicing {
    func preparedCopy() -> URL? { nil }
    func lastInstallResult() -> AppUpdateError? { nil }
    func changelog() -> String? { Self.bundledChangelog(in: .main) }

    /// The CHANGELOG.md in `bundle`'s Contents/Resources; nil without one.
    static func bundledChangelog(in bundle: Bundle) -> String? {
        guard let url = bundle.url(forResource: "CHANGELOG", withExtension: "md") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// A build without an update feed.
struct UnconfiguredAppUpdates: AppUpdateServicing {
    func currentVersion() -> AppVersion { AppVersion(bundle: .main) }
    func check() async throws -> AppUpdateCheck { .notConfigured }

    func prepare(_ offer: AppUpdateOffer,
                 progress: @escaping @Sendable (_ received: Int64, _ total: Int64) -> Void) async throws {
        throw AppUpdateError.notConfigured
    }

    func installPreparedUpdate() async throws { throw AppUpdateError.notConfigured }
}
