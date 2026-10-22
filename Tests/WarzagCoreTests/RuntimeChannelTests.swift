import Foundation
import Testing
import WarzagTestSupport
@testable import WarzagCore

/// Mach-O headers as runtime loaders have them.
enum Headers {
    /// MH_MAGIC_64 little-endian, then cputype and cpusubtype.
    static func thin(cpuType: UInt32, subtype: UInt32) -> Data {
        Data([0xCF, 0xFA, 0xED, 0xFE]) + littleEndian(cpuType) + littleEndian(subtype) + Data(count: 20)
    }

    static let x86_64 = thin(cpuType: 0x0100_0007, subtype: 3)
    static let arm64 = thin(cpuType: 0x0100_000C, subtype: 0)
    static let arm64e = thin(cpuType: 0x0100_000C, subtype: 0x8000_0002)

    /// A universal binary's header with these (cputype, cpusubtype) slices.
    static func fat(_ slices: [(UInt32, UInt32)], wide: Bool = false) -> Data {
        var data = Data([0xCA, 0xFE, 0xBA, wide ? 0xBF : 0xBE]) + bigEndian(UInt32(slices.count))
        for (type, subtype) in slices {
            data += bigEndian(type) + bigEndian(subtype) + Data(count: wide ? 24 : 12)
        }
        return data
    }

