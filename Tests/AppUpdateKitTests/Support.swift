import CryptoKit
import Foundation
import RuntimeKit
import Synchronization
import WarzagCore
import WarzagTestSupport
@testable import AppUpdateKit

func scratchDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "warzag-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    // Resolved (/var is /private/var), as the location checks and the kernel name it.
    return URL(filePath: LiveAppLocationInspector.resolved(url), directoryHint: .isDirectory)
}

/// An app bundle on disk with an Info.plist and a marker file; nothing in it runs.
@discardableResult
func makeApp(at url: URL, identifier: String = AppManifest.bundleIdentifier, version: String, build: String) throws -> URL {
    let contents = url.appending(path: "Contents", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
    try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleExecutable</key><string>Warzag</string>
        <key>CFBundleIdentifier</key><string>\(identifier)</string>
        <key>CFBundleShortVersionString</key><string>\(version)</string>
        <key>CFBundleVersion</key><string>\(build)</string>
        <key>LSMinimumSystemVersion</key><string>15.0</string>
        </dict></plist>
        """.utf8).write(to: contents.appending(path: "Info.plist"))
    try Data("build \(build)\n".utf8).write(to: contents.appending(path: "MacOS/Warzag"))
    return url
}

func build(of app: URL) -> String? {
    LocalBundleFiles().info(of: app).build
}

/// Accepts a bundle whose Info.plist names the required identity, version and build, unless it holds
/// `Contents/broken` (a copy whose "signature" no longer validates).
struct PlistBundleVerifier: AppBundleVerifying {
    func verify(_ bundle: URL, against requirement: AppRequirement) throws(AppBundleRejection) {
        guard FileManager.default.fileExists(atPath: bundle.appending(path: "Contents/Info.plist").plainPath) else {
            throw .notABundle(bundle.lastPathComponent)
        }
        if FileManager.default.fileExists(atPath: bundle.appending(path: "Contents/broken").plainPath) {
            throw .badSignature("a sealed resource is missing or invalid")
        }
        let app = InstalledApp.read(bundle)
        guard app.identifier == requirement.bundleIdentifier else {
            throw .identityMismatch(expected: requirement.bundleIdentifier, actual: app.identifier ?? "none")
        }
        guard app.version == requirement.version else {
            throw .versionMismatch(expected: requirement.version, actual: app.version)
        }
        guard app.build == requirement.build else { throw .buildMismatch(expected: requirement.build, actual: app.build) }
    }
}

/// "Downloads" by writing `data` (after checking it as the real downloader does), or throws `failure`.
final class FakeAppDownloader: PackDownloading {
    private struct State {
        var data = Data("archive".utf8)
        var failure: (any Error)?
        var urls: [URL] = []
    }

    private let state = Mutex(State())

    var data: Data {
        get { state.withLock { $0.data } }
        set { state.withLock { $0.data = newValue } }
    }

    var failure: (any Error)? {
        get { state.withLock { $0.failure } }
        set { state.withLock { $0.failure = newValue } }
    }

    var urls: [URL] { state.withLock { $0.urls } }

    func download(_ url: URL, to destination: URL, size: Int64, sha256: String,
                  progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        let (data, failure) = state.withLock { state in
            state.urls.append(url)
            return (state.data, state.failure)
        }
        if let failure { throw failure }
        try LocalFileSystem().writeAtomically(data, to: destination)
        try FileDigest.verify(destination, sha256: sha256, size: size, fileSystem: LocalFileSystem())
        progress(DownloadProgress(receivedBytes: size, totalBytes: size))
    }
}

/// "Unpacks" an archive by running `make` on the destination.
struct FakeAppExtractor: AppArchiveExtracting {
    var make: @Sendable (_ destination: URL) throws -> Void

    func extract(_ archive: URL, into destination: URL) async throws {
        try make(destination)
    }
}

struct FixedLocation: AppLocationInspecting {
    var obstacle: String?
    func obstacle(replacing bundle: URL) -> String? { obstacle }
}

/// Records the helpers it is asked to start: `launch` (the swap) returns a pid, `run` (the probe) answers with
/// `handler`.
final class RecordingLauncher: HelperLaunching {
    private struct State {
        var launched: [Command] = []
        var ran: [Command] = []
        var failure: POSIXError?
    }

    private let state = Mutex(State())
    private let handler: RecordingProcessRunner.Handler

    init(handler: @escaping RecordingProcessRunner.Handler = { _ in ProcessOutput(exitCode: 0) }) {
        self.handler = handler
    }

    /// The helpers started on their own (the swap).
    var commands: [Command] { state.withLock { $0.launched } }
    /// The helpers run and waited for (the probe).
    var runs: [Command] { state.withLock { $0.ran } }

    func fail(with error: POSIXError) { state.withLock { $0.failure = error } }

    func launch(_ command: Command) throws -> Int32 {
        try state.withLock { state in
            state.launched.append(command)
            if let failure = state.failure { throw failure }
            return 4242
        }
    }

    func run(_ command: Command) async throws -> ProcessOutput {
        state.withLock { $0.ran.append(command) }
        return try handler(command)
    }
}

/// The local disk, whose volume says it has `available` bytes free (nil: it does not say).
struct CapacityFileSystem: FileSystem {
    let base = LocalFileSystem()
    var available: Int64?

    func volumeInfo(for url: URL) throws -> VolumeInfo {
        var info = try base.volumeInfo(for: url)
        info.availableCapacity = available
        return info
    }

    func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }
    func directoryExists(at url: URL) -> Bool { base.directoryExists(at: url) }
    func contents(of url: URL) throws -> Data { try base.contents(of: url) }
    func read(_ url: URL, offset: UInt64, maxLength: Int) throws -> Data {
        try base.read(url, offset: offset, maxLength: maxLength)
    }
    func forEachChunk(of url: URL, chunkSize: Int, _ body: (Data) throws -> Void) throws {
        try base.forEachChunk(of: url, chunkSize: chunkSize, body)
    }
    func attributes(of url: URL) throws -> FileAttributes { try base.attributes(of: url) }
    func contentsOfDirectory(at url: URL) throws -> [URL] { try base.contentsOfDirectory(at: url) }
    func createDirectory(at url: URL) throws { try base.createDirectory(at: url) }
    func writeAtomically(_ data: Data, to url: URL) throws { try base.writeAtomically(data, to: url) }
    func createExclusively(_ data: Data, at url: URL) throws -> Bool { try base.createExclusively(data, at: url) }
    func append(_ data: Data, to url: URL) throws { try base.append(data, to: url) }
    func moveItem(at source: URL, to destination: URL) throws { try base.moveItem(at: source, to: destination) }
    func removeItem(at url: URL) throws { try base.removeItem(at: url) }
    func isWritableDirectory(at url: URL) -> Bool { base.isWritableDirectory(at: url) }
}

enum AppKeys {
    static let key = Curve25519.Signing.PrivateKey()
    static let strangerKey = Curve25519.Signing.PrivateKey()
    static let signer = String(repeating: "f3", count: 32)
    static let trust = ManifestTrust(publicKeys: ["test": key.publicKey.rawRepresentation], signerFingerprints: [signer])

    static func manifest(version: String = "0.2.0", build: String = "413", serial: UInt64 = 7,
                         archive: Data = Data("archive".utf8), minMacOS: String = "15.0",
                         now: Date = ManualClock().now) -> AppManifest {
        AppManifest(serial: serial, expires: now.addingTimeInterval(30 * 86_400), version: version, build: build,
                    minMacOS: minMacOS, url: URL(string: "https://releases.example.org/Warzag-\(version).zip")!,
                    size: Int64(archive.count), sha256: SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined(),
                    signerFingerprint: signer, releaseNotes: URL(string: "https://releases.example.org/v\(version)"))
    }

    static func signed(_ manifest: AppManifest, with key: Curve25519.Signing.PrivateKey = key) throws -> Data {
        try SignedManifest.sign(manifest, keyId: "test", with: key).encoded()
    }
}
