import Foundation
import GameKit
import Testing
import WarzagCore
import WineKit
@testable import WarzagApp

/// The launcher run LiveGameService shares between setup's EULA and download steps.
@Suite(.timeLimit(.minutes(1)))
struct ContentRunCoordinatorTests {
    /// Warzag quits as a download step starts: the step is cancelled before `cancelContentRun` runs, so a launcher run
    /// it started after that would never be closed, and the quit would wait for it.
    @Test func aCancelledStepStartsNoLauncherRun() async throws {
        let root = try temporaryDirectory("content-run")
        defer { try? FileManager.default.removeItem(at: root) }
        // A scratch installation without a host: even a run started by mistake could not start anything.
        let paths = WarzagPaths(home: root, userCacheDirectory: nil)
        let host = GameHost(bundle: root.appending(path: "Warzag.app"), channel: .n)
        let prefix = PrefixLayout(root: paths.prefix(for: .n), windowsUserName: "tenno")
        let installation = GameInstallation(host: host, prefix: prefix, library: paths.warframeLibrary)
        let service = ContentService(installation: installation,
                                     context: GameContext.live(paths: paths, inheritedEnvironment: [:]))
        let coordinator = ContentRunCoordinator()
        let asked = Flag()
        let step = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await coordinator.job {
                asked.set()
                return service
            }
        }
        await #expect(throws: CancellationError.self) { try await step.value }
        #expect(!asked.isSet)
        await coordinator.cancel()
    }

    /// Updates › Warframe's run is its own: a game that is not installed is GameKit's to say, nothing starts, and the
    /// coordinator is free for the next run (a caller cancelled before it began starts nothing either).
    @Test func anUpdateRunIsItsOwn() async throws {
        let root = try temporaryDirectory("content-update")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = WarzagPaths(home: root, userCacheDirectory: nil)
        let host = GameHost(bundle: root.appending(path: "Warzag.app"), channel: .n)
        let prefix = PrefixLayout(root: paths.prefix(for: .n), windowsUserName: "tenno")
        let installation = GameInstallation(host: host, prefix: prefix, library: paths.warframeLibrary)
        let service = ContentService(installation: installation,
                                     context: GameContext.live(paths: paths, inheritedEnvironment: [:]))
        let coordinator = ContentRunCoordinator()
        await #expect(throws: ContentError.notInstalled) { _ = try await coordinator.update(service) { _ in } }
        await #expect(throws: ContentError.notInstalled) { _ = try await coordinator.update(service) { _ in } }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await coordinator.update(service) { _ in }
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        await coordinator.cancel()
    }
}
