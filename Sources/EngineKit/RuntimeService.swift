import CryptoKit
import Foundation
import RuntimeKit
import WarzagCore
import WineKit

public enum RuntimeServiceError: Error, Equatable, CustomStringConvertible {
    case noRuntime
    case runtimeMissing(id: String, path: String)
    case revoked(String)
    case notAGameHost(String)
    case brokenSignature(String)
    /// The host is signed, but not by the signer its runtime was installed with.
    case signerChanged(expected: String, actual: String)
    case manifestRejected(ManifestRejection)
    case unreadableManifest(String)
    case invalidPublicKey
    case invalidSigner(String)
    case packUnreadable(String)
    /// A runtime feed must be https.
    case insecureFeed(String)

    public var description: String {
        switch self {
        case .noRuntime:
            "no engine runtime is installed (warzagctl runtime install, or runtime use-local for a development build)"
        case .runtimeMissing(let id, let path): "the active runtime \(id) is no longer on disk (\(path))"
        case .revoked(let id): "the active runtime \(id) has been revoked and there is nothing to roll back to"
        case .notAGameHost(let reason): "not a Warzag runtime host: \(reason)"
        case .brokenSignature(let reason): "the runtime's code signature does not verify: \(reason)"
        case .signerChanged(let expected, let actual):
            "the runtime is now signed by \(actual.prefix(16)), not by \(expected.prefix(16)) as when it was installed"
        case .manifestRejected(let rejection): "runtime manifest rejected: \(rejection)"
        case .unreadableManifest(let reason): "cannot read the runtime manifest: \(reason)"
        case .invalidPublicKey: "the public key must be a base64-encoded 32-byte Ed25519 key"
        case .invalidSigner(let text): "\(text) is not a certificate SHA-256 (64 hex digits) or \"adhoc\""
        case .packUnreadable(let reason): "cannot read the runtime pack: \(reason)"
        case .insecureFeed(let url): "the runtime feed must be an https URL, not \(url)"
        }
    }
}

/// How a manifest names the code signer of an ad-hoc signed pack. Such a pack is accepted only where a trust policy
/// lists this value explicitly, and its SHA-256 is still pinned by the signed manifest.
public enum RuntimeSigner {
    public static let adHoc = "adhoc"
}

/// Reports ad-hoc signed code as `RuntimeSigner.adHoc` instead of nil, so a manifest can name it. A broken
/// signature still throws.
struct NamedSignerInspector: CodeSignatureInspecting {
    let base: any CodeSignatureInspecting

    func signerFingerprint(of bundle: URL) throws -> String? {
        try base.signerFingerprint(of: bundle) ?? RuntimeSigner.adHoc
    }
}

/// Where manifest-signing trust comes from (docs/RELEASING.md).
///
/// Key ids are `ManifestTrust.keyID(for:)`. A debug build also trusts the DEV key, so packs signed on a development
/// Mac install without `--pubkey`; a release build (`swift build -c release`, what App/make-app.sh ships) trusts the
/// release key only, so a leaked DEV key can never reach players.
public enum RuntimeTrust {
    /// The DEV manifest key (`~/.warzag/keys/dev.ed25519`, made with warzag-release keygen): debug builds only.
    public static let developmentKeyID = "7dd0f476eb9f3526"
    public static let developmentPublicKey = "HtLZSzJHXX3S8TAyni6db6qchBPDmZLUQPGeQTmSydI="
    /// The release manifest key (tools/sign/release-manifest.ed25519.pub); its private half,
    /// `~/.warzag/keys/release-manifest.ed25519`, signs every published runtime manifest.
    public static let releaseKeyID = "01053f82ada7e84d"
    public static let releasePublicKey = "NBJpoXbHmkxyEIoVpr6/LgV69tA6PdtTwxHwHEbAvy0="
    /// The project certificate "Warzag Community Code Signing" (tools/sign/project-certificate.sha256): the only
    /// signer of runtime packs and Warzag updates the app installs. Ad-hoc signed packs are never trusted by the pins.
    public static let projectCertificate = "f37b1c9d98f8ed9211e4dd599fc1ec7edf74677a2cf54ec9e5ba2756986239e1"

