import Foundation
import Testing
import WarzagCore
import WarzagTestSupport
@testable import ContentKit

/// A supervisor starts tailing just before it starts the program, and must see only that program's run.
@Suite struct LogTailerSeekTests {
    let fileSystem = InMemoryFileSystem()
    let path = "/prefix/drive_c/users/tenno/AppData/Local/Warframe/EE.log"
    var url: URL { URL(filePath: path) }

    @Test func thePreviousRunIsNotReplayed() throws {
        fileSystem.append(path, "3.2 Sys [Info]: Steam active.\n9.9 Sys [Info]: last session's line\n")
        var tailer = LogTailer(url: url)
        try tailer.seekToEnd(fileSystem)
        #expect(try tailer.poll(fileSystem) == LogTailer.Chunk(lines: [], restarted: false))
        fileSystem.append(path, "0.1 Sys [Info]: appended by the new run\n")
        #expect(try tailer.poll(fileSystem) == LogTailer.Chunk(lines: ["0.1 Sys [Info]: appended by the new run"],
                                                              restarted: false))
    }

    @Test func aReplacedLogIsReadFromItsFirstLine() throws {
        // Warframe moves EE.log to EE.log.prev and starts a new file, even a shorter one.
        fileSystem.append(path, String(repeating: "old session\n", count: 50))
        var tailer = LogTailer(url: url)
        try tailer.seekToEnd(fileSystem)
        fileSystem.addFile(path, "0.1 Sys [Diag]: Process Command-line: -cluster:public\n")
        #expect(try tailer.poll(fileSystem) == LogTailer.Chunk(
            lines: ["0.1 Sys [Diag]: Process Command-line: -cluster:public"], restarted: true))
    }

    @Test func aTruncatedLogIsReadFromItsFirstLine() throws {
        fileSystem.append(path, "a long line from the previous launcher run\n")
        var tailer = LogTailer(url: url)
        try tailer.seekToEnd(fileSystem)
        fileSystem.truncate(path, to: "Current time: new run\n")
        #expect(try tailer.poll(fileSystem) == LogTailer.Chunk(lines: ["Current time: new run"], restarted: true))
    }

    @Test func aLogThatDoesNotExistYetIsReadFromTheStart() throws {
        var tailer = LogTailer(url: url)
        try tailer.seekToEnd(fileSystem)
        #expect(tailer.offset == 0)
        fileSystem.append(path, "first\nsecond\n")
        #expect(try tailer.poll(fileSystem).lines == ["first", "second"])
    }

    @Test func seekingDropsAHalfReadLine() throws {
        var tailer = LogTailer(url: url)
        fileSystem.append(path, "complete\nhalf")
        _ = try tailer.poll(fileSystem)
        try tailer.seekToEnd(fileSystem)
        fileSystem.append(path, " of an old line\nnew\n")
        #expect(try tailer.poll(fileSystem).lines == [" of an old line", "new"])
    }

    @Test func aMonitorSeeksToo() throws {
        fileSystem.append(path, "12.0 Sys [Error]: Steam does not appear to be running.\n")
        var monitor = LogMonitor(url: url, kind: .ee)
        try monitor.seekToEnd(fileSystem)
        #expect(try monitor.poll(fileSystem).isEmpty)
        fileSystem.append(path, "3.2 Sys [Info]: Steam active. IsBicPic=0 IsSteamDeck=0\n")
        #expect(try monitor.poll(fileSystem) == [.steamActive])
    }
}
