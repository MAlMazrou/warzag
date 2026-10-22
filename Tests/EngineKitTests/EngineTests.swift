import CryptoKit
import Foundation
import Testing
import RuntimeKit
import WarzagCore
import WarzagTestSupport
import WineKit
@testable import EngineKit
@testable import warzagctl

@Suite struct EngineTests {
    let fixture = EngineFixture()
    var prefix: PrefixService { fixture.engine.prefix }
    var root: String { fixture.paths.prefix(for: .n).plainPath }
    let macDriver = MacDriverSettings(retinaMode: false)

    @Test func useLocalReadsTheChannelFromTheHost() throws {
        fixture.makeHost()
        let state = try fixture.engine.runtime.useLocal(URL(filePath: EngineFixture.devHost, directoryHint: .isDirectory))
        let current = try #require(state.current)
        let stamp = RuntimeService.timestamp(fixture.clock.now)
        #expect(current.id == "n-dev-\(stamp)")
        #expect(current.channel == .n)
        let host = fixture.paths.gameHost(.n, version: current.version)
        #expect(host.plainPath.contains("/Runtimes.noindex/n/"))
        #expect(try fixture.engine.runtime.active().host == GameHost(bundle: host, channel: .n))
    }

    @Test func withoutTheKeyTheLoaderTells() throws {
        let bundle = URL(filePath: EngineFixture.devHost, directoryHint: .isDirectory)
        fixture.makeHost(channel: nil, loader: .arm64)
        #expect(try fixture.engine.runtime.channel(ofLocalHost: bundle) == .n)
        fixture.makeHost(channel: nil, loader: .x86_64)
        #expect(throws: RuntimeServiceError.notAGameHost("Contents/MacOS/wine is x86_64, not arm64")) {
            try fixture.engine.runtime.channel(ofLocalHost: bundle)
        }
        // Neither: refused.
        fixture.makeHost(channel: nil)
        #expect(throws: RuntimeServiceError.self) { try fixture.engine.runtime.channel(ofLocalHost: bundle) }
    }

    @Test func aHostDeclaringAnotherChannelIsNotAWarzagHost() throws {
        fixture.makeHost(channel: "x", loader: .arm64)
        #expect(throws: RuntimeServiceError.notAGameHost(#"Info.plist's WarzagRuntimeChannel is "x", not n"#)) {
            try fixture.engine.runtime.useLocal(URL(filePath: EngineFixture.devHost))
        }
    }

    @Test func aNewPrefixGetsTheEnginesSwitches() async throws {
        try fixture.registerDevelopmentRuntime()
        let report = try await prefix.create(macDriver: macDriver)
        #expect(report.prefix == root)
        #expect(report.channel == .n)
        #expect(report.filesInstalled == 7)
        #expect(report.log == fixture.paths.logs.plainPath + "/prefix-n.log")
        #expect(fixture.runner.commandLines.first == "wine wineboot --init")
        for command in fixture.runner.commands {
            let environment = try #require(command.environment)
            #expect(environment["WINEPREFIX"] == root)
            #expect(environment["WINEARCH"] == nil && environment["WINEMSYNC"] == nil)
            #expect(environment["NEUTRON_MSYNC"] == "0" && environment["NEUTRON_NATIVE_FULLSCREEN"] == "0")
            #expect(command.timeout != nil)
        }
    }

    @Test func placeholdersComeFromTheARM64DirectoriesIntoSystem32Only() async throws {
        try fixture.registerDevelopmentRuntime()
        _ = try await prefix.create(macDriver: macDriver)
        let system32 = root + "/drive_c/windows/system32"
        #expect(fixture.fileSystem.text(at: system32 + "/winemetal.dll") == "dxmt aarch64 winemetal.dll 0.1.0")
        #expect(fixture.fileSystem.text(at: system32 + "/nvapi64.dll") == "dxmt aarch64 nvapi64.dll 0.1.0")
        #expect(fixture.fileSystem.text(at: system32 + "/nvngx.dll") == "dxmt aarch64 nvngx.dll 0.1.0")
        #expect(fixture.fileSystem.text(at: system32 + "/lsteamclient.dll") == "lsteamclient 0.1.0")
        #expect(fixture.fileSystem.text(at: root + "/drive_c/windows/syswow64/winemetal.dll") == nil)
        #expect(fixture.fileSystem.text(at: root + "/drive_c/Program Files (x86)/Steam/steam.exe") == "steam.exe 0.1.0")
    }

    @Test func doctorPasses() async throws {
        try fixture.registerDevelopmentRuntime()
        _ = try await prefix.create(macDriver: macDriver)
        let report = await prefix.doctor()
        #expect(report.channel == .n)
        #expect(report.checks.map(\.name) == PrefixService.checkNames)
        #expect(report.passed, "\(report.lines)")
        #expect(report.checks.first { $0.name == "dxmt" }?.detail == "3 files match the runtime")
    }

    @Test func aProgramPastItsDeadlineStopsThePrefixToo() async throws {
        try fixture.registerDevelopmentRuntime()
        _ = try await prefix.create(macDriver: macDriver)
        fixture.wine.hang { $0.arguments.first?.hasSuffix("wz-d3d11-smoke.exe") == true }
        let log = fixture.paths.logs.plainPath + "/prefix-n.log"
        await #expect(throws: PrefixError.toolTimedOut(command: "wz-d3d11-smoke.exe", seconds: 30, log: log)) {
            _ = try await prefix.runProgram("/Users/tenno/src/warzag/build/pe/wz-d3d11-smoke.exe",
                                            renderer: RendererOptions(renderer: .dxmt), timeout: .seconds(30))
        }
        // What the program started may still run in the prefix: stopped as after a Wine tool's deadline.
        #expect(fixture.runner.commandLines.last == "wineserver -k")
        #expect(fixture.fileSystem.text(at: log)?
            .contains("warzag: wz-d3d11-smoke.exe did not finish within 30 s and was stopped; stopping the prefix") == true)
    }

    @Test func aPackInstallsUnderRuntimesN() async throws {
        let data = Data("warzag-pack 0.2.0".utf8)
        let pack = URL(filePath: "/Users/tenno/Downloads/WarzagRuntime-n-0.2.0.aar")
        fixture.fileSystem.addFile(pack.plainPath, data)
        let manifest = RuntimeManifest(
            serial: 50, expires: fixture.clock.now.addingTimeInterval(86_400), id: "n-0.2.0", version: "0.2.0",
            channel: .n, arch: "arm64", minLauncher: "0.1.0", minMacOS: "15.0",
            url: URL(string: "https://runtime.example.org/WarzagRuntime-n-0.2.0.aar")!, size: Int64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), signerFingerprint: "adhoc")
        let signed = try EngineFixture.signed(manifest)
        let state = try await fixture.engine.runtime.install(
            signedManifest: signed, pack: .file(pack), trust: try RuntimeTrust.explicitKey(EngineFixture.publicKey, for: signed),
            appVersion: "0.1.0", macOSVersion: "26.5.1")
        #expect(state.current?.channel == .n)
        #expect(try fixture.engine.runtime.active().host.channel == .n)
        #expect(try fixture.engine.runtime.active().host.bundle.plainPath
            == fixture.paths.applicationSupport.plainPath + "/Runtimes.noindex/n/0.2.0/Warzag.app")
    }
}

