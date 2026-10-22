import AppKit
import CoreGraphics
import Foundation

/// The live focus environment: AppKit's running apps, the window server's window list, and macOS 14's cooperative
/// activation. Only used inside the app (it needs AppKit's main run loop to keep its view of the apps current).
public struct WorkspaceFocusEnvironment: FocusEnvironment {
    /// Hides Steam in the game's first minute; nil hides nothing.
    public let steam: WorkspaceSteamEnvironment?

    public init(steam: WorkspaceSteamEnvironment? = nil) {
        self.steam = steam
    }

    /// Through `WorkspaceSteamEnvironment`, only while its gate is open.
    public func hideSteam() async -> Bool {
        guard let result = await steam?.hideIfAllowed() else { return false }
        return result.hidApps + result.hidHelpers > 0
    }

    public func frontmostApp() async -> FocusApp? {
        await MainActor.run {
            NSWorkspace.shared.frontmostApplication.map {
                FocusApp(processIdentifier: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier)
            }
        }
    }

    public func hostProcesses() async -> [HostProcess] {
        await MainActor.run {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: GameWindow.hostBundleIdentifier)
                .filter { !$0.isTerminated }
            let regular = Set(apps.filter { $0.activationPolicy == .regular }.map(\.processIdentifier))
            // The window list is read only once a process is regular: while the game starts there is none (this runs
            // twice a second then).
            let areas = regular.isEmpty ? [:] : WindowList.largestVisibleWindowAreas(owners: regular)
            return apps.map {
                HostProcess(processIdentifier: $0.processIdentifier, isRegular: $0.activationPolicy == .regular,
                            visibleWindowArea: areas[$0.processIdentifier] ?? 0, launchDate: $0.launchDate)
            }
        }
    }

    public func activate(_ processIdentifier: Int32) async -> Bool {
        await Self.activate(processIdentifier)
    }

    /// macOS 14 made activation cooperative: the active app hands the front over (`yieldActivation(to:)`, then
    /// `activate(from:options:)`), as after Play, Return to Game or Show the Window in Warzag. When another app is in
    /// front (for GameFocusKeeper only Steam, the game host's own shim or nobody), the plain request is tried first; if
    /// macOS does not honour it, Warzag takes the front back the way Steam took it (`activate(ignoringOtherApps:)`
    /// still lets an app activate itself regardless of the others) and hands it on at once.
    @MainActor
    static func activate(_ processIdentifier: Int32) async -> Bool {
        guard let target = NSRunningApplication(processIdentifier: processIdentifier), !target.isTerminated else {
            return false
        }
        if isFrontmost(processIdentifier) { return true }
        // Not inside an app (warzagctl has no NSApplication): a plain request is all there is.
        guard let application = NSApp else {
            _ = target.activate(options: [.activateAllWindows])
            return await becomesFrontmost(processIdentifier, within: .seconds(1))
        }
        if !application.isActive {
            _ = target.activate(options: [.activateAllWindows])
            if await becomesFrontmost(processIdentifier, within: .milliseconds(400)) { return true }
            // Checked again now, as the player may have gone to another app meanwhile: Warzag only ever takes the
            // front from Steam, the game host's own processes or nobody.
            let front = NSWorkspace.shared.frontmostApplication.map {
                FocusApp(processIdentifier: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier)
            }
            guard GameWindow.mayTakeFront(from: front,
                                          ownProcessIdentifier: NSRunningApplication.current.processIdentifier)
            else { return false }
            application.activate(ignoringOtherApps: true)
            guard await becomesActive(application, within: .seconds(1)) else { return false }
        }
        application.yieldActivation(to: target)
        _ = target.activate(from: .current, options: [.activateAllWindows])
        return await becomesFrontmost(processIdentifier, within: .seconds(1))
    }

    @MainActor
    private static func isFrontmost(_ processIdentifier: Int32) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier
    }

    /// Activation is asynchronous: the main run loop keeps running between the checks and brings the news.
    @MainActor
    private static func becomesFrontmost(_ processIdentifier: Int32, within limit: Duration) async -> Bool {
        await waitUntil(within: limit) { isFrontmost(processIdentifier) }
    }

    @MainActor
    private static func becomesActive(_ application: NSApplication, within limit: Duration) async -> Bool {
        await waitUntil(within: limit) { application.isActive }
    }

    @MainActor
    private static func waitUntil(within limit: Duration, _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while !condition() {
            guard clock.now < deadline else { return false }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return condition()
            }
        }
        return true
    }
}

/// The window server's list of windows on screen (`CGWindowListCopyWindowInfo`). A window's owner, level, alpha and
/// bounds need no screen-recording permission (only titles would, and they are never read).
enum WindowList {
    /// Smaller windows are helpers (Wine's message windows, tool tips), not something the player looks at.
    static let minimumSide: CGFloat = 64

    static func largestVisibleWindowAreas(owners: Set<Int32>) -> [Int32: Double] {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return largestVisibleWindowAreas(in: windows, owners: owners)
    }

    /// For each owner, the area of its largest window at the normal level (0) that is not fully transparent and at
    /// least `minimumSide` on each side.
    static func largestVisibleWindowAreas(in windows: [[String: Any]], owners: Set<Int32>) -> [Int32: Double] {
        var areas: [Int32: Double] = [:]
        for window in windows {
            guard let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, owners.contains(owner),
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let boundsInfo = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary),
                  bounds.width >= minimumSide, bounds.height >= minimumSide else { continue }
            areas[owner] = max(areas[owner] ?? 0, Double(bounds.width * bounds.height))
        }
        return areas
    }
}
