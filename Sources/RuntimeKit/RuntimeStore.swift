import Foundation
import WarzagCore

/// A runtime that is on disk under Runtimes.noindex/<channel>/<version>/Warzag.app.
public struct InstalledRuntime: Codable, Equatable, Sendable {
    public var id: String
    public var version: String
    public var channel: RuntimeChannel
    public var signerFingerprint: String
    public var activatedAt: Date?

    public init(id: String, version: String, channel: RuntimeChannel, signerFingerprint: String, activatedAt: Date? = nil) {
        self.id = id
        self.version = version
        self.channel = channel
        self.signerFingerprint = signerFingerprint
        self.activatedAt = activatedAt
    }

    init(_ manifest: RuntimeManifest, activatedAt: Date) {
        self.init(id: manifest.id, version: manifest.version, channel: manifest.channel,
                  signerFingerprint: manifest.signerFingerprint.lowercased(), activatedAt: activatedAt)
    }
}

/// Contents of Runtimes.noindex/active.json. One file holds the pointer and what the store has learned from
/// signed manifests, so a single atomic rename switches all of it.
public struct RuntimeStoreState: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public var schema: Int
    public var current: InstalledRuntime?
    /// The previous runtime, kept on disk for rollback.
    public var previous: InstalledRuntime?
    /// Highest manifest serial accepted (anti-rollback floor).
    public var lastSerial: UInt64?
    /// Every runtime id revoked by an accepted manifest (sorted).
    public var revoked: [String]
    /// Runtimes rolled back on this Mac; never activated again automatically.
    public var rolledBack: [String]

    public init(current: InstalledRuntime? = nil, previous: InstalledRuntime? = nil, lastSerial: UInt64? = nil,
                revoked: [String] = [], rolledBack: [String] = []) {
        schema = Self.schemaVersion
        self.current = current
        self.previous = previous
        self.lastSerial = lastSerial
        self.revoked = revoked
        self.rolledBack = rolledBack
    }

    /// The current runtime was revoked and there was nothing to roll back to: Play must be blocked.
    public var isCurrentRevoked: Bool { current.map { revoked.contains($0.id) } ?? false }
}

public enum RuntimeStoreError: Error, Equatable, CustomStringConvertible {
    case unreadablePointer(String)
    case invalidName(String)
    case revoked(String)
    case stagedHostMissing
    case noPreviousRuntime
    case previousRuntimeMissing(String)

    public var description: String {
        switch self {
        case .unreadablePointer(let reason): "\(WarzagPaths.runtimesFolderName)/active.json is unreadable: \(reason)"
        case .invalidName(let name): "\"\(name)\" is not a valid runtime name"
        case .revoked(let id): "runtime \(id) has been revoked"
        case .stagedHostMissing: "the staged runtime has no Warzag.app"
        case .noPreviousRuntime: "there is no previous runtime to roll back to"
        case .previousRuntimeMissing(let id): "the previous runtime \(id) is no longer on disk"
        }
    }
}

/// The on-disk runtime store: atomic activation through Runtimes.noindex/active.json, retention of the previous
/// runtime and rollback. Every engine copy lives inside `WarzagPaths.runtimes`, out of Spotlight.
public struct RuntimeStore: Sendable {
    public let paths: WarzagPaths
    public let fileSystem: any FileSystem
    public let clock: any WallClock

    public init(paths: WarzagPaths, fileSystem: any FileSystem, clock: any WallClock = SystemClock()) {
        self.paths = paths
        self.fileSystem = fileSystem
        self.clock = clock
    }

    public func load() throws -> RuntimeStoreState {
        let url = paths.activeRuntimePointer
        guard fileSystem.fileExists(at: url) else { return RuntimeStoreState() }
        let state: RuntimeStoreState
        do {
            state = try WarzagJSON.decoder().decode(RuntimeStoreState.self, from: try fileSystem.contents(of: url))
        } catch {
            throw RuntimeStoreError.unreadablePointer(String(describing: error))
        }
        guard state.schema == RuntimeStoreState.schemaVersion else {
            throw RuntimeStoreError.unreadablePointer("schema \(state.schema)")
        }
        return state
    }

    public func hostURL(for runtime: InstalledRuntime) -> URL {
        paths.gameHost(runtime.channel, version: runtime.version)
    }

    /// The game host to launch: the current runtime, if it is on disk and not revoked.
    public func activeHost() throws -> URL? {
        let state = try load()
        guard let current = state.current, !state.isCurrentRevoked else { return nil }
        let host = hostURL(for: current)
        return fileSystem.directoryExists(at: host) ? host : nil
    }

    /// Records a verified manifest: raises the serial floor and applies its revocations. A revoked current runtime
    /// is rolled back to the previous one when possible; otherwise `isCurrentRevoked` stays true and Play must be
    /// blocked.
    @discardableResult
    public func accept(_ manifest: RuntimeManifest) throws -> RuntimeStoreState {
        var state = try load()
        state.lastSerial = max(state.lastSerial ?? 0, manifest.serial)
        state.revoked = Array(Set(state.revoked).union(manifest.revoked)).sorted()
        if let previous = state.previous, state.revoked.contains(previous.id) { state.previous = nil }
        if let current = state.current, state.revoked.contains(current.id), let previous = usablePrevious(in: state) {
            state.rolledBack = Array(Set(state.rolledBack).union([current.id])).sorted()
            state.previous = nil
            state.current = activated(previous)
        }
        try save(state)
        try prune(keeping: state)
        return state
    }

