import AppKit
import AppUpdateKit
import GameKit
import SteamHostKit
import SwiftUI
import WarzagCore

/// The app (`WarzagEntry` starts it).
struct WarzagMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window(delegate.model.isDemo ? L10n.windowTitleDemo : L10n.appName, id: WindowID.main) {
            RootView()
                .environment(delegate.model)
                .frame(minWidth: 560, minHeight: 540)
                .background(MainWindowReader())
        }
        .defaultSize(width: 640, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) { CheckForUpdatesCommand(model: delegate.model) }
            CommandGroup(after: .help) {
                WhatsNewCommand()
                TroubleshootCommand()
            }
        }

        Window(L10n.troubleshootTitle, id: WindowID.troubleshoot) {
            TroubleshootView()
                .environment(delegate.model)
        }
        .defaultSize(width: 640, height: 640)

        // Sized to its content, so rows that grow (a longer message, a progress bar) grow the window.
        Window(L10n.updatesTitle, id: WindowID.updates) {
            UpdatesView()
                .environment(delegate.model)
        }
        .windowResizability(.contentSize)

        // Opens tall enough for a release's changes; the rest scrolls.
        Window(L10n.whatsNewTitle, id: WindowID.whatsNew) {
            WhatsNewView()
                .environment(delegate.model)
        }
        .defaultSize(width: 640, height: 700)

        Settings {
            SettingsView()
                .environment(delegate.model)
        }
    }
}

/// Help › What's New in Warzag.
struct WhatsNewCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(L10n.whatsNewTitle) { openWindow(id: WindowID.whatsNew) }
            .accessibilityLabel(L10n.whatsNewTitle)
    }
}

struct TroubleshootCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(L10n.troubleshootMenu) { openWindow(id: WindowID.troubleshoot) }
            .accessibilityLabel(L10n.troubleshootMenu)
    }
}

/// App menu › Check for Updates…, after About: opens the Updates window and checks.
struct CheckForUpdatesCommand: View {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel

    var body: some View {
        Button(L10n.checkForUpdatesMenu) {
            openWindow(id: WindowID.updates)
            model.updates.checkForUpdates()
        }
        .accessibilityLabel(L10n.checkForUpdatesMenu)
    }
}

/// Warzag's main window, so it can come back after a game during which Warzag left the Dock (Hide Warzag while
/// playing): nothing is closed when Warzag hides, but the player may have closed the window themselves.
@MainActor
enum MainWindow {
    /// The window that shows `RootView`, while it exists.
    static weak var window: NSWindow?
    /// SwiftUI's action that opens the main window again once it was closed.
    static var open: OpenWindowAction?

    /// Asks macOS to activate Warzag (cooperatively: the player's own app keeps the front if they are using one) and
    /// brings the main window to the front, or has SwiftUI open it again when the player closed it.
    static func show() {
        NSApp.activate()
        if let window, window.isVisible || window.isMiniaturized {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            open?(id: WindowID.main)
        }
    }
}

/// Tells `MainWindow` which window shows the main screen, and how SwiftUI opens it again.
struct MainWindowReader: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        WindowReporter()
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear { MainWindow.open = openWindow }
    }

    private struct WindowReporter: NSViewRepresentable {
        func makeNSView(context: Context) -> ReportingView { ReportingView() }
        func updateNSView(_ nsView: ReportingView, context: Context) {}

        final class ReportingView: NSView {
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if let window { MainWindow.window = window }
            }
        }
    }
}

