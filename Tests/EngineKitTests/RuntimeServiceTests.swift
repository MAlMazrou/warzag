import CryptoKit
import Foundation
import Testing
import RuntimeKit
import WarzagCore
import WarzagTestSupport
import WineKit
@testable import EngineKit

@Suite struct DevelopmentRuntimeTests {
    let fixture = EngineFixture()
    var runtime: RuntimeService { fixture.engine.runtime }
    var devHost: URL { URL(filePath: EngineFixture.devHost, directoryHint: .isDirectory) }

    @Test func useLocalClonesTheBuildAndActivatesIt() throws {
        fixture.makeHost()
        let state = try runtime.useLocal(devHost)
        let stamp = RuntimeService.timestamp(fixture.clock.now)
        let current = try #require(state.current)
        #expect(current.id == "n-dev-\(stamp)")
        #expect(current.version == "0.1.0-dev.\(stamp)")
        #expect(current.signerFingerprint == RuntimeSigner.adHoc)
        #expect(current.channel == .n)

        let host = fixture.paths.gameHost(.n, version: current.version)
        #expect(fixture.fileSystem.text(at: host.plainPath + "/Contents/MacOS/wine") == "wine loader 0.1.0")
        #expect(fixture.fileSystem.isExecutableFile(at: host.appending(path: "Contents/MacOS/wineserver")))
        #expect(fixture.fileSystem.text(at: host.plainPath + "/Contents/share/warzag/bridge/steam.reg") == EngineFixture.steamReg)
        // The signature was checked on the copy that was activated, cloned inside the store (out of Spotlight, never
        // in the download cache), and the staging tree is gone.
        #expect(fixture.signatures.bundles == [fixture.paths.runtimeStaging.plainPath + "/\(current.id)/Warzag.app"])
        #expect(try fixture.fileSystem.contentsOfDirectory(at: fixture.paths.runtimeStaging).isEmpty)
        #expect(!fixture.fileSystem.fileExists(at: runtime.workDirectory))

        let status = try runtime.status()
        #expect(status.current?.development == true)
        #expect(status.current?.onDisk == true)
        #expect(try runtime.active() == ActiveRuntime(runtime: current, host: GameHost(bundle: host, channel: .n)))
    }

    @Test func eachRegistrationIsANewVersionAndOnlyNMinusOneIsKept() throws {
        fixture.makeHost(version: "0.1.0")
        let first = try #require(try runtime.useLocal(devHost).current)
        fixture.clock.advance(by: 60)
        fixture.makeHost(version: "0.1.1")
        let second = try runtime.useLocal(devHost)
        #expect(second.previous?.id == first.id)
        fixture.clock.advance(by: 60)
        let third = try runtime.useLocal(devHost)
        #expect(third.previous?.id == second.current?.id)
        let versions = try fixture.fileSystem.contentsOfDirectory(at: fixture.paths.runtimeDirectory(.n))
            .map(\.lastPathComponent)
        #expect(versions == [second.current!.version, third.current!.version])
        // Registering twice in the same second changes nothing.
        #expect(try runtime.useLocal(devHost) == third)
    }

