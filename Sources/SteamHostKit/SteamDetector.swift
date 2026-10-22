import Foundation
import WarzagCore

/// What Warzag knows about the user's Mac Steam. Built only from allowlisted facts: whether files exist, the
/// client manifest's "version", registry.vdf's SteamPID and the last connection-state token.
public struct SteamStatus: Codable, Equatable, Sendable {
    /// Steam.app in /Applications or ~/Applications.
    public let appBundle: URL?
    public let installed: Bool
    /// steamclient.dylib, which the bootstrapper downloads on Steam's first run.
    public let clientRuntimeInstalled: Bool
    public let clientVersion: String?
    /// The live steam_osx process, if Steam is running.
    public let processID: Int32?
    public let running: Bool
    /// Latest connection state since Steam started; nil when Steam is not running or has logged nothing yet.
    public let connection: SteamConnectionState?
    public let signedIn: Bool

    public init(
        appBundle: URL?, clientRuntimeInstalled: Bool, clientVersion: String?,
        processID: Int32?, connection: SteamConnectionState?
    ) {
        self.appBundle = appBundle
        installed = appBundle != nil
        self.clientRuntimeInstalled = clientRuntimeInstalled
        self.clientVersion = clientVersion
        self.processID = processID
        running = processID != nil
        self.connection = processID != nil ? connection : nil
        signedIn = processID != nil && connection == .loggedOn
    }

    // Encoded with a plain path rather than a file:// URL, so `warzagctl steam status --json` reads like the rest.
    private enum CodingKeys: String, CodingKey {
        case appBundle, installed, clientRuntimeInstalled, clientVersion, processID, running, connection, signedIn
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            appBundle: try container.decodeIfPresent(String.self, forKey: .appBundle)
                .map { URL(filePath: $0, directoryHint: .isDirectory) },
            clientRuntimeInstalled: try container.decode(Bool.self, forKey: .clientRuntimeInstalled),
            clientVersion: try container.decodeIfPresent(String.self, forKey: .clientVersion),
            processID: try container.decodeIfPresent(Int32.self, forKey: .processID),
            connection: try container.decodeIfPresent(SteamConnectionState.self, forKey: .connection)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(appBundle?.plainPath, forKey: .appBundle)
        try container.encode(installed, forKey: .installed)
        try container.encode(clientRuntimeInstalled, forKey: .clientRuntimeInstalled)
        try container.encodeIfPresent(clientVersion, forKey: .clientVersion)
        try container.encodeIfPresent(processID, forKey: .processID)
        try container.encode(running, forKey: .running)
        try container.encodeIfPresent(connection, forKey: .connection)
        try container.encode(signedIn, forKey: .signedIn)
    }
}

/// Read-only detection of native Mac Steam.
public struct SteamDetector: Sendable {
    public let locations: SteamLocations
    public let fileSystem: any FileSystem
    public let processes: any ProcessInspecting
    public let timeZone: TimeZone

    public init(
        locations: SteamLocations = SteamLocations(),
        fileSystem: any FileSystem = LocalFileSystem(),
        processes: any ProcessInspecting = DarwinProcessInspector(),
        timeZone: TimeZone = .current
    ) {
        self.locations = locations
        self.fileSystem = fileSystem
        self.processes = processes
        self.timeZone = timeZone
    }

    public func status() -> SteamStatus {
        let pid = runningSteamProcess()
        var connection: SteamConnectionState?
        if let pid {
            connection = try? ConnectionLog.lastState(
                in: locations.connectionLog, since: processes.startDate(of: pid),
                fileSystem: fileSystem, timeZone: timeZone
            )
        }
        return SteamStatus(
            appBundle: installedApp(),
            clientRuntimeInstalled: fileSystem.fileExists(at: locations.steamClientLibrary),
            clientVersion: clientVersion(),
            processID: pid,
            connection: connection
        )
    }

    public func installedApp() -> URL? {
        locations.applicationCandidates.first { fileSystem.directoryExists(at: $0) }
    }

    /// The highest "version" across package/steam_client*osx.manifest (each one root block, "osx"): a client update can
    /// write a manifest under a new name and leave the old one behind. Versions compare as numbers; a manifest whose
    /// version is not a number counts only when no manifest has a numeric one.
    public func clientVersion() -> String? {
        guard let entries = try? fileSystem.contentsOfDirectory(at: locations.packageDirectory) else { return nil }
        var highest: (number: UInt64, text: String)?
        var other: String?
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where SteamLocations.isClientManifest(url.lastPathComponent) {
            guard let version = manifestVersion(url) else { continue }
            if let number = UInt64(version) {
                if highest.map({ number > $0.number }) ?? true { highest = (number, version) }
            } else if other == nil {
                other = version
            }
        }
        return highest?.text ?? other
    }

    /// Manifests are a few kilobytes; anything far larger is not one.
    static let manifestByteLimit: UInt64 = 1 << 20

    private func manifestVersion(_ url: URL) -> String? {
        guard let size = try? fileSystem.attributes(of: url).size, size <= Self.manifestByteLimit,
              let data = try? fileSystem.contents(of: url),
              let manifest = try? VDF.parse(data) else { return nil }
        let version = manifest.entries.lazy.compactMap { $0.value["version"]?.stringValue }.first?
            .trimmingCharacters(in: .whitespaces)
        return version?.isEmpty == false ? version : nil
    }

