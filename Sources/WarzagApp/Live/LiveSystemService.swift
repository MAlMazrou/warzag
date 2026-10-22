import AppKit
import Foundation
import GameKit
import Network
import SteamHostKit
import Synchronization
import WarzagCore

/// This Mac: hardware and power (WarzagCore, GameKit's PowerAdvisor), the network, Finder, LaunchServices, the Dock.
struct LiveSystemService: SystemServicing {
    /// The user's real home (Applications folders), whatever WARZAG_HOME says.
    let realHome: URL
    let steam: SteamLocations
    /// Steam's apps and windows, shared with LiveSteamService (one hide gate for the card and the focus keeper).
    let steamEnvironment: WorkspaceSteamEnvironment

    func hardware() -> HardwareProfile { HardwareProfile.detect() }

    func powerAdvice(for tier: PerformanceTier) -> [PowerAdvice] { PowerAdvisor().advice(for: tier) }

    func applicationLocation() -> ApplicationLocation {
        let url = Bundle.main.bundleURL
        // `swift run` and the test runner are not app bundles: nothing to move.
        guard url.pathExtension == "app" else { return ApplicationLocation(url: url, inApplicationsFolder: true) }
        let path = url.plainPath
        let inApplications = path.hasPrefix("/Applications/")
            || path.hasPrefix(realHome.appending(path: "Applications").plainPath + "/")
        return ApplicationLocation(url: url, inApplicationsFolder: inApplications)
    }

    func moveToApplications() async throws {
        let destination = try ApplicationMover.copyIntoApplications(Bundle.main.bundleURL, home: realHome)
        try await ApplicationMover.relaunch(destination)
    }

    func storage(for library: URL) -> StorageCheck {
        let fileSystem = LocalFileSystem()
        return StorageCheck(volume: try? fileSystem.volumeInfo(for: library),
                            libraryBytes: fileSystem.directoryExists(at: library)
                                ? LocalGameFiles().diskUsage(of: library) : 0)
    }

    func networkIsAvailable() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let once = Once()
            monitor.pathUpdateHandler = { path in
                guard once.claim() else { return }
                monitor.cancel()
                continuation.resume(returning: path.status == .satisfied)
            }
            monitor.start(queue: .global(qos: .utility))
        }
    }

    func networkAvailability() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { continuation.yield($0.status == .satisfied) }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: .global(qos: .utility))
        }
    }

    @MainActor func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    @MainActor func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @MainActor func showSteam() {
        guard let app = SteamDetector(locations: steam).installedApp() else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: app, configuration: configuration)
    }

    @MainActor func showGameHost(openedProcess: Int32?) {
        // The process LaunchServices returned for Play is the steam.exe shim, and the last process listed under the
        // host's bundle identifier may be any of Wine's: the window the player means is found by its window.
        Task { await WorkspaceFocusEnvironment().bringGameWindowForward(excluding: openedProcess) }
    }

    func keepGameInFront(openedProcess: Int32, hidingSteam: Bool,
                         events: @escaping @Sendable (GameFocusEvent) -> Void) async {
        let keeper = GameFocusKeeper(environment: WorkspaceFocusEnvironment(steam: steamEnvironment), clock: SystemClock(),
                                     ownProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
                                     hidesSteam: hidingSteam)
        await keeper.run(openedProcess: openedProcess, events: events)
    }

    @MainActor func setDockBadge(_ text: String?) {
        NSApp.dockTile.badgeLabel = text
    }

    @MainActor func requestAttention() {
        NSApp.requestUserAttention(.informationalRequest)
    }

    @MainActor func keepAwake(_ reason: KeepAwakeReason?) {
        AwakeAssertion.shared.set(reason)
    }

    @MainActor func setDockPresence(_ presence: DockPresence) {
        NSApp.setActivationPolicy(presence == .hidden ? .accessory : .regular)
    }

    @MainActor func showMainWindow() {
        MainWindow.show()
    }

    @MainActor func quit() {
        AppTermination.request()
    }
}

/// A flag that can be claimed once, from any thread.
final class Once: Sendable {
    private let claimed = Mutex(false)

    func claim() -> Bool {
        claimed.withLock { value in
            defer { value = true }
            return !value
        }
    }
}

/// Keeps the Mac awake while setup downloads (idle system sleep) and while the game runs (idle display sleep too:
/// a sleeping display stalls the game).
@MainActor
final class AwakeAssertion {
    static let shared = AwakeAssertion()
    private var activity: (any NSObjectProtocol)?

    func set(_ reason: KeepAwakeReason?) {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        switch reason {
        case .setup:
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                             reason: "Warzag is setting up Warframe")
        case .playing:
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled, .userInitiated],
                reason: "Warframe is running")
        case nil:
            break
        }
    }
}

/// Move to Applications: copy next to the destination, swap it in (an older copy goes to the Trash), relaunch from
/// there. The copy that is running stays where it was.
enum ApplicationMover {
    static func copyIntoApplications(_ source: URL, home: URL) throws -> URL {
        let manager = FileManager.default
        let system = URL(filePath: "/Applications", directoryHint: .isDirectory)
        let folder = manager.isWritableFile(atPath: system.plainPath)
            ? system : home.appending(path: "Applications", directoryHint: .isDirectory)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: source.lastPathComponent, directoryHint: .isDirectory)
        let staging = folder.appending(path: ".warzag-move-\(UUID().uuidString).app", directoryHint: .isDirectory)
        try manager.copyItem(at: source, to: staging)
        do {
            if manager.fileExists(atPath: destination.plainPath) {
                try manager.trashItem(at: destination, resultingItemURL: nil)
            }
            try manager.moveItem(at: staging, to: destination)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
        return destination
    }

    @MainActor static func relaunch(_ app: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        AppTermination.request()
    }
}