@Suite struct PrefixToolDeadlineTests {
    let fixture = EngineFixture()

    @Test func aHungWinebootIsStoppedReportedAndThePrefixStopped() async throws {
        try fixture.registerDevelopmentRuntime()
        fixture.wine.hang { $0.arguments == ["wineboot", "--init"] }
        let log = fixture.paths.logs.plainPath + "/prefix-n.log"
        await #expect(throws: PrefixError.toolTimedOut(command: "wineboot --init", seconds: 600, log: log)) {
            _ = try await fixture.engine.prefix.create(macDriver: MacDriverSettings(retinaMode: false))
        }
        #expect(fixture.runner.commandLines.suffix(2) == ["wine wineboot --init", "wineserver -k"])
        #expect(fixture.fileSystem.text(at: log)?.contains(
            "warzag: wineboot --init did not finish within 600 s and was stopped; stopping the prefix") == true)
    }

    @Test func aHungServerWaitIsReportedToo() async throws {
        try fixture.registerDevelopmentRuntime()
        fixture.wine.hang { $0.arguments == ["-w"] }
        await #expect(throws: PrefixError.self) {
            _ = try await fixture.engine.prefix.create(macDriver: MacDriverSettings(retinaMode: false))
        }
        #expect(fixture.runner.commandLines.last == "wineserver -k")
        #expect(fixture.runner.commands.allSatisfy { $0.timeout != nil })
    }

    @Test func theMessageSaysWhatHappened() {
        #expect(PrefixError.toolTimedOut(command: "reg import x.reg", seconds: 120, log: "/l").description
            == "reg import x.reg did not finish within 120 s; it and the prefix's other processes were stopped; see /l")
    }
}

