import Foundation
import Testing
import WarzagCore
import WarzagTestSupport
@testable import GameKit

@Suite struct InstallerVerificationTests {
    static let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

    func msi(_ size: Int, signature: [UInt8] = InstallerVerificationTests.signature) -> Data {
        var data = Data(signature)
        data.append(Data(count: size - signature.count))
        return data
    }

    @Test func aPlausibleInstallerPasses() throws {
        let fileSystem = InMemoryFileSystem()
        fileSystem.addFile("/d/Warframe.msi", msi(10_000_001))
        let url = URL(filePath: "/d/Warframe.msi")
        let (bytes, sha256) = try InstallerChecks.check(url, expectations: InstallerExpectations(), fileSystem: fileSystem)
        #expect(bytes == 10_000_001)
        #expect(sha256.count == 64 && sha256 == sha256.lowercased())
    }

    @Test func tenMegabytesIsTooSmall() {
        let fileSystem = InMemoryFileSystem()
        fileSystem.addFile("/d/Warframe.msi", msi(10_000_000))
        #expect(throws: InstallerCheckError.tooSmall(bytes: 10_000_000, minimum: 10_000_000)) {
            try InstallerChecks.check(URL(filePath: "/d/Warframe.msi"), expectations: InstallerExpectations(),
                                      fileSystem: fileSystem)
        }
    }

    @Test func anErrorPageIsNotAnInstaller() {
        let fileSystem = InMemoryFileSystem()
        var page = Data("<!DOCTYPE html><html>".utf8)
        page.append(Data(count: 64))
        fileSystem.addFile("/d/Warframe.msi", page)
        #expect(throws: InstallerCheckError.notAnInstaller) {
            try InstallerChecks.check(URL(filePath: "/d/Warframe.msi"), expectations: InstallerExpectations(minimumBytes: 16),
                                      fileSystem: fileSystem)
        }
        #expect(throws: InstallerCheckError.missing("/d/none.msi")) {
            try InstallerChecks.check(URL(filePath: "/d/none.msi"), expectations: InstallerExpectations(),
                                      fileSystem: fileSystem)
        }
    }

    // MARK: Authenticode

    @Test func withoutAVerifierNothingIsChecked() async {
        let verdict = await NoAuthenticodeVerifier().verify(URL(filePath: "/d/Warframe.msi"),
                                                            expectedSigner: InstallerExpectations.signer)
        guard case .unavailable = verdict else {
            Issue.record("expected .unavailable, got \(verdict)")
            return
        }
        #expect(verdict.description.hasPrefix("not checked"))
    }

    // MARK: InstallerSource

    struct FixedVerifier: AuthenticodeVerifying {
        var verdict: AuthenticodeVerdict
        func verify(_ file: URL, expectedSigner: String) async -> AuthenticodeVerdict { verdict }
    }

    @Test func aLocalInstallerIsCheckedAndItsVerdictReported() async throws {
        let fileSystem = InMemoryFileSystem()
        fileSystem.addFile("/d/Warframe.msi", msi(64))
        let states = Recorder<ContentRunState>()
        let source = InstallerSource(origin: .file(URL(filePath: "/d/Warframe.msi")),
                                     expectations: InstallerExpectations(minimumBytes: 16),
                                     authenticode: NoAuthenticodeVerifier(), fileSystem: fileSystem)
        let installer = try await source.installer { states.append($0) }
        #expect(installer.bytes == 64)
        #expect(states.all.first == .checkingInstaller)
        #expect(states.all.last == .installerChecked(sha256: installer.sha256, authenticode: installer.authenticode))

        let rejecting = InstallerSource(origin: .file(URL(filePath: "/d/Warframe.msi")),
                                        expectations: InstallerExpectations(minimumBytes: 16),
                                        authenticode: FixedVerifier(verdict: .rejected("bad chain")), fileSystem: fileSystem)
        await #expect(throws: InstallerCheckError.signatureRejected("bad chain")) {
            _ = try await rejecting.installer { _ in }
        }
    }

    @Test func aDownloadedInstallerIsReusedWhileItStillPasses() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = msi(300_000)
        let transport = FakeRangeTransport(body: body, behaviors: [.dropAfter(100_000)])
        let destination = directory.appending(path: "downloads/Warframe.msi")
        let source = InstallerSource(
            origin: .download(URL(string: "https://content.warframe.com/dl/Warframe.msi")!, to: destination),
            expectations: InstallerExpectations(minimumBytes: 1000),
            downloader: ResumableDownloader(transport: transport, clock: ManualClock()),
            authenticode: FixedVerifier(verdict: .trusted(signer: InstallerExpectations.signer)),
            fileSystem: LocalFileSystem())
        let states = Recorder<ContentRunState>()
        let first = try await source.installer { states.append($0) }
        #expect(try Data(contentsOf: destination) == body)
        #expect(first.authenticode == .trusted(signer: "Digital Extremes Ltd."))
        #expect(states.all.contains(.downloadingInstaller(receivedBytes: 300_000, totalBytes: 300_000)))
        #expect(transport.requests.count == 2)
        _ = try await source.installer { _ in }
        #expect(transport.requests.count == 2, "a file that still passes is not downloaded again")
    }
}
