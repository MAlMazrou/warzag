import CryptoKit
import Foundation
import Testing
import WarzagCore
import WarzagTestSupport
@testable import RuntimeKit

@Suite struct FileDigestTests {
    let fileSystem = InMemoryFileSystem()

    @Test func knownVectorAndStreamingAgree() throws {
        fileSystem.addFile("/abc", "abc")
        #expect(try FileDigest.sha256(of: URL(filePath: "/abc"), fileSystem: fileSystem)
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        let data = Data((0..<1_048_583).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        fileSystem.addFile("/pack.aar", data)
        let streamed = try FileDigest.sha256(of: URL(filePath: "/pack.aar"), fileSystem: fileSystem, chunkSize: 4093)
        #expect(streamed == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    @Test func mismatchesAreReported() throws {
        fileSystem.addFile("/abc", "abc")
        let file = URL(filePath: "/abc")
        let good = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        try FileDigest.verify(file, sha256: good.uppercased(), size: 3, fileSystem: fileSystem)
        #expect(throws: SizeMismatch(expected: 4, actual: 3)) {
            try FileDigest.verify(file, sha256: good, size: 4, fileSystem: fileSystem)
        }
        #expect(throws: DigestMismatch.self) {
            try FileDigest.verify(file, sha256: String(repeating: "0", count: 64), fileSystem: fileSystem)
        }
    }
}

@Suite struct RuntimeStoreTests {
    let fileSystem = InMemoryFileSystem()
    let clock = ManualClock()
    let paths = WarzagPaths(home: URL(filePath: "/Users/tenno", directoryHint: .isDirectory), userCacheDirectory: nil)
    var store: RuntimeStore { RuntimeStore(paths: paths, fileSystem: fileSystem, clock: clock) }

    /// A staged host for `version`, where the installer leaves it after unpacking (inside the store, out of Spotlight).
    func stage(_ version: String) -> URL {
        let host = paths.runtimeStaging.appending(path: "staged-\(version)/Warzag.app", directoryHint: .isDirectory)
        fileSystem.addFile(host.appending(path: "Contents/MacOS/wine").plainPath, "loader \(version)")
        return host
    }

    func install(_ version: String, serial: UInt64 = 42) throws -> RuntimeStoreState {
        try store.install(stagedHost: stage(version), for: Fixture.manifest(id: "n-\(version)", version: version,
                                                                           serial: serial))
    }

    func host(_ version: String) -> URL { paths.gameHost(.n, version: version) }

    func versionsOnDisk() throws -> [String] {
        try fileSystem.contentsOfDirectory(at: paths.runtimeDirectory(.n)).map(\.lastPathComponent).sorted()
    }

    @Test func anEmptyStore() throws {
        #expect(try store.load() == RuntimeStoreState())
        #expect(try store.activeHost() == nil)
    }

