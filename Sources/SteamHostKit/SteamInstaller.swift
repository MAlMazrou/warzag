import Foundation
import WarzagCore

public enum SteamInstallError: Error, Equatable, CustomStringConvertible {
    case downloadFailed(String)
    case attachFailed(String)
    case appMissingFromImage
    case signatureRejected(String)
    case copyFailed(String)

    public var description: String {
        switch self {
        case .downloadFailed(let reason): "Could not download Steam: \(reason)"
        case .attachFailed(let reason): "Could not open Valve's Steam installer: \(reason)"
        case .appMissingFromImage: "Valve's Steam installer did not contain Steam.app"
        case .signatureRejected(let reason): "Steam.app is not signed by Valve: \(reason)"
        case .copyFailed(let reason): "Could not copy Steam into Applications: \(reason)"
        }
    }
}

/// Installs Valve's own Steam.app when it is missing. Runs only after the user approves; never touches an
/// existing Steam.app.
///
/// Flow: download steam.dmg (Akamai, then Cloudflare) → `hdiutil attach -nobrowse -noautoopen -readonly` →
/// `codesign` against Valve's Developer ID requirement → `ditto` into a staging folder next to the destination →
/// verify the copy → rename into /Applications (or ~/Applications when /Applications is not writable) → detach.
public struct SteamInstaller: Sendable {
    public static let installerURLs = [
        URL(string: "https://cdn.akamai.steamstatic.com/client/installer/steam.dmg")!,
        URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/steam.dmg")!,
    ]
    /// Valve Corporation's Developer ID team. Anything else is not Steam.
    public static let codeRequirement = "anchor apple generic and certificate leaf[subject.OU] = MXGJJ98X76"

    public let locations: SteamLocations
    /// Scratch space for the disk image and its mount point, e.g. ~/Library/Caches/Warzag/steam-installer.
    public let workDirectory: URL
    public let http: any HTTPClient
    public let runner: any ProcessRunning
    public let fileSystem: any FileSystem

    public init(locations: SteamLocations, workDirectory: URL, http: any HTTPClient,
                runner: any ProcessRunning, fileSystem: any FileSystem) {
        self.locations = locations
        self.workDirectory = workDirectory
        self.http = http
        self.runner = runner
        self.fileSystem = fileSystem
    }

    /// Installs Steam if needed and returns where Steam.app is.
    public func install() async throws -> URL {
        if let existing = locations.applicationCandidates.first(where: fileSystem.directoryExists) {
            return existing
        }
        let image = workDirectory.appending(path: "steam.dmg")
        try await download(to: image)

        let mountPoint = workDirectory.appending(path: "mount-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileSystem.createDirectory(at: mountPoint)
        let attach = try await runner.run(Command("/usr/bin/hdiutil", [
            "attach", "-nobrowse", "-noautoopen", "-readonly", "-mountpoint", mountPoint.plainPath, image.plainPath,
        ]))
        guard attach.succeeded else {
            try? fileSystem.removeItem(at: mountPoint)
            throw SteamInstallError.attachFailed(Self.firstLine(attach.standardError))
        }

        let installed: URL
        do {
            installed = try await copySteam(from: mountPoint.appending(path: "Steam.app", directoryHint: .isDirectory))
        } catch {
            await detach(mountPoint)
            throw error
        }
        await detach(mountPoint)
        try? fileSystem.removeItem(at: image)
        return installed
    }

    private func download(to image: URL) async throws {
        var reasons: [String] = []
        for url in Self.installerURLs {
            do {
                try await http.download(from: url, to: image)
                return
            } catch {
                reasons.append("\(url.host() ?? url.absoluteString): \(error)")
            }
        }
        throw SteamInstallError.downloadFailed(reasons.joined(separator: "; "))
    }

    private func copySteam(from source: URL) async throws -> URL {
        guard fileSystem.directoryExists(at: source) else { throw SteamInstallError.appMissingFromImage }
        try await verifySignature(of: source)

        let applications: URL
        if fileSystem.isWritableDirectory(at: locations.systemApplications) {
            applications = locations.systemApplications
        } else {
            applications = locations.userApplications
            try fileSystem.createDirectory(at: applications)
        }
        let destination = applications.appending(path: "Steam.app", directoryHint: .isDirectory)
        if fileSystem.directoryExists(at: destination) { return destination }

        // Copy next to the destination first, so an interrupted copy never looks like an installed Steam.
        let staging = applications.appending(path: ".warzag-steam-\(UUID().uuidString)", directoryHint: .isDirectory)
        let stagedApp = staging.appending(path: "Steam.app", directoryHint: .isDirectory)
        defer { try? fileSystem.removeItem(at: staging) }
        try fileSystem.createDirectory(at: staging)
        let copy = try await runner.run(Command("/usr/bin/ditto", [source.plainPath, stagedApp.plainPath]))
        guard copy.succeeded else { throw SteamInstallError.copyFailed(Self.firstLine(copy.standardError)) }
        try await verifySignature(of: stagedApp)
        do {
            try fileSystem.moveItem(at: stagedApp, to: destination)
        } catch {
            throw SteamInstallError.copyFailed(String(describing: error))
        }
        return destination
    }

    private func verifySignature(of app: URL) async throws {
        let result = try await runner.run(Command("/usr/bin/codesign", [
            "--verify", "--deep", "--strict", "-R", "=" + Self.codeRequirement, app.plainPath,
        ]))
        guard result.succeeded else {
            throw SteamInstallError.signatureRejected(Self.firstLine(result.standardError))
        }
    }

    /// Runs in a task of its own: after a cancelled install the image must still be detached, and a cancelled task
    /// starts no process.
    private func detach(_ mountPoint: URL) async {
        let runner = runner
        let fileSystem = fileSystem
        await Task.detached {
            let detached = (try? await runner.run(Command("/usr/bin/hdiutil", ["detach", mountPoint.plainPath])))?
                .succeeded ?? false
            if !detached {
                _ = try? await runner.run(Command("/usr/bin/hdiutil", ["detach", "-force", mountPoint.plainPath]))
            }
            try? fileSystem.removeItem(at: mountPoint)
        }.value
    }

    private static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "exit status non-zero"
    }
}

