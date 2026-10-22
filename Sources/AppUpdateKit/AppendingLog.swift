import Darwin
import Foundation
import WarzagCore

/// Appends timestamped lines to Warzag.log the way the app's own log writes them (`<ISO 8601> <message>`), for the
/// update helper, which runs once the app has quit. Every line is one write(2) with O_APPEND, so it never tears a line
/// another process writes at the same moment. The home folder is written as ~, so nothing personal is logged.
public struct AppendingLog: Sendable {
    public let url: URL?
    /// The home folder as given and with its links resolved (/var is /private/var), longest first.
    let homes: [String]

    public init(url: URL?, home: URL? = FileManager.default.homeDirectoryForCurrentUser) {
        self.url = url
        var spellings: [String] = []
        if let path = home?.plainPath, path.count > 1 {
            spellings.append(path)
            if let real = realpath(path, nil) {
                spellings.append(String(cString: real))
                free(real)
            }
        }
        homes = Array(Set(spellings)).sorted { $0.count > $1.count }
    }

    /// `message` on one line, with the home folder written as ~ wherever a path starts with it.
    public func redacted(_ message: String) -> String {
        homes.reduce(message.replacingOccurrences(of: "\n", with: " ")) { line, home in
            Self.replacing(home, in: line)
        }
    }

    /// `home` replaced by ~ where it is a whole path or a path's start: not inside a longer path (the /var in
    /// /private/var) and not as part of a longer name (/Users/tenno in /Users/tenno2).
    static func replacing(_ home: String, in text: String) -> String {
        func isPathCharacter(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || "/._-~".contains(character)
        }
        var result = ""
        var rest = Substring(text)
        while let range = rest.range(of: home) {
            let before = rest[..<range.lowerBound]
            let previous = before.last ?? result.last
            let next = rest[range.upperBound...].first
            let whole = previous.map { !isPathCharacter($0) } ?? true
                && next.map { $0 == "/" || !isPathCharacter($0) } ?? true
            result += before
            result += whole ? "~" : String(rest[range])
            rest = rest[range.upperBound...]
        }
        return result + rest
    }

    public func write(_ message: String, at date: Date = Date()) {
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.plainPath, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        let line = "\(date.formatted(.iso8601)) \(redacted(message))\n"
        _ = line.utf8CString.withUnsafeBufferPointer { buffer in
            Darwin.write(descriptor, buffer.baseAddress, buffer.count - 1)
        }
    }
}
