import Foundation

public enum RegistryFileError: Error, Equatable, CustomStringConvertible {
    /// REGEDIT4 files are read in the prefix's ANSI code page; only ASCII round-trips everywhere.
    case notASCII(String)
    case controlCharacter(String)
    case invalidKeyPath(String)

    public var description: String {
        switch self {
        case .notASCII(let text): "registry text must be ASCII: \(text)"
        case .controlCharacter(let text): "registry text contains a control character: \(text.debugDescription)"
        case .invalidKeyPath(let path): "invalid registry key path: \(path)"
        }
    }
}

/// A REGEDIT4 `.reg` file, as imported by Wine's `reg import`.
///
/// Strings and value names are quoted with `\` and `"` escaped; DWORDs are `dword:` plus eight hex digits. Text
/// that REGEDIT4 cannot carry faithfully (non-ASCII, control characters) is rejected rather than mangled.
public struct RegistryFile: Sendable, Equatable {
    public enum Hive: String, Sendable {
        case currentUser = "HKEY_CURRENT_USER"
        case localMachine = "HKEY_LOCAL_MACHINE"
    }

    public enum Value: Sendable, Equatable {
        case string(String)
        case dword(UInt32)
    }

    public struct Entry: Sendable, Equatable {
        /// nil is the key's default value, written `@`.
        public var name: String?
        public var value: Value
    }

    public struct Key: Sendable, Equatable {
        public var hive: Hive
        /// Backslash-separated, e.g. `Software\Wine\Mac Driver`.
        public var path: String
        public var entries: [Entry]
    }

    public private(set) var keys: [Key] = []

    public init() {}

    /// Sets a value, creating the key if needed. Keys and value names match case-insensitively, as in the registry.
    public mutating func set(_ hive: Hive, _ path: String, _ name: String?, _ value: Value) {
        let keyIndex: Int
        if let index = keys.firstIndex(where: {
            $0.hive == hive && $0.path.caseInsensitiveCompare(path) == .orderedSame
        }) {
            keyIndex = index
        } else {
            keys.append(Key(hive: hive, path: path, entries: []))
            keyIndex = keys.count - 1
        }
        let entry = Entry(name: name, value: value)
        if let existing = keys[keyIndex].entries.firstIndex(where: { Self.sameName($0.name, name) }) {
            keys[keyIndex].entries[existing] = entry
        } else {
            keys[keyIndex].entries.append(entry)
        }
    }

    /// The file's text with CRLF line endings, as Windows and Wine write them.
    public func rendered() throws(RegistryFileError) -> String {
        var lines = ["REGEDIT4", ""]
        for key in keys {
            try Self.validate(keyPath: key.path)
            lines.append("[\(key.hive.rawValue)\\\(key.path)]")
            for entry in key.entries {
                let name = try entry.name.map(Self.quoted) ?? "@"
                switch entry.value {
                case .string(let text): lines.append("\(name)=\(try Self.quoted(text))")
                case .dword(let number): lines.append("\(name)=dword:\(String(format: "%08x", number))")
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    public func data() throws(RegistryFileError) -> Data {
        Data(try rendered().utf8)
    }

    static func quoted(_ text: String) throws(RegistryFileError) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            guard scalar.isASCII else { throw .notASCII(text) }
            guard scalar.value >= 0x20, scalar.value != 0x7F else { throw .controlCharacter(text) }
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    static func validate(keyPath: String) throws(RegistryFileError) {
        let components = keyPath.split(separator: "\\", omittingEmptySubsequences: false)
        for component in components {
            guard !component.isEmpty,
                  component.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 && $0.value != 0x7F }),
                  !component.contains("["), !component.contains("]") else {
                throw .invalidKeyPath(keyPath)
            }
        }
    }

    private static func sameName(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (left?, right?): left.caseInsensitiveCompare(right) == .orderedSame
        default: false
        }
    }
}
