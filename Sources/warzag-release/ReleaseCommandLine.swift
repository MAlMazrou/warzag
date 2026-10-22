import AppUpdateKit
import Foundation
import RuntimeKit
import WarzagCore

enum ReleaseCommand: Equatable {
    case help
    case keygen(KeygenOptions)
    case publicKey(keyFile: String)
    case manifest(ManifestOptions)
    case verify(VerifyOptions)
    case appManifest(AppManifestOptions)
    case appVerify(AppVerifyOptions)
}

struct KeygenOptions: Equatable {
    var directory: String
    var name: String = "manifest-signing"
}

struct ManifestOptions: Equatable {
    var pack: String
    var version: String
    var serial: UInt64
    var expiresInDays: Int
    var url: URL
    var keyFile: String
    var signerFingerprint: String
    /// Defaults to the key's own id (`ManifestTrust.keyID(for:)`).
    var keyID: String?
    var minLauncher: String = "0.1.0"
    var minMacOS: String = "15.0"
    var revoked: [String] = []
    var killSwitch: KillSwitch = .none
    /// Where the signed manifest goes; nil means stdout.
    var output: String?
}

struct VerifyOptions: Equatable {
    var manifest: String
    var pack: String
    /// Base64 of the raw 32-byte Ed25519 public key.
    var publicKey: String
    var keyID: String?
    /// The certificate the pack must be signed with; nil accepts the one the manifest names (with a note).
    var signerFingerprint: String?
    /// Checked against the manifest's minLauncher when set (empty skips the check, as in the app).
    var appVersion: String = ""
    /// Defaults to this Mac's macOS version.
    var macOSVersion: String?
    /// Runs RuntimeInstaller against a scratch home: unpack, code signature and signer, activation.
    var install: Bool = true
}

/// `app-manifest`: a signed app manifest for an update archive (Warzag's own updates).
struct AppManifestOptions: Equatable {
    var archive: String
    var serial: UInt64
    var expiresInDays: Int
    var url: URL
    var keyFile: String
    var signerFingerprint: String
    /// Defaults to the key's own id (`ManifestTrust.keyID(for:)`).
    var keyID: String?
    /// Defaults to the app's LSMinimumSystemVersion.
    var minMacOS: String?
    var releaseNotes: URL?
    /// Where the signed manifest goes; nil means stdout.
    var output: String?
}

/// `app-verify`: what Warzag checks before it installs an update.
struct AppVerifyOptions: Equatable {
    var manifest: String
    var archive: String
    /// Base64 of the raw 32-byte Ed25519 public key.
    var publicKey: String
    var keyID: String?
    /// The certificate the app must be signed with; nil accepts the one the manifest names (with a note).
    var signerFingerprint: String?
    /// When set, the offer must be a newer build (the app never offers this build or an older one).
    var runningBuild: String?
    /// Defaults to this Mac's macOS version.
    var macOSVersion: String?
}

struct ReleaseUsageError: Error, Equatable, CustomStringConvertible {
    var message: String
    var description: String { message }
}

/// `warzag-release <command> [--option value]...`
enum ReleaseCommandLine {
    static let usage = """
        usage: warzag-release <command> [options]

        commands:
          keygen --out <dir> [--name <name>]
              New Ed25519 key pair for signing runtime and app manifests: <dir>/<name>.ed25519 (private key, base64,
              mode 600, never overwritten) and <dir>/<name>.ed25519.pub (public key, base64). Prints the
              public key and its key id. Keep release keys out of the repository.
          pubkey --key <private key file>
              Prints the key's public key (base64) on stdout and its key id on stderr.
          manifest --pack <aar> --version <v> --serial <n> --expires <days> --url <https URL>
                   --key <private key file> --signer-sha256 <hex>
                   [--min-launcher <v>] [--min-macos <v>] [--revoke <runtime id>]...
                   [--kill-switch none|blockInstall] [--message <text>]
                   [--key-id <id>] [--out <file>]
              Signs a manifest for the pack (size and SHA-256 computed here) and writes the envelope the app
              fetches (to --out, or stdout). It is checked with the app's own ManifestVerifier first.
          verify --manifest <json> --pack <aar> --pubkey <base64> [--key-id <id>] [--signer-sha256 <hex>]
                 [--app-version <v>] [--macos <v>] [--no-install]
              Checks what the app checks: the manifest (ManifestVerifier), the pack's size and SHA-256, then
              (unless --no-install) a RuntimeInstaller run in a scratch home: unpack with aa, Warzag.app at
              the archive root, a valid code signature by the manifest's certificate, activation.
          app-manifest --archive <zip> --serial <n> --expires <days> --url <https URL> --key <private key file>
                       --signer-sha256 <hex> [--min-macos <v>] [--release-notes <https URL>] [--key-id <id>]
                       [--out <file>]
              Signs an app manifest (kind "app": Warzag's own updates) for an update archive, the
              Warzag-<version>.zip App/make-app.sh --dmg writes. The archive is unpacked with ditto and its app
              checked as Warzag checks a download (exactly one Warzag.app, com.warzag.app, arm64, a strict code
              signature by --signer-sha256, no link out of the bundle, no quarantine); version and build come
              from that app, minMacOS from its LSMinimumSystemVersion unless given. Checked with the app's
              AppManifestVerifier before anything is written.
          app-verify --manifest <json> --archive <zip> --pubkey <base64> [--key-id <id>] [--signer-sha256 <hex>]
                     [--running-build <n>] [--macos <v>]
              Checks what Warzag checks before it installs an update: the manifest (AppManifestVerifier:
              signature, kind, expiry, signer, URLs, versions), the archive's size and SHA-256, the unpacked app
              against the manifest, and with --running-build that the offer is a newer build.
          help

        The key id defaults to the first 16 hex digits of the SHA-256 of the raw public key.
        """