    @Test func installingActivatesThroughTheAtomicPointer() throws {
        let state = try install("0.1.0")
        #expect(state.current == InstalledRuntime(id: "n-0.1.0", version: "0.1.0", channel: .n,
                                                  signerFingerprint: Fixture.signer, activatedAt: clock.now))
        #expect(state.previous == nil)
        #expect(try store.load() == state)
        #expect(try store.activeHost() == host("0.1.0"))
        #expect(fileSystem.text(at: host("0.1.0").appending(path: "Contents/MacOS/wine").plainPath) == "loader 0.1.0")
        #expect(!fileSystem.fileExists(at: paths.runtimeStaging.appending(path: "staged-0.1.0/Warzag.app")))
        let pointer = try #require(fileSystem.text(at: paths.activeRuntimePointer.plainPath))
        #expect(pointer.contains(#""schema" : 1"#))
        #expect(paths.activeRuntimePointer.plainPath.hasSuffix("/Runtimes.noindex/active.json"))
    }

    @Test func onlyTheCurrentRuntimeAndNMinusOneAreKept() throws {
        _ = try install("0.1.0")
        let second = try install("0.2.0")
        #expect(second.current?.id == "n-0.2.0")
        #expect(second.previous?.id == "n-0.1.0")
        #expect(try versionsOnDisk() == ["0.1.0", "0.2.0"])

        let third = try install("0.3.0")
        #expect(third.current?.id == "n-0.3.0")
        #expect(third.previous?.id == "n-0.2.0")
        #expect(try versionsOnDisk() == ["0.2.0", "0.3.0"])
    }

    @Test func rollbackReturnsToNMinusOneAndForgetsTheBadRuntime() throws {
        _ = try install("0.1.0")
        _ = try install("0.2.0")
        clock.advance(by: 60)
        let state = try store.rollback()
        #expect(state.current?.id == "n-0.1.0")
        #expect(state.current?.activatedAt == clock.now)
        #expect(state.previous == nil)
        #expect(state.rolledBack == ["n-0.2.0"])
        #expect(try versionsOnDisk() == ["0.1.0"])
        #expect(try store.activeHost() == host("0.1.0"))
        #expect(throws: RuntimeStoreError.noPreviousRuntime) { try store.rollback() }
    }

    @Test func rollbackNeedsThePreviousRuntimeOnDisk() throws {
        _ = try install("0.1.0")
        _ = try install("0.2.0")
        try fileSystem.removeItem(at: paths.runtimeVersionDirectory(.n, version: "0.1.0"))
        #expect(throws: RuntimeStoreError.previousRuntimeMissing("n-0.1.0")) { try store.rollback() }
        #expect(try store.load().current?.id == "n-0.2.0")
    }

    @Test func revokingTheCurrentRuntimeRollsBackAutomatically() throws {
        _ = try install("0.1.0")
        _ = try install("0.2.0")
        var manifest = Fixture.manifest(id: "n-0.3.0", version: "0.3.0", serial: 50)
        manifest.revoked = ["n-0.2.0"]
        let state = try store.accept(manifest)
        #expect(state.current?.id == "n-0.1.0")
        #expect(state.previous == nil)
        #expect(state.lastSerial == 50)
        #expect(state.revoked == ["n-0.2.0"])
        #expect(!state.isCurrentRevoked)
        #expect(try versionsOnDisk() == ["0.1.0"])
    }

    @Test func revokingTheOnlyRuntimeBlocksPlay() throws {
        _ = try install("0.1.0")
        var manifest = Fixture.manifest(id: "n-0.1.1", version: "0.1.1", serial: 50)
        manifest.revoked = ["n-0.1.0"]
        let state = try store.accept(manifest)
        #expect(state.current?.id == "n-0.1.0")
        #expect(state.isCurrentRevoked)
        #expect(try store.activeHost() == nil)
        // Installing the fixed runtime clears the block, and the revoked one does not linger as the previous runtime.
        let fixed = try store.install(stagedHost: stage("0.1.1"), for: manifest)
        #expect(fixed.current?.id == "n-0.1.1")
        #expect(fixed.previous == nil)
        #expect(!fixed.isCurrentRevoked)
        #expect(try store.activeHost() == host("0.1.1"))
        #expect(try versionsOnDisk() == ["0.1.1"])
    }

    @Test func revokingNMinusOneDropsIt() throws {
        _ = try install("0.1.0")
        _ = try install("0.2.0")
        var manifest = Fixture.manifest(id: "n-0.2.0", version: "0.2.0", serial: 50)
        manifest.revoked = ["n-0.1.0"]
        let state = try store.accept(manifest)
        #expect(state.current?.id == "n-0.2.0")
        #expect(state.previous == nil)
        #expect(try versionsOnDisk() == ["0.2.0"])
    }

    @Test func theSerialFloorOnlyRises() throws {
        #expect(try store.accept(Fixture.manifest(serial: 50)).lastSerial == 50)
        #expect(try store.accept(Fixture.manifest(serial: 45)).lastSerial == 50)
    }

    @Test func revokedRuntimesCannotBeInstalled() throws {
        var manifest = Fixture.manifest(id: "n-0.3.0", version: "0.3.0", serial: 50)
        manifest.revoked = ["n-0.2.0"]
        _ = try store.accept(manifest)
        #expect(throws: RuntimeStoreError.revoked("n-0.2.0")) {
            try store.install(stagedHost: stage("0.2.0"), for: Fixture.manifest(id: "n-0.2.0", version: "0.2.0"))
        }
    }

    @Test func reinstallingTheCurrentRuntimeIsANoOp() throws {
        let first = try install("0.1.0")
        clock.advance(by: 60)
        #expect(try install("0.1.0") == first)
        #expect(try versionsOnDisk() == ["0.1.0"])
    }

    @Test func reinstallingNMinusOneSwapsWithoutCopying() throws {
        _ = try install("0.1.0")
        _ = try install("0.2.0")
        let state = try install("0.1.0")
        #expect(state.current?.id == "n-0.1.0")
        #expect(state.previous?.id == "n-0.2.0")
        #expect(try versionsOnDisk() == ["0.1.0", "0.2.0"])
    }

    @Test func unsafeNamesNeverBecomePaths() throws {
        #expect(throws: RuntimeStoreError.invalidName("../escape")) {
            try store.install(stagedHost: stage("x"), for: Fixture.manifest(id: "n-x", version: "../escape"))
        }
        #expect(throws: RuntimeStoreError.stagedHostMissing) {
            try store.install(stagedHost: URL(filePath: "/nowhere/Warzag.app"), for: Fixture.manifest())
        }
    }

    @Test func leftoversInTheRuntimeFolderArePruned() throws {
        fileSystem.addDirectory(paths.runtimeVersionDirectory(.n, version: "0.0.1").appending(path: "Warzag.app").plainPath)
        fileSystem.addDirectory(paths.runtimeVersionDirectory(.n, version: "9.9.9").plainPath)
        _ = try install("0.1.0")
        #expect(try versionsOnDisk() == ["0.1.0"])
    }

    /// Before an engine copy is staged, what earlier installs left in the staging folder goes: everything but that copy
    /// and use-local clones, which another process may be making. Each entry goes by a rename aside first: one that
    /// cannot be renamed (another process has just moved it into the store, say) is never deleted where it is.
    @Test func stagingLeftoversArePrunedButNeverDeletedInPlace() throws {
        let staging = paths.runtimeStaging.plainPath
        for name in ["n-0.3.1", "n-0.3.0", "n-dev-20261016-200000", ".discarded-0123"] {
            fileSystem.addFile(staging + "/\(name)/Warzag.app/Contents/MacOS/wine", name)
        }
        fileSystem.addFile(staging + "/.DS_Store", "Finder")
        func entries() throws -> [String] {
            try fileSystem.contentsOfDirectory(at: paths.runtimeStaging).map(\.lastPathComponent).sorted()
        }

        let renameFails = RenameFailingFileSystem(base: fileSystem)
        RuntimeStore(paths: paths, fileSystem: renameFails, clock: clock).pruneStaging(keeping: "n-0.3.1")
        #expect(try entries() == ["n-0.3.0", "n-0.3.1", "n-dev-20261016-200000"])
        #expect(fileSystem.text(at: staging + "/n-0.3.0/Warzag.app/Contents/MacOS/wine") == "n-0.3.0")

        store.pruneStaging(keeping: "n-0.3.1")
        #expect(try entries() == ["n-0.3.1", "n-dev-20261016-200000"])
        #expect(fileSystem.text(at: staging + "/n-0.3.1/Warzag.app/Contents/MacOS/wine") == "n-0.3.1")
    }

    @Test func anUnreadablePointerIsReportedNotOverwritten() {
        fileSystem.addFile(paths.activeRuntimePointer.plainPath, "{ broken")
        #expect(throws: RuntimeStoreError.self) { try store.load() }
        #expect(throws: RuntimeStoreError.self) { try install("0.1.0") }
        #expect(fileSystem.text(at: paths.activeRuntimePointer.plainPath) == "{ broken")
    }
}

