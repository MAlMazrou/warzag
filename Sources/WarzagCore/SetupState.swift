import Foundation

/// The four parts of first-run setup. Preflight gates the others; engine, Steam and game then run in parallel (the
/// game track waits for the engine's prefix after downloading DE's installer, and the Steam license check waits for
/// it too, because wz-steamprobe.exe runs inside that prefix).
public enum SetupTrack: String, Codable, Sendable, CaseIterable {
    case preflight, engine, steam, game

    /// The track's steps, in the order they run.
    ///
    /// `applyProfile` seeds EE.cfg before DE's launcher first runs: the ContentUpdate applet it spawns creates EE.cfg
    /// at the end of the download, and the seed only writes an absent file. `pinDirectX11` runs before `acceptEULA`
    /// starts the launcher, which goes straight from the EULA into downloading the chosen API's caches.
    public var steps: [SetupStep] {
        switch self {
        case .preflight: [.checkPlatform, .checkLocation, .checkStorage, .checkNetwork]
        case .engine: [.fetchManifest, .downloadRuntime, .verifyRuntime, .activateRuntime, .createPrefix]
        case .steam: [.installSteam, .startSteam, .waitForSignIn, .checkLicense]
        case .game: [.downloadInstaller, .extractGame, .applyProfile, .pinDirectX11, .acceptEULA, .downloadContent]
        }
    }
}

/// One idempotent unit of setup work. After a crash the interrupted step runs again from the top, so every step
/// must re-check before acting (and downloads resume from the bytes already on disk).
public enum SetupStep: String, Codable, Sendable, CaseIterable {
    // Preflight
    /// Apple silicon and macOS 15 or later.
    case checkPlatform
    /// Running from an Applications folder; otherwise offer Move to Applications.
    case checkLocation
    /// Room for the library on a case-insensitive volume (`StoragePolicy`: 80 GB for a fresh install).
    case checkStorage
    /// The network is reachable.
    case checkNetwork

    // Engine
    /// Fetch and verify the signed runtime manifest.
    case fetchManifest
    case downloadRuntime
    /// SHA-256 and signer fingerprint of the downloaded pack.
    case verifyRuntime
    /// Atomic switch of Runtimes.noindex/active.json.
    case activateRuntime
    /// wineboot, registry template, identity vault.
    case createPrefix

    // Steam
    /// Steam.app present; otherwise Valve's installer (with the user's approval).
    case installSteam
    /// `open -g -a <Steam.app> --args -silent` (`SteamLauncher`), then wait for steam_osx.
    case startSteam
    /// The last connection_log.txt state token is "Logged On".
    case waitForSignIn
    /// The account owns Warframe (app 230410): wz-steamprobe.exe in the engine's prefix.
    case checkLicense

    // Game
    /// Warframe.msi from DE, Authenticode signer checked.
    case downloadInstaller
    /// `msiexec /a` into the library.
    case extractGame
    /// Tier detection and the one-time EE.cfg seed, before any DE code creates EE.cfg.
    case applyProfile
    /// DE's launcher kept on DirectX 11 (GraphicsAPI 0) before it first runs.
    case pinDirectX11
    /// DE's launcher shown once for its EULA.
    case acceptEULA
    /// Bulk download by DE's launcher or applet, with native progress.
    case downloadContent

    public var track: SetupTrack {
        switch self {
        case .checkPlatform, .checkLocation, .checkStorage, .checkNetwork: .preflight
        case .fetchManifest, .downloadRuntime, .verifyRuntime, .activateRuntime, .createPrefix: .engine
        case .installSteam, .startSteam, .waitForSignIn, .checkLicense: .steam
        case .downloadInstaller, .extractGame, .applyProfile, .pinDirectX11, .acceptEULA, .downloadContent: .game
        }
    }

    /// The step after this one in its track, or nil for the last step.
    public var next: SetupStep? {
        let steps = track.steps
        guard let index = steps.firstIndex(of: self), index + 1 < steps.count else { return nil }
        return steps[index + 1]
    }
}

/// Something only the user can do, or must allow.
public enum UserAction: String, Codable, Sendable, CaseIterable {
    case moveToApplications
    case chooseStorage
    case installSteam
    case signInToSteam
    case addWarframeToLibrary
    case acceptEULA

    /// Actions that grant Warzag permission to act (install or move something) rather than asking the user to
    /// act in someone else's window. Approvals are remembered so a retried step can go ahead.
    public var isApproval: Bool {
        switch self {
        case .moveToApplications, .installSteam: true
        case .chooseStorage, .signInToSteam, .addWarframeToLibrary, .acceptEULA: false
        }
    }
}

