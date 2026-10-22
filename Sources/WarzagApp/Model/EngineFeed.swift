import AppUpdateKit
import EngineKit
import Foundation
import RuntimeKit
import WarzagCore

/// Where the app gets its engine: the URL of the signed runtime manifest the release page serves, written into the
/// app's Info.plist by `App/make-app.sh --feed-url`. A build without it uses a development engine or one installed with
/// `warzagctl runtime install`.
enum RuntimeFeedSource {
    static let infoPlistKey = "WarzagRuntimeManifestURL"

    /// The feed named in `info`, if it is an https URL with a host (`AppFeed`'s check); anything else is no feed.
    static func url(in info: [String: Any]?) -> URL? {
        AppFeed.url(info?[infoPlistKey] as? String, allowsLoopbackHTTP: false)
    }
}

/// A feed step was asked of a build without a feed.
struct NoRuntimeFeed: Error, CustomStringConvertible {
    var description: String { "this build has no runtime feed (App/make-app.sh --feed-url)" }
}

/// What the player reads when a feed step fails (one sentence; the detail goes to Warzag.log), and whether setup
/// retries by itself.
enum EngineFeedFailure {
    static func failure(for error: any Error) -> SetupFailure {
        switch error {
        case let error as RuntimeServiceError:
            switch error {
            case .manifestRejected(let rejection):
                switch rejection {
                case .requiresNewerApp:
                    return SetupFailure(.permanent, L10n.failureEngineNeedsNewerApp)
                case .requiresNewerMacOS(let version):
                    return SetupFailure(.permanent, L10n.failureEngineNeedsMacOS(version))
                case .expired:
                    // The release page publishes a fresh manifest; until then there is nothing safe to install.
                    return SetupFailure(.transient, L10n.failureEngineFeed)
                default:
                    return SetupFailure(.permanent, L10n.failureEngineRejected)
                }
            case .insecureFeed, .invalidSigner, .invalidPublicKey:
                return SetupFailure(.permanent, L10n.failureEngineRejected)
            default:
                return SetupFailure(.transient, L10n.failureEngineInstall)
            }
        case let error as RuntimeInstallError:
            switch error {
            case .blocked: return SetupFailure(.permanent, L10n.failureEnginePaused)
            case .signerMismatch, .channelMismatch: return SetupFailure(.permanent, L10n.failureEngineRejected)
            case .rolledBack: return SetupFailure(.permanent, L10n.failureEngineInstall)
            }
        case is DigestMismatch, is SizeMismatch:
            // The downloader deleted the file: the next try downloads it again.
            return SetupFailure(.transient, L10n.failureEngineDamaged)
        case is URLError, is HTTPError, is DownloadError:
            return SetupFailure(.transient, L10n.failureEngineDownload)
        default:
            return SetupFailure(.transient, L10n.failureEngineInstall)
        }
    }
}
