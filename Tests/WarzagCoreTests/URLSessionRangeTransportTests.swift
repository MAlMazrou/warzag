import Foundation
import Synchronization
import Testing
import WarzagTestSupport
@testable import WarzagCore

/// A Range-capable HTTP server inside URLSession's loading system, so the real transport (delegate, headers,
/// streaming, errors) runs without a network.
final class StubURLProtocol: URLProtocol {
    struct Stub: Sendable {
        var body: Data
        var etag = #""v1""#
        /// Drop the connection after this many body bytes, on the first request only.
        var dropFirstAfter: Int?
        var status: Int?
    }

    static let host = "stub.warzag.test"
    private static let stubs = Mutex<[String: Stub]>([:])
    private static let seen = Mutex<[String: [[String: String]]]>([:])

    static func serve(_ path: String, _ stub: Stub) -> URL {
        stubs.withLock { $0[path] = stub }
        return URL(string: "https://\(host)\(path)")!
    }

    /// Request headers, per request, for one path.
    static func requests(_ path: String) -> [[String: String]] {
        seen.withLock { $0[path] ?? [] }
    }

    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let client else { return }
        let path = url.path
        let headers = request.allHTTPHeaderFields ?? [:]
        let count = Self.seen.withLock { seen -> Int in
            seen[path, default: []].append(headers)
            return seen[path]!.count
        }
        guard let stub = Self.stubs.withLock({ $0[path] }) else {
            client.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let length = stub.body.count
        func respond(_ status: Int, _ fields: [String: String], _ data: Data, dropAfter: Int? = nil) {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: fields.merging(["ETag": stub.etag]) { $1 })!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let end = min(data.count, dropAfter ?? data.count)
            var start = 0
            while start < end {
                let stop = min(end, start + 16_384)
                client.urlProtocol(self, didLoad: data.subdata(in: start..<stop))
                start = stop
            }
            if dropAfter != nil {
                // A real connection drops after the bytes before it were handed on; failing in the same breath makes
                // URLSession discard data it has not delivered yet.
                let client = UncheckedBox(client)
                let protocolInstance = UncheckedBox(self)
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                    client.value.urlProtocol(protocolInstance.value, didFailWithError: URLError(.networkConnectionLost))
                }
            } else {
                client.urlProtocolDidFinishLoading(self)
            }
        }
        if let status = stub.status {
            respond(status, ["Content-Length": "4"], Data("nope".utf8))
            return
        }
        let dropAfter = count == 1 ? stub.dropFirstAfter : nil
        let range = headers["Range"].flatMap { Int($0.dropFirst("bytes=".count).dropLast()) }
        let ifRange = headers["If-Range"]
        if let offset = range, ifRange == nil || ifRange == stub.etag {
            guard offset < length else {
                respond(416, ["Content-Range": "bytes */\(length)"], Data())
                return
            }
            respond(206, ["Content-Range": "bytes \(offset)-\(length - 1)/\(length)",
                          "Content-Length": "\(length - offset)"],
                    stub.body.subdata(in: offset..<length), dropAfter: dropAfter)
        } else {
            respond(200, ["Content-Length": "\(length)"], stub.body, dropAfter: dropAfter)
        }
    }
}

struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

final class RecordingSink: DownloadSink {
    private let state = Mutex<(heads: [RangeResponseHead], data: Data)>(([], Data()))
    let rejectStatus: Bool

    init(rejectStatus: Bool = false) {
        self.rejectStatus = rejectStatus
    }

    var heads: [RangeResponseHead] { state.withLock { $0.heads } }
    var data: Data { state.withLock { $0.data } }

    func receive(head: RangeResponseHead) throws {
        state.withLock { $0.heads.append(head) }
        if rejectStatus, !(200..<300).contains(head.statusCode) { throw DownloadError.httpStatus(head.statusCode) }
    }

    func receive(data: Data) throws {
        state.withLock { $0.data.append(data) }
    }
}

@Suite struct URLSessionRangeTransportTests {
    let body = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 1) })
    let transport = URLSessionRangeTransport(configuration: StubURLProtocol.configuration, timeout: 10)

    @Test func aPlainGetStreamsTheWholeFile() async throws {
        let path = "/plain-\(UUID().uuidString)"
        let url = StubURLProtocol.serve(path, .init(body: body))
        let sink = RecordingSink()
        try await transport.get(url, from: 0, ifRange: nil, into: sink)
        #expect(sink.heads == [RangeResponseHead(statusCode: 200, contentLength: 200_000, entityTag: #""v1""#)])
        #expect(sink.data == body)
        let headers = try #require(StubURLProtocol.requests(path).first)
        #expect(headers["Range"] == nil && headers["If-Range"] == nil)
        #expect(headers["Accept-Encoding"] == "identity")
    }

    @Test func aResumeAsksForTheRestWithIfRange() async throws {
        let path = "/range-\(UUID().uuidString)"
        let url = StubURLProtocol.serve(path, .init(body: body))
        let sink = RecordingSink()
        try await transport.get(url, from: 150_000, ifRange: #""v1""#, into: sink)
        #expect(sink.heads.first?.statusCode == 206)
        #expect(sink.heads.first?.contentRange == ContentRange(first: 150_000, last: 199_999, total: 200_000))
        #expect(sink.data == body.subdata(in: 150_000..<200_000))
        let headers = try #require(StubURLProtocol.requests(path).first)
        #expect(headers["Range"] == "bytes=150000-")
        #expect(headers["If-Range"] == #""v1""#)
    }

    @Test func aDroppedConnectionIsAnError() async throws {
        let path = "/drop-\(UUID().uuidString)"
        let url = StubURLProtocol.serve(path, .init(body: body, dropFirstAfter: 40_000))
        let sink = RecordingSink()
        let error = await #expect(throws: URLError.self) {
            try await transport.get(url, from: 0, ifRange: nil, into: sink)
        }
        #expect(error?.code == .networkConnectionLost)
        // What arrived before the drop was handed on, so a resume can start after it.
        #expect(sink.data == body.prefix(40_000))
    }

    @Test func whatTheSinkThrowsIsWhatTheCallerSees() async throws {
        let url = StubURLProtocol.serve("/missing-\(UUID().uuidString)", .init(body: body, status: 404))
        await #expect(throws: DownloadError.httpStatus(404)) {
            try await transport.get(url, from: 0, ifRange: nil, into: RecordingSink(rejectStatus: true))
        }
    }

    @Test func theDownloaderResumesOverURLSession() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = "/resume-\(UUID().uuidString)"
        let url = StubURLProtocol.serve(path, .init(body: body, dropFirstAfter: 70_000))
        let destination = directory.appending(path: "Warframe.msi")
        let clock = ManualClock()
        try await ResumableDownloader(transport: transport, clock: clock).download(url, to: destination)
        #expect(try Data(contentsOf: destination) == body)
        let requests = StubURLProtocol.requests(path)
        #expect(requests.count == 2)
        let resumedAt = try #require(requests.last?["Range"])
        #expect(resumedAt.hasPrefix("bytes=") && resumedAt != "bytes=0-")
        #expect(requests.last?["If-Range"] == #""v1""#)
        #expect(clock.sleeps == [.seconds(2)])
    }
}
