import Foundation
import WarzagCore

/// Unpacks a runtime pack into an empty directory.
public protocol PackExtracting: Sendable {
    func extract(_ pack: URL, into destination: URL) async throws
}

public struct PackExtractionError: Error, Equatable, CustomStringConvertible {
    public var reason: String
    public var description: String { "could not unpack the runtime: \(reason)" }
}

/// Runtime packs are Apple Archives (`.aar`), unpacked with the system `aa` tool. A pack holds the host bundle at its
/// top level (`Warzag.app/Contents/...`), as `aa archive -D <dir>/Warzag.app -o <id>.aar` writes it, so the installer
/// finds `<staging>/Warzag.app`. Code signatures survive the round trip (EngineKit's integration test).
public struct AppleArchiveExtractor: PackExtracting {
    public let runner: any ProcessRunning

    public init(runner: any ProcessRunning) {
        self.runner = runner
    }

    public func extract(_ pack: URL, into destination: URL) async throws {
        let result = try await runner.run(
            Command("/usr/bin/aa", ["extract", "-i", pack.plainPath, "-d", destination.plainPath]))
        guard result.succeeded else { throw PackExtractionError(reason: result.standardError) }
    }
}

public enum RuntimeInstallError: Error, Equatable, CustomStringConvertible {
    case blocked(String?)
    case signerMismatch(expected: String, actual: String?)
    /// This Mac rolled the runtime back after it failed; it is only installed again on request.
    case rolledBack(String)
    /// The unpacked host is not of the manifest's channel (or says nothing usable).
    case channelMismatch(expected: RuntimeChannel, actual: String)

    public var description: String {
        switch self {
        case .blocked(let message): "runtime installs are paused" + (message.map { ": \($0)" } ?? "")
        case .signerMismatch(let expected, let actual): "runtime signed by \(actual ?? "nobody"), expected \(expected)"
        case .rolledBack(let id): "runtime \(id) was rolled back on this Mac"
        case .channelMismatch(let expected, let actual):
            "the pack is for channel \(expected.rawValue) but holds \(actual)"
        }
    }
}

/// Download -> size and SHA-256 -> unpack -> signer fingerprint -> channel -> atomic activation, for a manifest that
/// `ManifestVerifier` already accepted. A pack already downloaded intact is not fetched again.
///
/// `install` does it all at once; `stage` (everything up to a verified, unpacked host) and `activate` (the switch)
/// split it for setup's separate verify and install steps.
public struct RuntimeInstaller: Sendable {
    public let store: RuntimeStore
    public let http: any HTTPClient
    public let extractor: any PackExtracting
    public let signatures: any CodeSignatureInspecting
    /// Where packs are downloaded, e.g. ~/Library/Caches/Warzag/runtime (`WarzagPaths.runtimeDownloads`). The unpacked
    /// host is staged inside the store instead (`stagedHost(for:)`), out of Spotlight like every engine copy.
    public let workDirectory: URL

    public init(store: RuntimeStore, http: any HTTPClient, extractor: any PackExtracting,
                signatures: any CodeSignatureInspecting, workDirectory: URL) {
        self.store = store
        self.http = http
        self.extractor = extractor
        self.signatures = signatures
        self.workDirectory = workDirectory
    }

    private var fileSystem: any FileSystem { store.fileSystem }

    /// Where a pack is kept while it is installed (and found again, intact, instead of being downloaded).
    public func packFile(for manifest: RuntimeManifest) -> URL {
        workDirectory.appending(path: "\(manifest.id).aar")
    }

    /// Where `stage` leaves the unpacked, verified host for `activate`: `Runtimes.noindex/staging/<id>/Warzag.app`
    /// (`WarzagPaths.runtimeStaging`), next to the store, so activation is a rename on the same volume.
    public func stagedHost(for manifest: RuntimeManifest) -> URL {
        store.paths.runtimeStaging.appending(path: manifest.id, directoryHint: .isDirectory)
            .appending(path: WarzagPaths.gameHostName, directoryHint: .isDirectory)
    }

    /// `allowRolledBack` is for an explicit reinstall the user asked for. Without it, a runtime this Mac rolled back
    /// is refused: the manifest keeps offering it, and installing it again would undo the rollback on every fetch.
    @discardableResult
    public func install(_ manifest: RuntimeManifest, allowRolledBack: Bool = false) async throws -> RuntimeStoreState {
        let host = try await stage(manifest, allowRolledBack: allowRolledBack)
        // Verified a moment ago in this call: nothing could have changed it in between.
        return try place(host, for: manifest)
    }