    static func parse(_ arguments: [String]) throws(ReleaseUsageError) -> ReleaseCommand {
        guard let command = arguments.first else { throw ReleaseUsageError(message: "missing command") }
        let rest = Array(arguments.dropFirst())
        if ["help", "--help", "-h"].contains(command) || rest.contains("--help") || rest.contains("-h") {
            return .help
        }
        switch command {
        case "keygen":
            let options = try scan(rest, values: ["--out", "--name"])
            var keygen = KeygenOptions(directory: try options.required("--out"))
            if let name = options.single("--name") {
                guard isPlainName(name) else { throw ReleaseUsageError(message: "--name must be a plain file name") }
                keygen.name = name
            }
            return .keygen(keygen)
        case "pubkey":
            let options = try scan(rest, values: ["--key"])
            return .publicKey(keyFile: try options.required("--key"))
        case "manifest":
            return .manifest(try manifestOptions(rest))
        case "verify":
            return .verify(try verifyOptions(rest))
        case "app-manifest":
            return .appManifest(try appManifestOptions(rest))
        case "app-verify":
            return .appVerify(try appVerifyOptions(rest))
        default:
            throw ReleaseUsageError(message: "unknown command: \(command)")
        }
    }

    private static func appManifestOptions(_ arguments: [String]) throws(ReleaseUsageError) -> AppManifestOptions {
        let options = try scan(arguments, values: [
            "--archive", "--serial", "--expires", "--url", "--key", "--signer-sha256", "--min-macos", "--release-notes",
            "--key-id", "--out",
        ])
        let serialText = try options.required("--serial")
        guard let serial = UInt64(serialText), serial > 0 else {
            throw ReleaseUsageError(message: "--serial must be a positive integer")
        }
        let daysText = try options.required("--expires")
        guard let days = Int(daysText), (1...3650).contains(days) else {
            throw ReleaseUsageError(message: "--expires must be a number of days from 1 to 3650")
        }
        var notes: URL?
        if let text = options.single("--release-notes") {
            notes = try appURL(text, option: "--release-notes")
        }
        return AppManifestOptions(
            archive: try options.required("--archive"), serial: serial, expiresInDays: days,
            url: try appURL(try options.required("--url"), option: "--url"), keyFile: try options.required("--key"),
            signerFingerprint: try fingerprint(try options.required("--signer-sha256"), option: "--signer-sha256"),
            keyID: options.single("--key-id"), minMacOS: options.single("--min-macos"), releaseNotes: notes,
            output: options.single("--out"))
    }

    private static func appVerifyOptions(_ arguments: [String]) throws(ReleaseUsageError) -> AppVerifyOptions {
        let options = try scan(arguments, values: [
            "--manifest", "--archive", "--pubkey", "--key-id", "--signer-sha256", "--running-build", "--macos",
        ])
        var verify = AppVerifyOptions(manifest: try options.required("--manifest"),
                                      archive: try options.required("--archive"),
                                      publicKey: try options.required("--pubkey"), keyID: options.single("--key-id"))
        if let signer = options.single("--signer-sha256") {
            verify.signerFingerprint = try fingerprint(signer, option: "--signer-sha256")
        }
        verify.runningBuild = options.single("--running-build")
        verify.macOSVersion = options.single("--macos")
        return verify
    }

    /// An https URL with a host, as the app accepts it; a development build (`swift build`) also takes http on the
    /// loopback address, for a local test feed (`AppFeed.allowsLoopbackHTTP`).
    static func appURL(_ text: String, option: String,
                       allowsLoopbackHTTP: Bool = AppFeed.allowsLoopbackHTTP) throws(ReleaseUsageError) -> URL {
        guard let url = AppFeed.url(text, allowsLoopbackHTTP: allowsLoopbackHTTP) else {
            throw ReleaseUsageError(message: "\(option) must be an https URL"
                + (allowsLoopbackHTTP ? " (or http on 127.0.0.1 in a development build)" : ""))
        }
        return url
    }

