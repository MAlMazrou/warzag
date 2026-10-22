import Foundation

/// A value in a Valve KeyValues ("VDF") text file: a string, or a nested block.
public enum VDFValue: Equatable, Sendable {
    case string(String)
    case object(VDFObject)

    public var stringValue: String? {
        if case .string(let value) = self { value } else { nil }
    }

    public var objectValue: VDFObject? {
        if case .object(let value) = self { value } else { nil }
    }

    public subscript(key: String) -> VDFValue? { objectValue?[key] }
}

public struct VDFEntry: Equatable, Sendable {
    public var key: String
    public var value: VDFValue

    public init(key: String, value: VDFValue) {
        self.key = key
        self.value = value
    }
}

/// An ordered block of entries. KeyValues allows duplicate keys and looks keys up case-insensitively; lookups
/// return the first match, as Valve's `FindKey` does.
public struct VDFObject: Equatable, Sendable {
    public var entries: [VDFEntry]

    public init(entries: [VDFEntry] = []) {
        self.entries = entries
    }

    public subscript(key: String) -> VDFValue? {
        entries.first { Self.sameKey($0.key, key) }?.value
    }

    /// Follows a path of nested keys, e.g. ["Registry", "HKLM", "Software", "Valve", "Steam", "SteamPID"].
    public func value(atPath path: [String]) -> VDFValue? {
        guard let first = path.first else { return .object(self) }
        var current = self[first]
        for key in path.dropFirst() {
            current = current?[key]
        }
        return current
    }

    public func string(atPath path: [String]) -> String? {
        value(atPath: path)?.stringValue
    }

    private static func sameKey(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }
}

public struct VDFParseError: Error, Equatable, CustomStringConvertible {
    public var message: String
    public var line: Int
    public var column: Int

    public var description: String { "VDF \(line):\(column): \(message)" }
}

/// Parser for Valve's KeyValues text format as Steam writes it (registry.vdf, client manifests, libraryfolders.vdf):
/// quoted or bare tokens, nested `{ }` blocks, `//` comments, `\n \t \r \\ \"` escapes, and `[$OSX]`-style
/// conditionals (accepted and ignored). Unknown escapes are kept verbatim, so unescaped Windows paths survive.
public enum VDF {
    /// Deeper nesting than this is treated as a malformed (or hostile) file.
    public static let maximumDepth = 256

    public static func parse(_ text: String) throws(VDFParseError) -> VDFObject {
        try parse(Data(text.utf8))
    }

    public static func parse(_ data: Data) throws(VDFParseError) -> VDFObject {
        var lexer = Lexer(bytes: [UInt8](data))
        var stack: [(key: String, entries: [VDFEntry])] = [("", [])]

        while true {
            let (token, position) = try lexer.next()
            switch token {
            case .end:
                guard stack.count == 1 else { throw position.error("missing '}' at end of file") }
                return VDFObject(entries: stack[0].entries)
            case .conditional:
                continue
            case .closeBrace:
                guard stack.count > 1 else { throw position.error("unexpected '}'") }
                let block = stack.removeLast()
                let object = VDFValue.object(VDFObject(entries: block.entries))
                stack[stack.count - 1].entries.append(VDFEntry(key: block.key, value: object))
            case .openBrace:
                throw position.error("block without a key")
            case .text(let key):
                var (valueToken, valuePosition) = try lexer.next()
                while case .conditional = valueToken { (valueToken, valuePosition) = try lexer.next() }
                switch valueToken {
                case .text(let value):
                    stack[stack.count - 1].entries.append(VDFEntry(key: key, value: .string(value)))
                case .openBrace:
                    guard stack.count < maximumDepth else { throw valuePosition.error("nested too deeply") }
                    stack.append((key, []))
                case .closeBrace, .end, .conditional:
                    throw valuePosition.error("key \"\(key)\" has no value")
                }
            }
        }
    }

    private enum Token {
        case text(String)
        case openBrace
        case closeBrace
        case conditional
        case end
    }

    private struct Position {
        var line: Int
        var column: Int

        func error(_ message: String) -> VDFParseError {
            VDFParseError(message: message, line: line, column: column)
        }
    }

    private struct Lexer {
        let bytes: [UInt8]
        var index = 0
        var line = 1
        var lineStart = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3; lineStart = 3 }
        }

        private var position: Position { Position(line: line, column: index - lineStart + 1) }

        mutating func next() throws(VDFParseError) -> (Token, Position) {
            skipWhitespaceAndComments()
            let start = position
            guard index < bytes.count else { return (.end, start) }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                index += 1
                return (.openBrace, start)
            case UInt8(ascii: "}"):
                index += 1
                return (.closeBrace, start)
            case UInt8(ascii: "\""):
                return (.text(try quoted(start)), start)
            case UInt8(ascii: "["):
                skipConditional()
                return (.conditional, start)
            default:
                return (.text(bare()), start)
            }
        }

        private mutating func skipWhitespaceAndComments() {
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\n") {
                    index += 1
                    line += 1
                    lineStart = index
                } else if byte <= 0x20 {
                    // Spaces, tabs, CR and any other control byte separate tokens.
                    index += 1
                } else if byte == UInt8(ascii: "/"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "/") {
                    while index < bytes.count, bytes[index] != UInt8(ascii: "\n") { index += 1 }
                } else {
                    return
                }
            }
        }

        private mutating func quoted(_ start: Position) throws(VDFParseError) -> String {
            index += 1
            var buffer: [UInt8] = []
            while index < bytes.count {
                let byte = bytes[index]
                switch byte {
                case UInt8(ascii: "\""):
                    index += 1
                    return String(decoding: buffer, as: UTF8.self)
                case UInt8(ascii: "\\") where index + 1 < bytes.count:
                    let escaped = bytes[index + 1]
                    switch escaped {
                    case UInt8(ascii: "n"): buffer.append(0x0A)
                    case UInt8(ascii: "t"): buffer.append(0x09)
                    case UInt8(ascii: "r"): buffer.append(0x0D)
                    case UInt8(ascii: "\\"), UInt8(ascii: "\""): buffer.append(escaped)
                    default: buffer.append(contentsOf: [byte, escaped])
                    }
                    index += 2
                default:
                    if byte == UInt8(ascii: "\n") {
                        line += 1
                        lineStart = index + 1
                    }
                    buffer.append(byte)
                    index += 1
                }
            }
            throw start.error("unterminated string")
        }

        private mutating func bare() -> String {
            let begin = index
            while index < bytes.count {
                let byte = bytes[index]
                if byte <= 0x20 || byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "{") || byte == UInt8(ascii: "}") {
                    break
                }
                index += 1
            }
            return String(decoding: bytes[begin..<index], as: UTF8.self)
        }

        private mutating func skipConditional() {
            while index < bytes.count, bytes[index] != UInt8(ascii: "]"), bytes[index] != UInt8(ascii: "\n") {
                index += 1
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1 }
        }
    }
}