    static func littleEndian(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    static func bigEndian(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }

    static func plist(channel: String?) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleExecutable</key><string>wine</string>
        <key>CFBundleIdentifier</key><string>com.warzag.gamehost</string>
        \(channel.map { "<key>WarzagRuntimeChannel</key><string>\($0)</string>" } ?? "")
        </dict></plist>
        """
    }
}

@Suite struct MachOTests {
    @Test func thinLoaders() {
        #expect(MachO.architectures(header: Headers.x86_64) == [.x86_64])
        #expect(MachO.architectures(header: Headers.arm64) == [.arm64])
        #expect(MachO.architectures(header: Headers.arm64e) == [.arm64e])
    }

    @Test func universalBinaries() {
        let both = Headers.fat([(0x0100_0007, 3), (0x0100_000C, 0)])
        #expect(MachO.architectures(header: both) == [.x86_64, .arm64])
        #expect(MachO.architectures(header: Headers.fat([(0x0100_000C, 2)], wide: true)) == [.arm64e])
        #expect(MachO.architectures(header: Headers.fat([(7, 3)])) == [.i386])
    }

    @Test func whatIsNotAMachOFile() {
        #expect(MachO.architectures(header: Data("#!/bin/sh\n".utf8)) == nil)
        #expect(MachO.architectures(header: Data("wine loader 0.1.0".utf8)) == nil)
        #expect(MachO.architectures(header: Data([0xCF, 0xFA])) == nil)
        // A Java class file shares 0xCAFEBABE; its "slice count" is a class-file version.
        #expect(MachO.architectures(header: Data([0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x3D]) + Data(count: 64)) == nil)
        // A universal header cut short.
        #expect(MachO.architectures(header: Headers.fat([(0x0100_0007, 3), (0x0100_000C, 0)]).prefix(20)) == nil)
    }

    @Test func aSystemBinary() throws {
        let read = try FileHandle(forReadingFrom: URL(filePath: "/usr/bin/true")).read(upToCount: MachO.headerReadLength)
        let header = try #require(read)
        let slices = try #require(MachO.architectures(header: header))
        #expect(slices.contains(.x86_64))
        #expect(slices.contains(.arm64) || slices.contains(.arm64e))
    }
}

@Suite struct RuntimeHostChannelTests {
    @Test(arguments: [
        ("n", [MachOArchitecture.arm64]), (nil, [.arm64]), (nil, [.arm64e]), ("n", nil),
        ("n", [.x86_64, .arm64]),
    ] as [(String?, [MachOArchitecture]?)])
    func anArm64LoaderOrTheDeclarationMakesAnNHost(_ declared: String?, _ loader: [MachOArchitecture]?) throws {
        #expect(try RuntimeHostChannel.channel(declared: declared, loader: loader) == .n)
    }

    @Test func otherLoadersAndDeclarationsAreRefused() {
        #expect(throws: RuntimeHostChannelError.notArm64(loader: "x86_64")) {
            try RuntimeHostChannel.channel(declared: "n", loader: [.x86_64])
        }
        #expect(throws: RuntimeHostChannelError.notArm64(loader: "x86_64")) {
            try RuntimeHostChannel.channel(declared: nil, loader: [.x86_64])
        }
        #expect(throws: RuntimeHostChannelError.unknownDeclaration("x")) {
            try RuntimeHostChannel.channel(declared: "x", loader: [.arm64])
        }
        #expect(throws: RuntimeHostChannelError.unknownDeclaration("x86")) {
            try RuntimeHostChannel.channel(declared: "x86", loader: [.x86_64])
        }
        #expect(throws: RuntimeHostChannelError.self) { try RuntimeHostChannel.channel(declared: nil, loader: nil) }
        #expect(throws: RuntimeHostChannelError.self) {
            try RuntimeHostChannel.channel(declared: nil, loader: [.x86_64, .arm64])
        }
    }

    @Test func detectionReadsTheBundle() throws {
        let fileSystem = InMemoryFileSystem()
        let n = URL(filePath: "/build/n/Warzag.app", directoryHint: .isDirectory)
        fileSystem.addFile("/build/n/Warzag.app/Contents/Info.plist", Headers.plist(channel: "n"))
        fileSystem.addFile("/build/n/Warzag.app/Contents/MacOS/wine", Headers.arm64)
        #expect(try RuntimeHostChannel.detect(bundle: n, fileSystem: fileSystem) == .n)

        // A host without the key: the loader alone.
        fileSystem.addFile("/build/n/Warzag.app/Contents/Info.plist", Headers.plist(channel: nil))
        #expect(try RuntimeHostChannel.detect(bundle: n, fileSystem: fileSystem) == .n)

        // An x86_64 loader is refused, whatever the key says.
        let x86 = URL(filePath: "/build/x86/Warzag.app", directoryHint: .isDirectory)
        fileSystem.addFile("/build/x86/Warzag.app/Contents/Info.plist", Headers.plist(channel: "n"))
        fileSystem.addFile("/build/x86/Warzag.app/Contents/MacOS/wine", Headers.x86_64)
        #expect(throws: RuntimeHostChannelError.notArm64(loader: "x86_64")) {
            try RuntimeHostChannel.detect(bundle: x86, fileSystem: fileSystem)
        }
    }

    @Test func theChannelsFacts() {
        #expect(RuntimeChannel.n.wineArchitecture == "aarch64")
        #expect(RuntimeChannel.n.architecture == "arm64")
        #expect(RuntimeChannel.n.prefixDirectoryName == "warframe-arm64")
    }

    /// The real host on this Mac, when it is built (runtime/n/make-host.sh).
    @Test func theBuiltHostOnThisMac() throws {
        var directory = URL(filePath: #filePath).deletingLastPathComponent()
        while directory.plainPath != "/" {
            let host = directory.appending(path: "build/n/Warzag.app", directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: host.plainPath) {
                #expect(try RuntimeHostChannel.detect(bundle: host, fileSystem: LocalFileSystem()) == .n)
                return
            }
            directory = directory.deletingLastPathComponent()
        }
    }
}

@Suite struct ProcessDeadlineTests {
    @Test func aRunPastItsDeadlineIsStoppedAndReported() async throws {
        let started = Date()
        await #expect(throws: ProcessTimedOut(command: "/bin/sleep 30", timeout: .milliseconds(300))) {
            _ = try await SystemProcessRunner().run(Command("/bin/sleep", ["30"], timeout: .milliseconds(300)))
        }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func aProcessIgnoringSIGTERMIsKilled() async throws {
        let started = Date()
        let runner = SystemProcessRunner(killGracePeriod: .milliseconds(300))
        let command = Command("/bin/sh", ["-c", "trap '' TERM; sleep 30"], timeout: .milliseconds(300))
        await #expect(throws: ProcessTimedOut.self) { _ = try await runner.run(command) }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func aRunWithinItsDeadlineIsUnaffected() async throws {
        let output = try await SystemProcessRunner().run(Command("/bin/echo", ["hello"], timeout: .seconds(30)))
        #expect(output.succeeded)
        #expect(output.standardOutput == "hello\n")
        let failing = try await SystemProcessRunner().run(Command("/usr/bin/false", timeout: .seconds(30)))
        #expect(failing.exitCode == 1)
    }

    @Test func theReportNamesTheCommandAndItsDeadline() {
        #expect(ProcessTimedOut(command: "wine wineboot --init", timeout: .seconds(600)).description
            == "wine wineboot --init did not finish within 600 s and was stopped")
    }
}
