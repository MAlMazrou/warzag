import Foundation
import Synchronization

// Resumable HTTP downloads of public files: DE's Warframe.msi, runtime packs and Warzag's update archive.

/// The start of an HTTP response, as far as resuming needs it.
public struct RangeResponseHead: Equatable, Sendable {
    public var statusCode: Int
    /// Length of this response's body.
    public var contentLength: Int64?
    public var contentRange: ContentRange?
    public var entityTag: String?
    public var lastModified: String?

    public init(statusCode: Int, contentLength: Int64? = nil, contentRange: ContentRange? = nil,
                entityTag: String? = nil, lastModified: String? = nil) {
        self.statusCode = statusCode
        self.contentLength = contentLength
        self.contentRange = contentRange
        self.entityTag = entityTag
        self.lastModified = lastModified
    }

    /// What If-Range should carry next time: the entity tag if it is a strong one, else Last-Modified.
    public var validator: String? {
        if let entityTag, !entityTag.hasPrefix("W/") { return entityTag }
        return lastModified
    }
}

/// `Content-Range: bytes 100-199/1000`, `bytes 100-199/*` or `bytes */1000` (RFC 9110, 14.4).
public struct ContentRange: Equatable, Sendable {
    /// nil for an unsatisfied range (`bytes */1000`).
    public var first: Int64?
    public var last: Int64?
    public var total: Int64?

    public init(first: Int64?, last: Int64?, total: Int64?) {
        self.first = first
        self.last = last
        self.total = total
    }

    public init?(header: String) {
        let text = header.trimmingCharacters(in: .whitespaces)
        guard text.lowercased().hasPrefix("bytes ") else { return nil }
        let parts = text.dropFirst(6).split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let totalText = parts[1].trimmingCharacters(in: .whitespaces)
        let total = totalText == "*" ? nil : Int64(totalText)
        guard totalText == "*" || total != nil else { return nil }
        let range = parts[0].trimmingCharacters(in: .whitespaces)
        if range == "*" {
            self.init(first: nil, last: nil, total: total)
            return
        }
        let bounds = range.split(separator: "-", maxSplits: 1)
        guard bounds.count == 2, let first = Int64(bounds[0]), let last = Int64(bounds[1]), first <= last else {
            return nil
        }
        self.init(first: first, last: last, total: total)
    }
}

/// Receives one response, in order: the head once, then body chunks. Called serially.
public protocol DownloadSink: AnyObject, Sendable {
    func receive(head: RangeResponseHead) throws
    func receive(data: Data) throws
}

/// One HTTP GET, optionally for the bytes from `offset` on. Throws transport errors (`URLError`) and whatever the
/// sink throws; HTTP statuses are the sink's business.
public protocol RangeTransport: Sendable {
    func get(_ url: URL, from offset: Int64, ifRange validator: String?, into sink: any DownloadSink) async throws
}

public struct DownloadProgress: Equatable, Sendable {
    public var receivedBytes: Int64
    public var totalBytes: Int64?

    public init(receivedBytes: Int64, totalBytes: Int64?) {
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
    }
}

public enum DownloadError: Error, Equatable, CustomStringConvertible {
    /// An HTTP status that retrying will not fix (404, 403, ...).
    case httpStatus(Int)
    /// The server answered for different bytes than asked; the partial file was discarded.
    case rangeMismatch
    case incomplete(received: Int64, expected: Int64)
    case gaveUp(attempts: Int, lastError: String)

    public var description: String {
        switch self {
        case .httpStatus(let code): "the server answered HTTP \(code)"
        case .rangeMismatch: "the server sent a different part of the file than asked"
        case .incomplete(let received, let expected): "the download ended after \(received) of \(expected) bytes"
        case .gaveUp(let attempts, let lastError): "the download failed \(attempts) times in a row (last: \(lastError))"
        }
    }

    var isTransient: Bool {
        switch self {
        case .httpStatus(let code): code == 408 || code == 429 || (500...599).contains(code)
        case .rangeMismatch, .incomplete: true
        case .gaveUp: false
        }
    }
}