/// How the player signs in to Warframe. Without Steam, DE's own email login still works.
public enum LoginMode: String, Codable, Sendable {
    case steam
    case warframeAccount
}

public struct SetupFailure: Codable, Equatable, Sendable, Error {
    public enum Kind: String, Codable, Sendable {
        /// Worth retrying automatically (a dropped download, a busy server).
        case transient
        /// Needs the user to press Retry once the cause is fixed.
        case permanent
        /// This Mac cannot run Warzag (Intel, macOS too old); retrying will not help.
        case unsupported
    }

    public var kind: Kind
    /// One short sentence for the UI; never personal data.
    public var message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }
}

public enum TrackStatus: String, Codable, Sendable {
    /// The current step will run once its dependencies are met.
    case pending
    case running
    case waitingForUser
    /// Paused until the network comes back.
    case offline
    case failed
    case done
    /// The user opted out (the Steam track in Warframe-account mode).
    case skipped
}

/// Progress of one track: the step it is on and what is happening to it.
public struct TrackState: Codable, Equatable, Sendable {
    public var step: SetupStep
    public var status: TrackStatus
    /// Consecutive failed attempts of `step`; reset when it completes.
    public var attempts: Int
    /// What the user needs to do, while `status == .waitingForUser`.
    public var action: UserAction?
    /// Why the step failed, while `status == .failed`.
    public var failure: SetupFailure?

    public init(step: SetupStep, status: TrackStatus = .pending, attempts: Int = 0,
                action: UserAction? = nil, failure: SetupFailure? = nil) {
        self.step = step
        self.status = status
        self.attempts = attempts
        self.action = action
        self.failure = failure
    }

    public static func start(of track: SetupTrack) -> TrackState {
        TrackState(step: track.steps[0])
    }
}

/// Everything first-run setup has to remember, persisted to State/setup.json after every transition.
public struct SetupState: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public var schema: Int
    /// The engine channel (always n). A setup.json without it does not decode: setup starts over (`SetupStateStore`).
    public let channel: RuntimeChannel
    public var loginMode: LoginMode
    /// Actions the user approved (sorted, for a stable file).
    public var approvals: [UserAction]
    public var preflight: TrackState
    public var engine: TrackState
    public var steam: TrackState
    public var game: TrackState
    public var updatedAt: Date?

    public init(
        loginMode: LoginMode = .steam,
        approvals: [UserAction] = [],
        preflight: TrackState = .start(of: .preflight),
        engine: TrackState = .start(of: .engine),
        steam: TrackState = .start(of: .steam),
        game: TrackState = .start(of: .game),
        updatedAt: Date? = nil
    ) {
        schema = Self.schemaVersion
        channel = .n
        self.loginMode = loginMode
        self.approvals = approvals
        self.preflight = preflight
        self.engine = engine
        self.steam = steam
        self.game = game
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case schema, channel, loginMode, approvals, preflight, engine, steam, game, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(Int.self, forKey: .schema)
        channel = try container.decode(RuntimeChannel.self, forKey: .channel)
        loginMode = try container.decode(LoginMode.self, forKey: .loginMode)
        approvals = try container.decode([UserAction].self, forKey: .approvals)
        preflight = try container.decode(TrackState.self, forKey: .preflight)
        engine = try container.decode(TrackState.self, forKey: .engine)
        steam = try container.decode(TrackState.self, forKey: .steam)
        game = try container.decode(TrackState.self, forKey: .game)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    public static var initial: SetupState { SetupState() }

    public subscript(track: SetupTrack) -> TrackState {
        get {
            switch track {
            case .preflight: preflight
            case .engine: engine
            case .steam: steam
            case .game: game
            }
        }
        set {
            switch track {
            case .preflight: preflight = newValue
            case .engine: engine = newValue
            case .steam: steam = newValue
            case .game: game = newValue
            }
        }
    }

    /// Whether `step` has finished (a skipped Steam track keeps the steps it completed before the opt-out).
    public func isCompleted(_ step: SetupStep) -> Bool {
        let track = self[step.track]
        if track.status == .done { return true }
        let steps = step.track.steps
        guard let index = steps.firstIndex(of: step), let current = steps.firstIndex(of: track.step) else {
            return false
        }
        return index < current
    }

    public func isApproved(_ action: UserAction) -> Bool { approvals.contains(action) }

    /// The gate to Play: engine and game ready, and Steam ready unless the player uses a Warframe account.
    public var isReadyToPlay: Bool {
        engine.status == .done && game.status == .done && (steam.status == .done || loginMode == .warframeAccount)
    }
}
