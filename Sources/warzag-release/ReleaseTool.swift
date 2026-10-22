import AppUpdateKit
import CryptoKit
import Foundation
import RuntimeKit
import WarzagCore

/// A release step that cannot go on (bad key file, missing pack, a manifest the app would refuse).
struct ReleaseError: Error, Equatable, CustomStringConvertible {
    var message: String
    var description: String { message }
}

struct ReleaseResult: Equatable {
    var stdout = ""
    var stderr = ""
    var exitCode: Int32 = 0

    static func failure(_ message: String) -> ReleaseResult {
        ReleaseResult(stderr: "warzag-release: \(message)\n", exitCode: 1)
    }
}

/// The commands, with every side effect injectable for tests. The manifest types, the verifier and the installer are
/// RuntimeKit's own, so what this tool signs and checks is exactly what the app accepts.
struct ReleaseTool {
    var fileSystem: any FileSystem = LocalFileSystem()
    var now: @Sendable () -> Date = { Date() }
    var extractor: any PackExtracting = AppleArchiveExtractor(runner: SystemProcessRunner())
    var signatures: any CodeSignatureInspecting = SecurityCodeSignatureInspector()
    var temporaryDirectory: URL = FileManager.default.temporaryDirectory
    var currentMacOS: String = VersionNumber(ProcessInfo.processInfo.operatingSystemVersion).description
    /// Update archives: unpacked and their app checked with AppUpdateKit's own code, as Warzag does it.
    var appExtractor: any AppArchiveExtracting = DittoArchiveExtractor(runner: SystemProcessRunner())
    var bundles: any AppBundleVerifying = LiveAppBundleVerifier()
    /// Development builds only (`AppFeed.allowsLoopbackHTTP`): a local test feed.
    var allowsLoopbackHTTP = AppFeed.allowsLoopbackHTTP

    func run(_ command: ReleaseCommand) async -> ReleaseResult {
        do {
            switch command {
            case .help:
                return ReleaseResult(stdout: ReleaseCommandLine.usage + "\n")
            case .keygen(let options):
                return try keygen(options)
            case .publicKey(let keyFile):
                let key = try ManifestKeys.readPrivateKey(at: URL(filePath: keyFile))
                return ReleaseResult(stdout: key.publicKey.rawRepresentation.base64EncodedString() + "\n",
                                     stderr: "key id: \(ManifestTrust.keyID(for: key.publicKey))\n")
            case .manifest(let options):
                return try manifest(options)
            case .verify(let options):
                return await verify(options)
            case .appManifest(let options):
                return try await appManifest(options)
            case .appVerify(let options):
                return await appVerify(options)
            }
        } catch {
            return .failure(String(describing: error))
        }
    }

    // MARK: keygen

    func keygen(_ options: KeygenOptions) throws -> ReleaseResult {
        let key = Curve25519.Signing.PrivateKey()
        let files = try ManifestKeys.writeNewKeyPair(key, in: URL(filePath: options.directory, directoryHint: .isDirectory),
                                                     name: options.name)
        let keyID = ManifestTrust.keyID(for: key.publicKey)
        return ReleaseResult(stdout: """
            private key  \(files.privateKey.plainPath) (mode 600: keep it secret and out of the repository)
            public key   \(key.publicKey.rawRepresentation.base64EncodedString())
            key id       \(keyID)
            pinned as    ManifestTrust(publicKeys: ["\(keyID)": <public key bytes>], ...)

            """)
    }

    // MARK: manifest

