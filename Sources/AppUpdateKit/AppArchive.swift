import Foundation
import WarzagCore

/// Unpacks an update archive into an empty folder.
public protocol AppArchiveExtracting: Sendable {
    func extract(_ archive: URL, into destination: URL) async throws
}

public struct AppArchiveError: Error, Equatable, CustomStringConvertible {
    public var reason: String
    /// The disk (or the user's quota) ran out while unpacking: the archive is not at fault.
    public var isOutOfSpace: Bool

    public init(reason: String, isOutOfSpace: Bool = false) {
        self.reason = reason
        self.isOutOfSpace = isOutOfSpace
    }

    public var description: String { "could not unpack the update: \(reason)" }
}

/// Update archives are what `ditto -c -k --norsrc --noextattr --noacl --keepParent Warzag.app` writes
/// (`App/make-app.sh --dmg`): a zip with Warzag.app at its root and no attribute of the builder's copy (quarantine,
/// Finder info). `ditto -x -k --noqtn` unpacks it without the archive's own quarantine, and without `--norsrc`, so the
/// signature check refuses a stray AppleDouble entry for what it is rather than as a `._` file.
public struct DittoArchiveExtractor: AppArchiveExtracting {
    public let runner: any ProcessRunning

    public init(runner: any ProcessRunning) {
        self.runner = runner
    }

    public func extract(_ archive: URL, into destination: URL) async throws {
        let result = try await runner.run(Command("/usr/bin/ditto", ["-x", "-k", "--noqtn", archive.plainPath,
                                                                    destination.plainPath], timeout: .seconds(300)))
        guard result.succeeded else {
            let reason = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            // ditto exits 1 whatever went wrong; only its message (strerror's) tells a full disk from a bad archive.
            throw AppArchiveError(reason: reason, isOutOfSpace: [ENOSPC, EDQUOT].contains {
                reason.contains(String(cString: strerror($0)))
            })
        }
    }
}
