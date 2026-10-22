import Foundation
import Testing
import WarzagCore
@testable import EngineKit

@Suite struct LocalEngineFileSystemTests {
    let fileSystem = LocalEngineFileSystem()

    func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "warzag-engine-fs-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func linksAreCreatedReadAndRemovedWithoutTouchingTheirTarget() throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let target = base.appending(path: "target", directoryHint: .isDirectory)
        try fileSystem.writeAtomically(Data("keep".utf8), to: target.appending(path: "precious.txt"))

        let link = base.appending(path: "prefix/dosdevices/x:")
        try fileSystem.createSymbolicLink(at: link, destination: target.plainPath)
        #expect(fileSystem.isSymbolicLink(at: link))
        #expect(try fileSystem.destinationOfSymbolicLink(at: link) == target.plainPath)
        #expect(fileSystem.directoryExists(at: link))
        #expect(throws: (any Error).self) { try fileSystem.createSymbolicLink(at: link, destination: "/") }

        let dangling = base.appending(path: "dangling")
        try fileSystem.createSymbolicLink(at: dangling, destination: base.appending(path: "nowhere").plainPath)
        #expect(fileSystem.isSymbolicLink(at: dangling))
        #expect(!fileSystem.fileExists(at: dangling))
        #expect(!fileSystem.isSymbolicLink(at: target))

        // Removing the link, or a whole tree holding links (a prefix holds z: -> /), never follows them.
        let root = base.appending(path: "prefix/dosdevices/z:")
        try fileSystem.createSymbolicLink(at: root, destination: target.plainPath)
        try fileSystem.removeItem(at: link)
        try fileSystem.removeItem(at: base.appending(path: "prefix"))
        #expect(fileSystem.fileExists(at: target.appending(path: "precious.txt")))
    }

    @Test func treesAreCopiedWithTheirLinksAndModes() throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let app = base.appending(path: "src/Warzag.app", directoryHint: .isDirectory)
        let wine = app.appending(path: "Contents/MacOS/wine")
        try fileSystem.writeAtomically(Data("loader".utf8), to: wine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.plainPath)
        try fileSystem.createSymbolicLink(at: app.appending(path: "Contents/lib/libx.dylib"), destination: "libx.1.dylib")

        let copy = base.appending(path: "Runtimes/n/0.1.0/Warzag.app", directoryHint: .isDirectory)
        try fileSystem.copyItem(at: app, to: copy)
        #expect(try fileSystem.contents(of: copy.appending(path: "Contents/MacOS/wine")) == Data("loader".utf8))
        #expect(fileSystem.isExecutableFile(at: copy.appending(path: "Contents/MacOS/wine")))
        #expect(try fileSystem.destinationOfSymbolicLink(at: copy.appending(path: "Contents/lib/libx.dylib")) == "libx.1.dylib")
        #expect(throws: (any Error).self) { try fileSystem.copyItem(at: app, to: copy) }
    }

    @Test func replacingAFileIsOneRenameAndLeavesNoTemporaryFiles() throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appending(path: "runtime/nvapi64.dll")
        let destination = base.appending(path: "prefix/drive_c/windows/system32/nvapi64.dll")
        try fileSystem.writeAtomically(Data("dxmt".utf8), to: source)
        try fileSystem.writeAtomically(Data("wine stub".utf8), to: destination)
        let before = try fileSystem.attributes(of: destination).fileNumber

        try fileSystem.replaceFile(at: destination, withCopyOf: source)
        #expect(try fileSystem.contents(of: destination) == Data("dxmt".utf8))
        #expect(try fileSystem.attributes(of: destination).fileNumber != before)
        #expect(try fileSystem.contentsOfDirectory(at: destination.deletingLastPathComponent()).map(\.lastPathComponent)
            == ["nvapi64.dll"])
        try fileSystem.replaceFile(at: base.appending(path: "prefix/new/dir/file.dll"), withCopyOf: source)
        #expect(fileSystem.fileExists(at: base.appending(path: "prefix/new/dir/file.dll")))
    }
}