    /// What a release build trusts: the release key and the project certificate.
    public static let release = ManifestTrust(
        publicKeys: [releaseKeyID: Data(base64Encoded: releasePublicKey)!],
        signerFingerprints: [projectCertificate])

    /// What a debug build trusts: the release pins plus the DEV key.
    public static let development = ManifestTrust(
        publicKeys: [releaseKeyID: Data(base64Encoded: releasePublicKey)!,
                     developmentKeyID: Data(base64Encoded: developmentPublicKey)!],
        signerFingerprints: [projectCertificate])

    /// Whether this is a debug build (SwiftPM defines DEBUG for `swift build` and `swift test`, not for `-c release`).
    public static let isDebugBuild: Bool = {
        #if DEBUG
            return true
        #else
            return false
        #endif
    }()

    public static func pinned(debugBuild: Bool) -> ManifestTrust {
        debugBuild ? development : release
    }

    /// What this build pins at compile time.
    public static var pinned: ManifestTrust { pinned(debugBuild: isDebugBuild) }

    /// Development trust on top of `base`: more manifest keys (raw 32-byte Ed25519 public keys, each under its own key
    /// id) and more pack signers ("adhoc" or a certificate SHA-256). For `warzagctl runtime install --pubkey/--signer`
    /// and tests; the app itself uses `pinned`.
    public static func extending(_ base: ManifestTrust = RuntimeTrust.pinned, publicKeys: [Data] = [],
                                 signers: [String] = []) throws -> ManifestTrust {
        var keys = base.publicKeys
        for rawKey in publicKeys {
            guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey) else {
                throw RuntimeServiceError.invalidPublicKey
            }
            keys[ManifestTrust.keyID(for: key)] = rawKey
        }
        var fingerprints = base.signerFingerprints
        for signer in signers {
            let lowered = signer.lowercased()
            guard lowered == RuntimeSigner.adHoc || (lowered.count == 64 && lowered.allSatisfy(\.isHexDigit)) else {
                throw RuntimeServiceError.invalidSigner(signer)
            }
            fingerprints.insert(lowered)
        }
        return ManifestTrust(publicKeys: keys, signerFingerprints: fingerprints)
    }

    /// Trust for `warzagctl runtime install --pubkey`: exactly one Ed25519 key (under whatever key id the envelope
    /// names) plus the pinned trust, and the code signer the manifest names. The signer is read only after the
    /// signature over the payload has verified with that key, so the key holder vouches for it; the installer
    /// then still requires the unpacked host to be signed by exactly that signer.
    public static func explicitKey(_ rawKey: Data, for signedManifest: Data,
                                   pinned: ManifestTrust = RuntimeTrust.pinned) throws -> ManifestTrust {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey) else {
            throw RuntimeServiceError.invalidPublicKey
        }
        let envelope: SignedManifest
        do {
            envelope = try WarzagJSON.decoder().decode(SignedManifest.self, from: signedManifest)
        } catch {
            throw RuntimeServiceError.manifestRejected(.malformedEnvelope)
        }
        guard key.isValidSignature(envelope.signature, for: envelope.payload) else {
            throw RuntimeServiceError.manifestRejected(.badSignature)
        }
        let manifest: RuntimeManifest
        do {
            manifest = try WarzagJSON.decoder().decode(RuntimeManifest.self, from: envelope.payload)
        } catch {
            throw RuntimeServiceError.manifestRejected(.malformedManifest(String(describing: error)))
        }
        var keys = pinned.publicKeys
        keys[envelope.keyId] = rawKey
        return ManifestTrust(publicKeys: keys,
                             signerFingerprints: pinned.signerFingerprints.union([manifest.signerFingerprint]))
    }
}

/// Where the runtime pack comes from.
public enum PackSource: Sendable, Equatable {
    /// Download from the URL the manifest names.
    case manifestURL
    /// A pack already on this Mac.
    case file(URL)
    /// Another download location, e.g. a mirror.
    case url(URL)
}

