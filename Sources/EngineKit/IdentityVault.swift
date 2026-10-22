import Foundation
import WarzagCore
import WineKit

/// The machine identity a prefix shows Windows programs, persisted in Identity/identity.json so a rebuilt prefix
/// looks like the same PC to Warframe and does not trigger its new-device sign-in check.
///
/// Local data only: it is never uploaded, and warzagctl never prints its values.
public struct MachineIdentity: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public var schema: Int
    /// `HKLM\Software\Microsoft\Cryptography\MachineGuid`, created by the first wineboot.
    public var machineGuid: String
    /// The NetBIOS computer name. Wine derives it from the Mac's host name at every session start unless
    /// `HKCU\Software\Wine\Network\UseDnsComputerName` is "N", which Warzag sets so renaming the Mac changes nothing.
    public var computerName: String
    /// Drive letter ("C", "X") -> volume serial as eight uppercase hex digits. Wine reads a drive's serial from
    /// `.windows-serial` at the drive's root; without one this runtime reports a fixed default.
    public var volumeSerials: [String: String]
    /// The Windows profile name (Wine uses the macOS short user name); recorded, not something Warzag can change.
    public var windowsUserName: String
    public var capturedAt: Date

    public init(machineGuid: String, computerName: String, volumeSerials: [String: String], windowsUserName: String,
                capturedAt: Date) {
        schema = Self.schemaVersion
        self.machineGuid = machineGuid
        self.computerName = computerName
        self.volumeSerials = volumeSerials
        self.windowsUserName = windowsUserName
        self.capturedAt = capturedAt
    }

    public static let cryptographyKey = #"Software\Microsoft\Cryptography"#
    public static let computerNameKey = #"System\CurrentControlSet\Control\ComputerName\ComputerName"#
    public static let networkKey = #"Software\Wine\Network"#
    /// A computer name used only when the one wineboot derived cannot be written back through a REGEDIT4 file.
    public static let fallbackComputerName = "WARZAG-PC"

    /// The registry values that pin this identity in a prefix.
    public var registry: RegistryFile {
        var file = RegistryFile()
        file.set(.localMachine, Self.cryptographyKey, "MachineGuid", .string(machineGuid))
        file.set(.localMachine, Self.computerNameKey, "ComputerName", .string(computerName))
        file.set(.currentUser, Self.networkKey, "UseDnsComputerName", .string("N"))
        return file
    }

    public static func isValidMachineGuid(_ text: String) -> Bool {
        let groups = text.split(separator: "-", omittingEmptySubsequences: false)
        return groups.map(\.count) == [8, 4, 4, 4, 12] && groups.allSatisfy { $0.allSatisfy(\.isHexDigit) }
    }

    /// Something a REGEDIT4 file carries unchanged: printable ASCII, no longer than Windows allows.
    public static func isValidComputerName(_ text: String) -> Bool {
        (1...63).contains(text.count) && text.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) }
            && !text.contains("\\") && !text.contains("\"")
    }

    /// Throws unless every value can be written back into a prefix.
    public func validate() throws {
        guard schema == Self.schemaVersion else { throw IdentityError.unreadable("schema \(schema)") }
        guard Self.isValidMachineGuid(machineGuid) else { throw IdentityError.unreadable("MachineGuid is malformed") }
        guard Self.isValidComputerName(computerName) else { throw IdentityError.unreadable("ComputerName is malformed") }
        for (drive, serial) in volumeSerials {
            guard drive.count == 1, drive.first?.isLetter == true, VolumeSerial.normalized(serial) == serial else {
                throw IdentityError.unreadable("volume serial for \(drive): is malformed")
            }
        }
    }
}

public enum IdentityError: Error, Equatable, CustomStringConvertible {
    case unreadable(String)

    public var description: String {
        switch self {
        case .unreadable(let reason): "Identity/identity.json is unusable: \(reason)"
        }
    }
}

/// Identity/identity.json.
public struct IdentityVault: Sendable {
    public let paths: WarzagPaths
    public let fileSystem: any FileSystem

    public init(paths: WarzagPaths, fileSystem: any FileSystem) {
        self.paths = paths
        self.fileSystem = fileSystem
    }

    public var file: URL { paths.identityFile }

    /// nil when no identity has been captured yet.
    public func load() throws -> MachineIdentity? {
        guard fileSystem.fileExists(at: file) else { return nil }
        let identity: MachineIdentity
        do {
            identity = try WarzagJSON.decoder().decode(MachineIdentity.self, from: try fileSystem.contents(of: file))
        } catch {
            throw IdentityError.unreadable(String(describing: error))
        }
        try identity.validate()
        return identity
    }

    public func save(_ identity: MachineIdentity) throws {
        try identity.validate()
        try fileSystem.writeAtomically(try WarzagJSON.encoder(pretty: true).encode(identity), to: file)
    }
}

/// Wine's per-drive volume serial numbers.
public enum VolumeSerial {
    /// At the root of a drive (drive_c, or the folder X: maps to), as winecfg writes it.
    public static let fileName = ".windows-serial"

    /// Eight uppercase hex digits, or nil.
    public static func normalized(_ text: String) -> String? {
        let hex = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "-", with: "")
        guard (1...8).contains(hex.count), hex.allSatisfy(\.isHexDigit), let value = UInt32(hex, radix: 16) else {
            return nil
        }
        return String(format: "%08X", value)
    }

    public static func fileContents(_ serial: String) -> Data {
        Data((serial + "\n").utf8)
    }

    /// `vol` prints "Volume Serial Number is 4300-0000"; the words are localised, the number format is not.
    public static func parse(volOutput: String) -> String? {
        let characters = Array(volOutput)
        guard characters.count >= 9 else { return nil }
        var found: String?
        for start in 0...(characters.count - 9) where characters[start + 4] == "-" {
            let window = characters[start..<(start + 9)]
            let digits = window.filter { $0 != "-" }
            guard digits.count == 8, digits.allSatisfy(\.isHexDigit) else { continue }
            let before = start > 0 ? characters[start - 1] : " "
            let after = start + 9 < characters.count ? characters[start + 9] : " "
            guard !before.isHexDigit, !after.isHexDigit else { continue }
            found = normalized(String(digits))
        }
        return found
    }
}
