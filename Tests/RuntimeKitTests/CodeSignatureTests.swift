import Foundation
import Testing
import WarzagCore
@testable import RuntimeKit

/// `SecurityCodeSignatureInspector` on real bundles, ad-hoc signed in a scratch folder with the system's codesign.
/// Copies of /usr/bin/true stand in for the Wine loader and wineserver; nothing is ever run from the bundle.
@Suite struct SecurityCodeSignatureInspectorTests {
    struct ToolFailed: Error, CustomStringConvertible {
        var description: String
    }

    func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "warzag-codesign-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Contents/{Info.plist,MacOS/wine,MacOS/wineserver}, signed inside out as runtime/n/make-host.sh does it, so
    /// the bundle seals MacOS/wineserver as nested code (by its code-directory hash), like a real runtime host.
    func makeSignedHost(in directory: URL) async throws -> URL {
        let app = directory.appending(path: "Warzag.app", directoryHint: .isDirectory)
        let macOS = app.appending(path: "Contents/MacOS", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        for name in ["wine", "wineserver"] {
            try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appending(path: name).plainPath)
        }
        let licenses = app.appending(path: "Contents/Resources/licenses", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: licenses, withIntermediateDirectories: true)
        try Data("LGPL-2.1+\n".utf8).write(to: licenses.appending(path: "Wine-LICENSE.txt"))
        try Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleExecutable</key><string>wine</string>
            <key>CFBundleIdentifier</key><string>com.warzag.gamehost</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            </dict></plist>
            """.utf8).write(to: app.appending(path: "Contents/Info.plist"))
        for target in [macOS.appending(path: "wineserver"), app] {
            let result = try await SystemProcessRunner().run(
                Command("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", target.plainPath]))
            guard result.succeeded else { throw ToolFailed(description: "codesign: \(result.standardError)") }
        }
        return app
    }

    /// Flips the first byte after the load commands of every Mach-O slice: inside each slice's first page, which
    /// its code directory hashes, while the signature itself (and so the code-directory hash) stays as it was.
    func tamperFirstPages(of executable: URL) throws {
        var data = try Data(contentsOf: executable)
        func word(_ offset: Int, bigEndian: Bool) -> Int {
            let bytes = data[offset..<(offset + 4)].map(UInt32.init)
            let value = bigEndian
                ? bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3]
                : bytes[3] << 24 | bytes[2] << 16 | bytes[1] << 8 | bytes[0]
            return Int(value)
        }
        var slices = [0]
        if word(0, bigEndian: true) == 0xCAFE_BABE {  // fat_header, then 20-byte fat_arch entries
            slices = (0..<word(4, bigEndian: true)).map { word(8 + 20 * $0 + 8, bigEndian: true) }
        }
        for slice in slices {
            guard word(slice, bigEndian: false) == 0xFEED_FACF else {
                throw ToolFailed(description: "not a 64-bit Mach-O slice at \(slice)")
            }
            data[slice + 32 + word(slice + 20, bigEndian: false)] ^= 0x01  // mach_header_64 is 32 bytes
        }
        try data.write(to: executable)
    }

    @Test func anIntactAdHocHostVerifiesWithoutACertificate() async throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let app = try await makeSignedHost(in: base)
        #expect(try SecurityCodeSignatureInspector().signerFingerprint(of: app) == nil)
    }

    @Test func aModifiedNestedWineserverIsRefused() async throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let app = try await makeSignedHost(in: base)
        try tamperFirstPages(of: app.appending(path: "Contents/MacOS/wineserver"))
        // Default validation flags accept this bundle: they match nested code by its code-directory hash only.
        #expect(throws: CodeSignatureError.self) { _ = try SecurityCodeSignatureInspector().signerFingerprint(of: app) }
    }

    @Test func aModifiedResourceIsRefused() async throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let app = try await makeSignedHost(in: base)
        // Sealed by content hash: caught with any flags; kept here so the stricter flags are seen to still catch it.
        try Data("changed\n".utf8).write(to: app.appending(path: "Contents/Resources/licenses/Wine-LICENSE.txt"))
        #expect(throws: CodeSignatureError.self) { _ = try SecurityCodeSignatureInspector().signerFingerprint(of: app) }
    }
}
