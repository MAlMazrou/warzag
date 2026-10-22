import Foundation
import WarzagCore
import WineKit

/// The parts of a "Warzag.app" runtime host the engine copies into prefixes (runtime/n/make-host.sh and
/// bridge/README.md document the layout).
public struct RuntimeHostLayout: Sendable, Equatable {
    public static let bundleIdentifier = "com.warzag.gamehost"

    public let host: GameHost

    public init(_ host: GameHost) {
        self.host = host
    }

    /// DXMT's overlay (`WINEDLLPATH_PREPEND` for DXMT sessions), with `<arch>-windows` and `<arch>-unix` inside.
    public var dxmtDirectory: URL { host.contents.appending(path: "renderers/dxmt", directoryHint: .isDirectory) }
    /// DXMT's ARM64X Windows DLLs, `aarch64-windows`.
    public var dxmtWindowsDLLs: URL {
        dxmtDirectory.appending(path: "\(host.channel.wineArchitecture)-windows", directoryHint: .isDirectory)
    }
    /// Wine's own 64-bit builtin DLLs; the bridge's `lsteamclient.dll` lives here too.
    public var builtinDLLs: URL { host.builtinWindowsDLLs }
    /// The Steam bridge's prefix-side files (runtime/n/build.sh installs them; the forwarder under its shipping name).
    /// The forwarder and wz-steamprobe.exe are x86-64: FEX runs them, as it runs the game.
    public var bridgeDirectory: URL { host.contents.appending(path: "share/warzag/bridge", directoryHint: .isDirectory) }
    /// The bridge's registry values: the single source of truth for every Steam key in a prefix.
    public var steamRegistry: URL { bridgeDirectory.appending(path: "steam.reg") }
}

/// The host bundle's Info.plist, as far as the engine cares.
public struct HostInfo: Sendable, Equatable {
    public var bundleIdentifier: String?
    public var executable: String?
    public var shortVersion: String?
    public var build: String?

    public init(bundleIdentifier: String?, executable: String?, shortVersion: String?, build: String?) {
        self.bundleIdentifier = bundleIdentifier
        self.executable = executable
        self.shortVersion = shortVersion
        self.build = build
    }

    /// Reads `<bundle>/Contents/Info.plist`.
    public static func read(bundle: URL, fileSystem: any FileSystem) throws -> HostInfo {
        let data = try fileSystem.contents(of: bundle.appending(path: "Contents/Info.plist"))
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw RuntimeServiceError.notAGameHost("Info.plist is not a dictionary")
        }
        return HostInfo(
            bundleIdentifier: plist["CFBundleIdentifier"] as? String,
            executable: plist["CFBundleExecutable"] as? String,
            shortVersion: plist["CFBundleShortVersionString"] as? String,
            build: plist["CFBundleVersion"] as? String
        )
    }

    public static func read(_ host: GameHost, fileSystem: any FileSystem) throws -> HostInfo {
        try read(bundle: host.bundle, fileSystem: fileSystem)
    }
}

extension GameHost {
    /// Throws unless this is a Warzag runtime host: the bundle identifier, the Wine loader as main executable next to
    /// wineserver, and an arm64 loader (and Info.plist) of the channel.
    func validate(fileSystem: any EngineFileSystem) throws {
        _ = try Self.inspect(bundle: bundle, fileSystem: fileSystem)
    }

    /// Checks that `bundle` is a Warzag runtime host and returns the channel it was built for.
    static func inspect(bundle: URL, fileSystem: any EngineFileSystem) throws -> RuntimeChannel {
        guard fileSystem.directoryExists(at: bundle) else {
            throw RuntimeServiceError.notAGameHost("\(bundle.plainPath) does not exist")
        }
        let info: HostInfo
        do {
            info = try HostInfo.read(bundle: bundle, fileSystem: fileSystem)
        } catch let error as RuntimeServiceError {
            throw error
        } catch {
            throw RuntimeServiceError.notAGameHost("no readable Contents/Info.plist")
        }
        guard info.bundleIdentifier == RuntimeHostLayout.bundleIdentifier else {
            throw RuntimeServiceError.notAGameHost(
                "bundle identifier is \(info.bundleIdentifier ?? "missing"), not \(RuntimeHostLayout.bundleIdentifier)")
        }
        guard info.executable == "wine" else {
            throw RuntimeServiceError.notAGameHost("the main executable must be the Wine loader (wine)")
        }
        let contents = bundle.appending(path: "Contents", directoryHint: .isDirectory)
        for program in ["wine", "wineserver"]
        where !fileSystem.isExecutableFile(at: contents.appending(path: "MacOS/\(program)")) {
            throw RuntimeServiceError.notAGameHost("Contents/MacOS/\(program) is missing")
        }
        do {
            return try RuntimeHostChannel.detect(bundle: bundle, fileSystem: fileSystem)
        } catch {
            throw RuntimeServiceError.notAGameHost(error.description)
        }
    }
}
