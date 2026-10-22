import Darwin
import Foundation
import Testing
@testable import WarzagCore

/// Cancelling the task of a running command stops the command (a real child: harmless system tools only).
@Suite(.timeLimit(.minutes(1)))
struct ProcessCancellationTests {
    /// A scratch folder for the child's pid file.
    static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "warzag-cancel-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Waits until the child has written its pid.
    static func pid(in file: URL) async throws -> Int32 {
        for _ in 0..<500 {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CancellationError()
    }

    static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    @Test func cancellingARunStopsTheChildAndThrows() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appending(path: "pid")
        let command = Command("/bin/sh", ["-c", "echo $$ > '\(pidFile.plainPath)'; exec /bin/sleep 30"])
        let started = Date()
        let task = Task { try await SystemProcessRunner().run(command) }
        let pid = try await Self.pid(in: pidFile)
        #expect(Self.isAlive(pid))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        // It returned because the child is gone, not as soon as the task was cancelled.
        #expect(!Self.isAlive(pid))
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func aChildIgnoringSIGTERMIsKilledAfterTheGracePeriod() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appending(path: "pid")
        let command = Command("/bin/sh", ["-c", "trap '' TERM; echo $$ > '\(pidFile.plainPath)'; exec /bin/sleep 30"])
        let runner = SystemProcessRunner(killGracePeriod: .milliseconds(400))
        let task = Task { try await runner.run(command) }
        let pid = try await Self.pid(in: pidFile)
        let cancelled = Date()
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(!Self.isAlive(pid))
        // SIGTERM was ignored: only SIGKILL, after the grace period, ended it.
        #expect(Date().timeIntervalSince(cancelled) >= 0.35)
        #expect(Date().timeIntervalSince(cancelled) < 10)
    }

    @Test func aCancelledTaskStartsNothing() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appending(path: "ran")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SystemProcessRunner().run(Command("/usr/bin/touch", [marker.plainPath]))
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(!FileManager.default.fileExists(atPath: marker.plainPath))
    }

    @Test func aRunThatEndsOnItsOwnKeepsItsExitStatus() async throws {
        let output = try await SystemProcessRunner().run(Command("/bin/sh", ["-c", "echo done; exit 7"]))
        #expect(output.exitCode == 7)
        #expect(output.standardOutput == "done\n")
    }
}
