import Foundation
import WarzagCore
import WineKit

enum Invocation: Equatable {
    case help
    case version
    case paths(json: Bool)
    case doctor(json: Bool)
    case steamStatus(json: Bool)
    /// `steam timeline [--minutes N] [--follow]`.
    case steamTimeline(minutes: Int, follow: Bool)
    case steamProbe
    case profile(json: Bool)
    case env(EnvOptions)
}

struct EnvOptions: Equatable {
    enum Kind: Equatable {
        case session
        case tool
    }

    var kind: Kind
    var host: String?
    var prefix: String?
    var renderer: Renderer = .dxmt
    var steam = true
    /// `--nvext`: as `warzagctl play --nvext` (`PresetCatalog.nvextDefault`).
    var nvext = false
}

struct ParsedCommandLine: Equatable {
    /// `--home <dir>`: run against another home directory (tests, scratch trees).
    var home: String?
    var invocation: Invocation
}

struct UsageError: Error, Equatable, CustomStringConvertible {
    var message: String
    var description: String { message }
}

/// Parses `warzagctl [--home <dir>] <command> [options]`.
enum CommandLineParser {
    static let usage = """
        usage: warzagctl [--home <dir>] <command> [options]

        commands:
          paths [--json]                 Warzag's on-disk locations
          doctor [--json]                hardware, performance tier and Steam status
          steam status [--json]          native Mac Steam: installed, running, signed in, client version
          steam timeline [--minutes N] [--follow]
                                         Steam's starts and stops, connection states, sign-in steps and game
                                         processes, with Warzag's play and steam lines, as fixed tokens (no IDs,
                                         names or paths) timed from now; --follow prints new ones until Ctrl-C
          steam probe                    wz-steamprobe.exe in the prefix: can Steam be reached, is someone signed
                                         in, does the account own Warframe (registers with Steam as Warframe for a
                                         moment; Steam must be running)
          profile [--json]               graphics preset for this Mac (frame cap, upscaler, Retina, EE.cfg seed)
          env --session|--tool [--host <Warzag.app>] [--prefix <dir>]
              [--renderer dxmt|wined3d] [--no-steam] [--nvext]
                                         the exact Wine environment, as KEY=VALUE lines (--nvext: DXMT's NVIDIA
                                         identity, experiments only, no DLSS in Warframe)
          help, version
        """

    static func parse(_ arguments: [String]) throws(UsageError) -> ParsedCommandLine {
        var home: String?
        var words: [String] = []
        var options: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--home" {
                home = try value(after: argument, in: arguments, at: &index)
            } else if argument.hasPrefix("-") {
                options.append(argument)
                if ["--host", "--prefix", "--renderer", "--minutes"].contains(argument) {
                    options.append(try value(after: argument, in: arguments, at: &index))
                }
            } else {
                words.append(argument)
            }
            index += 1
        }

        if options.contains("--help") || options.contains("-h") { return ParsedCommandLine(home: home, invocation: .help) }
        if options.contains("--version") { return ParsedCommandLine(home: home, invocation: .version) }

        let invocation: Invocation
        switch words {
        case []: throw UsageError(message: "missing command")
        case ["help"]: invocation = .help
        case ["version"]: invocation = .version
        case ["paths"]: invocation = .paths(json: try jsonFlag(options))
        case ["doctor"]: invocation = .doctor(json: try jsonFlag(options))
        case ["steam", "status"], ["steam"]: invocation = .steamStatus(json: try jsonFlag(options))
        case ["steam", "timeline"]: invocation = try timelineOptions(options)
        case ["steam", "probe"]:
            if let option = options.first { throw UsageError(message: "unknown option for steam probe: \(option)") }
            invocation = .steamProbe
        case ["profile"]: invocation = .profile(json: try jsonFlag(options))
        case ["env"]: invocation = .env(try envOptions(options))
        default: throw UsageError(message: "unknown command: \(words.joined(separator: " "))")
        }
        return ParsedCommandLine(home: home, invocation: invocation)
    }

    private static func value(after option: String, in arguments: [String],
                              at index: inout Int) throws(UsageError) -> String {
        guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
            throw UsageError(message: "\(option) needs a value")
        }
        index += 1
        return arguments[index]
    }

    private static func jsonFlag(_ options: [String]) throws(UsageError) -> Bool {
        for option in options where option != "--json" {
            throw UsageError(message: "unknown option: \(option)")
        }
        return options.contains("--json")
    }

    private static func timelineOptions(_ options: [String]) throws(UsageError) -> Invocation {
        var minutes = SteamCommands.defaultMinutes
        var follow = false
        var index = 0
        while index < options.count {
            switch options[index] {
            case "--follow":
                follow = true
            case "--minutes":
                index += 1
                guard let value = Int(options[index]), (1...SteamCommands.longestWindow).contains(value) else {
                    throw UsageError(message: "--minutes needs a whole number from 1 to \(SteamCommands.longestWindow)")
                }
                minutes = value
            default:
                throw UsageError(message: "unknown option for steam timeline: \(options[index])")
            }
            index += 1
        }
        return .steamTimeline(minutes: minutes, follow: follow)
    }

    private static func envOptions(_ options: [String]) throws(UsageError) -> EnvOptions {
        var kind: EnvOptions.Kind?
        var result = EnvOptions(kind: .session)
        var index = 0
        while index < options.count {
            let option = options[index]
            switch option {
            case "--session", "--tool":
                let requested: EnvOptions.Kind = option == "--session" ? .session : .tool
                if let kind, kind != requested { throw UsageError(message: "use either --session or --tool") }
                kind = requested
            case "--no-steam":
                result.steam = false
            case "--nvext":
                result.nvext = true
            case "--host", "--prefix", "--renderer":
                index += 1
                let value = options[index]
                switch option {
                case "--host": result.host = value
                case "--prefix": result.prefix = value
                default:
                    guard let renderer = Renderer(rawValue: value) else {
                        throw UsageError(message: "unknown renderer: \(value) (dxmt or wined3d)")
                    }
                    result.renderer = renderer
                }
            default:
                throw UsageError(message: "unknown option for env: \(option)")
            }
            index += 1
        }
        guard let kind else { throw UsageError(message: "env needs --session or --tool") }
        result.kind = kind
        return result
    }
}
