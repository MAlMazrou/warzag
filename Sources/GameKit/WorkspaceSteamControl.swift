import AppKit
import Foundation
import SteamHostKit
import WarzagCore

/// The live `SteamControlling`: start by the detected Steam.app path, the cooperative bring-forward, steam:// links
/// only while Steam runs, and the standard quit (the only Apple event Warzag sends Steam, with no Automation prompt).
extension WorkspaceSteamEnvironment: SteamControlling {
    /// steam_osx runs (registry.vdf's SteamPID), or one of Steam's app processes is still up (the bootstrapper while it
    /// relaunches the client, or a client still quitting): opening Steam.app then would be a reopen event.
    public func isRunning() async -> Bool {
        if SteamDetector(locations: locations).runningSteamProcess() != nil { return true }
        return await MainActor.run {
            !NSRunningApplication.runningApplications(withBundleIdentifier: SteamAppProcess.appBundleIdentifier)
                .filter { !$0.isTerminated }.isEmpty
        }
    }

    public func send(_ link: SteamLink, activates: Bool) async -> Bool {
        guard await isRunning() else { return false }
        let url = link.url
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = activates
                NSWorkspace.shared.open(url, configuration: configuration) { _, error in
                    continuation.resume(returning: error == nil)
                }
            }
        }
    }

    public func terminate() async -> Bool {
        await MainActor.run {
            WorkspaceSteamApps.running().filter { $0.1 == .app }.map { $0.0.terminate() }.contains(true)
        }
    }

    public func start(_ mode: SteamStartMode) async throws {
        guard let app = SteamDetector(locations: locations).installedApp() else {
            throw SteamLaunchError(reason: "Steam is not installed")
        }
        try await SteamLauncher(runner: runner).launch(app: app, mode: mode)
    }

    public func bringForward() async -> Bool {
        let client = SteamDetector(locations: locations).runningSteamProcess()
        return await Self.bringForward(client: client)
    }

    /// The client's app (the steam_osx in registry.vdf) if AppKit lists it, else the newest of Steam's apps; then the
    /// handoff WorkspaceFocusEnvironment uses for the game: Warzag (where the button was clicked) yields activation and
    /// Steam takes it. Without Warzag in front (or outside an app), a plain request, which macOS may decline. Never a
    /// reopen, never `activate(ignoringOtherApps:)` on Steam.
    @MainActor
    static func bringForward(client: Int32?) async -> Bool {
        let candidates = WorkspaceSteamApps.running().filter { $0.1 == .app }.map(\.0)
        guard let steam = candidates.first(where: { $0.processIdentifier == client })
            ?? candidates.max(by: { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) })
        else { return false }
        if let application = NSApp, application.isActive {
            application.yieldActivation(to: steam)
            return steam.activate(from: .current, options: [.activateAllWindows])
        }
        return steam.activate(options: [.activateAllWindows])
    }
}
