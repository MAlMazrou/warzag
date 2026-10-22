import Darwin
import Foundation

/// Read-only questions about other processes (is Steam running, since when, does anything still run from a folder),
/// behind a protocol for tests.
public protocol ProcessInspecting: Sendable {
    func isAlive(_ pid: Int32) -> Bool
    func executablePath(of pid: Int32) -> String?
    func startDate(of pid: Int32) -> Date?
    /// Every process on this Mac.
    func processIdentifiers() -> [Int32]
}

public extension ProcessInspecting {
    /// A process whose executable is inside `directory`, e.g. a Wine process started from an engine copy; nil when
    /// there is none. The kernel names executables by their real path (/private/tmp, not /tmp), so the folder is
    /// compared in both spellings.
    func processRunning(inside directory: URL) -> Int32? {
        var spellings = [directory.plainPath]
        if let resolved = realpath(directory.plainPath, nil) {
            spellings.append(String(cString: resolved))
            free(resolved)
        }
        let prefixes = spellings.map { $0 == "/" ? $0 : $0 + "/" }
        return processIdentifiers().first { pid in
            guard let path = executablePath(of: pid) else { return false }
            return prefixes.contains { path.hasPrefix($0) }
        }
    }
}

/// libproc and kill(2) based inspection. Nothing here sends a real signal.
public struct DarwinProcessInspector: ProcessInspecting {
    public init() {}

    public func isAlive(_ pid: Int32) -> Bool {
        // pid 0 and negative pids address process groups in kill(2); never probe those.
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        // EPERM: the process exists but belongs to someone else.
        return errno == EPERM
    }

    public func executablePath(of pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public func startDate(of pid: Int32) -> Date? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
            + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }

    public func processIdentifiers() -> [Int32] {
        // With no buffer, proc_listallpids says how many processes there are; room for a few more that start meanwhile.
        let expected = proc_listallpids(nil, 0)
        guard expected > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(expected) + 64)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).filter { $0 > 0 }
    }
}
