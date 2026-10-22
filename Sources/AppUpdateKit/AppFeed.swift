import Foundation
import RuntimeKit

/// Where Warzag looks for a newer Warzag: the URL of the newest signed app manifest, written into the app's Info.plist
/// by `App/make-app.sh --update-url` (docs/RELEASING.md). A build without it has nothing to check.
public enum AppFeed {
    public static let infoPlistKey = "WarzagAppManifestURL"

    /// Debug builds (SwiftPM defines DEBUG for `swift build` and `swift test`) also take plain http on this Mac's
    /// loopback address, for a local test feed; release builds never do.
    public static let allowsLoopbackHTTP: Bool = {
        #if DEBUG
            return true
        #else
            return false
        #endif
    }()

    /// The feed `text` names: an https URL with a host (or, with `allowsLoopbackHTTP`, http on the loopback address);
    /// anything else counts as no feed.
    public static func url(_ text: String?, allowsLoopbackHTTP: Bool = allowsLoopbackHTTP) -> URL? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let url = URL(string: text),
              AppManifestVerifier.isAllowed(url, context: AppManifestContext(
                  now: .distantPast, lastAcceptedSerial: nil, allowsLoopbackHTTP: allowsLoopbackHTTP)) else {
            return nil
        }
        return url
    }

    /// The feed an Info.plist names.
    public static func url(in info: [String: Any]?, allowsLoopbackHTTP: Bool = allowsLoopbackHTTP) -> URL? {
        url(info?[infoPlistKey] as? String, allowsLoopbackHTTP: allowsLoopbackHTTP)
    }
}
