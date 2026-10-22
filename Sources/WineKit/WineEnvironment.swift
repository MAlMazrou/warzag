import Foundation
import WarzagCore

/// DXMT's `DXMT_CONFIG` value: `key=value;` pairs.
public struct DXMTConfig: Sendable, Equatable {
    /// `d3d11.preferredMaxFrameRate`, DXMT's limiter paced by Metal and Core Animation.
    public var preferredMaxFrameRate: Int?
    /// `dxgi.customVendorId`, always four lowercase hex digits ("10de"), never "0x10DE".
    public var customVendorID: String?

    public init(preferredMaxFrameRate: Int? = nil, customVendorID: String? = nil) {
        self.preferredMaxFrameRate = preferredMaxFrameRate
        self.customVendorID = customVendorID.flatMap(Self.normalizedVendorID)
    }

    /// The `DXMT_CONFIG` string, or nil when there is nothing to configure.
    public var rendered: String? {
        var pairs: [String] = []
        if let preferredMaxFrameRate { pairs.append("d3d11.preferredMaxFrameRate=\(preferredMaxFrameRate);") }
        if let customVendorID { pairs.append("dxgi.customVendorId=\(customVendorID);") }
        return pairs.isEmpty ? nil : pairs.joined()
    }

    /// "0x10DE", "10DE" or "10de" -> "10de"; anything that is not a 16-bit hex id -> nil.
    public static func normalizedVendorID(_ text: String) -> String? {
        var hex = text.lowercased()
        if hex.hasPrefix("0x") { hex.removeFirst(2) }
        guard (1...4).contains(hex.count), hex.allSatisfy(\.isHexDigit) else { return nil }
        return String(repeating: "0", count: 4 - hex.count) + hex
    }
}

/// Graphics choices for one game session.
public struct RendererOptions: Sendable, Equatable {
    public var renderer: Renderer
    /// Frame cap; DXMT applies it through DXMT_CONFIG.
    public var frameRateCap: Int?
    /// DXMT_ENABLE_NVEXT=1: DXMT reports an NVIDIA GPU (vendor 0x10DE) with nvapi/NGX. For experiments only
    /// (`PresetCatalog.nvextDefault`).
    public var enableNVEXT: Bool
    public var customVendorID: String?

    public init(renderer: Renderer = .dxmt, frameRateCap: Int? = nil, enableNVEXT: Bool = false,
                customVendorID: String? = nil) {
        self.renderer = renderer
        self.frameRateCap = frameRateCap
        self.enableNVEXT = enableNVEXT
        self.customVendorID = customVendorID
    }

    public var dxmtConfig: DXMTConfig {
        DXMTConfig(preferredMaxFrameRate: frameRateCap, customVendorID: customVendorID)
    }
}

/// Steam-mode facts for a game session.
public struct SteamSession: Sendable, Equatable {
    public var appID: Int
    /// The Mac client's MacOS folder, where lsteamclient finds steamclient.dylib (STEAM_COMPAT_CLIENT_INSTALL_PATH).
    public var clientDirectory: URL

    public init(appID: Int = Warframe.steamAppID, clientDirectory: URL) {
        self.appID = appID
        self.clientDirectory = clientDirectory
    }
}

/// Builds the exact environment of every Wine process Warzag starts.
///
/// Environments are complete, not layered on Warzag's own: only a short allowlist (home, user, locale, temp dir)
/// is inherited, so stray DYLD_*, WINE*, NEUTRON_* or Steam* variables can never leak into Wine. Every process of a
/// prefix, tool runs included, gets the engine's switches (`neutronDefaults`).
public enum WineEnvironment {
    public static let inheritedKeys: Set<String> = [
        "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "LC_MESSAGES",
        "__CF_USER_TEXT_ENCODING",
    ]
    public static let searchPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    /// The game's steam_api64.dll reaches lsteamclient through the steamclient64 forwarder.
    public static let steamDLLOverrides = "steamclient64=n;lsteamclient=b"
    /// Steam sets these for processes it launches itself; setting them here would change how the game and
    /// steam_api behave, so they must never appear.
    public static let forbiddenKeys: Set<String> = ["SteamClientLaunch", "SteamAppUser"]

