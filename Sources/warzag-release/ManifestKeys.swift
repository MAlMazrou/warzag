import CryptoKit
import Darwin
import Foundation

/// Ed25519 manifest-signing keys on disk: the private key is the base64 of its 32 raw bytes (one line, mode 600),
/// the public key likewise in `<name>.ed25519.pub`. The app pins public keys by key id (`ManifestTrust.keyID(for:)`).
enum ManifestKeys {
    static let privateExtension = ".ed25519"
    static let publicExtension = ".ed25519.pub"

    static func publicKey(base64 text: String) throws -> Curve25519.Signing.PublicKey {
        guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), data.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: data) else {
            throw ReleaseError(message: "the public key must be the base64 of a raw 32-byte Ed25519 key")
        }
        return key
    }

    /// Reads a private key, refusing one that other users could read (as ssh does).
    static func readPrivateKey(at url: URL) throws -> Curve25519.Signing.PrivateKey {
        let path = url.path(percentEncoded: false)
        var info = stat()
        guard stat(path, &info) == 0 else { throw ReleaseError(message: "cannot read the private key \(path)") }
        guard info.st_mode & 0o077 == 0 else {
            throw ReleaseError(message: "\(path) is readable by other users; run chmod 600 on it")
        }
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), data.count == 32,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
            throw ReleaseError(message: "\(path) is not a base64 Ed25519 private key")
        }
        return key
    }

    /// Writes a new key pair as `<directory>/<name>.ed25519` (mode 600) and `<name>.ed25519.pub` (mode 644).
    /// Never replaces an existing file; the directory is created with mode 700 if it is missing.
    static func writeNewKeyPair(_ key: Curve25519.Signing.PrivateKey, in directory: URL,
                                name: String) throws -> (privateKey: URL, publicKey: URL) {
        let directoryPath = directory.path(percentEncoded: false)
        if !FileManager.default.fileExists(atPath: directoryPath) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let privateURL = directory.appending(path: name + privateExtension)
        let publicURL = directory.appending(path: name + publicExtension)
        for url in [privateURL, publicURL] where FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            throw ReleaseError(message: "\(url.path(percentEncoded: false)) already exists; keys are never replaced")
        }
        try createExclusively(privateURL, contents: key.rawRepresentation.base64EncodedString() + "\n", mode: 0o600)
        try createExclusively(publicURL, contents: key.publicKey.rawRepresentation.base64EncodedString() + "\n",
                              mode: 0o644)
        return (privateURL, publicURL)
    }

    /// O_EXCL creation with the final mode from the start, so the secret is never briefly readable by others.
    private static func createExclusively(_ url: URL, contents: String, mode: mode_t) throws {
        let path = url.path(percentEncoded: false)
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, mode)
        guard descriptor >= 0 else {
            throw ReleaseError(message: "cannot create \(path): \(String(cString: strerror(errno)))")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: Data(contents.utf8))
        try handle.close()
        // open(2) applied the umask; make the mode exact.
        guard chmod(path, mode) == 0 else { throw ReleaseError(message: "cannot set the mode of \(path)") }
    }
}