@Suite struct RuntimeVerificationTests {
    let fixture = EngineFixture()

    @Test func theActiveHostMustStillVerifyAndKeepItsSigner() throws {
        try fixture.registerDevelopmentRuntime()
        let runtime = fixture.engine.runtime
        let active = try runtime.active()
        func verify() throws -> String {
            try runtime.verifySignature(of: active.host, expectedSigner: active.runtime.signerFingerprint)
        }
        #expect(try verify() == "adhoc")
        fixture.signatures.set(.broken)
        #expect(throws: RuntimeServiceError.self) { _ = try verify() }
        let other = String(repeating: "ab", count: 32)
        fixture.signatures.set(.certificate(other))
        #expect(throws: RuntimeServiceError.signerChanged(expected: "adhoc", actual: other)) { _ = try verify() }
    }

    @Test func releaseBuildsTrustOnlyTheReleaseKeyAndTheProjectCertificate() throws {
        let release = try Curve25519.Signing.PublicKey(
            rawRepresentation: try #require(Data(base64Encoded: RuntimeTrust.releasePublicKey)))
        let development = try Curve25519.Signing.PublicKey(
            rawRepresentation: try #require(Data(base64Encoded: RuntimeTrust.developmentPublicKey)))
        #expect(ManifestTrust.keyID(for: release) == RuntimeTrust.releaseKeyID)
        #expect(ManifestTrust.keyID(for: development) == RuntimeTrust.developmentKeyID)
        // What App/make-app.sh ships (-c release): the release key, never the DEV key.
        #expect(RuntimeTrust.release.publicKeys == [RuntimeTrust.releaseKeyID: release.rawRepresentation])
        #expect(RuntimeTrust.pinned(debugBuild: false).publicKeys == RuntimeTrust.release.publicKeys)
        // Debug builds (swift build, swift test) also take the DEV key.
        #expect(RuntimeTrust.development.publicKeys == [RuntimeTrust.releaseKeyID: release.rawRepresentation,
                                                        RuntimeTrust.developmentKeyID: development.rawRepresentation])
        #expect(RuntimeTrust.pinned(debugBuild: true).publicKeys == RuntimeTrust.development.publicKeys)
        #expect(RuntimeTrust.isDebugBuild, "the tests run in a debug build")
        #expect(RuntimeTrust.pinned.publicKeys == RuntimeTrust.development.publicKeys)
        for trust in [RuntimeTrust.release, RuntimeTrust.development] {
            #expect(trust.signerFingerprints == [RuntimeTrust.projectCertificate])
            #expect(!trust.signerFingerprints.contains(RuntimeSigner.adHoc))
        }
        // The same certificate the signing tools pin, and the release key the repository publishes.
        let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let pinned = try String(contentsOf: repository.appending(path: "tools/sign/project-certificate.sha256"),
                                encoding: .utf8)
        #expect(pinned.hasPrefix(RuntimeTrust.projectCertificate))
        let releaseFile = try String(contentsOf: repository.appending(path: "tools/sign/release-manifest.ed25519.pub"),
                                     encoding: .utf8)
        #expect(releaseFile.trimmingCharacters(in: .whitespacesAndNewlines) == RuntimeTrust.releasePublicKey)
    }