    /// The signed envelope for a pack, plus the manifest inside it. Refuses to produce one the app would reject.
    func signedManifest(_ options: ManifestOptions) throws -> (envelope: Data, manifest: RuntimeManifest, keyID: String) {
        let key = try ManifestKeys.readPrivateKey(at: URL(filePath: options.keyFile))
        let keyID = options.keyID ?? ManifestTrust.keyID(for: key.publicKey)
        let pack = URL(filePath: options.pack)
        guard fileSystem.fileExists(at: pack) else { throw ReleaseError(message: "no pack at \(options.pack)") }
        let size = Int64(try fileSystem.attributes(of: pack).size)
        let sha256 = try FileDigest.sha256(of: pack, fileSystem: fileSystem)
        // Whole seconds: the manifest's dates are ISO 8601 without fractions, and must round-trip exactly.
        let issued = Date(timeIntervalSince1970: now().timeIntervalSince1970.rounded(.down))
        let manifest = RuntimeManifest(
            serial: options.serial, expires: issued.addingTimeInterval(TimeInterval(options.expiresInDays) * 86_400),
            id: "\(RuntimeChannel.n.rawValue)-\(options.version)", version: options.version, channel: .n,
            arch: RuntimeChannel.n.architecture, minLauncher: options.minLauncher, minMacOS: options.minMacOS,
            url: options.url, size: size, sha256: sha256, signerFingerprint: options.signerFingerprint,
            revoked: options.revoked, killSwitch: options.killSwitch)
        let envelope = try SignedManifest.sign(manifest, keyId: keyID, with: key).encoded()

        // The app's verifier, with this key and signer pinned, must accept it byte for byte.
        let trust = ManifestTrust(publicKeys: [keyID: key.publicKey.rawRepresentation],
                                  signerFingerprints: [options.signerFingerprint])
        let context = ManifestContext(now: issued, lastAcceptedSerial: nil, revoked: [], appVersion: "", macOSVersion: "")
        let accepted: RuntimeManifest
        do {
            accepted = try ManifestVerifier.verify(envelope, trust: trust, context: context)
        } catch {
            throw ReleaseError(message: "the app would reject this manifest: \(error)")
        }
        guard accepted == manifest else { throw ReleaseError(message: "the manifest does not round-trip") }
        return (envelope, manifest, keyID)
    }

    func manifest(_ options: ManifestOptions) throws -> ReleaseResult {
        let signed = try signedManifest(options)
        let manifest = signed.manifest
        let summary = """
            manifest  \(manifest.id) (channel \(manifest.channel.rawValue), \(manifest.arch)) serial \(manifest.serial), \
            expires \(manifest.expires.formatted(.iso8601)), key id \(signed.keyID)
            pack      \(manifest.size) bytes, sha256 \(manifest.sha256)
            url       \(manifest.url.absoluteString)
            signer    \(manifest.signerFingerprint)

            """
        guard let output = options.output else {
            return ReleaseResult(stdout: String(decoding: signed.envelope, as: UTF8.self) + "\n", stderr: summary)
        }
        try fileSystem.writeAtomically(signed.envelope, to: URL(filePath: output))
        return ReleaseResult(stdout: "wrote \(output)\n" + summary)
    }

    // MARK: verify