/// Downloads one file into `<destination>.part`, resuming with HTTP Range requests (guarded by If-Range, so a file
/// the server replaced in the meantime starts over instead of being spliced), retrying network failures with
/// backoff, and moving the finished file into place only after `validate` accepts it.
///
/// A sidecar `<destination>.part.json` keeps the URL, validator and total size, so a resume survives a restart. It is
/// written as soon as a response is accepted, before its first byte lands, so a crash mid-download leaves it next to
/// the bytes.
public struct ResumableDownloader: Sendable {
    public var transport: any RangeTransport
    public var clock: any WallClock
    /// Consecutive failed attempts that made no progress before giving up.
    public var maximumAttempts: Int
    /// Waits between attempts; the last one repeats.
    public var backoff: [Duration]

    public init(transport: any RangeTransport = URLSessionRangeTransport(), clock: any WallClock = SystemClock(),
                maximumAttempts: Int = 6,
                backoff: [Duration] = [.seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30)]) {
        self.transport = transport
        self.clock = clock
        self.maximumAttempts = maximumAttempts
        self.backoff = backoff
    }

    public static func partURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent().appending(path: destination.lastPathComponent + ".part")
    }

    static func sidecarURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent().appending(path: destination.lastPathComponent + ".part.json")
    }

    struct Sidecar: Codable, Equatable {
        var url: URL
        var validator: String?
        var totalBytes: Int64?
    }

    /// Downloads `url` to `destination`. `validate` sees the complete `.part` file; when it throws, the partial data
    /// is deleted (the next try starts over) and the error is rethrown.
    public func download(
        _ url: URL, to destination: URL,
        validate: (URL) throws -> Void = { _ in },
        progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }
    ) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = Self.partURL(for: destination)
        let sidecarURL = Self.sidecarURL(for: destination)
        var sidecar = Self.loadSidecar(sidecarURL, for: url, part: part)
        if sidecar?.validator == nil {
            // Bytes nobody can vouch for (no sidecar, one for another URL, or a server that sent no validator)
            // could be part of another file: start over rather than resume them without If-Range.
            try? manager.removeItem(at: part)
            try? manager.removeItem(at: sidecarURL)
            sidecar = nil
        }

        var failures = 0
        while true {
            try Task.checkCancellation()
            let offset = Self.size(of: part) ?? 0
            let sink = PartFileSink(url: part, offset: offset, knownTotal: sidecar?.totalBytes,
                                    knownValidator: sidecar?.validator, progress: progress) { accepted in
                Self.saveSidecar(Sidecar(url: url, validator: accepted.validator, totalBytes: accepted.totalBytes),
                                 to: sidecarURL)
            }
            do {
                if let total = sidecar?.totalBytes, offset == total, offset > 0 {
                    // Complete already (the app stopped between the last byte and the rename).
                    break
                }
                try await transport.get(url, from: offset, ifRange: offset > 0 ? sidecar?.validator : nil, into: sink)
                try sink.finish()
                if let accepted = sink.accepted {
                    sidecar = Sidecar(url: url, validator: accepted.validator, totalBytes: accepted.totalBytes)
                }
                if let total = sink.total, sink.written != total {
                    throw DownloadError.incomplete(received: sink.written, expected: total)
                }
                break
            } catch {
                sink.close()
                // Only a response whose body was taken describes the bytes in the .part file; an error page's
                // entity tag must not become the file's validator.
                if let accepted = sink.accepted {
                    sidecar = Sidecar(url: url, validator: accepted.validator, totalBytes: accepted.totalBytes)
                }
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                if case DownloadError.rangeMismatch = error {
                    // Start over rather than splice two different files together.
                    try? manager.removeItem(at: part)
                    sidecar = nil
                    try? manager.removeItem(at: sidecarURL)
                }
                guard Self.isTransient(error) else { throw error }
                failures = sink.receivedThisAttempt > 0 ? 1 : failures + 1
                guard failures < maximumAttempts else {
                    throw DownloadError.gaveUp(attempts: failures, lastError: String(describing: error))
                }
                try await clock.sleep(for: backoff[min(failures - 1, backoff.count - 1)])
            }
        }

        do {
            try validate(part)
        } catch {
            try? manager.removeItem(at: part)
            try? manager.removeItem(at: sidecarURL)
            throw error
        }
        if manager.fileExists(atPath: destination.plainPath) { try manager.removeItem(at: destination) }
        try manager.moveItem(at: part, to: destination)
        try? manager.removeItem(at: sidecarURL)
    }

    static func isTransient(_ error: any Error) -> Bool {
        if let error = error as? DownloadError { return error.isTransient }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
                 .dnsLookupFailed, .resourceUnavailable, .internationalRoamingOff, .dataNotAllowed,
                 .secureConnectionFailed, .badServerResponse, .callIsActive, .backgroundSessionWasDisconnected:
                return true
            default:
                return false
            }
        }
        return false
    }

    static func size(of url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.plainPath) else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    private static func loadSidecar(_ sidecarURL: URL, for url: URL, part: URL) -> Sidecar? {
        guard size(of: part) != nil, let data = try? Data(contentsOf: sidecarURL),
              let sidecar = try? JSONDecoder().decode(Sidecar.self, from: data), sidecar.url == url else { return nil }
        return sidecar
    }

    static func saveSidecar(_ sidecar: Sidecar, to url: URL) {
        guard let data = try? WarzagJSON.encoder().encode(sidecar) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Writes one response into the `.part` file.
final class PartFileSink: DownloadSink, @unchecked Sendable {
    /// A response whose body goes into the `.part` file (200 or 206), as the sidecar must remember it.
    struct Accepted: Equatable, Sendable {
        var validator: String?
        var totalBytes: Int64?
    }

    private struct State {
        var handle: FileHandle?
        var accepted: Accepted?
        var written: Int64
        var total: Int64?
        var receivedThisAttempt: Int64 = 0
        var acceptingBody = false
    }

    let url: URL
    let offset: Int64
    /// The validator the bytes before `offset` were fetched under (sent as If-Range).
    let knownValidator: String?
    private let progress: @Sendable (DownloadProgress) -> Void
    /// Called once a response is accepted, after the `.part` file was opened (and truncated) for it and before any of
    /// its body is written.
    private let onAccept: @Sendable (Accepted) -> Void
    private let state: Mutex<State>

    init(url: URL, offset: Int64, knownTotal: Int64?, knownValidator: String? = nil,
         progress: @escaping @Sendable (DownloadProgress) -> Void,
         onAccept: @escaping @Sendable (Accepted) -> Void = { _ in }) {
        self.url = url
        self.offset = offset
        self.knownValidator = knownValidator
        self.progress = progress
        self.onAccept = onAccept
        state = Mutex(State(written: offset, total: knownTotal))
    }

    var accepted: Accepted? { state.withLock { $0.accepted } }
    var written: Int64 { state.withLock { $0.written } }
    var total: Int64? { state.withLock { $0.total } }
    var receivedThisAttempt: Int64 { state.withLock { $0.receivedThisAttempt } }

    func receive(head: RangeResponseHead) throws {
        let accepted = try state.withLock { state -> Accepted? in
            switch head.statusCode {
            case 206:
                guard let range = head.contentRange, range.first == offset else { throw DownloadError.rangeMismatch }
                state.handle = try Self.open(url, truncatingTo: offset)
                state.written = offset
                state.total = range.total ?? head.contentLength.map { offset + $0 }
                state.acceptingBody = true
                // A 206 to If-Range means the validator still holds; keep it if the response does not repeat it.
                state.accepted = Accepted(validator: head.validator ?? knownValidator, totalBytes: state.total)
            case 200:
                // The whole file: the server ignored the range, or the file changed and If-Range said so. The old
                // validator described the old bytes, which are gone.
                state.handle = try Self.open(url, truncatingTo: 0)
                state.written = 0
                state.total = head.contentLength
                state.acceptingBody = true
                state.accepted = Accepted(validator: head.validator, totalBytes: state.total)
            case 416:
                // Nothing left to send: complete if the file is exactly that long, otherwise start over.
                guard let total = head.contentRange?.total, total == offset else { throw DownloadError.rangeMismatch }
                state.total = total
                state.acceptingBody = false
                return nil
            default:
                throw DownloadError.httpStatus(head.statusCode)
            }
            return state.accepted
        }
        if let accepted { onAccept(accepted) }
        let snapshot = state.withLock { DownloadProgress(receivedBytes: $0.written, totalBytes: $0.total) }
        progress(snapshot)
    }

    func receive(data: Data) throws {
        let snapshot = try state.withLock { state -> DownloadProgress? in
            guard state.acceptingBody, let handle = state.handle else { return nil }
            try handle.write(contentsOf: data)
            state.written += Int64(data.count)
            state.receivedThisAttempt += Int64(data.count)
            return DownloadProgress(receivedBytes: state.written, totalBytes: state.total)
        }
        if let snapshot { progress(snapshot) }
    }

    /// Flushes and closes the file after a response ended normally.
    func finish() throws {
        try state.withLock { state in
            try state.handle?.synchronize()
            try state.handle?.close()
            state.handle = nil
        }
    }

    func close() {
        state.withLock { state in
            try? state.handle?.close()
            state.handle = nil
        }
    }

    private static func open(_ url: URL, truncatingTo length: Int64) throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: url.plainPath) {
            guard FileManager.default.createFile(atPath: url.plainPath, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.plainPath])
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(length))
        try handle.seekToEnd()
        return handle
    }
}