    /// Everything before the switch: the pack (downloaded unless an intact copy is at `packFile(for:)`), its size and
    /// SHA-256, unpacking, the host's code signature by the manifest's signer and its channel. Returns the verified
    /// host at `stagedHost(for:)`; a failure leaves no staging directory behind. Earlier installs' leftovers in the
    /// staging folder go first (`RuntimeStore.pruneStaging`).
    @discardableResult
    public func stage(_ manifest: RuntimeManifest, allowRolledBack: Bool = false) async throws -> URL {
        try checkInstallable(manifest, allowRolledBack: allowRolledBack)
        let pack = packFile(for: manifest)
        if (try? FileDigest.verify(pack, sha256: manifest.sha256, size: manifest.size, fileSystem: fileSystem)) == nil {
            try await http.download(from: manifest.url, to: pack)
            do {
                try FileDigest.verify(pack, sha256: manifest.sha256, size: manifest.size, fileSystem: fileSystem)
            } catch {
                try? fileSystem.removeItem(at: pack)
                throw error
            }
        }

        let host = stagedHost(for: manifest)
        let staging = host.deletingLastPathComponent()
        store.pruneStaging(keeping: manifest.id)
        try? fileSystem.removeItem(at: staging)
        try fileSystem.createDirectory(at: staging)
        do {
            try await extractor.extract(pack, into: staging)
            try verifyStaged(host, for: manifest)
            return host
        } catch {
            try? fileSystem.removeItem(at: staging)
            throw error
        }
    }

    /// Makes the host `stage` left current (the one it replaces becomes the previous runtime), after checking it
    /// again: a crash between the two steps can leave a half-unpacked tree, which must never become the engine.
    /// Removes the staging directory and the pack.
    @discardableResult
    public func activate(_ manifest: RuntimeManifest, allowRolledBack: Bool = false) throws -> RuntimeStoreState {
        try checkInstallable(manifest, allowRolledBack: allowRolledBack)
        let host = stagedHost(for: manifest)
        do {
            try verifyStaged(host, for: manifest)
        } catch {
            try? fileSystem.removeItem(at: host.deletingLastPathComponent())
            throw error
        }
        return try place(host, for: manifest)
    }

    /// Whether `manifest`'s runtime may be installed on this Mac at all: not paused (kill switch `blockInstall`), a
    /// safe id, and not one this Mac rolled back (unless `allowRolledBack`). `stage` and `activate` check it again; a
    /// caller that fetches the pack first checks it before the download, so a refused runtime costs no bytes.
    public func checkInstallable(_ manifest: RuntimeManifest, allowRolledBack: Bool = false) throws {
        guard manifest.killSwitch.level != .blockInstall else {
            throw RuntimeInstallError.blocked(manifest.killSwitch.message)
        }
        guard isSafePathComponent(manifest.id) else { throw RuntimeStoreError.invalidName(manifest.id) }
        if !allowRolledBack, try store.load().rolledBack.contains(manifest.id) {
            throw RuntimeInstallError.rolledBack(manifest.id)
        }
    }

    /// The unpacked host is there, signed by the manifest's signer, and of the manifest's channel.
    private func verifyStaged(_ host: URL, for manifest: RuntimeManifest) throws {
        guard fileSystem.directoryExists(at: host) else { throw RuntimeStoreError.stagedHostMissing }
        let signer = try signatures.signerFingerprint(of: host)
        guard signer == manifest.signerFingerprint.lowercased() else {
            throw RuntimeInstallError.signerMismatch(expected: manifest.signerFingerprint, actual: signer)
        }
        // Read only now that the signature (which seals Info.plist and the loader) is known to be the publisher's.
        do {
            _ = try RuntimeHostChannel.detect(bundle: host, fileSystem: fileSystem)
        } catch {
            throw RuntimeInstallError.channelMismatch(expected: manifest.channel, actual: error.description)
        }
    }

    private func place(_ host: URL, for manifest: RuntimeManifest) throws -> RuntimeStoreState {
        defer { try? fileSystem.removeItem(at: host.deletingLastPathComponent()) }
        let state = try store.install(stagedHost: host, for: manifest)
        try? fileSystem.removeItem(at: packFile(for: manifest))
        return state
    }
}
