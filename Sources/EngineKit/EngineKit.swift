import Foundation
import RuntimeKit
import WarzagCore
import WineKit

/// Every side effect the engine services use, injected so they run against fakes in tests.
///
/// - `runtime` (`RuntimeService`): signed runtime packs, development builds, rollback to the previous runtime.
/// - `prefix` (`PrefixService`): create, repair and check the Wine prefix.
public struct Engine: Sendable {
    public var paths: WarzagPaths
    public var fileSystem: any EngineFileSystem
    public var runner: any ProcessRunning
    public var http: any HTTPClient
    public var signatures: any CodeSignatureInspecting
    public var extractor: any PackExtracting
    /// Runtime packs over HTTP: resumable, with progress, size and SHA-256 checked.
    public var packDownloader: any PackDownloading
    public var clock: any WallClock
    /// The Windows profile folder name: Wine uses the macOS short user name.
    public var windowsUserName: String
    /// Warzag's own environment; Wine processes get only `WineEnvironment`'s allowlist of it.
    public var inheritedEnvironment: [String: String]

    public init(paths: WarzagPaths, fileSystem: any EngineFileSystem, runner: any ProcessRunning,
                http: any HTTPClient, signatures: any CodeSignatureInspecting, extractor: any PackExtracting,
                clock: any WallClock, windowsUserName: String, inheritedEnvironment: [String: String],
                packDownloader: any PackDownloading = ResumablePackDownloader()) {
        self.paths = paths
        self.fileSystem = fileSystem
        self.runner = runner
        self.http = http
        self.signatures = signatures
        self.extractor = extractor
        self.packDownloader = packDownloader
        self.clock = clock
        self.windowsUserName = windowsUserName
        self.inheritedEnvironment = inheritedEnvironment
    }

    public static func live(paths: WarzagPaths,
                            inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> Engine {
        let runner = SystemProcessRunner()
        return Engine(paths: paths, fileSystem: LocalEngineFileSystem(), runner: runner, http: URLSessionHTTPClient(),
                      signatures: SecurityCodeSignatureInspector(), extractor: AppleArchiveExtractor(runner: runner),
                      clock: SystemClock(), windowsUserName: NSUserName(), inheritedEnvironment: inheritedEnvironment)
    }

    public var runtime: RuntimeService { RuntimeService(engine: self) }
    public var prefix: PrefixService { PrefixService(engine: self) }
    public var identity: IdentityVault { IdentityVault(paths: paths, fileSystem: fileSystem) }
}
