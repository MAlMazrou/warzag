import Foundation
import Testing
import WarzagCore
import WarzagTestSupport
@testable import ContentKit

@Suite struct LogTailerTests {
    let fileSystem = InMemoryFileSystem()
    let path = "/prefix/drive_c/users/tenno/AppData/Local/Warframe/EE.log"
    var url: URL { URL(filePath: path) }

    @Test func aMissingLogIsNotAnError() throws {
        var tailer = LogTailer(url: url)
        #expect(try tailer.poll(fileSystem) == LogTailer.Chunk(lines: [], restarted: false))
    }

    @Test func onlyCompleteNewLinesAreReturned() throws {
        var tailer = LogTailer(url: url)
        fileSystem.append(path, "first\nsecond")
        #expect(try tailer.poll(fileSystem).lines == ["first"])
        #expect(try tailer.poll(fileSystem).lines.isEmpty)
        fileSystem.append(path, " half\r\nthird\r\n")
        #expect(try tailer.poll(fileSystem).lines == ["second half", "third"])
        #expect(tailer.offset == UInt64("first\nsecond half\r\nthird\r\n".utf8.count))
    }

    @Test func multiByteCharactersSplitAcrossPollsSurvive() throws {
        var tailer = LogTailer(url: url)
        let bytes = Data("Joueur: Tenno ✓ مرحبا\n".utf8)
        // Cut inside the three-byte check mark.
        fileSystem.append(path, bytes.prefix(16))
        #expect(try tailer.poll(fileSystem).lines.isEmpty)
        fileSystem.append(path, bytes.dropFirst(16))
        #expect(try tailer.poll(fileSystem).lines == ["Joueur: Tenno ✓ مرحبا"])
    }

    @Test func truncationRestartsFromTheTop() throws {
        var tailer = LogTailer(url: url)
        fileSystem.append(path, "old run line 1\nold run line 2\n")
        _ = try tailer.poll(fileSystem)
        fileSystem.truncate(path, to: "new run\n")
        #expect(try tailer.poll(fileSystem) == LogTailer.Chunk(lines: ["new run"], restarted: true))
    }

    @Test func replacementRestartsFromTheTop() throws {
        var tailer = LogTailer(url: url)
        fileSystem.append(path, "old run, a long line that is longer than the new one\n")
        _ = try tailer.poll(fileSystem)
        fileSystem.addFile(path, "new run, even longer than the old run's line was, so size alone would not tell\n")
        let chunk = try tailer.poll(fileSystem)
        #expect(chunk.restarted)
        #expect(chunk.lines == ["new run, even longer than the old run's line was, so size alone would not tell"])
    }

    @Test func aByteBudgetSpreadsBigBacklogsOverPolls() throws {
        var tailer = LogTailer(url: url)
        fileSystem.append(path, String(repeating: "0123456789\n", count: 100))
        let first = try tailer.poll(fileSystem, maxBytes: 300)
        #expect(first.lines.count == 27)
        let rest = try tailer.poll(fileSystem)
        #expect(rest.lines.count == 73)
    }

    @Test func runawayLinesAreDeliveredInsteadOfGrowingForever() throws {
        var tailer = LogTailer(url: url)
        fileSystem.append(path, String(repeating: "x", count: LogTailer.maximumLineLength + 10))
        let chunk = try tailer.poll(fileSystem)
        #expect(chunk.lines.count == 1)
        #expect(chunk.lines[0].count == LogTailer.maximumLineLength + 10)
    }
}

@Suite struct ContentProgressTests {
    @Test func launcherCounters() {
        var progress = ContentProgress()
        #expect(progress.fraction == nil)
        progress.apply(.launcherDownloaded(downloaded: 25, total: 100))
        #expect(progress.fraction == 0.25)
        progress.apply(.launcherDownloaded(downloaded: 150, total: 100))
        #expect(progress.fraction == 1)
    }

    @Test func appletAssetsThenDone() {
        var progress = ContentProgress()
        progress.apply(.assetsToDownload(4))
        #expect(progress.fraction == 0)
        progress.apply(.launcherDownloaded(downloaded: 1, total: 4))
        #expect(progress.fraction == 0.25)
        progress.apply(.wastedCacheSpace(bytes: 1_000, percent: 2.5))
        progress.apply(.downloadCorrupted)
        progress.apply(.preprocessDone)
        #expect(progress.fraction == 1)
        #expect(progress.wastedCacheBytes == 1_000)
        #expect(progress.corruptionReported)
        progress.apply(.logRestarted)
        #expect(progress == ContentProgress())
    }

    @Test func nothingToDownloadIsComplete() {
        var progress = ContentProgress()
        progress.apply(.assetsToDownload(0))
        #expect(progress.fraction == 1)
    }
}
