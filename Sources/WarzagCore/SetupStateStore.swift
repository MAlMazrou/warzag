import Foundation

/// Reads and writes State/setup.json.
///
/// A file Warzag cannot use (corrupt, or written by a newer schema) is moved aside to `setup.unreadable.json` and
/// setup starts over; every step re-checks its own work, so starting over costs seconds, not downloads.
public struct SetupStateStore: Sendable {
    public enum FileStatus: Equatable, Sendable {
        case missing
        case readable(SetupState)
        case unreadable
    }

    public let url: URL
    public let fileSystem: any FileSystem

    public init(url: URL, fileSystem: any FileSystem) {
        self.url = url
        self.fileSystem = fileSystem
    }

    public init(paths: WarzagPaths, fileSystem: any FileSystem) {
        self.init(url: paths.setupStateFile, fileSystem: fileSystem)
    }

    public var unreadableCopy: URL { url.deletingLastPathComponent().appending(path: "setup.unreadable.json") }

    /// What is on disk, without changing anything (for diagnostics).
    public func inspect() -> FileStatus {
        guard fileSystem.fileExists(at: url) else { return .missing }
        guard let data = try? fileSystem.contents(of: url),
              let header = try? WarzagJSON.decoder().decode(SchemaHeader.self, from: data),
              header.schema == SetupState.schemaVersion,
              let state = try? WarzagJSON.decoder().decode(SetupState.self, from: data)
        else { return .unreadable }
        return .readable(state)
    }

    /// The saved state, or nil when there is none. An unreadable file is set aside.
    public func load() -> SetupState? {
        switch inspect() {
        case .missing:
            return nil
        case .readable(let state):
            return state
        case .unreadable:
            try? fileSystem.removeItem(at: unreadableCopy)
            try? fileSystem.moveItem(at: url, to: unreadableCopy)
            return nil
        }
    }

    public func save(_ state: SetupState) throws {
        try fileSystem.writeAtomically(try WarzagJSON.encoder(pretty: true).encode(state), to: url)
    }

    private struct SchemaHeader: Decodable {
        var schema: Int
    }
}