public struct SteamLaunchError: Error, Equatable, CustomStringConvertible {
    public var reason: String
    public var description: String { "Could not start Steam: \(reason)" }

    public init(reason: String) {
        self.reason = reason
    }
}

/// How Warzag starts Steam.
public enum SteamStartMode: String, Sendable, Codable, CaseIterable {
    /// `open -g -a <Steam.app> --args -silent`: no sign-in window, main window or Big Picture (`-silent` forces the
    /// desktop UI). With a working saved sign-in Steam signs in by itself; without one it waits for credentials with
    /// nothing on screen. Used by setup, Play, and Log In when a saved sign-in exists.
    case background
    /// `open -a <Steam.app>`: Steam's sign-in window comes to the front; until sign-in it is Steam's only window apart
    /// from its updater and pages the sign-in screen opens. Used by Log In without a saved sign-in, and its restart.
    case withSignInWindow
}

/// Starts Steam by the path `SteamDetector.installedApp()` found, never by the name "Steam".
///
/// Callers make sure Steam isn't running: opening Steam.app while it runs is a reopen event, which brings Steam's
/// start page (library or store) forward. No `-j` (hides): it would reach only the bootstrapper process and could hide
/// Steam's updater and error alerts.
public struct SteamLauncher: Sendable {
    public static func command(app: URL, mode: SteamStartMode) -> Command {
        switch mode {
        case .background: Command("/usr/bin/open", ["-g", "-a", app.plainPath, "--args", "-silent"])
        case .withSignInWindow: Command("/usr/bin/open", ["-a", app.plainPath])
        }
    }

    public let runner: any ProcessRunning

    public init(runner: any ProcessRunning) {
        self.runner = runner
    }

    /// A failure's reason names Steam.app, not its path (in ~/Applications the path holds the home folder, and the
    /// reason goes to Warzag.log).
    public func launch(app: URL, mode: SteamStartMode) async throws {
        let result = try await runner.run(Self.command(app: app, mode: mode))
        guard result.succeeded else {
            throw SteamLaunchError(reason: result.standardError.replacingOccurrences(of: app.plainPath, with: "Steam.app")
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

/// One start of Steam by Warzag: how, and when.
public struct SteamLaunchRecord: Equatable, Sendable, Codable {
    public var mode: SteamStartMode
    public var at: Date

    public init(mode: SteamStartMode, at: Date) {
        self.mode = mode
        self.at = at
    }

    /// A start is in flight this long: Warzag never starts Steam again meanwhile.
    public static let inFlight: TimeInterval = 90
    /// While steamclient.dylib is missing, Steam's first start downloads the whole client.
    public static let firstRunInFlight: TimeInterval = 300

    /// Still starting at `now`: less than 90 s ago, or 5 minutes while the client is not installed yet.
    public func isInFlight(at now: Date, clientInstalled: Bool) -> Bool {
        let elapsed = now.timeIntervalSince(at)
        return elapsed >= 0 && elapsed < (clientInstalled ? Self.inFlight : Self.firstRunInFlight)
    }
}
