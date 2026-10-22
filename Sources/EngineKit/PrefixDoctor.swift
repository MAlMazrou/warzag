import Foundation
import RuntimeKit
import WarzagCore
import WineKit

/// One line of `warzagctl prefix doctor`.
public struct PrefixCheck: Codable, Equatable, Sendable {
    public var name: String
    public var passed: Bool
    /// What was found; never identity values or other personal data.
    public var detail: String

    public init(name: String, passed: Bool, detail: String) {
        self.name = name
        self.passed = passed
        self.detail = detail
    }
}

public struct PrefixDoctorReport: Codable, Equatable, Sendable {
    public var prefix: String
    public var channel: RuntimeChannel
    public var checks: [PrefixCheck]

    public var passed: Bool { checks.allSatisfy(\.passed) }

    /// `PASS  name      detail` lines.
    public var lines: [String] {
        let width = checks.map(\.name.count).max() ?? 0
        return checks.map { check in
            (check.passed ? "PASS" : "FAIL") + "  " + check.name.padding(toLength: width, withPad: " ", startingAt: 0)
                + "  " + check.detail
        }
    }

    enum CodingKeys: String, CodingKey { case prefix, channel, checks, passed }

    public init(prefix: String, channel: RuntimeChannel, checks: [PrefixCheck]) {
        self.prefix = prefix
        self.channel = channel
        self.checks = checks
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prefix = try container.decode(String.self, forKey: .prefix)
        channel = try container.decode(RuntimeChannel.self, forKey: .channel)
        checks = try container.decode([PrefixCheck].self, forKey: .checks)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(prefix, forKey: .prefix)
        try container.encode(channel, forKey: .channel)
        try container.encode(checks, forKey: .checks)
        try container.encode(passed, forKey: .passed)
    }
}

extension PrefixService {
    /// The checks `prefix doctor` runs, in order.
    public static let checkNames = ["runtime", "prefix", "manifest", "library", "dxmt", "lsteamclient", "bridge",
                                    "registry", "steam", "folders", "identity"]

    /// Verifies everything `create` sets up, without changing anything.
    public func doctor() async -> PrefixDoctorReport {
        var checks: [PrefixCheck] = []
        func add(_ name: String, _ passed: Bool, _ detail: String) {
            checks.append(PrefixCheck(name: name, passed: passed, detail: detail))
        }

        var active: ActiveRuntime?
        do {
            let runtime = try engine.runtime.active()
            try runtime.host.validate(fileSystem: engine.fileSystem)
            active = runtime
            add("runtime", true, "\(runtime.runtime.id), channel \(runtime.runtime.channel.rawValue) "
                + "(\(runtime.host.bundle.plainPath))")
        } catch {
            add("runtime", false, "\(error)")
        }

        let layout = self.layout
        let report = { PrefixDoctorReport(prefix: layout.root.plainPath, channel: .n, checks: checks) }
        guard isBooted(layout) else {
            add("prefix", false, "no prefix at \(layout.root.plainPath) (warzagctl prefix create)")
            for name in Self.checkNames.drop(while: { $0 != "prefix" }).dropFirst() {
                add(name, false, "no prefix")
            }
            return report()
        }
        add("prefix", true, layout.root.plainPath)

        var manifest: PrefixManifest?
        do {
            manifest = try PrefixManifest.load(from: layout, fileSystem: engine.fileSystem)
            if let manifest {
                if let active, manifest.runtimeID != active.runtime.id {
                    add("manifest", false, "set up with runtime \(manifest.runtimeID), the active runtime is "
                        + "\(active.runtime.id) (warzagctl prefix repair)")
                } else {
                    add("manifest", true, "set up with runtime \(manifest.runtimeID)")
                }
            } else {
                add("manifest", false, "no \(PrefixManifest.fileName) (warzagctl prefix repair)")
            }
        } catch {
            add("manifest", false, "\(error)")
        }

        // As in create/repair: the manifest's library, else where X: points now, else the default.
        let mapped = (try? engine.fileSystem.destinationOfSymbolicLink(at: layout.libraryDrive))
            .flatMap { $0.hasPrefix("/") ? $0 : nil }
        let library = (manifest?.library ?? mapped).map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? engine.paths.warframeLibrary
        let libraryProblem = checkLibrary(library, layout: layout)
        add("library", libraryProblem == nil, libraryProblem ?? "X: -> \(library.plainPath)")

        for group in PrefixFile.Group.allCases {
            guard let active else {
                add(group.rawValue, false, "needs the active runtime")
                continue
            }
            let files = PrefixFiles.all(host: active.host, layout: layout).filter { $0.group == group }
            let wrong = files.filter { !sameContents($0.source, $0.destination) }
                .map { layout.windowsPath(for: $0.destination) ?? $0.destination.lastPathComponent }
            add(group.rawValue, wrong.isEmpty, wrong.isEmpty
                ? (files.count == 1 ? "1 file matches the runtime" : "\(files.count) files match the runtime")
                : "missing or not the runtime's: " + wrong.joined(separator: ", "))
        }

        let hives = (user: hive(.user, in: layout), system: hive(.system, in: layout))
        let macDriver = manifest?.macDriver.settings ?? MacDriverSettings(retinaMode: false)
        let template = RegeditFile.entries(of: Self.registryTemplate(macDriver: macDriver))
        let templateMissing = missing(template, in: hives)
        add("registry", templateMissing.isEmpty, templateMissing.isEmpty
            ? "\(template.count) template values (Mac Driver, Launcher.exe overrides)"
            : "missing or different: " + templateMissing.joined(separator: ", "))

        if let active {
            let steamRegistry = RuntimeHostLayout(active.host).steamRegistry
            do {
                let entries = try RegeditFile.parse(String(decoding: try engine.fileSystem.contents(of: steamRegistry),
                                                           as: UTF8.self))
                let steamMissing = missing(entries, in: hives)
                add("steam", steamMissing.isEmpty, steamMissing.isEmpty
                    ? "\(entries.count) values from the bridge's steam.reg"
                    : "missing or different: " + steamMissing.joined(separator: ", "))
            } catch {
                add("steam", false, "cannot read \(steamRegistry.plainPath): \(error)")
            }
        } else {
            add("steam", false, "needs the active runtime")
        }

        let folders = folderProblems(in: layout)
        add("folders", folders.isEmpty, folders.isEmpty
            ? "real \(Self.realFolders.joined(separator: ", ")) folders (no links into the Mac home)"
            : folders.joined(separator: "; "))

        let identity = identityProblem(layout: layout, library: library, hives: hives)
        add("identity", identity == nil,
            identity ?? "MachineGuid, ComputerName and volume serials (C:, X:) match Identity/identity.json")
        return report()
    }