    func verify(_ options: VerifyOptions) async -> ReleaseResult {
        var report = ""
        func fail(_ message: String) -> ReleaseResult {
            ReleaseResult(stdout: report, stderr: "warzag-release: \(message)\n", exitCode: 1)
        }

        let data: Data
        let publicKey: Curve25519.Signing.PublicKey
        do {
            data = try fileSystem.contents(of: URL(filePath: options.manifest))
            publicKey = try ManifestKeys.publicKey(base64: options.publicKey)
        } catch {
            return fail(String(describing: error))
        }
        let keyID = options.keyID ?? ManifestTrust.keyID(for: publicKey)

        // Without a pinned signer, accept the one the manifest names; the verifier still checks the signature first.
        let signer: String
        if let pinned = options.signerFingerprint {
            signer = pinned
        } else {
            let claimed = (try? WarzagJSON.decoder().decode(SignedManifest.self, from: data))
                .flatMap { try? WarzagJSON.decoder().decode(RuntimeManifest.self, from: $0.payload) }?
                .signerFingerprint.lowercased()
            signer = claimed ?? ""
            report += "note      signer not pinned (--signer-sha256): taking the manifest's own\n"
        }
        let trust = ManifestTrust(publicKeys: [keyID: publicKey.rawRepresentation], signerFingerprints: [signer])
        let context = ManifestContext(now: now(), lastAcceptedSerial: nil, revoked: [], appVersion: options.appVersion,
                                      macOSVersion: options.macOSVersion ?? currentMacOS)
        let manifest: RuntimeManifest
        do {
            manifest = try ManifestVerifier.verify(data, trust: trust, context: context)
        } catch {
            return fail("manifest rejected: \(error)")
        }
        report += """
            manifest  ok: \(manifest.id) serial \(manifest.serial), expires \(manifest.expires.formatted(.iso8601)), \
            key id \(keyID), signer \(manifest.signerFingerprint)\n
            """

        let pack = URL(filePath: options.pack)
        do {
            try FileDigest.verify(pack, sha256: manifest.sha256, size: manifest.size, fileSystem: fileSystem)
        } catch {
            return fail("pack \(options.pack): \(error)")
        }
        report += "pack      ok: \(manifest.size) bytes, sha256 \(manifest.sha256)\n"
        if manifest.url.lastPathComponent != pack.lastPathComponent {
            report += "note      the manifest's URL names \(manifest.url.lastPathComponent), not \(pack.lastPathComponent)\n"
        }

        guard options.install else { return ReleaseResult(stdout: report) }
        guard manifest.killSwitch.level != .blockInstall else {
            report += "install   skipped: the manifest's kill switch blocks installs\n"
            return ReleaseResult(stdout: report)
        }
        let scratch = temporaryDirectory.appending(path: "warzag-release-verify-\(UUID().uuidString)",
                                                   directoryHint: .isDirectory)
        defer { try? fileSystem.removeItem(at: scratch) }
        let store = RuntimeStore(
            paths: WarzagPaths(home: scratch.appending(path: "home", directoryHint: .isDirectory), userCacheDirectory: nil),
            fileSystem: fileSystem)
        let installer = RuntimeInstaller(store: store, http: LocalPackSource(pack: pack, fileSystem: fileSystem),
                                         extractor: extractor, signatures: signatures,
                                         workDirectory: scratch.appending(path: "work", directoryHint: .isDirectory))
        do {
            try fileSystem.createDirectory(at: scratch.appending(path: "work", directoryHint: .isDirectory))
            let state = try await installer.install(manifest)
            guard let current = state.current, current.id == manifest.id,
                  fileSystem.directoryExists(at: store.hostURL(for: current)) else {
                return fail("install: the runtime did not become current")
            }
        } catch {
            return fail("install: \(error)")
        }
        report += """
            install   ok: RuntimeInstaller unpacked \(WarzagPaths.gameHostName), its code signature is valid and by \
            \(manifest.signerFingerprint), activated as \(WarzagPaths.runtimesFolderName)/\(manifest.channel.rawValue)/\
            \(manifest.version) \
            (scratch home)\n
            """
        return ReleaseResult(stdout: report)
    }
}

// MARK: - App updates

extension ReleaseTool {
    /// The app inside an update archive, unpacked into `scratch` with Warzag's own extractor: the archive must hold
    /// exactly Warzag.app.
    func unpackedApp(_ archive: URL, into scratch: URL) async throws -> URL {
        try fileSystem.createDirectory(at: scratch)
        try await appExtractor.extract(archive, into: scratch)
        let entries = try fileSystem.contentsOfDirectory(at: scratch).map(\.lastPathComponent).sorted()
        guard entries == [AppManifest.bundleName] else {
            throw ReleaseError(message: "\(archive.lastPathComponent) must hold exactly \(AppManifest.bundleName), not "
                + (entries.isEmpty ? "nothing" : entries.joined(separator: ", ")))
        }
        return scratch.appending(path: AppManifest.bundleName, directoryHint: .isDirectory)
    }

