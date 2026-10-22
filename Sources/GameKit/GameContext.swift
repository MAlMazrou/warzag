import EngineKit
import Foundation
import WarzagCore

/// Every side effect the content and play flows use, injected so they run against fakes in tests.
public struct GameContext: Sendable {
    public var fileSystem: any FileSystem
    public var files: any GameFiles
    /// Short Wine tool runs (msiexec, taskkill, wineserver -k), waited for.
    public var runner: any ProcessRunning
    /// DE's launcher, started and watched.
    public var launcher: any ProcessLaunching
    /// The game host, through LaunchServices.
    public var opener: any ApplicationOpening
    public var probe: any PrefixActivityProbing
    /// The code-signature check of the runtime host before Play.
    public var hostSignatures: any HostSignatureChecking
    public var clock: any WallClock
    /// Warzag's own environment; WineKit keeps only an allowlist of it (home, user, locale, temp dir).
    public var inheritedEnvironment: [String: String]
    /// Where Wine's own output goes (~/Library/Logs/Warzag).
    public var logDirectory: URL
    /// Warzag's State folder, for content.json.
    public var stateDirectory: URL

    public init(fileSystem: any FileSystem, files: any GameFiles, runner: any ProcessRunning,
                launcher: any ProcessLaunching, opener: any ApplicationOpening, probe: any PrefixActivityProbing,
                hostSignatures: any HostSignatureChecking, clock: any WallClock, inheritedEnvironment: [String: String],
                logDirectory: URL, stateDirectory: URL) {
        self.fileSystem = fileSystem
        self.files = files
        self.runner = runner
        self.launcher = launcher
        self.opener = opener
        self.probe = probe
        self.hostSignatures = hostSignatures
        self.clock = clock
        self.inheritedEnvironment = inheritedEnvironment
        self.logDirectory = logDirectory
        self.stateDirectory = stateDirectory
    }

    public static func live(paths: WarzagPaths,
                            inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> GameContext {
        GameContext(fileSystem: LocalFileSystem(), files: LocalGameFiles(), runner: SystemProcessRunner(),
                    launcher: FoundationProcessLauncher(), opener: WorkspaceApplicationOpener(),
                    probe: WineserverLockProbe(),
                    hostSignatures: RuntimeSignatureCheck(engine: .live(paths: paths,
                                                                        inheritedEnvironment: inheritedEnvironment)),
                    clock: SystemClock(), inheritedEnvironment: inheritedEnvironment,
                    logDirectory: paths.logs, stateDirectory: paths.state)
    }

    /// Output of short Wine tool runs.
    public var toolLog: URL { logDirectory.appending(path: "wine-tools.log") }
    /// Output of DE's launcher's Wine process (DE's own Launcher.log stays in the prefix).
    public var launcherOutputLog: URL { logDirectory.appending(path: "wine-launcher.log") }
}
