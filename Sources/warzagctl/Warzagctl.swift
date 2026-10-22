import Foundation

/// Headless driver for QA and support (ships in Warzag.app/Contents/Helpers).
@main
struct Warzagctl {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let result = ExtensionCommands.dispatch(arguments) ?? runBuiltIn(arguments)
        FileHandle.standardOutput.write(Data(result.stdout.utf8))
        FileHandle.standardError.write(Data(result.stderr.utf8))
        exit(result.exitCode)
    }

    private static func runBuiltIn(_ arguments: [String]) -> CommandResult {
        do {
            let parsed = try CommandLineParser.parse(arguments)
            return Commands.run(parsed.invocation, in: .live(home: parsed.home))
        } catch {
            // 64 is EX_USAGE from sysexits(3).
            return CommandResult(stderr: "warzagctl: \(error)\n\n\(CommandLineParser.usage)\n\(ExtensionCommands.usage)\n", exitCode: 64)
        }
    }
}