    /// The signed envelope for an update archive and the manifest inside it. The app in the archive is checked as
    /// Warzag checks a download, and the envelope with the app's own verifier; nothing Warzag would refuse is made.
    func signedAppManifest(_ options: AppManifestOptions) async throws -> (envelope: Data, manifest: AppManifest,
                                                                             keyID: String) {
        let key = try ManifestKeys.readPrivateKey(at: URL(filePath: options.keyFile))
        let keyID = options.keyID ?? ManifestTrust.keyID(for: key.publicKey)
        let archive = URL(filePath: options.archive)
        guard fileSystem.fileExists(at: archive) else { throw ReleaseError(message: "no archive at \(options.archive)") }
        let scratch = temporaryDirectory.appending(path: "warzag-release-app-\(UUID().uuidString)",
                                                   directoryHint: .isDirectory)
        defer { try? fileSystem.removeItem(at: scratch) }
        let app = try await unpackedApp(archive, into: scratch)
        let installed = InstalledApp.read(app, fileSystem: fileSystem)
        do {
            try bundles.verify(app, against: AppRequirement(version: installed.version, build: installed.build,
                                                            signerFingerprint: options.signerFingerprint))
        } catch {
            throw ReleaseError(message: "Warzag would refuse the app in \(archive.lastPathComponent): \(error)")
        }

        let size = Int64(try fileSystem.attributes(of: archive).size)
        let sha256 = try FileDigest.sha256(of: archive, fileSystem: fileSystem)
        // Whole seconds: the manifest's dates are ISO 8601 without fractions, and must round-trip exactly.
        let issued = Date(timeIntervalSince1970: now().timeIntervalSince1970.rounded(.down))
        let manifest = AppManifest(
            serial: options.serial, expires: issued.addingTimeInterval(TimeInterval(options.expiresInDays) * 86_400),
            version: installed.version, build: installed.build,
            minMacOS: options.minMacOS ?? installed.minimumMacOS ?? Platform.minimumMacOS.description, url: options.url,
            size: size, sha256: sha256, signerFingerprint: options.signerFingerprint, releaseNotes: options.releaseNotes)
        let envelope = try SignedManifest.sign(manifest, keyId: keyID, with: key).encoded()

        // The app's verifier, with this key and signer pinned, must accept it byte for byte.
        let trust = ManifestTrust(publicKeys: [keyID: key.publicKey.rawRepresentation],
                                  signerFingerprints: [options.signerFingerprint])
        let accepted: AppManifest
        do {
            accepted = try AppManifestVerifier.verify(envelope, trust: trust, context: AppManifestContext(
                now: issued, lastAcceptedSerial: nil, allowsLoopbackHTTP: allowsLoopbackHTTP))
        } catch {
            throw ReleaseError(message: "Warzag would reject this app manifest: \(error)")
        }
        guard accepted == manifest else { throw ReleaseError(message: "the app manifest does not round-trip") }
        return (envelope, manifest, keyID)
    }

    func appManifest(_ options: AppManifestOptions) async throws -> ReleaseResult {
        let signed = try await signedAppManifest(options)
        let manifest = signed.manifest
        let summary = """
            manifest  Warzag \(manifest.version) (build \(manifest.build)), kind app, serial \(manifest.serial), expires \
            \(manifest.expires.formatted(.iso8601)), key id \(signed.keyID)
            archive   \(manifest.size) bytes, sha256 \(manifest.sha256)
            url       \(manifest.url.absoluteString)
            signer    \(manifest.signerFingerprint)
            macOS     \(manifest.minMacOS) or later\(manifest.releaseNotes.map { "\nnotes     \($0.absoluteString)" } ?? "")

            """
        guard let output = options.output else {
            return ReleaseResult(stdout: String(decoding: signed.envelope, as: UTF8.self) + "\n", stderr: summary)
        }
        try fileSystem.writeAtomically(signed.envelope, to: URL(filePath: output))
        return ReleaseResult(stdout: "wrote \(output)\n" + summary)
    }

