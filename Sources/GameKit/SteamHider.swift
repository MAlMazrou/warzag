import Foundation
import Synchronization
import WarzagCore

/// One of Steam's app processes as AppKit lists them.
public struct SteamAppProcess: Equatable, Hashable, Sendable {
    public enum Kind: String, Equatable, Hashable, Sendable {
        /// `com.valvesoftware.steam`: Steam's app (the bootstrapper and the client report it).
        case app
        /// `com.valvesoftware.steam.helper`: where Steam's windows live (an LSUIElement app).
        case helper
    }

    public var processIdentifier: Int32
    public var kind: Kind
    public var isHidden: Bool
    public var isActive: Bool

    public init(processIdentifier: Int32, kind: Kind, isHidden: Bool = false, isActive: Bool = false) {
        self.processIdentifier = processIdentifier
        self.kind = kind
        self.isHidden = isHidden
        self.isActive = isActive
    }

    public static let appBundleIdentifier = GameWindow.steamBundleIdentifier
    public static let helperBundleIdentifier = GameWindow.steamBundleIdentifier + ".helper"

    public static func kind(ofBundle identifier: String?) -> Kind? {
        switch identifier {
        case appBundleIdentifier: .app
        case helperBundleIdentifier: .helper
        default: nil
        }
    }
}

/// One of Steam's windows on screen: its owner, layer and size. Never its title (that would need the screen-recording
/// permission, and window titles can carry friends' names).
public struct SteamWindow: Equatable, Hashable, Sendable {
    public var processIdentifier: Int32
    public var layer: Int
    public var width: Double
    public var height: Double

    public init(processIdentifier: Int32, layer: Int, width: Double, height: Double) {
        self.processIdentifier = processIdentifier
        self.layer = layer
        self.width = width
        self.height = height
    }
}

/// What Warzag may do to Steam's app processes: list them, hide and unhide them (NSRunningApplication `hide()` and
/// `unhide()`, the same as the player pressing ⌘H: no Accessibility, Screen Recording or Automation permission), and
/// list their windows on screen. Nothing here closes, minimises, moves or resizes a window. Behind a protocol so
/// `SteamHider` runs against fakes; `WorkspaceSteamApps` is the live one.
public protocol SteamApps: Sendable {
    /// Steam's running app and helper processes.
    func processes() async -> [SteamAppProcess]
    /// `NSRunningApplication.hide()`: false when it did nothing (Steam's GPU and renderer helpers have no windows).
    func hide(_ processIdentifier: Int32) async -> Bool
    /// `NSRunningApplication.unhide()`.
    func unhide(_ processIdentifier: Int32) async -> Bool
    /// Steam's windows on screen now (app and helper).
    func windowsOnScreen() async -> [SteamWindow]
}

public struct SteamHidePolicy: Equatable, Sendable {
    /// After hiding Steam's app, how long before checking whether its windows went (Steam passes hiding on to its
    /// helper itself).
    public var helperDelay: Duration = .milliseconds(300)
    /// Steam windows still on screen after this many hides of the same process: Warzag stops trying for it (Steam can
    /// ignore Hide).
    public var maximumIneffectiveHides = 2

    public init() {}
}

/// What a hide did.
public struct SteamHideResult: Equatable, Sendable {
    /// Processes Warzag hid now.
    public var hidApps: Int
    public var hidHelpers: Int
    /// Steam windows still on screen after the hide.
    public var windowsStillOnScreen: Int
    /// Steam windows stayed on screen after `SteamHidePolicy.maximumIneffectiveHides` hides of the same process:
    /// Warzag stopped trying for it.
    public var gaveUp: Bool

    public init(hidApps: Int, hidHelpers: Int, windowsStillOnScreen: Int, gaveUp: Bool) {
        self.hidApps = hidApps
        self.hidHelpers = hidHelpers
        self.windowsStillOnScreen = windowsStillOnScreen
        self.gaveUp = gaveUp
    }
}