/// Fakes for the installer pipeline. The unpacked host says which channel it is for in its Info.plist (its loader is
/// not a Mach-O file here); nil leaves the key out.
struct FakeExtractor: PackExtracting {
    let fileSystem: InMemoryFileSystem
    var channel: String? = "n"

    func extract(_ pack: URL, into destination: URL) async throws {
        fileSystem.addFile(destination.appending(path: "Warzag.app/Contents/MacOS/wine").plainPath, "unpacked")
        if let channel {
            fileSystem.addFile(destination.appending(path: "Warzag.app/Contents/Info.plist").plainPath, """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>WarzagRuntimeChannel</key><string>\(channel)</string></dict></plist>
            """)
        }
    }
}

struct FakeSignatures: CodeSignatureInspecting {
    var fingerprint: String?
    func signerFingerprint(of bundle: URL) throws -> String? { fingerprint }
}

@Suite struct RuntimeInstallerTests {
    let fileSystem = InMemoryFileSystem()
    let paths = WarzagPaths(home: URL(filePath: "/Users/tenno", directoryHint: .isDirectory), userCacheDirectory: nil)
    let pack = Data("a runtime pack".utf8)

    func installer(http: FakeHTTPClient, signer: String? = Fixture.signer,
                   unpacks channel: String? = "n") -> RuntimeInstaller {
        RuntimeInstaller(store: RuntimeStore(paths: paths, fileSystem: fileSystem, clock: ManualClock()), http: http,
                         extractor: FakeExtractor(fileSystem: fileSystem, channel: channel),
                         signatures: FakeSignatures(fingerprint: signer),
                         workDirectory: paths.caches.appending(path: "runtime", directoryHint: .isDirectory))
    }

