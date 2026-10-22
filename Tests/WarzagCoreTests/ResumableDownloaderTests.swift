import Foundation
import Synchronization
import Testing
import WarzagTestSupport
@testable import WarzagCore

@Suite struct ResumableDownloaderTests {
    let body = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    let source = URL(string: "https://content.warframe.com/dl/Warframe.msi")!

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.plainPath) }

    @Test func aFreshDownloadLandsInPlace() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "Warframe.msi")
        let transport = FakeRangeTransport(body: body)
        let clock = ManualClock()
        let progress = Recorder<DownloadProgress>()
        try await ResumableDownloader(transport: transport, clock: clock)
            .download(source, to: destination, progress: { progress.append($0) })
        #expect(try Data(contentsOf: destination) == body)
        #expect(!exists(ResumableDownloader.partURL(for: destination)))
        #expect(!exists(ResumableDownloader.sidecarURL(for: destination)))
        #expect(progress.all.first == DownloadProgress(receivedBytes: 0, totalBytes: 300_000))
        #expect(progress.all.last == DownloadProgress(receivedBytes: 300_000, totalBytes: 300_000))
        #expect(transport.requests == [.init(offset: 0, validator: nil)])
        #expect(clock.sleeps.isEmpty)
    }

    @Test func aDroppedConnectionResumesWhereItStopped() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "Warframe.msi")
        let transport = FakeRangeTransport(body: body, behaviors: [.dropAfter(100_000)])
        let clock = ManualClock()
        try await ResumableDownloader(transport: transport, clock: clock).download(source, to: destination)
        #expect(try Data(contentsOf: destination) == body)
        #expect(transport.requests == [.init(offset: 0, validator: nil), .init(offset: 100_000, validator: #""v1""#)])
        #expect(clock.sleeps == [.seconds(2)])
    }

    @Test func aResumeSurvivesAnAppRestart() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "Warframe.msi")
        let first = FakeRangeTransport(body: body, behaviors: [.dropAfter(120_000)])
        await #expect(throws: DownloadError.self) {
            try await ResumableDownloader(transport: first, clock: ManualClock(), maximumAttempts: 1)
                .download(source, to: destination)
        }
        #expect(ResumableDownloader.size(of: ResumableDownloader.partURL(for: destination)) == 120_000)
        // A new process: only the sidecar remembers the validator.
        let second = FakeRangeTransport(body: body)
        try await ResumableDownloader(transport: second, clock: ManualClock()).download(source, to: destination)
        #expect(second.requests == [.init(offset: 120_000, validator: #""v1""#)])
        #expect(try Data(contentsOf: destination) == body)
    }

    @Test func aFileReplacedOnTheServerIsNotSplicedIntoTheOldOne() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "Warframe.msi")
        let transport = FakeRangeTransport(body: body, behaviors: [.dropAfter(100_000)])
        await #expect(throws: DownloadError.self) {
            try await ResumableDownloader(transport: transport, clock: ManualClock(), maximumAttempts: 1)
                .download(source, to: destination)
        }
        let newer = Data(body.reversed())
        transport.replace(body: newer, etag: #""v2""#)
        try await ResumableDownloader(transport: transport, clock: ManualClock()).download(source, to: destination)
        // If-Range carried the old tag, so the server sent the whole new file.
        #expect(transport.requests.last == .init(offset: 100_000, validator: #""v1""#))
        #expect(try Data(contentsOf: destination) == newer)
    }

    @Test func aServerWithoutRangesIsReadFromTheStart() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "Warframe.msi")
        let transport = FakeRangeTransport(body: body, behaviors: [.dropAfter(50_000), .ignoreRange])
        try await ResumableDownloader(transport: transport, clock: ManualClock()).download(source, to: destination)
        #expect(try Data(contentsOf: destination) == body)
        #expect(transport.requests.count == 2)
    }

    @Test func aCompletePartIsFinishedWithoutData() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // The app stopped between the last byte and the rename: the sidecar knows the total, so nothing is fetched.
        let destination = directory.appending(path: "Warframe.msi")
        try body.write(to: ResumableDownloader.partURL(for: destination))
        try Self.writeSidecar(.init(url: source, validator: #""v1""#, totalBytes: 300_000), for: destination)
        let transport = FakeRangeTransport(body: body)
        try await ResumableDownloader(transport: transport, clock: ManualClock()).download(source, to: destination)
        #expect(transport.requests.isEmpty)
        #expect(try Data(contentsOf: destination) == body)

        // Without a known total (a response without Content-Length), the server's 416 says the part is complete.
        let unsized = directory.appending(path: "unsized/Warframe.msi")
        try FileManager.default.createDirectory(at: unsized.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: ResumableDownloader.partURL(for: unsized))
        try Self.writeSidecar(.init(url: source, validator: #""v1""#, totalBytes: nil), for: unsized)
        let server = FakeRangeTransport(body: body)
        try await ResumableDownloader(transport: server, clock: ManualClock()).download(source, to: unsized)
        #expect(server.requests == [.init(offset: 300_000, validator: #""v1""#)])
        #expect(try Data(contentsOf: unsized) == body)
    }

    // MARK: Crashes and partial files of unknown origin (kill -9 never re-downloads finished bytes)

    static func writeSidecar(_ sidecar: ResumableDownloader.Sidecar, for destination: URL) throws {
        try WarzagJSON.encoder().encode(sidecar).write(to: ResumableDownloader.sidecarURL(for: destination))
    }

    /// Copies what is on disk for `destination` (its .part and, if there is one, its sidecar) into `image`.
    static func crashImage(of destination: URL, into image: URL) -> @Sendable () -> Void {
        let files = [ResumableDownloader.partURL(for: destination), ResumableDownloader.sidecarURL(for: destination)]
        return {
            let manager = FileManager.default
            try? manager.createDirectory(at: image, withIntermediateDirectories: true)
            for file in files where manager.fileExists(atPath: file.plainPath) {
                try? manager.copyItem(at: file, to: image.appending(path: file.lastPathComponent))
            }
        }
    }

    /// Puts a crash image back next to `<directory>/Warframe.msi`, as a restarted app finds it.
    static func restore(_ image: URL, into directory: URL) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in try manager.contentsOfDirectory(atPath: image.plainPath) {
            try manager.copyItem(at: image.appending(path: name), to: directory.appending(path: name))
        }
        return directory.appending(path: "Warframe.msi")
    }

    /// Kills the first download after 120,000 bytes and returns the restarted app's destination.
    func killedDownload(in directory: URL) async throws -> URL {
        let crashed = directory.appending(path: "crashed/Warframe.msi")
        let image = directory.appending(path: "image", directoryHint: .isDirectory)
        let transport = FakeRangeTransport(body: body, behaviors: [
            .crash(after: 120_000, snapshot: Self.crashImage(of: crashed, into: image)),
        ])
        await #expect(throws: URLError.self) {
            try await ResumableDownloader(transport: transport, clock: ManualClock()).download(source, to: crashed)
        }
        return try Self.restore(image, into: directory.appending(path: "restarted", directoryHint: .isDirectory))
    }

    @Test func aDownloadKilledMidwayResumesWithItsValidator() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = try await killedDownload(in: directory)
        #expect(ResumableDownloader.size(of: ResumableDownloader.partURL(for: destination)) == 120_000)
        let server = FakeRangeTransport(body: body)
        try await ResumableDownloader(transport: server, clock: ManualClock()).download(source, to: destination)
        #expect(server.requests == [.init(offset: 120_000, validator: #""v1""#)])
        #expect(try Data(contentsOf: destination) == body)
    }

    @Test func aDownloadKilledMidwayIsNeverSplicedOntoAFileReplacedSince() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = try await killedDownload(in: directory)
        // DE published a new Warframe.msi while the Mac was off.
        let newer = Data(body.reversed())
        let server = FakeRangeTransport(body: newer, etag: #""v2""#)
        try await ResumableDownloader(transport: server, clock: ManualClock()).download(source, to: destination)
        #expect(try Data(contentsOf: destination) == newer)
    }

    @Test func aPartWithoutItsSidecarIsNotResumed() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Bytes nobody can vouch for (the sidecar is gone): without If-Range they could be another file's.
        let destination = directory.appending(path: "Warframe.msi")
        try Data(repeating: 0xEE, count: 100_000).write(to: ResumableDownloader.partURL(for: destination))
        let server = FakeRangeTransport(body: body)
        try await ResumableDownloader(transport: server, clock: ManualClock()).download(source, to: destination)
        #expect(server.requests == [.init(offset: 0, validator: nil)])
        #expect(try Data(contentsOf: destination) == body)
    }

    @Test func aPartOfAnotherURLIsNotResumed() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // The installer moved: what was fetched from the old URL is not a prefix of the new file.
        let destination = directory.appending(path: "Warframe.msi")
        try Data(repeating: 0xEE, count: 100_000).write(to: ResumableDownloader.partURL(for: destination))
        try Self.writeSidecar(.init(url: URL(string: "https://content.warframe.com/dl/Old.msi")!, validator: #""v1""#,
                                    totalBytes: 300_000), for: destination)
        let server = FakeRangeTransport(body: body)
        try await ResumableDownloader(transport: server, clock: ManualClock()).download(source, to: destination)
        #expect(server.requests == [.init(offset: 0, validator: nil)])
        #expect(try Data(contentsOf: destination) == body)
    }

    @Test func anErrorPagesTagDoesNotReplaceTheFilesValidator() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "Warframe.msi")
        let server = FakeRangeTransport(body: body, behaviors: [.dropAfter(100_000), .errorPage(503, etag: #""error-page""#)])
        try await ResumableDownloader(transport: server, clock: ManualClock()).download(source, to: destination)
        // The 503's tag says nothing about the file: the resume after it still asks for the bytes of "v1".
        #expect(server.requests == [
            .init(offset: 0, validator: nil), .init(offset: 100_000, validator: #""v1""#),
            .init(offset: 100_000, validator: #""v1""#),
        ])
        #expect(try Data(contentsOf: destination) == body)
    }

    @Test func aMissingFileIsNotRetried() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = FakeRangeTransport(body: body, behaviors: [.status(404)])
        let clock = ManualClock()
        await #expect(throws: DownloadError.httpStatus(404)) {
            try await ResumableDownloader(transport: transport, clock: clock)
                .download(source, to: directory.appending(path: "Warframe.msi"))
        }
        #expect(transport.requests.count == 1)
        #expect(clock.sleeps.isEmpty)
    }

    @Test func serverErrorsBackOffThenGiveUp() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = FakeRangeTransport(body: body, behaviors: Array(repeating: .status(503), count: 6))
        let clock = ManualClock()
        await #expect(throws: DownloadError.gaveUp(attempts: 6, lastError: "the server answered HTTP 503")) {
            try await ResumableDownloader(transport: transport, clock: clock)
                .download(source, to: directory.appending(path: "Warframe.msi"))
        }
        #expect(clock.sleeps == [.seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30)])
    }

    @Test func aRejectedFileIsDeletedSoTheNextTryStartsClean() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "Warframe.msi")
        struct Rejected: Error, Equatable {}
        await #expect(throws: Rejected()) {
            try await ResumableDownloader(transport: FakeRangeTransport(body: body), clock: ManualClock())
                .download(source, to: destination, validate: { _ in throw Rejected() })
        }
        #expect(!exists(destination))
        #expect(!exists(ResumableDownloader.partURL(for: destination)))
        #expect(!exists(ResumableDownloader.sidecarURL(for: destination)))
    }

    @Test func aMismatchedRangeIsDiscarded() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "Warframe.msi")
        try body.prefix(100_000).write(to: ResumableDownloader.partURL(for: destination))
        try Self.writeSidecar(.init(url: source, validator: #""v1""#, totalBytes: 300_000), for: destination)
        let transport = FakeRangeTransport(body: body, behaviors: [.wrongRange])
        try await ResumableDownloader(transport: transport, clock: ManualClock()).download(source, to: destination)
        #expect(transport.requests == [.init(offset: 100_000, validator: #""v1""#), .init(offset: 0, validator: nil)])
        #expect(try Data(contentsOf: destination) == body)
    }

    @Test(arguments: [
        ("bytes 100-199/1000", ContentRange(first: 100, last: 199, total: 1000)),
        ("bytes 0-0/1", ContentRange(first: 0, last: 0, total: 1)),
        ("bytes 100-199/*", ContentRange(first: 100, last: 199, total: nil)),
        ("bytes */1000", ContentRange(first: nil, last: nil, total: 1000)),
        ("Bytes 5-9/10", ContentRange(first: 5, last: 9, total: 10)),
    ])
    func contentRanges(_ header: String, _ range: ContentRange) {
        #expect(ContentRange(header: header) == range)
    }

    @Test(arguments: ["items 1-2/3", "bytes 9-5/10", "bytes 1-2", "bytes a-b/c", "bytes */*x"])
    func notContentRanges(_ header: String) {
        #expect(ContentRange(header: header) == nil)
    }

    @Test func weakTagsAreNotValidators() {
        #expect(RangeResponseHead(statusCode: 200, entityTag: #"W/"x""#, lastModified: "Thu, 15 Oct 2026").validator
            == "Thu, 15 Oct 2026")
        #expect(RangeResponseHead(statusCode: 200, entityTag: #""x""#).validator == #""x""#)
    }
}
