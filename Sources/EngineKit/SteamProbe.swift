import Foundation
import WarzagCore
import WineKit

/// wz-steamprobe.exe (bridge/steamprobe/steamprobe.c) in the prefix: can a Windows program reach the player's Mac
/// Steam through the bridge, is an account signed in, does it own the app? The answer is its exit status; its one
/// JSON line goes to the prefix log.
///
/// Its full run briefly registers with Steam as the app named by SteamAppId (Warframe, 230410), so Steam shows the
/// account as playing it. It runs only for setup's license check and for `warzagctl steam probe`.
public enum SteamProbe {
    public static let program = PrefixTemplate.steamDirectory + #"\wz-steamprobe.exe"#
    /// The probe gives up after this long (stage "timeout").
    public static let timeoutSeconds = 30

    public static func arguments(appID: Int = Warframe.steamAppID) -> [String] {
        ["--appid", String(appID), "--timeout", String(timeoutSeconds)]
    }

    /// The exit status, as steamprobe.c documents it.
    public enum Outcome: Equatable, Sendable, CustomStringConvertible {
        /// 0: every step passed.
        case owned
        /// 24 owns_app.
        case notOwned
        /// 23 logged_on.
        case signedOut
        /// 20 pipe, 21 connect.
        case steamNotRunning
        /// 10 registry, 11 load, 12 export, 13 client, 22 interfaces: the bridge did not load.
        case bridgeFailed(stage: String)
        /// 25: Steam's IPC did not answer in time.
        case timedOut
        /// Anything else (2: bad arguments).
        case failed(exitCode: Int32)

        public init(exitCode: Int32) {
            switch exitCode {
            case 0: self = .owned
            case 24: self = .notOwned
            case 23: self = .signedOut
            case 20, 21: self = .steamNotRunning
            case 10: self = .bridgeFailed(stage: "registry")
            case 11: self = .bridgeFailed(stage: "load")
            case 12: self = .bridgeFailed(stage: "export")
            case 13: self = .bridgeFailed(stage: "client")
            case 22: self = .bridgeFailed(stage: "interfaces")
            case 25: self = .timedOut
            default: self = .failed(exitCode: exitCode)
            }
        }

        public var description: String {
            switch self {
            case .owned: "the signed-in account owns Warframe"
            case .notOwned: "the signed-in account does not own Warframe (add it to the library in Steam)"
            case .signedOut: "Steam runs but nobody is signed in"
            case .steamNotRunning: "the probe could not reach Steam (not running, or not answering)"
            case .bridgeFailed(let stage): "the Steam bridge did not load (stage \(stage)); Repair sets it up again"
            case .timedOut: "Steam did not answer within \(SteamProbe.timeoutSeconds) s"
            case .failed(let exitCode): "wz-steamprobe.exe exited with status \(exitCode)"
            }
        }
    }
}

public extension PrefixService {
    /// wz-steamprobe.exe with the Steam variables (lsteamclient finds the Mac steamclient.dylib through
    /// STEAM_COMPAT_CLIENT_INSTALL_PATH) and the wined3d renderer (it draws nothing). The probe's own exit is the
    /// answer: it releases its Steam connection before it exits, and nothing waits for the prefix to go quiet (DE's
    /// launcher shares it and may be downloading for an hour).
    func runSteamProbe(steamClientDirectory: URL) async throws -> ProcessOutput {
        try await runProgram(SteamProbe.program, arguments: SteamProbe.arguments(),
                             renderer: RendererOptions(renderer: .wined3d),
                             steam: SteamSession(clientDirectory: steamClientDirectory))
    }
}
