import AppUpdateKit
import Darwin
import EngineKit
import Foundation
import WarzagCore

/// Warzag's own updates: AppUpdateKit's `AppUpdater` on the signed app feed (Info.plist `WarzagAppManifestURL`,
/// `App/make-app.sh --update-url`), with the download and its checks in Warzag's caches. Once this Warzag has quit, the
/// new Warzag's executable swaps the app as the update helper (`UpdateHelper`, docs/RELEASING.md) and records the
/// outcome for the Warzag that opens next (`lastInstallResult`). Every step writes one line to Warzag.log.
struct LiveAppUpdateService: AppUpdateServicing {
    var updater: AppUpdater
    let log: AppLog
    /// The user's home, written as ~ in Warzag.log (a reason can name ~/Applications/Warzag.app).
    var home: URL = FileManager.default.homeDirectoryForCurrentUser

    /// The running app, the manifest keys and certificate this build pins (`RuntimeTrust.pinned`: release builds the
    /// release key only), Warzag's data in `paths`. `realHome` is the user's own (its Applications folder counts as
    /// one), whatever WARZAG_HOME says.
    static func make(feed: URL, paths: WarzagPaths, realHome: URL, log: AppLog,
                     bundle: Bundle = .main) -> LiveAppUpdateService {
        LiveAppUpdateService(
            updater: .live(installed: InstalledApp.read(bundle.bundleURL), feed: feed, trust: RuntimeTrust.pinned,
                           paths: paths, home: realHome),
            log: log, home: realHome)
    }

    /// A failure's line: its reason may name a path in the home folder.
    private func note(_ message: String) {
        log.write(AppendingLog(url: nil, home: home).redacted(message))
    }

    func currentVersion() -> AppVersion {
        AppVersion(version: updater.installed.version, build: updater.installed.build)
    }

    private var running: String { "Warzag \(updater.installed.version) (build \(updater.installed.build))" }

    func check() async throws -> AppUpdateCheck {
        do {
            switch try await updater.check() {
            case .notConfigured:
                return .notConfigured
            case .upToDate(let manifest):
                log.write("update: \(running) is up to date (the feed offers build \(manifest.build))")
                return .upToDate
            case .available(let manifest):
                log.write("update: Warzag \(manifest.version) (build \(manifest.build)) is available, "
                    + "\(manifest.size) bytes")
                return .available(AppUpdateOffer(version: manifest.version, build: manifest.build, bytes: manifest.size,
                                                 releaseNotes: manifest.releaseNotes))
            }
        } catch {
            note("update: checking for a newer Warzag failed: \(error)")
            throw AppUpdateError(error)
        }
    }

    func prepare(_ offer: AppUpdateOffer,
                 progress: @escaping @Sendable (_ received: Int64, _ total: Int64) -> Void) async throws {
        do {
            try await updater.prepare(build: offer.build, progress: progress)
            log.write("update: Warzag \(offer.version) (build \(offer.build)) downloaded and checked")
        } catch {
            note("update: preparing Warzag \(offer.version) (build \(offer.build)) failed: \(error)")
            throw AppUpdateError(error)
        }
    }

    func installPreparedUpdate() async throws {
        do {
            try await updater.install(.afterExit(pid: getpid()), log: log.url)
            log.write("update: the new Warzag's helper takes over once \(running) has quit")
        } catch {
            note("update: installing the new Warzag failed: \(error)")
            throw AppUpdateError(error)
        }
    }

    func preparedCopy() -> URL? {
        updater.prepared() == nil ? nil : updater.stagedApp
    }

    func lastInstallResult() -> AppUpdateError? {
        guard let failure = updater.takeSwapFailure() else { return nil }
        note("update: the last update did not replace \(running): \(failure)")
        return AppUpdateError(failure)
    }
}

extension AppUpdateError {
    /// The kit's reasons, case for case.
    init(_ failure: AppUpdateFailure) {
        switch failure {
        case .notConfigured: self = .notConfigured
        case .unreachable(let detail): self = .unreachable(detail)
        case .rejected(let detail): self = .rejected(detail)
        case .requiresNewerMacOS(let version): self = .requiresNewerMacOS(version)
        case .cannotReplace(let detail): self = .cannotReplace(detail)
        case .gameRunning: self = .gameRunning
        }
    }
}