/// Hides and unhides Steam and records exactly which processes Warzag hid, so it only ever unhides those (never one
/// the player hid). When to hide is the caller's decision (`SteamHideGate`).
public actor SteamHider {
    public let apps: any SteamApps
    let clock: any WallClock
    let policy: SteamHidePolicy
    /// The processes Warzag hid and has not unhidden yet.
    public private(set) var hidden: [Int32: SteamAppProcess.Kind] = [:]
    private var ineffective: [Int32: Int] = [:]
    private var givenUp: Set<Int32> = []

    public init(apps: any SteamApps, clock: any WallClock, policy: SteamHidePolicy = SteamHidePolicy()) {
        self.apps = apps
        self.clock = clock
        self.policy = policy
    }

    /// Hides Steam's app; if Steam windows are still on screen `helperDelay` later, its helper too. A process already
    /// hidden (by the player) is left as it is and not recorded. When windows stay on screen, each process tried
    /// counts a hide with no effect; at the limit Warzag stops trying for it (`gaveUp`).
    public func hide() async -> SteamHideResult {
        let app = await hideAll(.app)
        var tried = app.tried
        var hidHelpers = 0
        try? await clock.sleep(for: policy.helperDelay)
        var windows = await apps.windowsOnScreen()
        if !windows.isEmpty {
            let helper = await hideAll(.helper)
            tried.formUnion(helper.tried)
            hidHelpers = helper.hid
            try? await clock.sleep(for: policy.helperDelay)
            windows = await apps.windowsOnScreen()
        }
        let hidApps = app.hid
        var gaveUp = false
        if windows.isEmpty {
            for process in tried { ineffective[process] = nil }
        } else {
            for process in tried {
                let count = (ineffective[process] ?? 0) + 1
                ineffective[process] = count
                if count >= policy.maximumIneffectiveHides {
                    givenUp.insert(process)
                    gaveUp = true
                }
            }
        }
        return SteamHideResult(hidApps: hidApps, hidHelpers: hidHelpers, windowsStillOnScreen: windows.count,
                               gaveUp: gaveUp)
    }

    /// Hides every process of `kind` not hidden yet; returns the processes tried and how many it hid.
    private func hideAll(_ kind: SteamAppProcess.Kind) async -> (tried: Set<Int32>, hid: Int) {
        var tried: Set<Int32> = []
        var hid = 0
        for process in await apps.processes()
        where process.kind == kind && !givenUp.contains(process.processIdentifier) {
            tried.insert(process.processIdentifier)
            // Hidden already (by Warzag, or by the player, which is never recorded as Warzag's). One Warzag hid that
            // is shown again (a Steam that activates itself unhides itself) is hidden and recorded again.
            guard !process.isHidden else { continue }
            // A false result is ignored: Steam's GPU and renderer processes have no windows.
            if await apps.hide(process.processIdentifier) {
                hidden[process.processIdentifier] = kind
                hid += 1
            }
        }
        return (tried, hid)
    }

    /// Unhides every process Warzag hid that still runs as Steam; returns how many.
    @discardableResult
    public func unhideWhatWarzagHid() async -> Int {
        let running = Set(await apps.processes().map(\.processIdentifier))
        var count = 0
        for process in hidden.keys.sorted() {
            hidden[process] = nil
            // A pid that is no longer Steam's may be another app's now: never touch it.
            guard running.contains(process) else { continue }
            if await apps.unhide(process) { count += 1 }
        }
        return count
    }
}

/// Whether Warzag may hide Steam right now. The app opens it while Keep Steam out of sight applies and closes it while
/// the player logs in to Steam or out of it.
public final class SteamHideGate: Sendable {
    private let open: Mutex<Bool>

    public init(open: Bool = false) {
        self.open = Mutex(open)
    }

    public var isOpen: Bool { open.withLock { $0 } }

    public func set(_ open: Bool) {
        self.open.withLock { $0 = open }
    }
}
