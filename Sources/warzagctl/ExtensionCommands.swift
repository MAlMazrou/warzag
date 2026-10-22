import Foundation

/// A command group with its own usage text (EngineCommands, GameCommands, AppCommands).
struct CommandGroup: Sendable {
    let usage: String
    let run: @Sendable (_ arguments: [String], _ context: CommandContext) -> CommandResult
}

enum ExtensionCommands {
    static let groups: [String: CommandGroup] = [
        "runtime": EngineCommands.runtime,
        "prefix": EngineCommands.prefix,
        "content": GameCommands.content,
        "play": GameCommands.play,
        "app": AppCommands.group,
    ]

    /// Dispatches to a group, or returns nil if the first word is not one. `--home <dir>` may stand anywhere on the
    /// line (`takeHome`), and the context is built for that home only (`CommandContext.live` may move its engine
    /// store), so a command run against a scratch home never touches the real one.
    static func dispatch(_ arguments: [String],
                         context makeContext: (_ home: String?) -> CommandContext = { CommandContext.live(home: $0) })
        -> CommandResult? {
        let (home, arguments) = takeHome(from: arguments)
        guard let word = arguments.first, let group = groups[word] else { return nil }
        if arguments.prefix(while: { $0 != "--" }).contains("--home") {
            // 64 is EX_USAGE from sysexits(3).
            return CommandResult(stderr: "warzagctl: --home needs a value\n\n\(group.usage)\n", exitCode: 64)
        }
        return group.run(Array(arguments.dropFirst()), makeContext(home))
    }

    /// Takes every `--home <dir>` off a command line, wherever it stands; the last one wins, as in
    /// `CommandLineParser`. What follows `--` is a program's own (`prefix run -- <program> [arguments...]`) and stays
    /// as it is. A `--home` without a value stays in place for the caller to refuse.
    static func takeHome(from arguments: [String]) -> (home: String?, arguments: [String]) {
        var home: String?
        var rest: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                rest += arguments[index...]
                break
            }
            if argument == "--home", index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                home = arguments[index + 1]
                index += 2
                continue
            }
            rest.append(argument)
            index += 1
        }
        return (home, rest)
    }

    static var usage: String { groups.keys.sorted().compactMap { groups[$0]?.usage }.joined(separator: "\n") }
}
