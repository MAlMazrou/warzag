import Foundation
import Testing
import RuntimeKit
import WarzagCore
import WarzagTestSupport
import WineKit
@testable import EngineKit

/// Every engine path the engine checks or hands to Wine and LaunchServices is inside Runtimes.noindex: each engine copy
/// is an app bundle named Warzag, and only the .noindex folder keeps Spotlight and the Apps view from listing it next
/// to Warzag itself.
@Suite struct EngineStoreLayoutTests {
    let fixture = EngineFixture()
    var runtime: RuntimeService { fixture.engine.runtime }
    var store: String { fixture.paths.runtimes.plainPath }

    /// Every path in what ran: executables, arguments, working directories and environment values (PATH-like values
    /// split at their colons).
    func paths(in commands: [Command]) -> [String] {
        commands.flatMap { (command: Command) -> [String] in
            var paths: [String] = [command.executable.plainPath]
            paths += command.arguments
            if let directory = command.workingDirectory { paths.append(directory.plainPath) }
            for value in (command.environment ?? [:]).values {
                paths += value.split(separator: ":").map(String.init)
            }
            return paths
        }
    }

    /// The paths into a game host (an engine copy) among those, which must all be inside the store.
    func expectEnginePathsInsideTheStore(_ commands: [Command], sourceLocation: SourceLocation = #_sourceLocation) {
        let engine = paths(in: commands).filter { $0.contains("/\(WarzagPaths.gameHostName)") }
        #expect(!engine.isEmpty, "nothing ran from the engine", sourceLocation: sourceLocation)
        for path in engine {
            #expect(path.hasPrefix(store + "/"), "\(path)", sourceLocation: sourceLocation)
        }
    }

    @Test func aFeedEngineIsUnpackedCheckedAndRunFromInsideTheStore() async throws {
        let (pack, manifest) = try fixture.pack(version: "0.3.0")
        let signed = try EngineFixture.signed(manifest)
        try await runtime.install(signedManifest: signed, pack: .file(pack),
                                  trust: try RuntimeTrust.explicitKey(EngineFixture.publicKey, for: signed),
                                  appVersion: "0.1.0", macOSVersion: "26.5.1")
        // The signature check saw the copy unpacked in the store's staging folder, never one in the download cache.
        #expect(fixture.signatures.bundles == [store + "/staging/n-0.3.0/Warzag.app"])
        let active = try runtime.active()
        #expect(active.host.bundle.plainPath == store + "/n/0.3.0/Warzag.app")
        #expect(try runtime.status().current?.host == store + "/n/0.3.0/Warzag.app")

        _ = try await fixture.engine.prefix.create(macDriver: MacDriverSettings(retinaMode: false))
        expectEnginePathsInsideTheStore(fixture.runner.commands)
    }

    @Test func aDevelopmentBuildIsClonedIntoTheStoreAndRunFromThere() async throws {
        try fixture.registerDevelopmentRuntime()
        let active = try runtime.active()
        #expect(active.host.bundle.plainPath.hasPrefix(store + "/n/"))
        _ = try await fixture.engine.prefix.create(macDriver: MacDriverSettings(retinaMode: false))
        expectEnginePathsInsideTheStore(fixture.runner.commands)
        // The build tree itself is never what Wine runs.
        #expect(!paths(in: fixture.runner.commands).contains { $0.hasPrefix(EngineFixture.devHost) })
    }
}