    func appVerify(_ options: AppVerifyOptions) async -> ReleaseResult {
        var report = ""
        func fail(_ message: String) -> ReleaseResult {
            ReleaseResult(stdout: report, stderr: "warzag-release: \(message)\n", exitCode: 1)
        }

        let data: Data
        let publicKey: Curve25519.Signing.PublicKey
        do {
            data = try fileSystem.contents(of: URL(filePath: options.manifest))
            publicKey = try ManifestKeys.publicKey(base64: options.publicKey)
        } catch {
            return fail(String(describing: error))
        }
        let keyID = options.keyID ?? ManifestTrust.keyID(for: publicKey)
        // Without a pinned signer, accept the one the manifest names; the verifier still checks the signature first.
        let signer: String
        if let pinned = options.signerFingerprint {
            signer = pinned
        } else {
            signer = (try? WarzagJSON.decoder().decode(SignedManifest.self, from: data))
                .flatMap { try? WarzagJSON.decoder().decode(AppManifest.self, from: $0.payload) }?
                .signerFingerprint.lowercased() ?? ""
            report += "note      signer not pinned (--signer-sha256): taking the manifest's own\n"
        }
        let trust = ManifestTrust(publicKeys: [keyID: publicKey.rawRepresentation], signerFingerprints: [signer])
        let manifest: AppManifest
        do {
            manifest = try AppManifestVerifier.verify(data, trust: trust, context: AppManifestContext(
                now: now(), lastAcceptedSerial: nil, allowsLoopbackHTTP: allowsLoopbackHTTP))
        } catch {
            return fail("app manifest rejected: \(error)")
        }
        report += """
            manifest  ok: Warzag \(manifest.version) (build \(manifest.build)) serial \(manifest.serial), expires \
            \(manifest.expires.formatted(.iso8601)), key id \(keyID), signer \(manifest.signerFingerprint)\n
            """
        if let running = options.runningBuild, !AppManifest.isNewer(manifest.build, than: running) {
            return fail("build \(manifest.build) is not newer than the running build \(running): Warzag would not "
                + "offer it")
        }
        let macOS = options.macOSVersion ?? currentMacOS
        if let required = VersionNumber(manifest.minMacOS), let running = VersionNumber(macOS), running < required {
            return fail("Warzag \(manifest.version) needs macOS \(manifest.minMacOS) or later, not \(macOS)")
        }

        let archive = URL(filePath: options.archive)
        do {
            try FileDigest.verify(archive, sha256: manifest.sha256, size: manifest.size, fileSystem: fileSystem)
        } catch {
            return fail("archive \(options.archive): \(error)")
        }
        report += "archive   ok: \(manifest.size) bytes, sha256 \(manifest.sha256)\n"
        if manifest.url.lastPathComponent != archive.lastPathComponent {
            report += "note      the manifest's URL names \(manifest.url.lastPathComponent), not \(archive.lastPathComponent)\n"
        }
        let scratch = temporaryDirectory.appending(path: "warzag-release-app-verify-\(UUID().uuidString)",
                                                   directoryHint: .isDirectory)
        defer { try? fileSystem.removeItem(at: scratch) }
        do {
            let app = try await unpackedApp(archive, into: scratch)
            try bundles.verify(app, against: AppRequirement(manifest))
        } catch {
            return fail("app: \(error)")
        }
        report += """
            app       ok: \(AppManifest.bundleIdentifier) \(manifest.version) (build \(manifest.build)), arm64, strictly \
            signed by \(manifest.signerFingerprint), no link out of the bundle, no quarantine\n
            """
        return ReleaseResult(stdout: report)
    }
}

/// The installer's "download": the local pack, whatever the manifest's URL says.
struct LocalPackSource: HTTPClient {
    let pack: URL
    let fileSystem: any FileSystem

    func data(from url: URL) async throws -> Data {
        try fileSystem.contents(of: pack)
    }

    func download(from url: URL, to destination: URL) async throws {
        try? fileSystem.removeItem(at: destination)
        try fileSystem.createDirectory(at: destination.deletingLastPathComponent())
        if fileSystem is LocalFileSystem {
            // A clone on APFS: packs are hundreds of megabytes.
            try FileManager.default.copyItem(at: pack, to: destination)
        } else {
            try fileSystem.writeAtomically(try fileSystem.contents(of: pack), to: destination)
        }
    }
}
