import Foundation
import WarzagCore

/// Wine tools Warzag runs directly (not through the host app), each with the tool-run environment and a deadline: a
/// tool still running after `timeout` is stopped and reported (`ProcessTimedOut`), so a hung Wine never hangs setup,
/// an update or the end of a session.
public enum WineTool: Sendable, Equatable {
    /// Creates or updates the prefix.
    case wineboot
    /// Imports a .reg file; the path is a Windows path (C:\…), so it never depends on the Z: drive.
    case regImport(windowsPath: String)
    /// Administrative install: unpacks an MSI (DE's Warframe.msi) without running its install logic.
    case msiexecAdministrative(package: String, targetDirectory: String)
    /// `cmd /c <command line>` (PrefixService reads volume serials with `vol`).
    case cmd([String])
    /// Asks the windows of every process with this image name to close (WM_CLOSE; never `/F`).
    case taskkill(imageName: String)
    /// `wineserver -w`: returns once every process in the prefix has exited.
    case wineserverWait
    /// Stops the prefix's wineserver and every process in it.
    case wineserverKill

    /// How long the tool may run. Generous: DE's installer unpacks slowly on a busy Mac.
    public var timeout: Duration {
        switch self {
        case .wineboot: .seconds(600)
        case .regImport: .seconds(120)
        case .msiexecAdministrative: .seconds(900)
        case .cmd: .seconds(120)
        case .taskkill: .seconds(60)
        case .wineserverWait: .seconds(300)
        case .wineserverKill: .seconds(60)
        }
    }

    /// A short name for messages ("wineboot --init", "wineserver -w").
    public var name: String {
        switch self {
        case .wineboot: "wineboot --init"
        case .regImport: "reg import"
        case .msiexecAdministrative: "msiexec /a"
        case .cmd(let arguments): (["cmd", "/c"] + arguments.prefix(1)).joined(separator: " ")
        case .taskkill(let image): "taskkill /IM \(image)"
        case .wineserverWait: "wineserver -w"
        case .wineserverKill: "wineserver -k"
        }
    }

    public func command(host: GameHost, prefix: URL, inherited: [String: String] = [:], logFile: URL? = nil,
                        timeout: Duration? = nil) -> Command {
        var environment = WineEnvironment.toolRun(prefix: prefix, inherited: inherited)
        environment.merge(extraEnvironment) { $1 }
        let deadline = timeout ?? self.timeout
        // wineserver is a Unix program: run straight from the bundle, never through the Windows loader.
        let (executable, arguments): (URL, [String]) = switch self {
        case .wineboot: (host.wine, ["wineboot", "--init"])
        case .regImport(let path): (host.wine, ["reg", "import", path])
        case .msiexecAdministrative(let package, let target):
            (host.wine, ["msiexec", "/a", package, "/qn", "TARGETDIR=\(target)"])
        case .cmd(let line): (host.wine, ["cmd", "/c"] + line)
        case .taskkill(let image): (host.wine, ["taskkill", "/IM", image])
        case .wineserverWait: (host.wineserver, ["-w"])
        case .wineserverKill: (host.wineserver, ["-k"])
        }
        return Command(executable: executable, arguments: arguments, environment: environment, logFile: logFile,
                       timeout: deadline)
    }

    /// Unattended prefix creation must not stop on Wine's Mono and Gecko download dialogs; nothing Warzag runs
    /// needs either.
    var extraEnvironment: [String: String] {
        switch self {
        case .wineboot: ["WINEDLLOVERRIDES": "mscoree,mshtml="]
        case .regImport, .msiexecAdministrative, .cmd, .taskkill, .wineserverWait, .wineserverKill: [:]
        }
    }
}
