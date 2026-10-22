import Foundation
import Synchronization
import WarzagCore

/// An HTTP server for one file, with scripted misbehaviour per request (for `ResumableDownloader` and the downloads
/// built on it: DE's installer in GameKit, runtime packs in EngineKit).
public final class FakeRangeTransport: RangeTransport {
    public enum Behavior: Sendable {
        /// Honours Range (and If-Range against the current entity tag), like content.warframe.com.
        case serve
        /// Always the whole file with 200.
        case ignoreRange
        /// Like `serve`, but the connection drops after this many body bytes.
        case dropAfter(Int)
        /// Only a status line.
        case status(Int)
        /// An error status whose page carries an entity tag of its own (a CDN error page).
        case errorPage(Int, etag: String)
        /// 206 for a different start than asked.
        case wrongRange
        /// Like `serve`, but the process dies (kill -9, power cut) after this many body bytes: `snapshot` sees the disk
        /// as it is at that moment, before any error handling could write anything.
        case crash(after: Int, snapshot: @Sendable () -> Void)
    }

    public struct Request: Equatable, Sendable {
        public var offset: Int64
        public var validator: String?

        public init(offset: Int64, validator: String?) {
            self.offset = offset
            self.validator = validator
        }
    }

    private struct State {
        var body: Data
        var etag: String
        var behaviors: [Behavior]
        var requests: [Request] = []
        var urls: [URL] = []
    }

    private let state: Mutex<State>

    public init(body: Data, etag: String = #""v1""#, behaviors: [Behavior] = []) {
        state = Mutex(State(body: body, etag: etag, behaviors: behaviors))
    }

    public func replace(body: Data, etag: String) {
        state.withLock {
            $0.body = body
            $0.etag = etag
        }
    }

    public var requests: [Request] { state.withLock { $0.requests } }
    /// Every URL asked for, in order.
    public var urls: [URL] { state.withLock { $0.urls } }

    public func get(_ url: URL, from offset: Int64, ifRange validator: String?, into sink: any DownloadSink) async throws {
        let (body, etag, behavior) = state.withLock { state -> (Data, String, Behavior) in
            state.requests.append(Request(offset: offset, validator: validator))
            state.urls.append(url)
            let behavior = state.behaviors.isEmpty ? .serve : state.behaviors.removeFirst()
            return (state.body, state.etag, behavior)
        }
        let length = Int64(body.count)
        switch behavior {
        case .status(let code):
            try sink.receive(head: RangeResponseHead(statusCode: code, contentLength: 0))
        case .errorPage(let code, let tag):
            try sink.receive(head: RangeResponseHead(statusCode: code, contentLength: 0, entityTag: tag))
        case .ignoreRange:
            try sink.receive(head: RangeResponseHead(statusCode: 200, contentLength: length, entityTag: etag))
            try Self.deliver(body, to: sink, limit: nil)
        case .wrongRange:
            let start = offset + 1
            try sink.receive(head: RangeResponseHead(
                statusCode: 206, contentLength: length - start,
                contentRange: ContentRange(first: start, last: length - 1, total: length), entityTag: etag))
            try Self.deliver(body.subdata(in: Int(start)..<body.count), to: sink, limit: nil)
        case .serve, .dropAfter, .crash:
            var limit: Int?
            if case .dropAfter(let bytes) = behavior { limit = bytes }
            if case .crash(let bytes, _) = behavior { limit = bytes }
            if offset > 0, offset >= length {
                try sink.receive(head: RangeResponseHead(statusCode: 416,
                                                         contentRange: ContentRange(first: nil, last: nil, total: length)))
                return
            }
            if offset > 0, validator == nil || validator == etag {
                try sink.receive(head: RangeResponseHead(
                    statusCode: 206, contentLength: length - offset,
                    contentRange: ContentRange(first: offset, last: length - 1, total: length), entityTag: etag))
                try Self.deliver(body.subdata(in: Int(offset)..<body.count), to: sink, limit: limit)
            } else {
                try sink.receive(head: RangeResponseHead(statusCode: 200, contentLength: length, entityTag: etag))
                try Self.deliver(body, to: sink, limit: limit)
            }
            if case .crash(_, let snapshot) = behavior {
                snapshot()
                throw URLError(.cancelled)
            }
            if limit != nil { throw URLError(.networkConnectionLost) }
        }
    }

    private static func deliver(_ data: Data, to sink: any DownloadSink, limit: Int?) throws {
        let end = min(data.count, limit ?? data.count)
        var start = 0
        while start < end {
            let stop = min(end, start + 65_536)
            try sink.receive(data: data.subdata(in: start..<stop))
            start = stop
        }
    }
}

/// Collects values a callback reports (progress, events), from any thread.
public final class Recorder<Value: Sendable>: Sendable {
    private let values = Mutex<[Value]>([])

    public init() {}

    public func append(_ value: Value) {
        values.withLock { $0.append(value) }
    }

    public var all: [Value] { values.withLock { $0 } }
}

/// A new, empty folder under the temporary directory, for tests that need real files.
public func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "warzag-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