    private static func manifestOptions(_ arguments: [String]) throws(ReleaseUsageError) -> ManifestOptions {
        let options = try scan(arguments, values: [
            "--pack", "--version", "--serial", "--expires", "--url", "--key", "--signer-sha256",
            "--min-launcher", "--min-macos", "--revoke", "--kill-switch", "--message", "--key-id", "--out",
        ])
        let serialText = try options.required("--serial")
        guard let serial = UInt64(serialText), serial > 0 else {
            throw ReleaseUsageError(message: "--serial must be a positive integer")
        }
        let daysText = try options.required("--expires")
        guard let days = Int(daysText), (1...3650).contains(days) else {
            throw ReleaseUsageError(message: "--expires must be a number of days from 1 to 3650")
        }
        let urlText = try options.required("--url")
        guard let url = URL(string: urlText), url.scheme == "https", url.host() != nil else {
            throw ReleaseUsageError(message: "--url must be an https URL")
        }
        var manifest = ManifestOptions(
            pack: try options.required("--pack"), version: try options.required("--version"),
            serial: serial, expiresInDays: days, url: url, keyFile: try options.required("--key"),
            signerFingerprint: try fingerprint(try options.required("--signer-sha256"), option: "--signer-sha256"),
            keyID: options.single("--key-id"), revoked: options.all("--revoke"), output: options.single("--out"))
        if let minLauncher = options.single("--min-launcher") { manifest.minLauncher = minLauncher }
        if let minMacOS = options.single("--min-macos") { manifest.minMacOS = minMacOS }
        if let levelName = options.single("--kill-switch") {
            guard let level = KillSwitch.Level(rawValue: levelName) else {
                throw ReleaseUsageError(message: "unknown kill switch level: \(levelName)")
            }
            manifest.killSwitch = KillSwitch(level: level, message: options.single("--message"))
        } else if options.single("--message") != nil {
            throw ReleaseUsageError(message: "--message needs --kill-switch")
        }
        return manifest
    }

    private static func verifyOptions(_ arguments: [String]) throws(ReleaseUsageError) -> VerifyOptions {
        let options = try scan(arguments, values: [
            "--manifest", "--pack", "--pubkey", "--key-id", "--signer-sha256", "--app-version", "--macos",
        ], flags: ["--no-install"])
        var verify = VerifyOptions(manifest: try options.required("--manifest"), pack: try options.required("--pack"),
                                   publicKey: try options.required("--pubkey"), keyID: options.single("--key-id"))
        if let signer = options.single("--signer-sha256") {
            verify.signerFingerprint = try fingerprint(signer, option: "--signer-sha256")
        }
        if let appVersion = options.single("--app-version") { verify.appVersion = appVersion }
        verify.macOSVersion = options.single("--macos")
        verify.install = !options.flags.contains("--no-install")
        return verify
    }

    /// A lowercase SHA-256 in hex.
    static func fingerprint(_ text: String, option: String) throws(ReleaseUsageError) -> String {
        let lowered = text.lowercased()
        guard lowered.count == 64, lowered.allSatisfy(\.isHexDigit) else {
            throw ReleaseUsageError(message: "\(option) must be a SHA-256 (64 hex digits)")
        }
        return lowered
    }

    static func isPlainName(_ text: String) -> Bool {
        !text.isEmpty && text != "." && text != ".." && !text.hasPrefix("-")
            && text.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-+".unicodeScalars.contains($0)) }
    }

    struct ScannedOptions {
        var values: [String: [String]] = [:]
        var flags: Set<String> = []

        func single(_ name: String) -> String? { values[name]?.last }
        func all(_ name: String) -> [String] { values[name] ?? [] }

        func required(_ name: String) throws(ReleaseUsageError) -> String {
            guard let value = single(name) else { throw ReleaseUsageError(message: "missing \(name)") }
            return value
        }
    }

    /// `--name value` pairs and bare flags; anything else is an error. A repeated option keeps every value
    /// (`all`), and `single` takes the last one.
    private static func scan(_ arguments: [String], values: Set<String>,
                             flags: Set<String> = []) throws(ReleaseUsageError) -> ScannedOptions {
        var scanned = ScannedOptions()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if values.contains(argument) {
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                    throw ReleaseUsageError(message: "\(argument) needs a value")
                }
                scanned.values[argument, default: []].append(arguments[index + 1])
                index += 2
            } else if flags.contains(argument) {
                scanned.flags.insert(argument)
                index += 1
            } else {
                throw ReleaseUsageError(message: argument.hasPrefix("-") ? "unknown option: \(argument)"
                                                                          : "unexpected argument: \(argument)")
            }
        }
        return scanned
    }
}
