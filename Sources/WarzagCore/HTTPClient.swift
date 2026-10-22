import Foundation

/// Network side effects. Warzag only fetches public files (Valve's Steam installer, DE's Warframe.msi, signed
/// manifests, runtime packs, update archives); the game's own downloads are left to DE's launcher.
public protocol HTTPClient: Sendable {
    func data(from url: URL) async throws -> Data
    /// Downloads to `destination`, replacing anything already there.
    func download(from url: URL, to destination: URL) async throws
}

public enum HTTPError: Error, Equatable, CustomStringConvertible {
    case status(Int, URL)

    public var description: String {
        switch self {
        case .status(let code, let url): "HTTP \(code) from \(url.host() ?? url.absoluteString)"
        }
    }
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// For signed manifests: always from the server. A cached copy could be one that has expired or been replaced
    /// since, and retries would read the same copy again.
    public static let uncachedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    public func data(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        try Self.check(response, url)
        return data
    }

    public func download(from url: URL, to destination: URL) async throws {
        let (temporary, response) = try await session.download(from: url)
        try Self.check(response, url)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.plainPath) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporary, to: destination)
    }

    private static func check(_ response: URLResponse, _ url: URL) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPError.status(http.statusCode, url)
        }
    }
}
