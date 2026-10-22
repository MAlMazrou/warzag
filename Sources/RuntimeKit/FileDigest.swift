import CryptoKit
import Foundation
import WarzagCore

public struct DigestMismatch: Error, Equatable, CustomStringConvertible {
    public var expected: String
    public var actual: String
    public var description: String { "SHA-256 mismatch: expected \(expected), got \(actual)" }
}

public struct SizeMismatch: Error, Equatable, CustomStringConvertible {
    public var expected: Int64
    public var actual: Int64
    public var description: String { "size mismatch: expected \(expected) bytes, got \(actual)" }
}

/// Streaming SHA-256 over files of any size (runtime packs are hundreds of megabytes).
public enum FileDigest {
    public static func sha256(of url: URL, fileSystem: any FileSystem, chunkSize: Int = 1 << 20) throws -> String {
        var hasher = SHA256()
        try fileSystem.forEachChunk(of: url, chunkSize: chunkSize) { hasher.update(data: $0) }
        return hasher.finalize().hexString
    }

    /// Throws `SizeMismatch` or `DigestMismatch` unless the file is exactly what was published.
    public static func verify(_ url: URL, sha256 expected: String, size: Int64? = nil,
                              fileSystem: any FileSystem) throws {
        if let size {
            let actual = Int64(try fileSystem.attributes(of: url).size)
            guard actual == size else { throw SizeMismatch(expected: size, actual: actual) }
        }
        let actual = try sha256(of: url, fileSystem: fileSystem)
        guard actual == expected.lowercased() else { throw DigestMismatch(expected: expected.lowercased(), actual: actual) }
    }
}

extension Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

extension Data {
    var sha256Hex: String { SHA256.hash(data: self).hexString }
}