    private func checkLibrary(_ library: URL, layout: PrefixLayout) -> String? {
        let link = layout.libraryDrive
        guard engine.fileSystem.isSymbolicLink(at: link) else { return "dosdevices/x: is not a link" }
        guard let destination = try? engine.fileSystem.destinationOfSymbolicLink(at: link),
              destination == library.plainPath else {
            return "X: does not point at \(library.plainPath)"
        }
        guard engine.fileSystem.directoryExists(at: library) else { return "\(library.plainPath) does not exist" }
        return nil
    }

    private func sameContents(_ source: URL, _ destination: URL) -> Bool {
        let fileSystem = engine.fileSystem
        guard let a = try? fileSystem.attributes(of: source), let b = try? fileSystem.attributes(of: destination),
              a.size == b.size,
              let left = try? FileDigest.sha256(of: source, fileSystem: fileSystem),
              let right = try? FileDigest.sha256(of: destination, fileSystem: fileSystem) else { return false }
        return left == right
    }

    private func missing(_ entries: [RegistryEntry],
                         in hives: (user: WineRegistryHive?, system: WineRegistryHive?)) -> [String] {
        entries.filter { entry in
            let hive = entry.hive == .user ? hives.user : hives.system
            return hive?.value(entry.key, entry.name) != entry.value
        }.map(\.displayName)
    }

    private func folderProblems(in layout: PrefixLayout) -> [String] {
        var problems: [String] = []
        for name in Self.realFolders {
            let folder = layout.userProfile.appending(path: name, directoryHint: .isDirectory)
            if engine.fileSystem.isSymbolicLink(at: folder) {
                problems.append("\(name) links into the Mac home")
            } else if !engine.fileSystem.directoryExists(at: folder) {
                problems.append("\(name) is missing")
            }
        }
        return problems
    }

    private func identityProblem(layout: PrefixLayout, library: URL,
                                 hives: (user: WineRegistryHive?, system: WineRegistryHive?)) -> String? {
        let identity: MachineIdentity
        do {
            guard let saved = try engine.identity.load() else {
                return "no Identity/identity.json (warzagctl prefix repair captures it)"
            }
            identity = saved
        } catch {
            return "\(error)"
        }
        var wrong: [String] = []
        if hives.system?.value(MachineIdentity.cryptographyKey, "MachineGuid") != .string(identity.machineGuid) {
            wrong.append("MachineGuid")
        }
        if hives.system?.value(MachineIdentity.computerNameKey, "ComputerName") != .string(identity.computerName) {
            wrong.append("ComputerName")
        }
        if hives.user?.value(MachineIdentity.networkKey, "UseDnsComputerName") != .string("N") {
            wrong.append("UseDnsComputerName")
        }
        for (drive, root) in [("C", layout.driveC), ("X", library)] {
            let file = root.appending(path: VolumeSerial.fileName)
            let current = (try? engine.fileSystem.contents(of: file))
                .flatMap { VolumeSerial.normalized(String(decoding: $0, as: UTF8.self)) }
            if current == nil || current != identity.volumeSerials[drive] { wrong.append("\(drive): volume serial") }
        }
        return wrong.isEmpty ? nil : "differs from Identity/identity.json: " + wrong.joined(separator: ", ")
            + " (warzagctl prefix repair)"
    }
}
