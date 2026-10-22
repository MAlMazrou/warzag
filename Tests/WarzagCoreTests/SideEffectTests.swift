import Foundation
import Testing
import WarzagTestSupport
@testable import WarzagCore

/// The real process runner, against harmless system tools.
@Suite struct SystemProcessRunnerTests {
    let runner = SystemProcessRunner()

    @Test func capturesOutputAndExitStatus() async throws {
        let echo = try await runner.run(Command("/bin/echo", ["hello world"]))
        #expect(echo.succeeded)
        #expect(echo.standardOutput == "hello world\n")

        let failing = try await runner.run(Command("/bin/sh", ["-c", "echo oops >&2; exit 3"]))
        #expect(failing.exitCode == 3)
        #expect(failing.standardError == "oops\n")
    }

    @Test func outputLargerThanAPipeBufferDoesNotDeadlock() async throws {
        let result = try await runner.run(Command("/bin/sh", ["-c", "head -c 1000000 /dev/zero; head -c 300000 /dev/zero >&2"]))
        #expect(result.stdout.count == 1_000_000)
        #expect(result.stderr.count == 300_000)
    }

    @Test func environmentIsReplacedNotMerged() async throws {
        let result = try await runner.run(Command("/usr/bin/env", environment: ["WARZAG_TEST": "1"]))
        #expect(result.standardOutput == "WARZAG_TEST=1\n")
    }

    @Test func logFilesCollectOutputInsteadOfPipes() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "warzag-runner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appending(path: "tool.log")
        let first = try await runner.run(Command("/bin/sh", ["-c", "echo one; echo two >&2"], logFile: log))
        _ = try await runner.run(Command("/bin/echo", ["three"], logFile: log))
        #expect(first.stdout.isEmpty)
        let text = try String(contentsOf: log, encoding: .utf8)
        #expect(text.contains("one\n") && text.contains("two\n") && text.hasSuffix("three\n"))
    }

    @Test func workingDirectoryIsHonoured() async throws {
        let result = try await runner.run(Command("/bin/pwd", workingDirectory: URL(filePath: "/usr")))
        #expect(result.standardOutput == "/usr\n")
    }

    @Test func missingExecutablesThrow() async {
        await #expect(throws: (any Error).self) {
            _ = try await runner.run(Command("/nonexistent/warzag-tool"))
        }
    }

    @Test func descriptionQuotesArgumentsWithSpaces() {
        #expect(Command("/usr/bin/open", ["-a", "Some App"]).description == "/usr/bin/open -a 'Some App'")
    }
}

@Suite struct LocalFileSystemTests {
    let fileSystem = LocalFileSystem()
    let root = FileManager.default.temporaryDirectory.appending(path: "warzag-fs-\(UUID().uuidString)", directoryHint: .isDirectory)