/// Owns the model; starts it at launch, shuts it down cleanly on quit (also on SIGTERM), and keeps setup running with
/// the window closed (the Dock icon reopens it).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    private var terminationSignal: (any DispatchSourceSignal)?
    private var snapshotter: WindowSnapshotter?
    private var terminating = false

    override init() {
        model = AppModel.make(options: .current())
        super.init()
        if let directory = model.options.snapshotDirectory {
            let snapshotter = WindowSnapshotter(directory: directory)
            self.snapshotter = snapshotter
            model.onMilestone = { snapshotter.capture($0) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SIGTERM (logout scripts, `kill`) quits like Cmd-Q, with the same clean shutdown.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { AppTermination.request() }
        source.resume()
        terminationSignal = source
        model.log.write("app: launch" + (model.isDemo ? " (demo)" : ""))
        Task { await model.launch() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.appBecameActive()
    }

    /// During a game Warzag may leave the Dock once the player is elsewhere (Hide Warzag while playing).
    func applicationDidResignActive(_ notification: Notification) {
        model.appResignedActive()
    }

    /// Opening Warzag again (Finder, Spotlight, `open`) while it hides during a game brings it back with its window at
    /// once; otherwise AppKit reopens the window as usual.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.reopened()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Closes DE's launcher if setup runs it, then quits. AppKit waits in a nested run loop for the reply; the
    /// shutdown runs on the main actor there. A watchdog replies after a few seconds regardless, through a run-loop
    /// block, which that loop services even when the main dispatch queue cannot run.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateNow }
        terminating = true
        let replied = Once()
        let reply: @Sendable () -> Void = {
            guard replied.claim() else { return }
            MainActor.assumeIsolated { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        let model = model
        Task { @MainActor in
            await model.shutdown()
            reply()
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 8) {
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { reply() }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        return .terminateLater
    }
}

/// Quitting from code. `NSApp.terminate` is deferred to the run loop: called from inside a main-queue block (a signal
/// source, a main-actor task), AppKit's wait for `applicationShouldTerminate`'s reply could not run the main actor.
enum AppTermination {
    static func request() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
            }
        }
    }
}

extension AppModel {
    /// The model for this run: live kits, or simulated ones in Demo mode.
    static func make(options: LaunchOptions) -> AppModel {
        let paths = WarzagPaths(home: options.home)
        let fileSystem = LocalFileSystem()
        let settings = SettingsBox(AppSettingsStore(paths: paths, fileSystem: fileSystem).load(),
                                   launchDevelopmentRuntime: options.developmentRuntime)
        let log = AppLog(directory: paths.logs)
        let services = options.isDemo
            ? DemoServices.make(speed: options.demoSpeed)
            : LiveServices.make(paths: paths, settings: settings, log: log)
        let model = AppModel(options: options, services: services, settings: settings, fileSystem: fileSystem, log: log)
        if options.isDemo { model.demoAutoPlay = options.demoAutoPlay }
        return model
    }
}

/// The kits, wired for this Mac.
enum LiveServices {
    static func make(paths: WarzagPaths, settings: SettingsBox, log: AppLog) -> AppServices {
        let environment = ProcessInfo.processInfo.environment
        // Steam is the user's own, in their real home, even when WARZAG_HOME moves Warzag's data.
        let realHome = FileManager.default.homeDirectoryForCurrentUser
        let steamLocations = SteamLocations(home: realHome)
        var engine = LiveEngineService(paths: paths, settings: settings, steam: steamLocations,
                                       inheritedEnvironment: environment, log: log)
        // The release page's signed runtime manifest (App/make-app.sh --feed-url), if any.
        engine.feed = RuntimeFeedSource.url(in: Bundle.main.infoDictionary)
        let steamEnvironment = WorkspaceSteamEnvironment(locations: steamLocations)
        let steam = LiveSteamService(locations: steamLocations,
                                     workDirectory: paths.caches.appending(path: "steam-installer", directoryHint: .isDirectory),
                                     environment: steamEnvironment)
        let game = LiveGameService(paths: paths, engine: engine, steam: steam, inheritedEnvironment: environment, log: log)
        // Warzag's own updates: the release page's signed app feed (App/make-app.sh --update-url), if any.
        let appUpdate: any AppUpdateServicing = AppFeed.url(in: Bundle.main.infoDictionary)
            .map { LiveAppUpdateService.make(feed: $0, paths: paths, realHome: realHome, log: log) }
            ?? UnconfiguredAppUpdates()
        return AppServices(system: LiveSystemService(realHome: realHome, steam: steamLocations,
                                                     steamEnvironment: steamEnvironment), engine: engine,
                           steam: steam, game: game, clock: SystemClock(), appUpdate: appUpdate, isDemo: false)
    }
}

/// Demo mode with WARZAG_SNAPSHOT_DIR: a PNG of the main window at each milestone of the flow, rendered by the app
/// itself (no screen recording permission involved).
@MainActor
final class WindowSnapshotter {
    let directory: URL
    private var count = 0

    init(directory: URL) {
        self.directory = directory
    }

    func capture(_ milestone: String) {
        count += 1
        let name = String(format: "%02d-%@.png", count, milestone)
        Task { @MainActor in
            // Let SwiftUI lay out and draw the new state first.
            try? await Task.sleep(for: .milliseconds(900))
            self.write(name)
        }
    }

    private func write(_ name: String) {
        let windows = NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) && $0.contentView != nil }
        guard let window = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
              let view = window.contentView?.superview ?? window.contentView,
              let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appending(path: name))
    }
}
