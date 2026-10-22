import CryptoKit
import Foundation
import Synchronization
import RuntimeKit
import WarzagCore
import WarzagTestSupport
import WineKit
@testable import EngineKit

struct BrokenSignature: Error, Equatable {}

/// Who signed a bundle, as the tests decide.
final class FakeSignatures: CodeSignatureInspecting {
    enum Answer: Sendable {
        case adHoc
        case certificate(String)
        case broken
    }

    private let answer = Mutex(Answer.adHoc)
    private let inspected = Mutex<[String]>([])

    func set(_ answer: Answer) { self.answer.withLock { $0 = answer } }
    var bundles: [String] { inspected.withLock { $0 } }

    func signerFingerprint(of bundle: URL) throws -> String? {
        inspected.withLock { $0.append(bundle.plainPath) }
        switch answer.withLock({ $0 }) {
        case .adHoc: return nil
        case .certificate(let fingerprint): return fingerprint
        case .broken: throw BrokenSignature()
        }
    }
}

struct NotATestPack: Error {}

/// Unpacks the tests' runtime packs: a pack's bytes are "warzag-pack <version>", and unpacking builds that host.
struct FakeExtractor: PackExtracting {
    let fixture: EngineFixture

    func extract(_ pack: URL, into destination: URL) async throws {
        let text = String(decoding: try fixture.fileSystem.contents(of: pack), as: UTF8.self)
        let prefix = "warzag-pack "
        guard text.hasPrefix(prefix) else { throw NotATestPack() }
        fixture.makeHost(at: destination.appending(path: WarzagPaths.gameHostName).plainPath,
                         version: String(text.dropFirst(prefix.count)))
    }
}

/// Packs from the canned HTTP responses into the in-memory files, in 64 KB pieces with progress, then checked like the
/// real one (size and SHA-256; a file that fails is deleted). Resuming is `ResumableDownloader`'s, tested in WarzagCore
/// and end to end in `RuntimeFeedLiveDownloadTests`.
struct FakePackDownloader: PackDownloading {
    let http: FakeHTTPClient
    let fileSystem: any FileSystem

    func download(_ url: URL, to destination: URL, size: Int64, sha256: String,
                  progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        let data = try await http.data(from: url)
        var offset = 0
        repeat {
            offset = min(data.count, offset + 65_536)
            progress(DownloadProgress(receivedBytes: Int64(offset), totalBytes: Int64(data.count)))
        } while offset < data.count
        try fileSystem.writeAtomically(data, to: destination)
        do {
            try FileDigest.verify(destination, sha256: sha256, size: size, fileSystem: fileSystem)
        } catch {
            try? fileSystem.removeItem(at: destination)
            throw error
        }
    }
}

/// An engine wired to fakes: in-memory files with links, FakeWine behind a recording runner, canned HTTP, a manual
/// clock, and a fake runtime host at `devHost`.
final class EngineFixture: Sendable {
    static let home = "/Users/tenno"
    static let devHost = "/Users/tenno/src/warzag/build/n/Warzag.app"
    static let steamReg: String = {
        // The bridge's real steam.reg: the tests check the prefix against the file the runtime ships.
        let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return (try? String(contentsOf: repository.appending(path: "bridge/prefix/steam.reg"), encoding: .utf8)) ?? ""
    }()

    let fileSystem = FakeEngineFileSystem()
    let clock = ManualClock()
    let signatures = FakeSignatures()
    let wine: FakeWine
    let runner: RecordingProcessRunner
    let http: FakeHTTPClient
    let paths = WarzagPaths(home: URL(filePath: EngineFixture.home, directoryHint: .isDirectory), userCacheDirectory: nil)

    init() {
        wine = FakeWine(fileSystem: fileSystem, macHome: Self.home, userName: "tenno")
        let wine = wine
        runner = RecordingProcessRunner { try wine.handle($0) }
        http = FakeHTTPClient(fileSystem: fileSystem)
    }

    var engine: Engine {
        Engine(paths: paths, fileSystem: fileSystem, runner: runner, http: http, signatures: signatures,
               extractor: FakeExtractor(fixture: self), clock: clock, windowsUserName: "tenno",
               inheritedEnvironment: ["HOME": Self.home, "USER": "tenno", "DYLD_INSERT_LIBRARIES": "/evil.dylib",
                                      "WINEDLLPATH": "/somewhere", "SteamAppUser": "someone"],
               packDownloader: FakePackDownloader(http: http, fileSystem: fileSystem))
    }

