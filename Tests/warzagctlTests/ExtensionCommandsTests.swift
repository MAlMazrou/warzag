import Foundation
import Testing
import WarzagCore
import WarzagTestSupport
@testable import warzagctl

/// The command groups (runtime, prefix, content, play) take `--home` as the built-in commands do, anywhere on the line.
@Suite struct ExtensionCommandsTests {
    func words(_ line: String) -> [String] { line.split(separator: " ").map(String.init) }

    @Test(arguments: [
        ("runtime status --home /tmp/h", "/tmp/h", "runtime status"),
        ("--home /tmp/h runtime status", "/tmp/h", "runtime status"),
        ("prefix doctor --json --home /tmp/h", "/tmp/h", "prefix doctor --json"),
        ("content status --home /tmp/a --prefix /p --home /tmp/h", "/tmp/h", "content status --prefix /p"),
        // After `--`, the program's own arguments, its own --home included.
        ("prefix run --home /tmp/h -- x.exe --home /y", "/tmp/h", "prefix run -- x.exe --home /y"),
        ("runtime use-local build/n/Warzag.app", nil, "runtime use-local build/n/Warzag.app"),
        // Without a value it stays for the caller to refuse.
        ("runtime status --home", nil, "runtime status --home"),
        ("runtime status --home --json", nil, "runtime status --home --json"),
    ] as [(String, String?, String)])
    func homeIsTakenFromAnywhereButAProgramsOwnArguments(_ line: String, _ home: String?, _ rest: String) {
        let taken = ExtensionCommands.takeHome(from: words(line))
        #expect(taken.home == home)
        #expect(taken.arguments == words(rest))
    }

    /// Runs a blocking warzagctl entry point (it waits on a semaphore for its async work) on a thread of its own,
    /// never on one of the cooperative threads the tests share.
    func onOwnThread(_ body: @escaping @Sendable () -> CommandResult?) async -> CommandResult? {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread { continuation.resume(returning: body()) }
        }
    }

    /// A group's context is built for the `--home` given anywhere on the line, never for the default home.
    @Test func aScratchHomeAnywhereOnTheLineIsTheOneUsed() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultHome = root.appending(path: "default", directoryHint: .isDirectory)
        let scratch = root.appending(path: "scratch", directoryHint: .isDirectory).plainPath

        let asked = Recorder<String?>()
        func dispatch(_ line: String) async -> CommandResult? {
            let arguments = words(line)
            return await onOwnThread {
                ExtensionCommands.dispatch(arguments) { home in
                    asked.append(home)
                    // The default home stands in for the real one.
                    return CommandContext.live(home: home ?? defaultHome.plainPath)
                }
            }
        }

        for line in ["runtime status --home \(scratch)", "--home \(scratch) runtime status"] {
            let status = await dispatch(line)
            #expect(status?.exitCode == 0, "\(status?.stderr ?? "no result")")
            #expect(status?.stdout.contains("none (warzagctl runtime install") == true, "\(status?.stdout ?? "")")
        }
        let prefix = await dispatch("prefix path --home \(scratch)")
        #expect(prefix?.stdout == scratch + "/Library/Application Support/Warzag/Prefixes/warframe-arm64\n")
        let missing = await dispatch("runtime status --home")
        #expect(missing?.exitCode == 64)
        #expect(missing?.stderr.hasPrefix("warzagctl: --home needs a value\n") == true)

        #expect(asked.all == [scratch, scratch, scratch], "a context for the scratch home only, never the default one")
        #expect(!FileManager.default.fileExists(atPath: defaultHome.plainPath))
    }
}
