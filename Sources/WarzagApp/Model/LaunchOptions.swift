import Foundation
import WarzagCore

/// How this run of Warzag was started. Environment variables (handy with `open --env`) and command-line arguments:
///
/// | Variable | Argument | Meaning |
/// |---|---|---|
/// | `WARZAG_HOME=<dir>` | `--home <dir>` | Warzag's own data (Application Support, caches, logs) under `<dir>/Library`. Steam is still the user's real Steam. |
/// | `WARZAG_DEMO=1` | `--demo` | Demo mode: every step is simulated; Wine, Steam and DE's launcher are never touched. Without a home its data goes to `$TMPDIR/Warzag-Demo`, never the player's own. |
/// | `WARZAG_DEV_RUNTIME=<Warzag.app>` | `--dev-runtime <Warzag.app>` | A locally built game host, registered like `warzagctl runtime use-local`. |
/// | `WARZAG_SNAPSHOT_DIR=<dir>` | | Demo mode only: PNG snapshots of the window at each stage of the flow. |
/// | `WARZAG_DEMO_SPEED=<x>` | | Demo mode only: runs the simulation x times faster (default 1). |
/// | `WARZAG_DEMO_AUTOPLAY=1` | | Demo mode only: presses Play once at Home, and Quit a few seconds later. |
///
/// Unknown arguments (AppKit adds its own, such as `-NSDocumentRevisionsDebugMode`) are ignored.
struct LaunchOptions: Equatable, Sendable {
    var home: URL
    var isDemo: Bool
    var developmentRuntime: URL?
    var snapshotDirectory: URL?
    var demoSpeed: Double
    var demoAutoPlay: Bool

    init(home: URL, isDemo: Bool = false, developmentRuntime: URL? = nil, snapshotDirectory: URL? = nil,
         demoSpeed: Double = 1, demoAutoPlay: Bool = false) {
        self.home = home
        self.isDemo = isDemo
        self.developmentRuntime = developmentRuntime
        self.snapshotDirectory = snapshotDirectory
        self.demoSpeed = demoSpeed
        self.demoAutoPlay = demoAutoPlay
    }

    /// A demo's data when no home is given. Never the player's real home: a demo's simulated setup finishes, and the
    /// real app would then open on Home with nothing installed.
    static func demoHome(in temporaryDirectory: URL) -> URL {
        temporaryDirectory.appending(path: "Warzag-Demo", directoryHint: .isDirectory)
    }

    static func parse(environment: [String: String], arguments: [String], defaultHome: URL,
                      currentDirectory: URL,
                      temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> LaunchOptions {
        func location(_ text: String?) -> URL? {
            guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
            let expanded = text == "~" ? defaultHome.plainPath
                : text.hasPrefix("~/") ? defaultHome.plainPath + "/" + text.dropFirst(2) : text
            let url = expanded.hasPrefix("/") ? URL(filePath: expanded, directoryHint: .isDirectory)
                : currentDirectory.appending(path: expanded, directoryHint: .isDirectory)
            return url.standardized
        }
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        func flag(_ name: String) -> Bool {
            ["1", "true", "yes"].contains(environment[name]?.lowercased() ?? "")
        }
        let isDemo = flag("WARZAG_DEMO") || arguments.contains("--demo")
        let speed = environment["WARZAG_DEMO_SPEED"].flatMap(Double.init).map { min(max($0, 0.1), 100) } ?? 1
        let home = location(environment["WARZAG_HOME"]) ?? location(value(after: "--home"))
        return LaunchOptions(
            home: home ?? (isDemo ? demoHome(in: temporaryDirectory) : defaultHome),
            isDemo: isDemo,
            developmentRuntime: location(environment["WARZAG_DEV_RUNTIME"]) ?? location(value(after: "--dev-runtime")),
            snapshotDirectory: isDemo ? location(environment["WARZAG_SNAPSHOT_DIR"]) : nil,
            demoSpeed: speed,
            demoAutoPlay: isDemo && flag("WARZAG_DEMO_AUTOPLAY")
        )
    }

    /// This process's options.
    static func current() -> LaunchOptions {
        parse(environment: ProcessInfo.processInfo.environment, arguments: CommandLine.arguments,
              defaultHome: FileManager.default.homeDirectoryForCurrentUser,
              currentDirectory: URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory))
    }
}