/// `RangeTransport` over URLSession, streaming the body to the sink as it arrives (one ephemeral session per
/// request: no cache, no cookies, no stored credentials).
public final class URLSessionRangeTransport: RangeTransport, @unchecked Sendable {
    // Only copied from, never mutated after init.
    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .ephemeral, timeout: TimeInterval = 60) {
        let configuration = configuration.copy() as? URLSessionConfiguration ?? .ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        self.configuration = configuration
    }

    public func get(_ url: URL, from offset: Int64, ifRange validator: String?, into sink: any DownloadSink) async throws {
        var request = URLRequest(url: url)
        // Byte ranges count the bytes as stored; a compressed transfer would make them meaningless.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            if let validator { request.setValue(validator, forHTTPHeaderField: "If-Range") }
        }
        let delegate = RangeTaskDelegate(sink: sink)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                delegate.begin(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

private final class RangeTaskDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<Void, any Error>?
        var sinkError: (any Error)?
    }

    private let sink: any DownloadSink
    private let state = Mutex(State())

    init(sink: any DownloadSink) {
        self.sink = sink
    }

    func begin(_ continuation: CheckedContinuation<Void, any Error>) {
        state.withLock { $0.continuation = continuation }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            state.withLock { $0.sinkError = URLError(.badServerResponse) }
            completionHandler(.cancel)
            return
        }
        let header = { (name: String) in http.value(forHTTPHeaderField: name) }
        let head = RangeResponseHead(
            statusCode: http.statusCode,
            contentLength: header("Content-Length").flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) },
            contentRange: header("Content-Range").flatMap(ContentRange.init(header:)),
            entityTag: header("ETag"),
            lastModified: header("Last-Modified")
        )
        do {
            try sink.receive(head: head)
            completionHandler(.allow)
        } catch {
            state.withLock { $0.sinkError = error }
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try sink.receive(data: data)
        } catch {
            state.withLock { $0.sinkError = error }
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, sinkError) = state.withLock { state in
            defer { state.continuation = nil }
            return (state.continuation, state.sinkError)
        }
        if let sinkError {
            continuation?.resume(throwing: sinkError)
        } else if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }
}