    @Test func useLocalRefusesWhatIsNotAWarzagHost() throws {
        fixture.makeHost(identifier: "org.winehq.wine")
        #expect(throws: RuntimeServiceError.notAGameHost("bundle identifier is org.winehq.wine, not com.warzag.gamehost")) {
            try runtime.useLocal(devHost)
        }
        #expect(throws: RuntimeServiceError.notAGameHost("/Users/tenno/nowhere/Warzag.app does not exist")) {
            try runtime.useLocal(URL(filePath: "/Users/tenno/nowhere/Warzag.app"))
        }
        fixture.makeHost()
        try fixture.fileSystem.removeItem(at: devHost.appending(path: "Contents/MacOS/wineserver"))
        #expect(throws: RuntimeServiceError.notAGameHost("Contents/MacOS/wineserver is missing")) {
            try runtime.useLocal(devHost)
        }
        #expect(try runtime.store.load().current == nil)
    }

    @Test func useLocalNeedsAValidSignature() throws {
        fixture.makeHost()
        fixture.signatures.set(.broken)
        #expect(throws: RuntimeServiceError.self) { try runtime.useLocal(devHost) }
        #expect(try runtime.store.load().current == nil)
        #expect(!fixture.fileSystem.fileExists(at: fixture.paths.runtimeDirectory(.n)))
        #expect(try fixture.fileSystem.contentsOfDirectory(at: fixture.paths.runtimeStaging).isEmpty)
        fixture.signatures.set(.certificate(String(repeating: "cd", count: 32)))
        #expect(try runtime.useLocal(devHost).current?.signerFingerprint == String(repeating: "cd", count: 32))
    }

    @Test func activeNeedsARuntimeOnDisk() throws {
        #expect(throws: RuntimeServiceError.noRuntime) { try runtime.active() }
        let state = try fixture.registerDevelopmentRuntime()
        let current = try #require(state.current)
        try fixture.fileSystem.removeItem(at: fixture.paths.runtimeVersionDirectory(.n, version: current.version))
        #expect(throws: RuntimeServiceError.runtimeMissing(
            id: current.id, path: fixture.paths.gameHost(.n, version: current.version).plainPath)) {
            try runtime.active()
        }
        #expect(try runtime.status().current?.onDisk == false)
    }

    @Test func rollbackReturnsToThePreviousRegistration() throws {
        let first = try #require(try fixture.registerDevelopmentRuntime().current)
        fixture.clock.advance(by: 60)
        let second = try #require(try fixture.registerDevelopmentRuntime(version: "0.2.0").current)
        let state = try runtime.rollback()
        #expect(state.current?.id == first.id)
        #expect(state.rolledBack == [second.id])
        #expect(throws: RuntimeStoreError.noPreviousRuntime) { try runtime.rollback() }
    }
}

@Suite struct RuntimePackTests {
    let fixture = EngineFixture()
    var runtime: RuntimeService { fixture.engine.runtime }

    func install(_ data: Data, pack: PackSource, allowRolledBack: Bool = false) async throws -> RuntimeStoreState {
        let trust = try RuntimeTrust.explicitKey(EngineFixture.publicKey, for: data)
        return try await runtime.install(signedManifest: data, pack: pack, trust: trust, appVersion: "0.1.0",
                                         macOSVersion: "26.5.1", allowRolledBack: allowRolledBack)
    }

    @Test func aLocalAdHocPackInstallsAndBecomesCurrent() async throws {
        let (pack, manifest) = try fixture.pack(version: "0.2.0")
        let state = try await install(try EngineFixture.signed(manifest), pack: .file(pack))
        #expect(state.current?.id == "n-0.2.0")
        #expect(state.current?.signerFingerprint == "adhoc")
        #expect(state.lastSerial == 42)
        let host = fixture.paths.gameHost(.n, version: "0.2.0")
        #expect(fixture.fileSystem.text(at: host.plainPath + "/Contents/MacOS/wine") == "wine loader 0.2.0")
        #expect(fixture.http.requests.isEmpty)
        // The unpacked host's signature was checked where it was unpacked, inside the store; the copied pack and the
        // staging tree are gone.
        #expect(fixture.signatures.bundles == [fixture.paths.runtimeStaging.plainPath + "/n-0.2.0/Warzag.app"])
        #expect(try fixture.fileSystem.contentsOfDirectory(at: runtime.workDirectory).isEmpty)
        #expect(try fixture.fileSystem.contentsOfDirectory(at: fixture.paths.runtimeStaging).isEmpty)
        #expect(fixture.fileSystem.fileExists(at: pack))
    }

    @Test func anInstalledPackKeepsTheDevelopmentRuntimeAsNMinusOne() async throws {
        let development = try #require(try fixture.registerDevelopmentRuntime().current)
        let (pack, manifest) = try fixture.pack(version: "0.2.0")
        let state = try await install(try EngineFixture.signed(manifest), pack: .file(pack))
        #expect(state.previous?.id == development.id)
        #expect(try runtime.rollback().current?.id == development.id)
    }

