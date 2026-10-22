import Foundation
import WarzagCore

/// Direct3D translation for a process. DE's launcher needs a real D3D11 adapter too: wined3d over macOS's OpenGL 4.1
/// fails its adapter check and it stalls, so it runs on DXMT, with nvapi64/nvngx disabled for Launcher.exe by
/// `PrefixTemplate`. Plain tool runs (wineboot, reg, msiexec) need no renderer.
public enum Renderer: String, Codable, Sendable, CaseIterable {
    /// DXMT (Direct3D 11 -> Metal), the default.
    case dxmt
    /// Wine's own Direct3D, with no overlay: for wz-steamprobe.exe (it draws nothing) and diagnostics; never for the
    /// game.
    case wined3d
}

/// A "Warzag.app" runtime host (runtime/n/make-host.sh documents the layout).
public struct GameHost: Sendable, Equatable {
    public let bundle: URL
    public let channel: RuntimeChannel

    public init(bundle: URL, channel: RuntimeChannel) {
        self.bundle = bundle.standardizedFileURL
        self.channel = channel
    }

    /// The host at `bundle`, with its channel read from the bundle itself (`RuntimeHostChannel`).
    public static func detect(bundle: URL, fileSystem: any FileSystem) throws(RuntimeHostChannelError) -> GameHost {
        GameHost(bundle: bundle, channel: try RuntimeHostChannel.detect(bundle: bundle, fileSystem: fileSystem))
    }

    public var contents: URL { bundle.appending(path: "Contents", directoryHint: .isDirectory) }
    /// The Wine loader is the bundle's main executable (Game Mode and Dock identity come from the bundle).
    public var wine: URL { contents.appending(path: "MacOS/wine") }
    public var wineserver: URL { contents.appending(path: "MacOS/wineserver") }

    /// Wine's 64-bit builtin Windows DLLs, `lib/wine/<arch>-windows` (the bridge's `lsteamclient.dll` lives here too).
    public var builtinWindowsDLLs: URL {
        contents.appending(path: "lib/wine/\(channel.wineArchitecture)-windows", directoryHint: .isDirectory)
    }

    /// The overlay directory put in front of Wine's builtin DLLs with WINEDLLPATH_PREPEND (runtime patch wz-n-0003);
    /// Wine looks for `<arch>-windows` and `<arch>-unix` inside it. nil for wined3d.
    public func rendererDirectory(_ renderer: Renderer) -> URL? {
        switch renderer {
        case .dxmt: contents.appending(path: "renderers/\(renderer.rawValue)", directoryHint: .isDirectory)
        case .wined3d: nil
        }
    }

    /// The renderer's Windows DLLs for this host's architecture, `renderers/<renderer>/<arch>-windows`.
    public func rendererWindowsDLLs(_ renderer: Renderer) -> URL? {
        rendererDirectory(renderer)?.appending(path: "\(channel.wineArchitecture)-windows", directoryHint: .isDirectory)
    }
}
