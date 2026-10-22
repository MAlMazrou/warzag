import Foundation
import WarzagCore
import WineKit

/// A registry value as the engine compares it.
public enum RegistryValue: Sendable, Equatable, CustomStringConvertible {
    case string(String)
    case dword(UInt32)
    /// Anything else (hex, multi-string ...), kept as written.
    case other(String)

    public var description: String {
        switch self {
        case .string(let text): "\"\(text)\""
        case .dword(let number): "dword:\(String(format: "%08x", number))"
        case .other(let text): text
        }
    }
}

/// Which of Wine's hive files holds a key.
public enum RegistryHiveFile: String, Sendable, Equatable {
    /// `system.reg`: HKEY_LOCAL_MACHINE (and HKEY_CLASSES_ROOT, under Software\Classes).
    case system
    /// `user.reg`: HKEY_CURRENT_USER.
    case user

    public var fileName: String { rawValue + ".reg" }
}

/// One value from a REGEDIT4 file, placed where Wine stores it.
public struct RegistryEntry: Sendable, Equatable {
    public var hive: RegistryHiveFile
    /// Backslash-separated key path relative to the hive file's root.
    public var key: String
    /// nil is the key's default value (`@`).
    public var name: String?
    public var value: RegistryValue

    public init(hive: RegistryHiveFile, key: String, name: String?, value: RegistryValue) {
        self.hive = hive
        self.key = key
        self.name = name
        self.value = value
    }

    /// For messages: `HKCU\Software\Valve\Steam\SteamPath`.
    public var displayName: String {
        (hive == .user ? "HKCU\\" : "HKLM\\") + key + "\\" + (name ?? "@")
    }
}

public struct RegistryParseError: Error, Equatable, CustomStringConvertible {
    public var line: Int
    public var reason: String
    public var description: String { "line \(line): \(reason)" }
}

/// Reads Wine's own registry files (`system.reg`, `user.reg`): `[key\\path] <timestamp>` sections of
/// `"name"=value` lines, escaped the way Wine's server writes them. wineserver saves a file up to 30 seconds after a
/// change and when it exits, so the file can trail the live registry.
public struct WineRegistryHive: Sendable {
    private var keys: [String: [String: RegistryValue]] = [:]

    public init(text: String) {
        var current: String?
        for line in Self.logicalLines(text) {
            if line.hasPrefix("[") {
                current = Self.parseQuoted(line, from: line.index(after: line.startIndex), terminator: "]")
                    .map { Self.normalize($0.0) }
                if let current, keys[current] == nil { keys[current] = [:] }
            } else if let key = current, line.first == "\"" || line.first == "@",
                      let (name, value) = Self.parseValueLine(line) {
                keys[key, default: [:]][(name ?? "@").lowercased()] = value
            }
        }
    }

    /// The hive in `url`, or nil when the file is missing or unreadable.
    public static func load(_ url: URL, fileSystem: any FileSystem) -> WineRegistryHive? {
        guard let data = try? fileSystem.contents(of: url) else { return nil }
        return WineRegistryHive(text: String(decoding: data, as: UTF8.self))
    }

    public func hasKey(_ key: String) -> Bool {
        Self.candidates(for: key).contains { keys[$0] != nil }
    }

    /// The value, matching key paths and names case-insensitively like Windows. `System\CurrentControlSet` is read
    /// from `ControlSet001`, where Wine keeps it.
    public func value(_ key: String, _ name: String?) -> RegistryValue? {
        for candidate in Self.candidates(for: key) {
            if let value = keys[candidate]?[(name ?? "@").lowercased()] { return value }
        }
        return nil
    }

    /// The value when it is a string (`REG_SZ`, `REG_EXPAND_SZ`).
    public func string(_ key: String, _ name: String?) -> String? {
        if case .string(let text)? = value(key, name) { return text }
        return nil
    }

    static func candidates(for key: String) -> [String] {
        let normalized = normalize(key)
        let alias = "system\\currentcontrolset"
        if normalized == alias || normalized.hasPrefix(alias + "\\") {
            return [normalized, "system\\controlset001" + normalized.dropFirst(alias.count)]
        }
        return [normalized]
    }

    static func normalize(_ key: String) -> String {
        key.split(separator: "\\", omittingEmptySubsequences: true).joined(separator: "\\").lowercased()
    }

