import CryptoKit
import Foundation
import Testing
import RuntimeKit
import WarzagCore
import WineKit
@testable import EngineKit

/// Opt-in tests against the real runtime: `WARZAG_INTEGRATION=1 swift test --filter Integration`. They run in a
/// temporary home and never start Warframe, DE's launcher or Steam; `localRuntimePrefixAndDXMT` opens the GPU smoke
/// test's window. `WARZAG_DEV_HOST` and `WARZAG_PE_DIR` override the nearest build/n/Warzag.app and build/pe.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["WARZAG_INTEGRATION"] == "1"))
struct IntegrationTests {
    static let environment = ProcessInfo.processInfo.environment

    /// The first `build/<relative>` found walking up from this file.
    static func buildArtifact(_ relative: String, override key: String) -> URL? {
        if let path = environment[key] { return URL(filePath: path, directoryHint: .isDirectory) }
        var directory = URL(filePath: #filePath).deletingLastPathComponent()
        while directory.plainPath != "/" {
            let candidate = directory.appending(path: "build/\(relative)", directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: candidate.plainPath) { return candidate }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "warzag-integration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    @Test func localRuntimePrefixAndDXMT() async throws {
        let devHost = try #require(Self.buildArtifact("n/Warzag.app", override: "WARZAG_DEV_HOST"),
                                   "no runtime build (runtime/n/make-host.sh) found")
        let smoke = try #require(Self.buildArtifact("pe", override: "WARZAG_PE_DIR"), "no build/pe (make -C qa/pe)")
            .appending(path: "wz-d3d11-smoke.exe")
        let home = try temporaryHome()
        let engine = Engine.live(paths: WarzagPaths(home: home))
        defer {
            // The prefix holds dosdevices/z: -> /; removal never follows links (LocalEngineFileSystemTests).
            try? FileManager.default.removeItem(at: home)
            #expect(!FileManager.default.fileExists(atPath: home.plainPath))
        }

        let registered = try engine.runtime.useLocal(devHost)
        let channel = try #require(registered.current?.channel)
        print("integration: registered \(registered.current?.id ?? "?") (channel \(channel.rawValue)) from \(devHost.plainPath)")

        let started = Date()
        let report = try await engine.prefix.create(macDriver: MacDriverSettings(retinaMode: false))
        print("integration: prefix created in \(Int(Date().timeIntervalSince(started))) s at \(report.prefix)")
        #expect(report.created)
        #expect(report.identity == .captured)

        let doctor = await engine.prefix.doctor()
        for line in doctor.lines { print("integration: \(line)") }
        #expect(doctor.passed)

        let output = #"C:\windows\temp\wz-d3d11-smoke.json"#
        let run = try await engine.prefix.runProgram(smoke.plainPath, arguments: ["--frames", "60", "--out", output],
                                                     renderer: RendererOptions(renderer: .dxmt))
        try await engine.prefix.waitForServer()
        let layout = engine.prefix.layout
        let resultFile = layout.windowsTemp.appending(path: "wz-d3d11-smoke.json")
        let line = try String(contentsOf: resultFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        print("integration: wz-d3d11-smoke exit \(run.exitCode): \(line)")
        #expect(run.exitCode == 0)
        let result = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(result["ok"] as? Bool == true)
        #expect(result["d3d11_impl"] as? String == "dxmt")
        #expect(result["dxgi_impl"] as? String == "dxmt")
    }

    @Test func signedPackThroughAppleArchiveAndCodeSigning() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = SystemProcessRunner()

        // A tiny but real host: ad-hoc signed, archived the way packs are published (top-level Warzag.app/).
        let source = home.appending(path: "src/Warzag.app", directoryHint: .isDirectory)
        let contents = source.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: contents.appending(path: "MacOS/wine").plainPath)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: contents.appending(path: "MacOS/wineserver").plainPath)
        try Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleExecutable</key><string>wine</string>
            <key>CFBundleIdentifier</key><string>com.warzag.gamehost</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            <key>WarzagRuntimeChannel</key><string>n</string>
            </dict></plist>
            """.utf8).write(to: contents.appending(path: "Info.plist"))
        let sign = try await runner.run(Command("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none",
                                                                       source.plainPath]))
        #expect(sign.succeeded, "\(sign.standardError)")
        let pack = home.appending(path: "WarzagRuntime-n-9.9.9.aar")
        let archive = try await runner.run(Command("/usr/bin/aa", ["archive", "-D", source.plainPath, "-o", pack.plainPath]))
        #expect(archive.succeeded, "\(archive.standardError)")

        let data = try Data(contentsOf: pack)
        let key = Curve25519.Signing.PrivateKey()
        let manifest = RuntimeManifest(
            serial: 1, expires: Date().addingTimeInterval(86_400), id: "n-9.9.9", version: "9.9.9", channel: .n,
            arch: "arm64", minLauncher: "0.1.0", minMacOS: "15.0",
            url: URL(string: "https://runtime.example.org/WarzagRuntime-n-9.9.9.aar")!, size: Int64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            signerFingerprint: RuntimeSigner.adHoc)
        let signed = try SignedManifest.sign(manifest, keyId: "rt-integration", with: key).encoded()
        let trust = try RuntimeTrust.explicitKey(key.publicKey.rawRepresentation, for: signed)

        let engine = Engine.live(paths: WarzagPaths(home: home))
        let state = try await engine.runtime.install(signedManifest: signed, pack: .file(pack), trust: trust,
                                                     appVersion: "0.1.0", macOSVersion: "26.5.1")
        #expect(state.current?.id == "n-9.9.9")
        let host = try engine.runtime.active().host
        let verify = try await runner.run(Command("/usr/bin/codesign", ["--verify", "--deep", "--strict",
                                                                        host.bundle.plainPath]))
        #expect(verify.succeeded, "\(verify.standardError)")
        print("integration: installed n-9.9.9 through aa + SecStaticCode at \(host.bundle.plainPath)")

        // One flipped byte in the pack: refused before anything is unpacked.
        var tampered = data
        tampered[tampered.count / 2] ^= 0x01
        try tampered.write(to: pack)
        await #expect(throws: DigestMismatch.self) {
            _ = try await engine.runtime.install(signedManifest: signed, pack: .file(pack), trust: trust,
                                                 appVersion: "0.1.0", macOSVersion: "26.5.1", allowRolledBack: true)
        }
    }
}