    @Test func atomicWritesCreateParentsAndReplace() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "a/b/state.json")
        try fileSystem.writeAtomically(Data("one".utf8), to: file)
        let first = try fileSystem.attributes(of: file)
        try fileSystem.writeAtomically(Data("two!".utf8), to: file)
        let second = try fileSystem.attributes(of: file)
        #expect(try fileSystem.contents(of: file) == Data("two!".utf8))
        #expect(second.size == 4)
        // An atomic replace is a new inode, which is how log tailers notice replacement.
        #expect(first.fileNumber != second.fileNumber)
    }

    @Test func exclusiveCreationNeverOverwrites() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "EE.cfg")
        #expect(try fileSystem.createExclusively(Data("seed".utf8), at: file))
        #expect(try !fileSystem.createExclusively(Data("other".utf8), at: file))
        #expect(try fileSystem.contents(of: file) == Data("seed".utf8))
        #expect(try fileSystem.contentsOfDirectory(at: root).map(\.lastPathComponent) == ["EE.cfg"])
    }

    @Test func partialReadsAndChunks() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "data.bin")
        try fileSystem.writeAtomically(Data("0123456789".utf8), to: file)
        #expect(try fileSystem.read(file, offset: 3, maxLength: 4) == Data("3456".utf8))
        #expect(try fileSystem.read(file, offset: 8, maxLength: 100) == Data("89".utf8))
        var chunks: [Data] = []
        try fileSystem.forEachChunk(of: file, chunkSize: 4) { chunks.append($0) }
        #expect(chunks.map(\.count) == [4, 4, 2])
    }

    @Test func moveRemoveAndDirectoryQueries() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "staging/Warzag.app", directoryHint: .isDirectory)
        try fileSystem.createDirectory(at: source)
        #expect(fileSystem.directoryExists(at: source))
        #expect(fileSystem.isWritableDirectory(at: root))
        let destination = root.appending(path: "Runtimes/n/0.1.0/Warzag.app", directoryHint: .isDirectory)
        try fileSystem.moveItem(at: source, to: destination)
        #expect(fileSystem.directoryExists(at: destination))
        #expect(!fileSystem.fileExists(at: source))
        try fileSystem.removeItem(at: root.appending(path: "Runtimes"))
        #expect(!fileSystem.fileExists(at: destination))
    }

    @Test func volumeInfoForAPathThatDoesNotExistYet() throws {
        let info = try fileSystem.volumeInfo(for: root.appending(path: "not/yet/created"))
        #expect(info.isLocal)
        #expect((info.availableCapacity ?? 0) > 0)
    }

    /// APFS counts purgeable space for important data; HFS+ and other volumes answer 0 there, and their plain free space
    /// is what Finder shows.
    @Test(arguments: [
        (Int64?(5_000), Int64?(3_000), Int64?(5_000)), (0, 1_568_768, 1_568_768), (nil, 7, 7), (0, nil, 0), (nil, nil, nil),
    ])
    func freeSpaceOnVolumesThatDoNotCountPurgeableSpace(_ important: Int64?, _ plain: Int64?, _ expected: Int64?) {
        #expect(LocalFileSystem.availableCapacity(important: important, plain: plain) == expected)
    }

    @Test func liveProcessInspectionOfOurselves() {
        let inspector = DarwinProcessInspector()
        let me = getpid()
        #expect(inspector.isAlive(me))
        #expect(inspector.executablePath(of: me)?.isEmpty == false)
        #expect((inspector.startDate(of: me) ?? .distantFuture) <= Date())
        #expect(!inspector.isAlive(0))
        #expect(!inspector.isAlive(-1))
    }

    @Test func liveProcessListFindsAProcessByItsFolder() throws {
        let inspector = DarwinProcessInspector()
        let me = getpid()
        #expect(inspector.processIdentifiers().contains(me))
        let executable = URL(filePath: try #require(inspector.executablePath(of: me)))
        #expect(inspector.processRunning(inside: executable.deletingLastPathComponent()) != nil)
        // Nothing runs from a fresh folder.
        try fileSystem.createDirectory(at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(inspector.processRunning(inside: root) == nil)
    }

    /// The kernel names an executable by its real path (/private/tmp/...), however the folder was spelled.
    @Test func aFolderSpelledThroughASymbolicLinkStillMatches() throws {
        let folder = URL(filePath: "/tmp/warzag-process-\(UUID().uuidString)/Runtimes", directoryHint: .isDirectory)
        try fileSystem.createDirectory(at: folder)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let real = "/private" + folder.plainPath + "/n/0.3.0/Warzag.app/Contents/MacOS/wine"
        let processes = FakeProcessInspector([41: .init(path: "/Applications/Other.app/Contents/MacOS/Other", start: nil),
                                              42: .init(path: real, start: nil)])
        #expect(processes.processRunning(inside: folder) == 42)
        // A sibling whose name only starts the same is not inside.
        #expect(processes.processRunning(inside: URL(filePath: folder.plainPath + ".old")) == nil)
    }
}