    /// Lines with `\`-continued values joined: Wine and regedit wrap long hex values that way.
    static func logicalLines(_ text: String) -> [String] {
        var lines: [String] = []
        var pending: String?
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var line = String(raw)
            if let joined = pending {
                line = joined + line.trimmingCharacters(in: .whitespaces)
                pending = nil
            }
            if line.hasSuffix("\\"), line.first == "\"" || line.first == "@" {
                pending = String(line.dropLast())
                continue
            }
            lines.append(line)
        }
        if let pending { lines.append(pending) }
        return lines
    }

    /// `"name"=value` or `@=value`.
    static func parseValueLine(_ line: String) -> (String?, RegistryValue)? {
        let name: String?
        var index: String.Index
        if line.first == "@" {
            name = nil
            index = line.index(after: line.startIndex)
        } else {
            guard line.first == "\"",
                  let (parsed, end) = parseQuoted(line, from: line.index(after: line.startIndex), terminator: "\"")
            else { return nil }
            name = parsed
            index = end
        }
        guard index < line.endIndex, line[index] == "=" else { return nil }
        index = line.index(after: index)
        let rest = line[index...]
        if rest.first == "\"" {
            guard let (text, _) = parseQuoted(line, from: line.index(after: index), terminator: "\"") else { return nil }
            return (name, .string(text))
        }
        if rest.hasPrefix("dword:") {
            guard let number = UInt32(rest.dropFirst(6).prefix(8), radix: 16) else { return nil }
            return (name, .dword(number))
        }
        if rest.hasPrefix("str(2):\"") || rest.hasPrefix("str(1):\""),
           let (text, _) = parseQuoted(line, from: line.index(index, offsetBy: 8), terminator: "\"") {
            return (name, .string(text))
        }
        return (name, .other(String(rest)))
    }

    /// Reads up to an unescaped `terminator`; returns the unescaped text and the index after the terminator.
    /// Escapes as Wine's server writes them: `\\`, `\"`, `\]`, C escapes, `\x` + hex digits, `\` + octal digits.
    static func parseQuoted(_ line: String, from start: String.Index,
                            terminator: Character) -> (String, String.Index)? {
        var result = ""
        var index = start
        while index < line.endIndex {
            let character = line[index]
            if character == terminator { return (result, line.index(after: index)) }
            index = line.index(after: index)
            guard character == "\\" else {
                result.append(character)
                continue
            }
            guard index < line.endIndex else { return nil }
            let escaped = line[index]
            index = line.index(after: index)
            switch escaped {
            case "a": result.append("\u{07}")
            case "b": result.append("\u{08}")
            case "e": result.append("\u{1B}")
            case "f": result.append("\u{0C}")
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            case "v": result.append("\u{0B}")
            case "x":
                var digits = ""
                while index < line.endIndex, digits.count < 4, line[index].isHexDigit {
                    digits.append(line[index])
                    index = line.index(after: index)
                }
                if let value = UInt32(digits, radix: 16), let scalar = Unicode.Scalar(value) {
                    result.unicodeScalars.append(scalar)
                }
            case "0"..."7":
                var digits = String(escaped)
                while index < line.endIndex, digits.count < 3, ("0"..."7").contains(line[index]) {
                    digits.append(line[index])
                    index = line.index(after: index)
                }
                if let value = UInt32(digits, radix: 8), let scalar = Unicode.Scalar(value) {
                    result.unicodeScalars.append(scalar)
                }
            default:
                result.append(escaped)
            }
        }
        return nil
    }
}

/// Reads REGEDIT4 files, such as the bridge's steam.reg and the .reg files Warzag renders, placing each value in the
/// hive file Wine keeps it in (HKEY_CLASSES_ROOT is HKEY_LOCAL_MACHINE\Software\Classes).
public enum RegeditFile {
    public static func parse(_ text: String) throws -> [RegistryEntry] {
        var entries: [RegistryEntry] = []
        var current: (RegistryHiveFile, String)?
        var sawHeader = false
        for (offset, line) in WineRegistryHive.logicalLines(text).enumerated() {
            let number = offset + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix(";") { continue }
            if !sawHeader {
                guard trimmed == "REGEDIT4" else { throw RegistryParseError(line: number, reason: "not a REGEDIT4 file") }
                sawHeader = true
                continue
            }
            if trimmed.hasPrefix("[") {
                guard trimmed.hasSuffix("]") else { throw RegistryParseError(line: number, reason: "unterminated key") }
                current = try place(String(trimmed.dropFirst().dropLast()), line: number)
                continue
            }
            guard let (hive, key) = current else {
                throw RegistryParseError(line: number, reason: "value outside a key")
            }
            guard let (name, value) = WineRegistryHive.parseValueLine(trimmed) else {
                throw RegistryParseError(line: number, reason: "unreadable value")
            }
            entries.append(RegistryEntry(hive: hive, key: key, name: name, value: value))
        }
        guard sawHeader else { throw RegistryParseError(line: 1, reason: "not a REGEDIT4 file") }
        return entries
    }

    /// The entries of a `RegistryFile` Warzag renders, placed like `parse` places them.
    public static func entries(of file: RegistryFile) -> [RegistryEntry] {
        file.keys.flatMap { key in
            key.entries.map { entry in
                let value: RegistryValue = switch entry.value {
                case .string(let text): .string(text)
                case .dword(let number): .dword(number)
                }
                return RegistryEntry(hive: key.hive == .currentUser ? .user : .system, key: key.path,
                                     name: entry.name, value: value)
            }
        }
    }

    static func place(_ path: String, line: Int) throws -> (RegistryHiveFile, String) {
        let parts = path.split(separator: "\\", maxSplits: 1, omittingEmptySubsequences: false)
        let rest = parts.count > 1 ? String(parts[1]) : ""
        switch parts[0].uppercased() {
        case "HKEY_CURRENT_USER": return (.user, rest)
        case "HKEY_LOCAL_MACHINE": return (.system, rest)
        case "HKEY_CLASSES_ROOT": return (.system, rest.isEmpty ? "Software\\Classes" : "Software\\Classes\\" + rest)
        default: throw RegistryParseError(line: line, reason: "unsupported root key \(parts[0])")
        }
    }
}