/// A signed runtime manifest feed: the https URL the release page serves it at (the app's Info.plist key
/// `WarzagRuntimeManifestURL`) and what its manifests are checked against.
public struct RuntimeFeed: Sendable, Equatable {
    public var url: URL
    /// Checked against the manifest's `minLauncher` and `minMacOS`.
    public var appVersion: String
    public var macOSVersion: String

    public init(url: URL, appVersion: String, macOSVersion: String) {
        self.url = url
        self.appVersion = appVersion
        self.macOSVersion = macOSVersion
    }
}

/// The runtime the engine runs with: its record in Runtimes.noindex/active.json and its host bundle on disk.
public struct ActiveRuntime: Sendable, Equatable {
    public var runtime: InstalledRuntime
    public var host: GameHost

    public init(runtime: InstalledRuntime, host: GameHost) {
        self.runtime = runtime
        self.host = host
    }
}

/// `warzagctl runtime status`.
public struct RuntimeStatus: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var id: String
        public var version: String
        public var channel: RuntimeChannel
        /// Hex SHA-256 of the signing certificate, or "adhoc".
        public var signer: String
        public var activatedAt: Date?
        public var host: String
        public var onDisk: Bool
        /// Registered from a local build with `runtime use-local`.
        public var development: Bool
    }

    public var current: Entry?
    /// The previous runtime, kept for rollback.
    public var previous: Entry?
    /// The current runtime was revoked with nothing to roll back to: Play is blocked.
    public var currentRevoked: Bool
    public var lastSerial: UInt64?
    public var revoked: [String]
    public var rolledBack: [String]
}

/// Installs, activates and rolls back engine runtimes on top of RuntimeKit's store and installer.
///
/// - Packs: signed manifest (Ed25519, serial, expiry, revocations) -> pack (local file, mirror or the manifest's
///   URL) -> `RuntimeInstaller` (size and SHA-256, unpacking, code signature by the manifest's signer, atomic
///   activation, the previous runtime kept for rollback).
/// - Development: `useLocal` registers a local build (runtime/n/make-host.sh) as a new runtime version, a clone of the
///   bundle, so it can be rolled back like any other and later rebuilds of the build tree change nothing in it.
public struct RuntimeService: Sendable {
    /// Runtime ids of development builds start with "<channel>-dev-".
    public static let developmentMarker = RuntimeStore.developmentMarker

    public let engine: Engine

    public init(engine: Engine) {
        self.engine = engine
    }

    public var store: RuntimeStore {
        RuntimeStore(paths: engine.paths, fileSystem: engine.fileSystem, clock: engine.clock)
    }
    /// Downloaded packs and the feed's manifest; engine copies are staged inside the store instead
    /// (`WarzagPaths.runtimeStaging`).
    public var workDirectory: URL { engine.paths.runtimeDownloads }

    // MARK: Status

    public func status() throws -> RuntimeStatus {
        let state = try store.load()
        return RuntimeStatus(current: state.current.map(entry), previous: state.previous.map(entry),
                             currentRevoked: state.isCurrentRevoked, lastSerial: state.lastSerial,
                             revoked: state.revoked, rolledBack: state.rolledBack)
    }

    private func entry(_ runtime: InstalledRuntime) -> RuntimeStatus.Entry {
        let host = store.hostURL(for: runtime)
        return RuntimeStatus.Entry(
            id: runtime.id, version: runtime.version, channel: runtime.channel, signer: runtime.signerFingerprint,
            activatedAt: runtime.activatedAt, host: host.plainPath,
            onDisk: engine.fileSystem.directoryExists(at: host),
            development: runtime.id.hasPrefix(runtime.channel.rawValue + Self.developmentMarker))
    }

