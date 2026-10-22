import Foundation
import Synchronization
import WarzagCore

/// Warzag's own log, ~/Library/Logs/Warzag/Warzag.log: one timestamped line per notable event (setup failures with
/// their technical detail, Play results). Nothing personal is written on purpose, and Export Diagnostics redacts it
/// anyway. Over 2 MB it moves to Warzag.old.log.
final class AppLog: Sendable {
    static let fileName = "Warzag.log"
    static let maximumBytes: UInt64 = 2_000_000

    let url: URL?
    private let lock = Mutex(())

    init(directory: URL?) {
        url = directory?.appending(path: Self.fileName)
    }

    /// A log that writes nothing (tests).
    static let disabled = AppLog(directory: nil)

    func write(_ message: String, at date: Date = Date()) {
        guard let url else { return }
        let line = "\(date.formatted(.iso8601)) \(message.replacingOccurrences(of: "\n", with: " "))\n"
        lock.withLock { _ in
            let manager = FileManager.default
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? manager.attributesOfItem(atPath: url.plainPath))?[.size] as? NSNumber,
               size.uint64Value > Self.maximumBytes {
                let old = url.deletingLastPathComponent().appending(path: "Warzag.old.log")
                try? manager.removeItem(at: old)
                try? manager.moveItem(at: url, to: old)
            }
            if !manager.fileExists(atPath: url.plainPath) {
                manager.createFile(atPath: url.plainPath, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }
}
