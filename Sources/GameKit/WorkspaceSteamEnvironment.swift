import AppKit
import CoreGraphics
import Foundation
import SteamHostKit
import WarzagCore

/// Steam's app and helper as AppKit sees them: `NSRunningApplication` by bundle identifier, `hide()`/`unhide()`, and
/// the window server's list of on-screen windows (owner, layer and bounds need no permission; titles are never read).
public struct WorkspaceSteamApps: SteamApps {
    public init() {}

    public func processes() async -> [SteamAppProcess] {
        await MainActor.run {
            Self.running().map { app, kind in
                SteamAppProcess(processIdentifier: app.processIdentifier, kind: kind, isHidden: app.isHidden,
                                isActive: app.isActive)
            }
        }
    }

    public func hide(_ processIdentifier: Int32) async -> Bool {
        await MainActor.run { Self.steamApp(processIdentifier)?.hide() ?? false }
    }

    public func unhide(_ processIdentifier: Int32) async -> Bool {
        await MainActor.run { Self.steamApp(processIdentifier)?.unhide() ?? false }
    }

    public func windowsOnScreen() async -> [SteamWindow] {
        let owners = Set(await processes().map(\.processIdentifier))
        guard !owners.isEmpty else { return [] }
        return WindowList.steamWindows(owners: owners)
    }

    @MainActor
    static func running() -> [(NSRunningApplication, SteamAppProcess.Kind)] {
        [(SteamAppProcess.appBundleIdentifier, SteamAppProcess.Kind.app),
         (SteamAppProcess.helperBundleIdentifier, .helper)].flatMap { identifier, kind in
            NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .filter { !$0.isTerminated }.map { ($0, kind) }
        }
    }

    /// The app with this pid, only while it is one of Steam's (a pid can be reused once Steam has quit).
    @MainActor
    static func steamApp(_ processIdentifier: Int32) -> NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: processIdentifier), !app.isTerminated,
              SteamAppProcess.kind(ofBundle: app.bundleIdentifier) != nil else { return nil }
        return app
    }
}

/// The live Steam controls for the app: hiding with a record of what Warzag hid (`hider`, gated by `gate`) and Steam's
/// windows on screen. It never automates Steam's UI: no Accessibility, no Apple event but the standard quit, no window
/// moved, closed or resized.
public final class WorkspaceSteamEnvironment: Sendable {
    public let locations: SteamLocations
    public let hider: SteamHider
    public let gate: SteamHideGate
    let apps: WorkspaceSteamApps
    let runner: any ProcessRunning

    public init(locations: SteamLocations = SteamLocations(), clock: any WallClock = SystemClock(),
                runner: any ProcessRunning = SystemProcessRunner(), hidePolicy: SteamHidePolicy = SteamHidePolicy()) {
        self.locations = locations
        apps = WorkspaceSteamApps()
        hider = SteamHider(apps: apps, clock: clock, policy: hidePolicy)
        gate = SteamHideGate()
        self.runner = runner
    }

    /// Steam's windows on screen now.
    public func windowsOnScreen() async -> [SteamWindow] {
        await apps.windowsOnScreen()
    }

    public func processes() async -> [SteamAppProcess] {
        await apps.processes()
    }

    /// A hide, only while the gate is open: after a sign-in, and GameFocusKeeper's when Steam takes the front in the
    /// game's first minute.
    public func hideIfAllowed() async -> SteamHideResult? {
        guard gate.isOpen else { return nil }
        return await hider.hide()
    }
}

extension WindowList {
    /// Steam's smallest windows that count (its 283 x 70 "signed in" pop-up does; its menu bar extra does not).
    static let steamMinimumSide: CGFloat = 40

    static func steamWindows(owners: Set<Int32>) -> [SteamWindow] {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return steamWindows(in: windows, owners: owners)
    }

    /// The on-screen windows of `owners` at any level that are not fully transparent and at least
    /// `steamMinimumSide` on each side: owner, layer and size only.
    static func steamWindows(in windows: [[String: Any]], owners: Set<Int32>) -> [SteamWindow] {
        windows.compactMap { window in
            guard let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, owners.contains(owner),
                  ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let boundsInfo = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary),
                  bounds.width >= steamMinimumSide, bounds.height >= steamMinimumSide else { return nil }
            return SteamWindow(processIdentifier: owner,
                               layer: (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                               width: Double(bounds.width), height: Double(bounds.height))
        }
    }
}