    /// The runtime to run Wine with: current, not revoked, and on disk.
    public func active() throws -> ActiveRuntime {
        let state = try store.load()
        guard let current = state.current else { throw RuntimeServiceError.noRuntime }
        guard !state.isCurrentRevoked else { throw RuntimeServiceError.revoked(current.id) }
        let host = store.hostURL(for: current)
        guard engine.fileSystem.directoryExists(at: host) else {
            throw RuntimeServiceError.runtimeMissing(id: current.id, path: host.plainPath)
        }
        return ActiveRuntime(runtime: current, host: GameHost(bundle: host, channel: current.channel))
    }

    /// Validates `host`'s code signature, nested code included (`SecurityCodeSignatureInspector.validationFlags`);
    /// with `expectedSigner`, it must also be that signer's ("adhoc" for ad-hoc signed development builds). Returns the
    /// signer.
    @discardableResult
    public func verifySignature(of host: GameHost, expectedSigner: String?) throws -> String {
        let signer: String
        do {
            signer = try NamedSignerInspector(base: engine.signatures).signerFingerprint(of: host.bundle)
                ?? RuntimeSigner.adHoc
        } catch {
            throw RuntimeServiceError.brokenSignature("\(error)")
        }
        if let expectedSigner, signer != expectedSigner.lowercased() {
            throw RuntimeServiceError.signerChanged(expected: expectedSigner.lowercased(), actual: signer)
        }
        return signer
    }

    // MARK: Development builds

    /// The channel a local host was built for (its loader's architecture and Info.plist), after checking that it is a
    /// Warzag runtime host.
    public func channel(ofLocalHost bundle: URL) throws -> RuntimeChannel {
        try GameHost.inspect(bundle: bundle, fileSystem: engine.fileSystem)
    }

    /// Registers a locally built host (development only): checks that it is a Warzag host, clones it into the store as
    /// `<channel>-dev-<UTC time>`, checks the clone's code signature (ad hoc is fine, broken is not) and makes it
    /// current, keeping the one it replaces as the previous runtime.
    @discardableResult
    public func useLocal(_ bundle: URL) throws -> RuntimeStoreState {
        let fileSystem = engine.fileSystem
        let channel = try channel(ofLocalHost: bundle)
        let host = GameHost(bundle: bundle, channel: channel)
        let info = try HostInfo.read(host, fileSystem: fileSystem)

        let stamp = Self.timestamp(engine.clock.now)
        let id = "\(channel.rawValue)\(Self.developmentMarker)\(stamp)"
        let baseVersion = (info.shortVersion ?? "0").filter { $0.isASCII && ($0.isNumber || $0 == ".") }
        let version = "\(baseVersion.isEmpty ? "0" : baseVersion)-dev.\(stamp)"

        // A store still in the old place moves (or refuses) before a clone is put next to it.
        _ = try store.load()
        // A feed pack staged for its activation is not wanted while a development build is the engine (activating it
        // later stages it again), nor is what a crash left.
        store.pruneStaging(keeping: id)
        let stagingRoot = engine.paths.runtimeStaging.appending(path: id, directoryHint: .isDirectory)
        try? fileSystem.removeItem(at: stagingRoot)
        defer { try? fileSystem.removeItem(at: stagingRoot) }
        let staged = stagingRoot.appending(path: WarzagPaths.gameHostName, directoryHint: .isDirectory)
        try fileSystem.copyItem(at: host.bundle, to: staged)
        // The copy is what gets activated, so that is what must verify.
        let signer: String
        do {
            signer = try NamedSignerInspector(base: engine.signatures).signerFingerprint(of: staged)
                ?? RuntimeSigner.adHoc
        } catch {
            throw RuntimeServiceError.brokenSignature("\(error) (re-run runtime/n/make-host.sh)")
        }
        let manifest = RuntimeManifest(
            serial: 0, expires: .distantFuture, id: id, version: version, channel: channel,
            arch: channel.architecture, minLauncher: "0.0", minMacOS: Platform.minimumMacOS.description,
            url: host.bundle, size: 0, sha256: "", signerFingerprint: signer)
        return try store.install(stagedHost: staged, for: manifest)
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    // MARK: Packs

    /// Verifies a signed manifest, records it (serial floor, revocations), then installs and activates its pack.
    /// `allowRolledBack` reinstalls a runtime this Mac rolled back (an explicit user request). A pack from the network
    /// is downloaded with `Engine.packDownloader` (resumable; `progress` sees its bytes). A paused runtime (kill switch
    /// `blockInstall`), or one this Mac rolled back, is refused before its pack is fetched or copied.
    @discardableResult
    public func install(signedManifest: Data, pack: PackSource = .manifestURL, trust: ManifestTrust,
                        appVersion: String, macOSVersion: String, allowRolledBack: Bool = false,
                        progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }) async throws
        -> RuntimeStoreState {
        let fileSystem = engine.fileSystem
        let manifest = try verified(signedManifest, trust: trust, appVersion: appVersion, macOSVersion: macOSVersion)
        try store.accept(manifest)
        try installer.checkInstallable(manifest, allowRolledBack: allowRolledBack)

        // RuntimeInstaller reuses an intact pack at <work>/<id>.aar instead of downloading; an explicit pack is put
        // there only after it has proven to be exactly the published file.
        let packPath = packFile(for: manifest)
        switch pack {
        case .manifestURL:
            try await downloadPack(for: manifest, allowRolledBack: allowRolledBack, progress: progress)
        case .file(let source):
            guard fileSystem.fileExists(at: source) else { throw RuntimeServiceError.packUnreadable(source.plainPath) }
            try FileDigest.verify(source, sha256: manifest.sha256, size: manifest.size, fileSystem: fileSystem)
            if source.standardizedFileURL != packPath.standardizedFileURL {
                try fileSystem.replaceFile(at: packPath, withCopyOf: source)
            }
        case .url(let source):
            try await downloadPack(for: manifest, from: source, allowRolledBack: allowRolledBack, progress: progress)
        }
        return try await installer.install(manifest, allowRolledBack: allowRolledBack)
    }