    @Test func aPackHoldingAnotherChannelsHostIsRefused() async throws {
        let http = FakeHTTPClient(fileSystem: fileSystem)
        http.respond(to: manifest.url, with: pack)
        await #expect(throws: RuntimeInstallError.channelMismatch(
            expected: .n, actual: #"Info.plist's WarzagRuntimeChannel is "x", not n"#)) {
            _ = try await installer(http: http, unpacks: "x").install(manifest)
        }
        #expect(try RuntimeStore(paths: paths, fileSystem: fileSystem).load().current == nil)
        // A host that says nothing about its channel (no key, no readable loader) is not installed either.
        await #expect(throws: RuntimeInstallError.self) {
            _ = try await installer(http: http, unpacks: nil).install(manifest)
        }
        #expect(try RuntimeStore(paths: paths, fileSystem: fileSystem).load().current == nil)
    }

    var manifest: RuntimeManifest {
        Fixture.manifest(sha256: SHA256.hash(data: pack).map { String(format: "%02x", $0) }.joined(),
                         size: Int64(pack.count))
    }

    @Test func downloadVerifyUnpackAndActivate() async throws {
        let http = FakeHTTPClient(fileSystem: fileSystem)
        http.respond(to: manifest.url, with: pack)
        let state = try await installer(http: http).install(manifest)
        #expect(state.current?.id == "n-0.1.0")
        #expect(fileSystem.text(at: paths.gameHost(.n, version: "0.1.0").appending(path: "Contents/MacOS/wine").plainPath)
            == "unpacked")
        #expect(http.requests == [manifest.url])
        #expect(!fileSystem.allFiles.contains { $0.contains("/Caches/Warzag/runtime/") })
        #expect(!fileSystem.allFiles.contains { $0.hasPrefix(paths.runtimeStaging.plainPath + "/") })
    }

    @Test func anIntactPackIsNotDownloadedAgain() async throws {
        fileSystem.addFile(paths.caches.appending(path: "runtime/n-0.1.0.aar").plainPath, pack)
        let http = FakeHTTPClient(fileSystem: fileSystem)
        _ = try await installer(http: http).install(manifest)
        #expect(http.requests.isEmpty)
    }

    @Test func aCorruptDownloadIsDiscarded() async {
        let http = FakeHTTPClient(fileSystem: fileSystem)
        http.respond(to: manifest.url, with: Data("not the pack!!".utf8))
        await #expect(throws: DigestMismatch.self) { _ = try await installer(http: http).install(manifest) }
        #expect(fileSystem.allFiles.isEmpty)
    }

    @Test func aPackSignedBySomeoneElseIsNotActivated() async throws {
        let http = FakeHTTPClient(fileSystem: fileSystem)
        http.respond(to: manifest.url, with: pack)
        await #expect(throws: RuntimeInstallError.signerMismatch(expected: Fixture.signer, actual: nil)) {
            _ = try await installer(http: http, signer: nil).install(manifest)
        }
        #expect(try RuntimeStore(paths: paths, fileSystem: fileSystem).load().current == nil)
    }

    @Test func aRolledBackRuntimeIsOnlyReinstalledOnRequest() async throws {
        // n-0.1.0 failed on this Mac and was rolled back to n-0.0.9; the manifest still offers n-0.1.0.
        let store = RuntimeStore(paths: paths, fileSystem: fileSystem, clock: ManualClock())
        for (id, version) in [("n-0.0.9", "0.0.9"), ("n-0.1.0", "0.1.0")] {
            let staged = paths.caches.appending(path: "seed-\(version)/Warzag.app", directoryHint: .isDirectory)
            fileSystem.addFile(staged.appending(path: "Contents/MacOS/wine").plainPath, id)
            try store.install(stagedHost: staged, for: Fixture.manifest(id: id, version: version))
        }
        #expect(try store.rollback().rolledBack == ["n-0.1.0"])

        let http = FakeHTTPClient(fileSystem: fileSystem)
        http.respond(to: manifest.url, with: pack)
        await #expect(throws: RuntimeInstallError.rolledBack("n-0.1.0")) {
            _ = try await installer(http: http).install(manifest)
        }
        #expect(http.requests.isEmpty)
        #expect(try store.load().current?.id == "n-0.0.9")

        let state = try await installer(http: http).install(manifest, allowRolledBack: true)
        #expect(state.current?.id == "n-0.1.0")
        #expect(state.previous?.id == "n-0.0.9")
        #expect(state.rolledBack.isEmpty)
    }

    @Test func theKillSwitchBlocksInstalls() async {
        var blocked = manifest
        blocked.killSwitch = KillSwitch(level: .blockInstall, message: "Warframe 44.2 breaks this runtime")
        let http = FakeHTTPClient(fileSystem: fileSystem)
        await #expect(throws: RuntimeInstallError.blocked("Warframe 44.2 breaks this runtime")) {
            _ = try await installer(http: http).install(blocked)
        }
        #expect(http.requests.isEmpty)
    }

    @Test func stagingVerifiesAndActivatingSwitches() async throws {
        let http = FakeHTTPClient(fileSystem: fileSystem)
        http.respond(to: manifest.url, with: pack)
        let installer = installer(http: http)
        let staged = try await installer.stage(manifest)
        #expect(staged == installer.stagedHost(for: manifest))
        // Unpacked inside the store, out of Spotlight, never into the download cache.
        #expect(staged.plainPath == paths.runtimeStaging.plainPath + "/n-0.1.0/Warzag.app")
        #expect(fileSystem.text(at: staged.appending(path: "Contents/MacOS/wine").plainPath) == "unpacked")
        // Staged is not installed: nothing is current yet.
        #expect(try RuntimeStore(paths: paths, fileSystem: fileSystem).load().current == nil)

        let state = try installer.activate(manifest)
        #expect(state.current?.id == "n-0.1.0")
        #expect(fileSystem.text(at: paths.gameHost(.n, version: "0.1.0").appending(path: "Contents/MacOS/wine").plainPath)
            == "unpacked")
        #expect(!fileSystem.allFiles.contains { $0.contains("/Caches/Warzag/runtime/") })
    }

    @Test func activatingChecksTheStagedHostAgain() async throws {
        let http = FakeHTTPClient(fileSystem: fileSystem)
        http.respond(to: manifest.url, with: pack)
        // Nothing staged (a crash before the unpack finished, or the staging was cleaned up): nothing is activated.
        #expect(throws: RuntimeStoreError.stagedHostMissing) { try installer(http: http).activate(manifest) }

        try await installer(http: http).stage(manifest)
        // What sits in the staging folder no longer carries the manifest's signature (a half-unpacked tree, say).
        #expect(throws: RuntimeInstallError.signerMismatch(expected: Fixture.signer, actual: nil)) {
            try installer(http: http, signer: nil).activate(manifest)
        }
        #expect(try RuntimeStore(paths: paths, fileSystem: fileSystem).load().current == nil)
        #expect(!fileSystem.allFiles.contains { $0.hasPrefix(paths.runtimeStaging.plainPath + "/") },
                "a refused staging tree is removed")
    }

    @Test func aFailedStagingLeavesNothingBehind() async throws {
        let http = FakeHTTPClient(fileSystem: fileSystem)
        http.respond(to: manifest.url, with: pack)
        await #expect(throws: RuntimeInstallError.self) { try await installer(http: http, unpacks: "x").stage(manifest) }
        #expect(!fileSystem.allFiles.contains { $0.hasPrefix(paths.runtimeStaging.plainPath + "/") })
        // The verified pack stays for the next try.
        #expect(fileSystem.fileExists(at: installer(http: http).packFile(for: manifest)))
    }

    @Test func theAppleArchiveExtractorRunsAA() async throws {
        let runner = RecordingProcessRunner()
        try await AppleArchiveExtractor(runner: runner).extract(URL(filePath: "/c/r.aar"), into: URL(filePath: "/c/staging"))
        #expect(runner.commands == [Command("/usr/bin/aa", ["extract", "-i", "/c/r.aar", "-d", "/c/staging"])])
    }
}