    @Test func aPackThatIsNotThePublishedFileIsRefused() async throws {
        let (pack, manifest) = try fixture.pack(version: "0.2.0")
        fixture.fileSystem.addFile(pack.plainPath, "warzag-pack 0.2.X")
        await #expect(throws: DigestMismatch.self) {
            _ = try await install(try EngineFixture.signed(manifest), pack: .file(pack))
        }
        #expect(try runtime.store.load().current == nil)
        #expect(fixture.http.requests.isEmpty)
    }

    @Test func theHostMustBeSignedByTheSignerTheManifestNames() async throws {
        let certificate = String(repeating: "ab", count: 32)
        let (pack, manifest) = try fixture.pack(version: "0.2.0", signer: certificate)
        await #expect(throws: RuntimeInstallError.signerMismatch(expected: certificate, actual: "adhoc")) {
            _ = try await install(try EngineFixture.signed(manifest), pack: .file(pack))
        }
        fixture.signatures.set(.certificate(certificate))
        #expect(try await install(try EngineFixture.signed(manifest), pack: .file(pack)).current?.id == "n-0.2.0")
    }

    @Test func manifestsFromAnotherKeyOrOlderSerialsAreRejected() async throws {
        let (pack, manifest) = try fixture.pack(version: "0.2.0")
        let forged = try EngineFixture.signed(manifest, with: EngineFixture.strangerKey)
        #expect(throws: RuntimeServiceError.manifestRejected(.badSignature)) {
            _ = try RuntimeTrust.explicitKey(EngineFixture.publicKey, for: forged)
        }
        _ = try await install(try EngineFixture.signed(manifest), pack: .file(pack))
        let (olderPack, older) = try fixture.pack(version: "0.1.9", serial: 41)
        await #expect(throws: RuntimeServiceError.manifestRejected(.olderSerial(received: 41, accepted: 42))) {
            _ = try await install(try EngineFixture.signed(older), pack: .file(olderPack))
        }
    }

    @Test func revocationsInANewManifestApply() async throws {
        let (firstPack, first) = try fixture.pack(version: "0.2.0")
        _ = try await install(try EngineFixture.signed(first), pack: .file(firstPack))
        let (secondPack, second) = try fixture.pack(version: "0.3.0", serial: 43)
        _ = try await install(try EngineFixture.signed(second), pack: .file(secondPack))
        var third = try fixture.pack(version: "0.3.1", serial: 44)
        third.manifest.revoked = ["n-0.3.0"]
        let state = try await install(try EngineFixture.signed(third.manifest), pack: .file(third.pack))
        #expect(state.current?.id == "n-0.3.1")
        #expect(state.revoked == ["n-0.3.0"])
        // n-0.3.0 was current when the revocation arrived: it rolled back to the previous runtime first, then 0.3.1
        // was installed.
        #expect(state.previous?.id == "n-0.2.0")
    }

    @Test func packsDownloadFromTheManifestOrAMirror() async throws {
        let (pack, manifest) = try fixture.pack(version: "0.2.0")
        let bytes = try #require(fixture.fileSystem.data(at: pack.plainPath))
        fixture.http.respond(to: manifest.url, with: bytes)
        #expect(try await install(try EngineFixture.signed(manifest), pack: .manifestURL).current?.id == "n-0.2.0")
        #expect(fixture.http.requests == [manifest.url])

        let mirror = URL(string: "https://mirror.example.org/WarzagRuntime-n-0.3.0.aar")!
        let (mirrored, next) = try fixture.pack(version: "0.3.0", serial: 43)
        fixture.http.respond(to: mirror, with: try #require(fixture.fileSystem.data(at: mirrored.plainPath)))
        #expect(try await install(try EngineFixture.signed(next), pack: .url(mirror)).current?.id == "n-0.3.0")
        #expect(fixture.http.requests.last == mirror)

        let bad = URL(string: "https://mirror.example.org/corrupt.aar")!
        let (_, last) = try fixture.pack(version: "0.4.0", serial: 44)
        fixture.http.respond(to: bad, with: Data("warzag-pack 0.4.X".utf8))
        await #expect(throws: DigestMismatch.self) {
            _ = try await install(try EngineFixture.signed(last), pack: .url(bad))
        }
        #expect(!fixture.fileSystem.fileExists(at: runtime.workDirectory.appending(path: "n-0.4.0.aar")))
        #expect(try runtime.store.load().current?.id == "n-0.3.0")
    }

    @Test func aRolledBackRuntimeNeedsAnExplicitReinstall() async throws {
        let (firstPack, first) = try fixture.pack(version: "0.2.0")
        _ = try await install(try EngineFixture.signed(first), pack: .file(firstPack))
        let (secondPack, second) = try fixture.pack(version: "0.3.0", serial: 43)
        let signed = try EngineFixture.signed(second)
        _ = try await install(signed, pack: .file(secondPack))
        _ = try runtime.rollback()
        await #expect(throws: RuntimeInstallError.rolledBack("n-0.3.0")) {
            _ = try await install(signed, pack: .file(secondPack))
        }
        #expect(try await install(signed, pack: .file(secondPack), allowRolledBack: true).current?.id == "n-0.3.0")
    }

    /// `warzagctl runtime install` of a runtime that would be refused anyway: refused before its pack is downloaded
    /// (from the manifest's URL or a mirror) or copied.
    @Test func aPausedOrRolledBackRuntimeIsRefusedBeforeItsPackIsFetched() async throws {
        var paused = try fixture.pack(version: "0.2.0")
        paused.manifest.killSwitch = KillSwitch(level: .blockInstall)
        let mirror = URL(string: "https://mirror.example.org/WarzagRuntime-n-0.2.0.aar")!
        let bytes = try #require(fixture.fileSystem.data(at: paused.pack.plainPath))
        fixture.http.respond(to: paused.manifest.url, with: bytes)
        fixture.http.respond(to: mirror, with: bytes)
        let signedPaused = try EngineFixture.signed(paused.manifest)
        for source in [PackSource.manifestURL, .url(mirror), .file(paused.pack)] {
            await #expect(throws: RuntimeInstallError.blocked(nil)) {
                _ = try await install(signedPaused, pack: source)
            }
        }
        #expect(fixture.http.requests.isEmpty)
        #expect(!fixture.fileSystem.fileExists(at: runtime.packFile(for: paused.manifest)))

        let (firstPack, first) = try fixture.pack(version: "0.3.0", serial: 43)
        _ = try await install(try EngineFixture.signed(first), pack: .file(firstPack))
        let (secondPack, second) = try fixture.pack(version: "0.4.0", serial: 44)
        fixture.http.respond(to: second.url, with: try #require(fixture.fileSystem.data(at: secondPack.plainPath)))
        let signed = try EngineFixture.signed(second)
        _ = try await install(signed, pack: .manifestURL)
        _ = try runtime.rollback()
        let requests = fixture.http.requests
        await #expect(throws: RuntimeInstallError.rolledBack("n-0.4.0")) {
            _ = try await install(signed, pack: .manifestURL)
        }
        #expect(fixture.http.requests == requests)
        // --reinstall downloads it again.
        #expect(try await install(signed, pack: .manifestURL, allowRolledBack: true).current?.id == "n-0.4.0")
        #expect(fixture.http.requests == requests + [second.url])
    }
}