    /// RuntimeKit's installer on this engine's store, ad-hoc signers named "adhoc".
    var installer: RuntimeInstaller {
        RuntimeInstaller(store: store, http: engine.http, extractor: engine.extractor,
                         signatures: NamedSignerInspector(base: engine.signatures), workDirectory: workDirectory)
    }

    /// The manifest inside a signed envelope, if `trust` and this Mac's records accept it (signature first, then
    /// schema, serial floor, expiry, revocations, signer, architecture, URL, versions).
    func verified(_ signedManifest: Data, trust: ManifestTrust, appVersion: String,
                  macOSVersion: String) throws -> RuntimeManifest {
        let state = try store.load()
        let context = ManifestContext(now: engine.clock.now, lastAcceptedSerial: state.lastSerial,
                                      revoked: Set(state.revoked), appVersion: appVersion, macOSVersion: macOSVersion)
        do {
            return try ManifestVerifier.verify(signedManifest, trust: trust, context: context)
        } catch {
            throw RuntimeServiceError.manifestRejected(error)
        }
    }

    /// Where a pack is kept while it is installed.
    public func packFile(for manifest: RuntimeManifest) -> URL { installer.packFile(for: manifest) }

    /// Downloads `manifest`'s pack (from `source`, a mirror, or the manifest's own URL) to `packFile(for:)`, resuming
    /// an earlier partial download; a file whose size or SHA-256 is not the manifest's is deleted. Nothing is fetched
    /// when an intact copy is already there, and a runtime this Mac would not install
    /// (`RuntimeInstaller.checkInstallable`) throws before the first byte.
    public func downloadPack(for manifest: RuntimeManifest, from source: URL? = nil, allowRolledBack: Bool = false,
                             progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }) async throws {
        try installer.checkInstallable(manifest, allowRolledBack: allowRolledBack)
        let destination = packFile(for: manifest)
        if (try? FileDigest.verify(destination, sha256: manifest.sha256, size: manifest.size,
                                   fileSystem: engine.fileSystem)) != nil {
            progress(DownloadProgress(receivedBytes: manifest.size, totalBytes: manifest.size))
            return
        }
        try engine.fileSystem.createDirectory(at: workDirectory)
        try await engine.packDownloader.download(source ?? manifest.url, to: destination, size: manifest.size,
                                                 sha256: manifest.sha256, progress: progress)
    }

    // MARK: Feed

    /// Where the manifest `fetchManifest` accepted waits for the steps that follow (verified again on every read).
    public var feedManifestFile: URL { workDirectory.appending(path: "feed-manifest.json") }

    /// Fetches the feed's signed manifest and acts on nothing until it verifies (`ManifestVerifier`). The accepted
    /// manifest raises the serial floor and applies its revocations (a revoked current runtime rolls back to the
    /// previous one), and is kept for `savedManifest(for:trust:)`.
    @discardableResult
    public func fetchManifest(from feed: RuntimeFeed, trust: ManifestTrust) async throws -> RuntimeManifest {
        let data = try await feedData(feed)
        let manifest = try feedManifest(data, feed: feed, trust: trust)
        try store.accept(manifest)
        try engine.fileSystem.writeAtomically(data, to: feedManifestFile)
        return manifest
    }

    /// The manifest `fetchManifest` would accept, fetched and verified the same way, with nothing recorded or kept: the
    /// serial floor, the revocations and the kept manifest stay as they are. For a check that must not change the store
    /// while a game may run on the current runtime (the app's Check for Updates): recording a revocation can make the
    /// previous runtime current and delete the revoked runtime's directory.
    public func checkManifest(from feed: RuntimeFeed, trust: ManifestTrust) async throws -> RuntimeManifest {
        try feedManifest(try await feedData(feed), feed: feed, trust: trust)
    }

    /// The feed's signed manifest as the server sends it (https only).
    private func feedData(_ feed: RuntimeFeed) async throws -> Data {
        guard feed.url.scheme == "https" else { throw RuntimeServiceError.insecureFeed(feed.url.absoluteString) }
        return try await engine.http.data(from: feed.url)
    }

    /// The manifest the last `fetchManifest` accepted, verified again now; nil when there is none or it no longer
    /// passes (expired since, revoked since, signed with a key this build does not trust).
    public func savedManifest(for feed: RuntimeFeed, trust: ManifestTrust) -> RuntimeManifest? {
        guard let data = try? engine.fileSystem.contents(of: feedManifestFile) else { return nil }
        return try? feedManifest(data, feed: feed, trust: trust)
    }

    private func feedManifest(_ data: Data, feed: RuntimeFeed, trust: ManifestTrust) throws -> RuntimeManifest {
        try verified(data, trust: trust, appVersion: feed.appVersion, macOSVersion: feed.macOSVersion)
    }

    /// `manifest`'s runtime is already the current one, on disk and not revoked: nothing to download or install.
    public func isCurrent(_ manifest: RuntimeManifest) -> Bool {
        guard let state = try? store.load(), let current = state.current, current.id == manifest.id,
              !state.isCurrentRevoked else { return false }
        return engine.fileSystem.directoryExists(at: store.hostURL(for: current))
    }

    /// Unpacks `manifest`'s pack (`downloadPack` first) and checks the host: code signature valid, nested code
    /// included, and by the manifest's signer; the manifest's channel. The host stays staged for `activatePack`.
    public func stagePack(for manifest: RuntimeManifest) async throws {
        try await installer.stage(manifest)
    }

    /// Makes the host `stagePack` left the current runtime, after checking it again; the runtime it replaces becomes
    /// the previous one. Throws `RuntimeStoreError.stagedHostMissing` when nothing is staged (`stagePack` again).
    @discardableResult
    public func activatePack(for manifest: RuntimeManifest) throws -> RuntimeStoreState {
        try installer.activate(manifest)
    }

    /// Makes the previous runtime current again; the runtime it replaces is not installed again automatically.
    @discardableResult
    public func rollback() throws -> RuntimeStoreState {
        try store.rollback()
    }
}