    /// The engine's switches (runtime/n/patches/README.md lists the patch behind each), each set explicitly so a
    /// change of neutron's built-in defaults never changes the game silently:
    /// - `NEUTRON_PRECISE_TIMERS=1`: per-thread kqueue timers for precise sleeps (neutron: on unless "0").
    /// - `NEUTRON_FAST_QPC=1`: QueryPerformanceCounter without a syscall (on unless "0").
    /// - `NEUTRON_RAW_MOUSE=1`: unaccelerated mouse look from GCMouse as WM_INPUT (on unless "0").
    /// - `NEUTRON_NATIVE_FULLSCREEN=0`: no macOS native fullscreen Space (on only with "1"); Warframe runs borderless.
    /// - `NEUTRON_RENDER_SCALE=1`: Windows sees the real screen size (values from 0.5 shrink it for MetalFX).
    /// - `NEUTRON_MSYNC=0`: Wine's own server synchronisation; neutron's msync stays off, as neutron ships it.
    public static let neutronDefaults: [String: String] = [
        "NEUTRON_PRECISE_TIMERS": "1",
        "NEUTRON_FAST_QPC": "1",
        "NEUTRON_RAW_MOUSE": "1",
        "NEUTRON_NATIVE_FULLSCREEN": "0",
        "NEUTRON_RENDER_SCALE": "1",
        "NEUTRON_MSYNC": "0",
    ]

    /// Wine tool runs (wineboot, reg import, msiexec /a, wineserver -k): no renderer overlays and no Steam variables,
    /// so Steam never shows "Playing" during setup and updates.
    ///
    /// Other programs Warzag starts directly use `gameSession`: DE's launcher and its ContentUpdate applet with the
    /// DXMT overlay and `steam: nil` (see `Renderer`); wz-steamprobe.exe with `.wined3d` and the Steam variables, since
    /// lsteamclient finds the Mac steamclient.dylib through STEAM_COMPAT_CLIENT_INSTALL_PATH.
    public static func toolRun(prefix: URL, inherited: [String: String] = [:],
                               wineDebug: String = "-all") -> [String: String] {
        common(prefix: prefix, inherited: inherited, wineDebug: wineDebug)
    }

    /// The game session opened through the host app. `steam` is nil when the player signs in with a Warframe
    /// account instead of Steam.
    public static func gameSession(
        prefix: URL, host: GameHost, renderer: RendererOptions, steam: SteamSession?,
        inherited: [String: String] = [:], wineDebug: String = "-all"
    ) -> [String: String] {
        var environment = common(prefix: prefix, inherited: inherited, wineDebug: wineDebug)
        if let overlay = host.rendererDirectory(renderer.renderer) {
            environment["WINEDLLPATH_PREPEND"] = overlay.plainPath
        }
        switch renderer.renderer {
        case .dxmt:
            if let config = renderer.dxmtConfig.rendered { environment["DXMT_CONFIG"] = config }
            if renderer.enableNVEXT { environment["DXMT_ENABLE_NVEXT"] = "1" }
        case .wined3d:
            break
        }
        if let steam {
            let appID = String(steam.appID)
            environment["SteamAppId"] = appID
            environment["SteamGameId"] = appID
            environment["SteamOverlayGameId"] = appID
            environment["STEAM_COMPAT_APP_ID"] = appID
            environment["STEAM_COMPAT_CLIENT_INSTALL_PATH"] = steam.clientDirectory.plainPath
            environment["WINEDLLOVERRIDES"] = steamDLLOverrides
        }
        return environment
    }

    private static func common(prefix: URL, inherited: [String: String], wineDebug: String) -> [String: String] {
        var environment = inherited.filter { inheritedKeys.contains($0.key) }
        environment["PATH"] = searchPath
        environment["WINEPREFIX"] = prefix.plainPath
        // Every process in the prefix must agree on these, or wineserver refuses the mismatched one.
        environment.merge(neutronDefaults) { $1 }
        environment["WINEDEBUG"] = wineDebug
        environment["SteamDeck"] = "0"
        return environment
    }
}