    @Test func developmentTrustExtendsThePins() throws {
        let extra = Curve25519.Signing.PrivateKey().publicKey
        let trust = try RuntimeTrust.extending(publicKeys: [extra.rawRepresentation], signers: ["ADHOC", String(repeating: "C", count: 64)])
        #expect(trust.publicKeys[ManifestTrust.keyID(for: extra)] == extra.rawRepresentation)
        #expect(trust.publicKeys[RuntimeTrust.developmentKeyID] != nil)
        #expect(trust.signerFingerprints == [RuntimeTrust.projectCertificate, "adhoc", String(repeating: "c", count: 64)])
        #expect(throws: RuntimeServiceError.invalidSigner("nobody")) { try RuntimeTrust.extending(signers: ["nobody"]) }
        #expect(throws: RuntimeServiceError.invalidPublicKey) { try RuntimeTrust.extending(publicKeys: [Data([1, 2])]) }
    }

    @Test func aManifestFromThePinnedKeyNeedsNoExplicitKey() async throws {
        // Signed with a stand-in for the DEV key: the pins with that key's public half.
        let (pack, manifest) = try fixture.pack(version: "0.3.0", signer: RuntimeTrust.projectCertificate)
        let signed = try EngineFixture.signed(manifest, keyId: "pinned-test")
        let trust = ManifestTrust(publicKeys: ["pinned-test": EngineFixture.publicKey],
                                  signerFingerprints: [RuntimeTrust.projectCertificate])
        fixture.signatures.set(.certificate(RuntimeTrust.projectCertificate))
        let state = try await fixture.engine.runtime.install(signedManifest: signed, pack: .file(pack), trust: trust,
                                                            appVersion: "0.1.0", macOSVersion: "26.5.1")
        #expect(state.current?.id == "n-0.3.0")
        // The real pins refuse a manifest signed with any other key.
        await #expect(throws: RuntimeServiceError.manifestRejected(.unknownKey("pinned-test"))) {
            _ = try await fixture.engine.runtime.install(signedManifest: signed, pack: .file(pack),
                                                         trust: RuntimeTrust.pinned, appVersion: "0.1.0",
                                                         macOSVersion: "26.5.1", allowRolledBack: true)
        }
    }
}

@Suite struct ChannelCommandsTests {
    let fixture = EngineFixture()

    var environment: EngineCLIEnvironment {
        EngineCLIEnvironment(engine: fixture.engine, macDriver: MacDriverSettings(retinaMode: false),
                             appVersion: "0.1.0", macOSVersion: "26.5.1",
                             currentDirectory: URL(filePath: "/Users/tenno/src/warzag", directoryHint: .isDirectory))
    }

    func run(_ group: String, _ line: String) async -> CommandResult {
        let words = line.split(separator: " ").map(String.init)
        return group == "runtime" ? await EngineCLI.runtime(words, environment: environment)
            : await EngineCLI.prefix(words, environment: environment)
    }

    @Test func useLocalReadsTheHost() async throws {
        fixture.makeHost()
        let local = await run("runtime", "use-local build/n/Warzag.app")
        #expect(local.exitCode == 0)
        #expect(local.stdout.contains("channel n"))
        let status = await run("runtime", "status")
        #expect(status.stdout.contains("channel n"))
        let json = await run("runtime", "status --json")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["runtime"])
        let path = await run("prefix", "path")
        #expect(path.stdout == fixture.paths.prefix(for: .n).plainPath + "\n")
    }

    @Test func prefixRunUsesTheSessionEnvironment() async throws {
        try fixture.registerDevelopmentRuntime()
        _ = await run("prefix", "create")
        let result = await run("prefix", "run --nvext --timeout 30 -- build/pe/wz-d3d11-smoke.exe --frames 60")
        #expect(result.exitCode == 0, "\(result.stderr)")
        #expect(result.stdout.hasPrefix("build/pe/wz-d3d11-smoke.exe exited with status 0"))
        let command = try #require(fixture.wine.programs.last)
        #expect(command.arguments == ["/Users/tenno/src/warzag/build/pe/wz-d3d11-smoke.exe", "--frames", "60"])
        #expect(command.environment?["DXMT_ENABLE_NVEXT"] == "1")
        #expect(command.environment?["WINEDLLPATH_PREPEND"]?.hasSuffix("/Contents/renderers/dxmt") == true)
        #expect(command.environment?["NEUTRON_RAW_MOUSE"] == "1")
        #expect(command.timeout == .seconds(30))
        let missing = await run("prefix", "run")
        #expect(missing.exitCode == 64)
        #expect(missing.stderr.hasPrefix("warzagctl: prefix run needs -- <program> [arguments...]"))
    }
}