    /// registry.vdf's Registry/HKLM/Software/Valve/Steam/SteamPID, if that process is alive and is steam_osx.
    /// Steam leaves a stale pid behind when it quits, and pids get reused, hence the executable check.
    public func runningSteamProcess() -> Int32? {
        guard let text = registry()?.string(atPath: ["Registry", "HKLM", "Software", "Valve", "Steam", "SteamPID"]),
              let pid = Int32(text), pid > 0,
              processes.isAlive(pid),
              let path = processes.executablePath(of: pid),
              path.hasSuffix("/steam_osx")
        else { return nil }
        return pid
    }

    /// registry.vdf is a few kilobytes.
    static let registryByteLimit: UInt64 = 1 << 20

    private func registry() -> VDFObject? {
        guard let size = try? fileSystem.attributes(of: locations.registryFile).size, size <= Self.registryByteLimit,
              let data = try? fileSystem.contents(of: locations.registryFile) else { return nil }
        return try? VDF.parse(data)
    }

    // MARK: The sign-in phase

    /// Where Steam is on its way to a signed-in account (`SteamSignInPhase.derive`), from `status` (read a moment ago)
    /// and what Steam logged since steam_osx started. `launch`: Warzag's latest start of Steam, if any.
    public func phase(for status: SteamStatus, launch: SteamLaunchRecord?, now: Date) -> SteamSignInPhase {
        var start: Date?
        var connection: ConnectionLogSummary?
        var login: SteamLoginTransition?
        if let pid = status.processID, !status.signedIn {
            start = processes.startDate(of: pid)
            connection = try? ConnectionLog.summary(in: locations.connectionLog, since: start, fileSystem: fileSystem,
                                                    timeZone: timeZone)
            login = try? LoginStateLog.lastTransition(in: locations.loginStateLog, since: start, fileSystem: fileSystem,
                                                      timeZone: timeZone)
        }
        return SteamSignInPhase.derive(status: status, processStart: start, connection: connection, login: login,
                                       launch: unfinished(launch, status: status), now: now)
    }

    /// Warzag's start, unless the latest thing Steam logged since is a shutdown: then it came up and ended, and is no
    /// longer starting. A restart logs a shutdown and then a start, so it still counts as starting.
    func unfinished(_ launch: SteamLaunchRecord?, status: SteamStatus) -> SteamLaunchRecord? {
        guard let launch, !status.running else { return launch }
        let latest = try? BootstrapLog.latestEvent(in: locations.bootstrapLog, since: launch.at, fileSystem: fileSystem,
                                                   timeZone: timeZone)
        return latest == .shutdown ? nil : launch
    }

    /// Whether the running Steam was started with `-silent` (bootstrap_log.txt's latest start line since steam_osx
    /// started); nil when Steam isn't running or its log does not say.
    public func startedSilently() -> Bool? {
        guard let pid = runningSteamProcess() else { return nil }
        return try? BootstrapLog.startedSilently(in: locations.bootstrapLog, since: processes.startDate(of: pid),
                                                 fileSystem: fileSystem, timeZone: timeZone)
    }

    // MARK: The account and saved sign-in

    /// The account signed in to the running Steam, for the Home card; nil unless `status` is signed in and its
    /// "Logged On" line names an account (`[U:1:N]`, N ≠ 0). The account is that line's, never the AutoLogin one or
    /// the newest timestamp. Steam's files keep the old name and picture after a sign-out or quit, so nothing is read
    /// while signed out. Reads the files each time; callers keep the last good value, as a file may be mid-rewrite.
    public func account(for status: SteamStatus, name: SteamDisplayName = .profileName) -> SteamAccount? {
        guard status.signedIn, let pid = status.processID, pid == runningSteamProcess(),
              let entry = try? ConnectionLog.lastEntry(in: locations.connectionLog, since: processes.startDate(of: pid),
                                                       fileSystem: fileSystem, timeZone: timeZone),
              entry.state.isSignedIn, let accountID = entry.accountID else { return nil }
        let steamID64 = SteamAccount.steamID64(accountID: accountID)
        let user = LoginUsers.read(locations.loginUsersFile, fileSystem: fileSystem,
                                   includeAccountName: name == .signInName)?
            .first { $0.steamID64 == steamID64 }
        let raw = switch name {
        case .profileName: user?.personaName
        case .signInName: user?.accountName
        }
        return SteamAccount(displayName: raw.flatMap(SteamAccount.clean), steamID64: steamID64,
                            avatarFile: locations.avatarCacheDirectory.appending(path: "\(steamID64).png"),
                            fileSystem: fileSystem)
    }

    /// Whether Steam can probably sign in by itself, from registry.vdf's AutoLoginUser (set or not) and loginusers.vdf
    /// (`LoginUsers.hints`).
    public func loginHints() -> SteamLoginHints {
        let autoLoginUser = registry()?.string(atPath: ["Registry", "HKCU", "Software", "Valve", "Steam", "AutoLoginUser"])
        return LoginUsers.hints(users: LoginUsers.read(locations.loginUsersFile, fileSystem: fileSystem),
                                autoLoginUserSet: !(autoLoginUser ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
    }
}