/// The in-memory file system with a rename that fails (permissions, say).
final class RenameFailingFileSystem: FileSystem {
    let base: InMemoryFileSystem

    init(base: InMemoryFileSystem) {
        self.base = base
    }

    func moveItem(at source: URL, to destination: URL) throws { throw CocoaError(.fileWriteNoPermission) }
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
    func removeItem(at url: URL) throws { try base.removeItem(at: url) }
    func isWritableDirectory(at url: URL) -> Bool { base.isWritableDirectory(at: url) }
    func volumeInfo(for url: URL) throws -> VolumeInfo { try base.volumeInfo(for: url) }
}

/// The store on the real file system, under a home whose path starts with /private (temp homes for QA and tests).
@Suite struct RuntimeStoreOnDiskTests {
    @Test func pruningKeepsTheActivatedRuntimeUnderAPrivateHome() throws {
        // `standardizedFileURL` turns an existing "/private/tmp/x" into "/tmp/x"; pruning must not depend on it.
        // As in `warzagctl --home <new dir>`: the paths are made before the home exists, so they keep "/private".
        let home = URL(filePath: "/private/tmp/warzag-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        let paths = WarzagPaths(home: home, userCacheDirectory: nil)
        #expect(paths.home.plainPath.hasPrefix("/private/"))
        defer { try? FileManager.default.removeItem(at: home) }
        let fileSystem = LocalFileSystem()
        try fileSystem.createDirectory(at: home)
        let store = RuntimeStore(paths: paths, fileSystem: fileSystem, clock: ManualClock())

        for version in ["0.1.0", "0.2.0", "0.3.0"] {
            let staged = paths.caches.appending(path: "staging-\(version)/Warzag.app", directoryHint: .isDirectory)
            try fileSystem.writeAtomically(Data(version.utf8), to: staged.appending(path: "Contents/MacOS/wine"))
            try store.install(stagedHost: staged, for: Fixture.manifest(id: "n-\(version)", version: version))
            #expect(try store.activeHost() != nil)
        }
        let kept = try fileSystem.contentsOfDirectory(at: paths.runtimeDirectory(.n)).map(\.lastPathComponent).sorted()
        #expect(kept == ["0.2.0", "0.3.0"])
        #expect(try store.load().previous?.id == "n-0.2.0")
    }
}
