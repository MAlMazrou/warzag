import EngineKit
import Foundation
import SteamHostKit
import WarzagCore

/// `warzagctl steam timeline` and `warzagctl steam probe`: developer diagnostics for Steam's sign-in. Both only read
/// Steam's files or ask Steam through the bridge; neither starts, shows or changes Steam.
enum SteamCommands {
    // MARK: timeline

    static let defaultMinutes = 60
    static let longestWindow = 7 * 24 * 60

    /// The last `minutes` of fixed tokens (no IDs, names or paths), times relative to now. With `follow`, keeps
    /// printing new events once a second until Ctrl-C (`polls` bounds it for tests).
    static func timeline(minutes: Int, follow: Bool, _ context: CommandContext, output: GameCommands.Output,
                         clock: any WallClock, polls: Int? = nil) async -> CommandResult {
        let now = clock.now
        let timeline = SteamTimeline(locations: context.steam,
                                     warzagLog: context.paths.logs.appending(path: "Warzag.log"),
                                     fileSystem: context.fileSystem, timeZone: context.timeZone)
        var follower = follow ? timeline.follower() : nil
        let events = timeline.events(since: now.addingTimeInterval(-Double(minutes) * 60), before: follower)
        var text = "Steam timeline, the last \(minutes) min (times from now; fixed tokens only, no IDs, names or paths)\n"
        text += events.isEmpty ? "  nothing logged\n" : SteamTimeline.render(events, relativeTo: now)
        guard follower != nil else { return CommandResult(stdout: text) }

        output.write(text + "following (Ctrl-C ends it)\n")
        follower?.continueAfter(events)
        var last = events.last?.at
        var count = 0
        while !Task.isCancelled, polls.map({ count < $0 }) ?? true {
            do {
                try await clock.sleep(for: .seconds(1))
            } catch {
                break
            }
            count += 1
            guard let new = follower?.poll(), !new.isEmpty else { continue }
            output.write(SteamTimeline.render(new, relativeTo: now, after: last))
            last = new.last?.at
        }
        return CommandResult()
    }

    // MARK: probe

    static let probeNotice = "wz-steamprobe.exe registers with Steam as Warframe (230410) for a moment: Steam shows "
        + "Warframe as playing while it runs.\n"

    /// wz-steamprobe.exe through EngineKit with setup's own invocation (`PrefixService.runSteamProbe`). Says first
    /// that it registers with Steam as Warframe; refuses while Steam isn't running (warzagctl never starts Steam).
    static func probe(_ context: CommandContext, engine: Engine, output: GameCommands.Output) async -> CommandResult {
        output.write(probeNotice)
        let steam = SteamDetector(locations: context.steam, fileSystem: context.fileSystem,
                                  processes: context.processes, timeZone: context.timeZone)
        guard steam.runningSteamProcess() != nil else {
            return CommandResult(stderr: "warzagctl: Steam is not running; start Steam and sign in first (warzagctl "
                + "never starts Steam)\n", exitCode: 1)
        }
        let prefix = engine.prefix
        do {
            let result = try await prefix.runSteamProbe(steamClientDirectory: context.steam.clientDirectory)
            let outcome = SteamProbe.Outcome(exitCode: result.exitCode)
            let home = context.steam.home.plainPath
            let log = prefix.logFile.plainPath
            let text = "wz-steamprobe.exe exited with status \(result.exitCode): \(outcome)\n"
                + "its JSON line is in \(log.hasPrefix(home + "/") ? "~" + String(log.dropFirst(home.count)) : log)\n"
            return CommandResult(stdout: text, exitCode: outcome == .owned ? 0 : 1)
        } catch {
            return CommandResult(stderr: "warzagctl steam probe: \(error)\n", exitCode: 1)
        }
    }
}