    var prefixRoot: String { paths.prefix(for: .n).plainPath }
    var layout: PrefixLayout { PrefixLayout(root: paths.prefix(for: .n), windowsUserName: "tenno") }
    var library: String { paths.warframeLibrary.plainPath }

    /// A runtime host with every file the prefix takes from it; contents name the version so copies are traceable.
    /// Info.plist declares `channel` (nil leaves the key out, so only a Mach-O loader tells); `loader` writes a real
    /// loader header of that architecture instead of text.
    func makeHost(at path: String? = nil, version: String = "0.1.0", build: String = "9",
                  identifier: String = "com.warzag.gamehost", channel: String? = "n", loader: Loader? = nil) {
        let path = path ?? Self.devHost
        let contents = path + "/Contents"
        fileSystem.addFile(contents + "/Info.plist", """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleExecutable</key><string>wine</string>
            <key>CFBundleIdentifier</key><string>\(identifier)</string>
            <key>CFBundleShortVersionString</key><string>\(version)</string>
            <key>CFBundleVersion</key><string>\(build)</string>
            \(channel.map { "<key>WarzagRuntimeChannel</key><string>\($0)</string>" } ?? "")
            </dict></plist>
            """)
        if let loader {
            fileSystem.addExecutable(contents + "/MacOS/wine", "")
            fileSystem.addFile(contents + "/MacOS/wine", loader.header)
        } else {
            fileSystem.addExecutable(contents + "/MacOS/wine", "wine loader \(version)")
        }
        fileSystem.addExecutable(contents + "/MacOS/wineserver", "wineserver \(version)")
        let arch = RuntimeChannel.n.wineArchitecture
        for dll in ["winemetal.dll", "nvapi64.dll", "nvngx.dll", "d3d11.dll", "dxgi.dll"] {
            fileSystem.addFile(contents + "/renderers/dxmt/\(arch)-windows/\(dll)", "dxmt \(arch) \(dll) \(version)")
        }
        fileSystem.addFile(contents + "/lib/wine/\(arch)-windows/lsteamclient.dll", "lsteamclient \(version)")
        let bridge = contents + "/share/warzag/bridge"
        for file in ["steam.exe", "steamclient64-forwarder.dll", "wz-steamprobe.exe"] {
            fileSystem.addFile("\(bridge)/\(file)", "\(file) \(version)")
        }
        fileSystem.addFile(bridge + "/steam.reg", Self.steamReg)
    }

    @discardableResult
    func registerDevelopmentRuntime(version: String = "0.1.0") throws -> RuntimeStoreState {
        makeHost(version: version)
        return try engine.runtime.useLocal(URL(filePath: Self.devHost, directoryHint: .isDirectory))
    }

    /// A thin Mach-O loader of this architecture.
    enum Loader {
        case arm64
        case x86_64

        /// Its first bytes.
        var header: Data {
            let cpuType: UInt32 = self == .arm64 ? 0x0100_000C : 0x0100_0007
            return Data([0xCF, 0xFA, 0xED, 0xFE]) + withUnsafeBytes(of: cpuType.littleEndian) { Data($0) } + Data(count: 24)
        }
    }

    // MARK: Signed manifests

    static let key = Curve25519.Signing.PrivateKey()
    static let strangerKey = Curve25519.Signing.PrivateKey()
    static var publicKey: Data { key.publicKey.rawRepresentation }

    /// A test pack in the fake file system and its manifest.
    func pack(version: String, serial: UInt64 = 42, signer: String = RuntimeSigner.adHoc,
              at path: String? = nil) throws -> (pack: URL, manifest: RuntimeManifest) {
        let data = Data("warzag-pack \(version)".utf8)
        let name = "WarzagRuntime-n-\(version).aar"
        let pack = URL(filePath: path ?? "/Users/tenno/Downloads/\(name)")
        fileSystem.addFile(pack.plainPath, data)
        let manifest = RuntimeManifest(
            serial: serial, expires: clock.now.addingTimeInterval(30 * 86_400), id: "n-\(version)",
            version: version, channel: .n, arch: "arm64", minLauncher: "0.1.0", minMacOS: "15.0",
            url: URL(string: "https://runtime.example.org/stable/\(name)")!,
            size: Int64(data.count), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            signerFingerprint: signer)
        return (pack, manifest)
    }

    static func signed(_ manifest: RuntimeManifest, keyId: String = "rt-test",
                       with key: Curve25519.Signing.PrivateKey = EngineFixture.key) throws -> Data {
        try SignedManifest.sign(manifest, keyId: keyId, with: key).encoded()
    }
}
