import Darwin
import Foundation
import RuntimeKit
import Testing
import WarzagCore
@testable import AppUpdateKit

/// `LiveAppBundleVerifier` on real bundles: a tiny C program stands in for Warzag and warzagctl. A stand-in signature
/// reader answers for the project certificate; qa/packaging/app-update-test.sh covers the real one.
@Suite(.serialized) struct AppBundleVerifierTests {
    struct ToolFailed: Error, CustomStringConvertible {
        var description: String
    }

    static let requirement = AppRequirement(version: "0.2.0", build: "413", signerFingerprint: AppKeys.signer)
    /// What the project certificate's signature reads as.
    static let projectSigned = LiveAppBundleVerifier(signature: { _ in
        LiveAppBundleVerifier.Signature(fingerprint: AppKeys.signer, identifier: "com.warzag.app")
    })

    func run(_ executable: String, _ arguments: [String]) async throws {
        let result = try await SystemProcessRunner().run(Command(executable, arguments))
        guard result.succeeded else { throw ToolFailed(description: "\(executable): \(result.standardError)") }
    }

    func makeBundle(arch: String = "arm64", helperArch: String = "arm64", identifier: String = "com.warzag.app",
                    build: String = "413") async throws -> URL {
        let root = try scratchDirectory("bundle-verifier")
        let source = root.appending(path: "main.c")
        try Data("int main(void) { return 0; }\n".utf8).write(to: source)
        let app = try makeApp(at: root.appending(path: "Warzag.app", directoryHint: .isDirectory), identifier: identifier,
                              version: "0.2.0", build: build)
        let helpers = app.appending(path: "Contents/Helpers", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try await run("/usr/bin/clang", ["-arch", arch, "-o", app.appending(path: "Contents/MacOS/Warzag").plainPath,
                                         source.plainPath])
        try await run("/usr/bin/clang", ["-arch", helperArch, "-o", helpers.appending(path: "warzagctl").plainPath,
                                         source.plainPath])
        return app
    }

    func adHocSign(_ app: URL) async throws {
        try await run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none",
                                            app.appending(path: "Contents/Helpers/warzagctl").plainPath])
        try await run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", app.plainPath])
    }

    func cleanUp(_ app: URL) {
        try? FileManager.default.removeItem(at: app.deletingLastPathComponent())
    }

    @Test func aWellFormedBundleSignedByTheRequiredCertificatePasses() async throws {
        let app = try await makeBundle()
        defer { cleanUp(app) }
        try Self.projectSigned.verify(app, against: Self.requirement)
    }

    @Test func identityVersionAndBuildComeFromTheSealedInfoPlist() async throws {
        let app = try await makeBundle(identifier: "com.example.other", build: "412")
        defer { cleanUp(app) }
        #expect(throws: AppBundleRejection.identityMismatch(expected: "com.warzag.app", actual: "com.example.other")) {
            try Self.projectSigned.verify(app, against: Self.requirement)
        }
        let renamed = LiveAppBundleVerifier(signature: { _ in .init(fingerprint: AppKeys.signer, identifier: "com.other") })
        #expect(throws: AppBundleRejection.identityMismatch(expected: "com.warzag.app", actual: "com.other")) {
            try renamed.verify(app, against: Self.requirement)
        }
        var other = Self.requirement
        other.bundleIdentifier = "com.example.other"
        let matchingIdentity = LiveAppBundleVerifier(signature: { _ in
            .init(fingerprint: AppKeys.signer, identifier: "com.example.other")
        })
        #expect(throws: AppBundleRejection.buildMismatch(expected: "413", actual: "412")) {
            try matchingIdentity.verify(app, against: other)
        }
    }

    @Test func anotherSignerIsRefused() async throws {
        let app = try await makeBundle()
        defer { cleanUp(app) }
        let stranger = String(repeating: "0", count: 64)
        let verifier = LiveAppBundleVerifier(signature: { _ in .init(fingerprint: stranger, identifier: "com.warzag.app") })
        #expect(throws: AppBundleRejection.signerMismatch(expected: AppKeys.signer, actual: stranger)) {
            try verifier.verify(app, against: Self.requirement)
        }
    }

    @Test(arguments: [("x86_64", "arm64", "Contents/MacOS/Warzag"), ("arm64", "x86_64", "Contents/Helpers/warzagctl")])
    func everyProgramMustBeArm64(_ arch: String, _ helperArch: String, _ path: String) async throws {
        let app = try await makeBundle(arch: arch, helperArch: helperArch)
        defer { cleanUp(app) }
        #expect(throws: AppBundleRejection.architecture(path: path, found: "x86_64")) {
            try Self.projectSigned.verify(app, against: Self.requirement)
        }
    }

    @Test func aMissingHelperIsRefused() async throws {
        let app = try await makeBundle()
        defer { cleanUp(app) }
        try FileManager.default.removeItem(at: app.appending(path: AppRequirement.helperPath))
        #expect(throws: AppBundleRejection.missingCode(AppRequirement.helperPath)) {
            try Self.projectSigned.verify(app, against: Self.requirement)
        }
    }

    @Test func linksMustStayInsideTheBundle() async throws {
        let app = try await makeBundle()
        defer { cleanUp(app) }
        let resources = app.appending(path: "Contents/Resources", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: resources.appending(path: "inside").plainPath,
                                                   withDestinationPath: "../MacOS/Warzag")
        try Self.projectSigned.verify(app, against: Self.requirement)
        for (name, target) in [("absolute", "/etc/hosts"), ("escaping", "../../../outside")] {
            let link = resources.appending(path: name)
            try FileManager.default.createSymbolicLink(atPath: link.plainPath, withDestinationPath: target)
            #expect(throws: AppBundleRejection.linkLeavesBundle("Contents/Resources/\(name)")) {
                try Self.projectSigned.verify(app, against: Self.requirement)
            }
            try FileManager.default.removeItem(at: link)
        }
    }

    @Test func staysInsideResolvesDotsAgainstTheLinksFolder() {
        #expect(LiveAppBundleVerifier.staysInside(link: "Contents/Resources/a", target: "../MacOS/Warzag"))
        #expect(LiveAppBundleVerifier.staysInside(link: "Contents/Resources/a", target: "./b/../c"))
        #expect(LiveAppBundleVerifier.staysInside(link: "Contents/a", target: "../Contents/b"))
        #expect(!LiveAppBundleVerifier.staysInside(link: "Contents/a", target: "../../b"))
        #expect(!LiveAppBundleVerifier.staysInside(link: "a", target: ".."))
        #expect(!LiveAppBundleVerifier.staysInside(link: "Contents/a", target: "/Applications"))
    }

    @Test func noQuarantineAnywhere() async throws {
        let app = try await makeBundle()
        defer { cleanUp(app) }
        let data = app.appending(path: "Contents/MacOS/Warzag").plainPath
        let quarantine = Array("0081;6716c2a0;Safari;".utf8)
        #expect(setxattr(data, "com.apple.quarantine", quarantine, quarantine.count, 0, 0) == 0)
        #expect(throws: AppBundleRejection.quarantined("Contents/MacOS/Warzag")) {
            try Self.projectSigned.verify(app, against: Self.requirement)
        }
        removexattr(data, "com.apple.quarantine", 0)
        #expect(setxattr(app.plainPath, "com.apple.quarantine", quarantine, quarantine.count, 0, 0) == 0)
        #expect(throws: AppBundleRejection.quarantined("Warzag.app")) {
            try Self.projectSigned.verify(app, against: Self.requirement)
        }
    }

    @Test func aFIFOIsNoPartOfAnApp() async throws {
        let app = try await makeBundle()
        defer { cleanUp(app) }
        #expect(mkfifo(app.appending(path: "Contents/pipe").plainPath, 0o644) == 0)
        #expect(throws: AppBundleRejection.unexpectedItem("Contents/pipe")) {
            try Self.projectSigned.verify(app, against: Self.requirement)
        }
    }

    @Test func aLinkInsteadOfTheBundleIsRefused() async throws {
        let app = try await makeBundle()
        defer { cleanUp(app) }
        let link = app.deletingLastPathComponent().appending(path: "Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
        #expect(throws: AppBundleRejection.notABundle("Link.app")) {
            try Self.projectSigned.verify(link, against: Self.requirement)
        }
    }

    // MARK: Security.framework

    /// Ad hoc: the signature validates but names no certificate, so it cannot be the project's.
    @Test func adHocSignedIsRefused() async throws {
        let app = try await makeBundle()
        defer { cleanUp(app) }
        try await adHocSign(app)
        let signature = try LiveAppBundleVerifier.codeSignature(of: app)
        #expect(signature.fingerprint == nil)
        #expect(signature.identifier == "com.warzag.app")
        #expect(throws: AppBundleRejection.noCertificate) { try LiveAppBundleVerifier().verify(app, against: Self.requirement) }
    }

    @Test func aChangedOrAddedFileBreaksTheSignature() async throws {
        let app = try await makeBundle()
        defer { cleanUp(app) }
        try await adHocSign(app)
        try Data("extra".utf8).write(to: app.appending(path: "Contents/extra.txt"))
        #expect {
            try LiveAppBundleVerifier().verify(app, against: Self.requirement)
        } throws: { error in
            if case .badSignature = error as? AppBundleRejection { true } else { false }
        }
        try FileManager.default.removeItem(at: app.appending(path: "Contents/extra.txt"))
        #expect(throws: AppBundleRejection.noCertificate) { try LiveAppBundleVerifier().verify(app, against: Self.requirement) }
        // A nested program changed after signing, in the padding of its first page: its code directory, and so the
        // bundle's seal, is unchanged; only checking nested code page by page notices.
        let helper = app.appending(path: AppRequirement.helperPath)
        var bytes = try Data(contentsOf: helper)
        bytes[0x1000] ^= 0xFF
        try bytes.write(to: helper)
        #expect {
            try LiveAppBundleVerifier().verify(app, against: Self.requirement)
        } throws: { error in
            if case .badSignature = error as? AppBundleRejection { true } else { false }
        }
    }

    @Test func anUnsignedBundleIsRefused() async throws {
        let app = try await makeBundle()
        defer { cleanUp(app) }
        #expect {
            try LiveAppBundleVerifier().verify(app, against: Self.requirement)
        } throws: { error in
            if case .badSignature = error as? AppBundleRejection { true } else { false }
        }
    }
}
