import AppKit
import Foundation

/// Opens the game host through LaunchServices (`NSWorkspace.openApplication`): the host's main executable is the Wine
/// loader, so the game gets the host bundle's identity (Game Mode, Dock name, privacy prompts) instead of Warzag's.
public struct WorkspaceApplicationOpener: ApplicationOpening {
    public init() {}

    public func openNewInstance(of application: URL, arguments: [String], environment: [String: String],
                                activates: Bool) async throws -> any RunningProcess {
        let processIdentifier = try await Self.open(application, arguments: arguments, environment: environment,
                                                    activates: activates)
        return WatchedProcess(processIdentifier: processIdentifier)
    }

    @MainActor
    private static func open(_ application: URL, arguments: [String], environment: [String: String],
                             activates: Bool) async throws -> Int32 {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.environment = environment
        // Another Wine process of the same bundle (DE's launcher, a tool run that opened a window) may already be
        // registered as this app; without a new instance LaunchServices would only activate it.
        configuration.createsNewApplicationInstance = true
        configuration.activates = activates
        configuration.addsToRecentItems = false
        // Fail instead of showing a dialog: Warzag reports the problem itself.
        configuration.promptsUserIfNeeded = false
        let running = try await NSWorkspace.shared.openApplication(at: application, configuration: configuration)
        return running.processIdentifier
    }
}
