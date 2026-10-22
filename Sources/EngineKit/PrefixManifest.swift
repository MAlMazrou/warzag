import Foundation
import WarzagCore
import WineKit

/// `MacDriverSettings` as recorded in a prefix manifest.
public struct MacDriverOptions: Codable, Equatable, Sendable {
    public var retinaMode: Bool
    public var optionAsAlt: Bool
    public var commandAsControl: Bool

    public init(_ settings: MacDriverSettings) {
        retinaMode = settings.retinaMode
        optionAsAlt = settings.optionAsAlt
        commandAsControl = settings.commandAsControl
    }

    public var settings: MacDriverSettings {
        MacDriverSettings(retinaMode: retinaMode, optionAsAlt: optionAsAlt, commandAsControl: commandAsControl)
    }
}

/// `<prefix>/warzag-prefix.json`: what the prefix was last set up with. When the active runtime differs, the
/// prefix needs `repair` (placeholders, bridge files and registry from the new runtime).
public struct PrefixManifest: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let fileName = "warzag-prefix.json"

    public var schema: Int
    public var channel: RuntimeChannel
    public var runtimeID: String
    public var runtimeVersion: String
    /// The folder X: maps to.
    public var library: String
    public var macDriver: MacDriverOptions
    public var createdAt: Date
    /// Last create or repair.
    public var configuredAt: Date

    public init(channel: RuntimeChannel, runtimeID: String, runtimeVersion: String, library: String,
                macDriver: MacDriverOptions, createdAt: Date, configuredAt: Date) {
        schema = Self.schemaVersion
        self.channel = channel
        self.runtimeID = runtimeID
        self.runtimeVersion = runtimeVersion
        self.library = library
        self.macDriver = macDriver
        self.createdAt = createdAt
        self.configuredAt = configuredAt
    }

    public static func url(in layout: PrefixLayout) -> URL { layout.root.appending(path: fileName) }

    /// nil when the prefix has none (not created by Warzag yet).
    public static func load(from layout: PrefixLayout, fileSystem: any FileSystem) throws -> PrefixManifest? {
        let file = url(in: layout)
        guard fileSystem.fileExists(at: file) else { return nil }
        let manifest: PrefixManifest
        do {
            manifest = try WarzagJSON.decoder().decode(PrefixManifest.self, from: try fileSystem.contents(of: file))
        } catch {
            throw PrefixError.manifestUnreadable(String(describing: error))
        }
        guard manifest.schema == schemaVersion else { throw PrefixError.manifestUnreadable("schema \(manifest.schema)") }
        return manifest
    }

    public func save(in layout: PrefixLayout, fileSystem: any FileSystem) throws {
        try fileSystem.writeAtomically(try WarzagJSON.encoder(pretty: true).encode(self), to: Self.url(in: layout))
    }
}
