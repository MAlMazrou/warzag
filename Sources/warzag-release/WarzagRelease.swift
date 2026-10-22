// warzag-release: Ed25519 keys, signed manifests and verification for runtime packs and Warzag's own updates
// (docs/RELEASING.md).
import Foundation

@main
struct WarzagRelease {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let result: ReleaseResult
        do {
            result = await ReleaseTool().run(try ReleaseCommandLine.parse(arguments))
        } catch {
            // 64 is EX_USAGE from sysexits(3).
            result = ReleaseResult(stderr: "warzag-release: \(error)\n\n\(ReleaseCommandLine.usage)\n", exitCode: 64)
        }
        FileHandle.standardOutput.write(Data(result.stdout.utf8))
        FileHandle.standardError.write(Data(result.stderr.utf8))
        exit(result.exitCode)
    }
}