@Suite struct RuntimeTrustTests {
    @Test func theExplicitKeyTrustsTheEnvelopesKeyIdAndTheNamedSigner() throws {
        let fixture = EngineFixture()
        let (_, manifest) = try fixture.pack(version: "0.2.0", signer: String(repeating: "AB", count: 32))
        let trust = try RuntimeTrust.explicitKey(EngineFixture.publicKey,
                                                 for: try EngineFixture.signed(manifest, keyId: "rt-2027a"))
        // The pins, plus the explicit key under the envelope's key id and the signer its manifest names.
        #expect(trust.publicKeys == RuntimeTrust.pinned.publicKeys.merging(["rt-2027a": EngineFixture.publicKey]) { $1 })
        #expect(trust.signerFingerprints == RuntimeTrust.pinned.signerFingerprints.union([String(repeating: "ab", count: 32)]))
    }

    @Test func malformedInputsAreRejected() throws {
        #expect(throws: RuntimeServiceError.invalidPublicKey) {
            _ = try RuntimeTrust.explicitKey(Data(repeating: 1, count: 31), for: Data())
        }
        #expect(throws: RuntimeServiceError.manifestRejected(.malformedEnvelope)) {
            _ = try RuntimeTrust.explicitKey(EngineFixture.publicKey, for: Data("not json".utf8))
        }
        // Nothing was added to the pins: the release key and, in this debug build, the DEV key.
        #expect(RuntimeTrust.pinned.publicKeys.keys.sorted()
            == [RuntimeTrust.releaseKeyID, RuntimeTrust.developmentKeyID].sorted())
        #expect(RuntimeTrust.pinned.signerFingerprints == [RuntimeTrust.projectCertificate])
    }

    @Test func adHocIsOnlyEverANameInTheManifest() throws {
        // A bundle whose signature is broken still fails; only "no certificate" becomes "adhoc".
        let signatures = FakeSignatures()
        #expect(try NamedSignerInspector(base: signatures).signerFingerprint(of: URL(filePath: "/a.app")) == "adhoc")
        signatures.set(.broken)
        #expect(throws: BrokenSignature()) {
            _ = try NamedSignerInspector(base: signatures).signerFingerprint(of: URL(filePath: "/a.app"))
        }
    }
}
