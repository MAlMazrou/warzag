import AppUpdateKit
import EngineKit
import Foundation
import WarzagCore

/// Warzag's entry point: the app, unless the Warzag this one replaces started it as its update helper
/// (`UpdateHelper`), which never starts the app.
@main
enum WarzagEntry {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        if UpdateHelper.isRequested(by: arguments) { exit(UpdateHelper.run(arguments)) }
        WarzagMain.main()
    }
}

/// Warzag's own executable as the update helper (`AppSwapCommand`, docs/RELEASING.md). Only the Warzag it replaces
/// starts it, with `AppSwapCommand.appFlag` first: once to probe while that Warzag runs and once to swap after it has
/// quit, each responsible for itself (`PosixHelperLauncher`), so macOS treats both as Warzag. It records the outcome
/// and exits without an NSApplication: no window, no Dock icon, no model.
enum UpdateHelper {
    static func isRequested(by arguments: [String]) -> Bool {
        arguments.dropFirst().first == AppSwapCommand.appFlag
    }

    /// Runs it on this process's `arguments` (the executable, the flag, then `AppSwapCommand`'s) and returns the exit
    /// status (`AppSwapExit`; 64 for a command line it does not take). The last line on stderr says why it failed,
    /// for the app that waits for the probe.
    static func run(_ arguments: [String], signers: Set<String> = RuntimeTrust.pinned.signerFingerprints) -> Int32 {
        let result: AppSwapCommand.Result
        do {
            let command = try AppSwapCommand.parse(Array(arguments.dropFirst(2)))
            let home = command.home.map { URL(filePath: $0, directoryHint: .isDirectory) }
                ?? FileManager.default.homeDirectoryForCurrentUser
            let directory = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
            result = AppSwapCommand.blocking {
                await command.run(signers: signers, paths: WarzagPaths(home: home), currentDirectory: directory,
                                  output: { FileHandle.standardOutput.write(Data($0.utf8)) },
                                  swap: { AppSwap.live(installed: $0, staged: $1, requirement: $2, log: $3) })
            }
        } catch {
            // 64 is EX_USAGE from sysexits(3).
            result = AppSwapCommand.Result(exitCode: 64, reason: error.description)
        }
        if let reason = result.reason { FileHandle.standardError.write(Data((reason + "\n").utf8)) }
        return result.exitCode
    }
}