    /// Moves a verified, staged "Warzag.app" into place and makes it current, keeping the one it replaces as the
    /// previous runtime.
    @discardableResult
    public func install(stagedHost: URL, for manifest: RuntimeManifest) throws -> RuntimeStoreState {
        guard isSafePathComponent(manifest.id) else { throw RuntimeStoreError.invalidName(manifest.id) }
        guard isSafePathComponent(manifest.version) else { throw RuntimeStoreError.invalidName(manifest.version) }
        var state = try load()
        guard !state.revoked.contains(manifest.id), !manifest.revoked.contains(manifest.id) else {
            throw RuntimeStoreError.revoked(manifest.id)
        }
        guard fileSystem.directoryExists(at: stagedHost) else { throw RuntimeStoreError.stagedHostMissing }

        if let current = state.current, current.id == manifest.id, fileSystem.directoryExists(at: hostURL(for: current)) {
            try? fileSystem.removeItem(at: stagedHost)
            return state
        }
        // A revoked runtime is never kept as the previous one: it can never be rolled back to, so pruning reclaims
        // its space.
        let revoked = Set(state.revoked).union(manifest.revoked)
        let demoted = state.current.flatMap { revoked.contains($0.id) ? nil : $0 }
        if let previous = state.previous, previous.id == manifest.id,
           fileSystem.directoryExists(at: hostURL(for: previous)) {
            // Re-installing the previous runtime: it is already on disk, so swap instead of copying.
            try? fileSystem.removeItem(at: stagedHost)
            state.previous = demoted
            state.current = activated(previous)
        } else {
            let versionDirectory = paths.runtimeVersionDirectory(manifest.channel, version: manifest.version)
            if fileSystem.directoryExists(at: versionDirectory) {
                try fileSystem.removeItem(at: versionDirectory)
            }
            try fileSystem.moveItem(at: stagedHost, to: paths.gameHost(manifest.channel, version: manifest.version))
            if let demoted { state.previous = demoted }
            state.current = InstalledRuntime(manifest, activatedAt: clock.now)
        }
        state.rolledBack.removeAll { $0 == manifest.id }
        try save(state)
        try prune(keeping: state)
        return state
    }

    /// Makes the previous runtime current again (after failed launches, or a revocation) and forgets the bad one.
    @discardableResult
    public func rollback() throws -> RuntimeStoreState {
        var state = try load()
        guard let current = state.current, let previous = state.previous else {
            throw RuntimeStoreError.noPreviousRuntime
        }
        guard usablePrevious(in: state) != nil else { throw RuntimeStoreError.previousRuntimeMissing(previous.id) }
        state.rolledBack = Array(Set(state.rolledBack).union([current.id])).sorted()
        state.previous = nil
        state.current = activated(previous)
        try save(state)
        try prune(keeping: state)
        return state
    }

    /// Deletes every runtime directory except the current and the previous one.
    ///
    /// Entries are matched by folder name, never by full path: `standardizedFileURL` drops a leading "/private" only
    /// for paths that exist, so under a home in /private/tmp a full-path comparison could delete the runtime just
    /// activated.
    public func prune(keeping state: RuntimeStoreState) throws {
        let keep = Set([state.current, state.previous].compactMap { $0?.version })
        let directory = paths.runtimeDirectory(.n)
        guard fileSystem.directoryExists(at: directory) else { return }
        for entry in try fileSystem.contentsOfDirectory(at: directory) where !keep.contains(entry.lastPathComponent) {
            try fileSystem.removeItem(at: entry)
        }
    }

    /// Runtime ids of development builds (`warzagctl runtime use-local`, Warzag's development engine) have the form
    /// `<channel>-dev-<UTC time>`.
    public static let developmentMarker = "-dev-"

    /// Clears `Runtimes.noindex/staging` before an engine copy is staged there, so packs that were never activated do
    /// not keep hundreds of MB that macOS never purges. It keeps `id` (that copy) and use-local clones
    /// (`developmentMarker`), which another warzagctl or Warzag may be making right now and which their own install
    /// removes. A feed pack removed here is staged again when it is activated (`RuntimeStoreError.stagedHostMissing`).
    ///
    /// Each entry is renamed aside before it is deleted, so a copy another process is moving into the store at that
    /// moment ends up there whole, or stays where it is if the rename fails; it is never deleted half-way.
    public func pruneStaging(keeping id: String) {
        let staging = paths.runtimeStaging
        guard let entries = try? fileSystem.contentsOfDirectory(at: staging) else { return }
        for entry in entries {
            let name = entry.lastPathComponent
            guard name != id, !name.contains(Self.developmentMarker) else { continue }
            // A dot entry is nobody's copy: one an earlier prune set aside and could not finish deleting, or Finder's.
            var doomed = entry
            if !name.hasPrefix(".") {
                doomed = staging.appending(path: ".discarded-\(UUID().uuidString)")
                guard (try? fileSystem.moveItem(at: entry, to: doomed)) != nil else { continue }
            }
            try? fileSystem.removeItem(at: doomed)
        }
    }

    /// The previous runtime, if a rollback could use it.
    private func usablePrevious(in state: RuntimeStoreState) -> InstalledRuntime? {
        guard let previous = state.previous, !state.revoked.contains(previous.id),
              fileSystem.directoryExists(at: hostURL(for: previous)) else { return nil }
        return previous
    }

    private func activated(_ runtime: InstalledRuntime) -> InstalledRuntime {
        var runtime = runtime
        runtime.activatedAt = clock.now
        return runtime
    }

    private func save(_ state: RuntimeStoreState) throws {
        try fileSystem.writeAtomically(try WarzagJSON.encoder(pretty: true).encode(state), to: paths.activeRuntimePointer)
    }
}
