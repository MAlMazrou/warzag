import AppKit
import Foundation
import SwiftUI
import Testing
import WarzagCore
@testable import WarzagApp

/// Every screen rendered offscreen with SwiftUI's ImageRenderer (no window is created), in the states that matter, light
/// and dark. ImageRenderer draws AppKit-backed controls (buttons, progress bars, pickers) as placeholders; text, symbols,
/// cards and layout are real. Set WARZAG_RENDER_PREVIEWS=<dir> to keep the PNGs.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ViewRenderTests {
    let fixture = AppFixture()
    let size = CGSize(width: 640, height: 900)

    private func render(_ name: String, height: CGFloat? = nil, dark: Bool = false,
                        @ViewBuilder _ view: () -> some View) throws {
        let content = view()
            .frame(width: size.width, height: height ?? size.height, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        var image: CGImage?
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance { image = renderer.cgImage }
        let rendered = try #require(image, "\(name) did not render")
        #expect(rendered.width == Int(size.width * 2))
        if let directory = ProcessInfo.processInfo.environment["WARZAG_RENDER_PREVIEWS"] {
            let url = URL(filePath: directory, directoryHint: .isDirectory).appending(path: "\(name).png")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let png = try #require(NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]))
            try png.write(to: url)
        }
    }

    @Test func welcome() throws {
        let model = fixture.makeModel()
        try render("01-welcome", height: 720) { WelcomeView().environment(model) }
    }

    @Test func setupWithCardsAndLiveProgress() async throws {
        fixture.engine.useDevelopmentEngine(.n)
        fixture.steam.set { $0.signedIn = false }
        fixture.game.set {
            $0.holdDownload = true
            $0.downloadProgress = [.downloading(bytesThisRun: 23_400_000_000, bytesOnDisk: 23_400_000_000, expectedBytes: 55_700_000_000,
                                                megabytesPerSecond: 47)]
        }
        let model = fixture.makeModel()
        await model.launch()
        #expect(await eventually {
            model.attentionItems == [.action(.steam, .signInToSteam)] && model.activities[.game]?.progress != nil
        })
        try render("02-setup-progress", height: 1250) { SetupContent().environment(model) }
        try render("02-setup-progress-dark", height: 1250, dark: true) { SetupContent().environment(model) }
        fixture.game.set { $0.holdDownload = false }
    }

    @Test func setupWaitingForDEsEULAWindow() async throws {
        fixture.engine.useDevelopmentEngine(.n)
        fixture.game.set { $0.holdEULA = true }
        let model = fixture.makeModel()
        await model.launch()
        #expect(await eventually { model.attentionItems.contains(.live(.game, .acceptEULAInDEWindow)) })
        try render("03-setup-eula", height: 1100) { SetupContent().environment(model) }
        fixture.game.set { $0.holdEULA = false }
    }

    @Test func setupWithoutAnEngine() async throws {
        let model = fixture.makeModel()
        await model.launch()
        #expect(await eventually { model.setup.engine.status == .failed })
        await model.waitUntilSetupIsIdle()
        try render("04-setup-no-engine", height: 1100) { SetupContent().environment(model) }
    }

    @Test func homeWithPowerWarnings() async throws {
        try fixture.saveReadyState()
        fixture.system.set {
            $0.lowPowerMode = true
            $0.battery = true
            $0.adapterWatts = 8
            $0.batteryPercent = 7
        }
        fixture.game.set { $0.motionBlur = .on }
        let model = fixture.makeModel()
        await model.launch()
        #expect(await eventually { model.content != nil && model.motionBlur == .on })
        try render("05-home", height: 760) { HomeView().environment(model) }
        try render("05-home-dark", height: 760, dark: true) { HomeView().environment(model) }
    }

    @Test func playing() async throws {
        try fixture.saveReadyState()
        fixture.game.set {
            $0.holdPlayUntilQuit = true
            $0.playUpdates = [.game(.opening), .game(.started(processIdentifier: 42)), .game(.signal(.loggedIn))]
        }
        let model = fixture.makeModel()
        await model.launch()
        model.playGame()
        #expect(await eventually {
            if case .running(let session) = model.play { !session.signals.isEmpty } else { false }
        })
        try render("06-playing", height: 640) { PlayingView().environment(model) }
        model.quitGame()
        #expect(await eventually { model.play == .idle })
    }

    /// Home with the Updates button's badge (a newer Warzag was found), and Play's place while the engine updates.
    @Test func homeWithAnUpdate() async throws {
        try fixture.saveReadyState()
        fixture.appUpdate.set { $0.check = .success(.available(FakeAppUpdates.offer)) }
        fixture.engine.set {
            $0.feed = FakeEngine.feedURL
            $0.active = UpdatesTests.installed
            $0.prefixRuntime = UpdatesTests.installed.id
            $0.holdFeedSteps = ["download"]
        }
        let model = fixture.makeModel()
        await model.launch()
        #expect(await eventually { model.updates.updateAvailable && !model.updates.checking })
        try render("08-home-update-available", height: 760) { HomeView().environment(model) }
        model.updates.updateEngine()
        #expect(await eventually { model.updates.progress(of: .engine) != nil })
        try render("08-home-updating-engine", height: 760, dark: true) { HomeView().environment(model) }
        fixture.engine.set { $0.holdFeedSteps = [] }
        #expect(await eventually { model.updates.running == nil })
    }

    /// The Updates window: a newer Warzag downloading, the engine up to date, Warframe's last run of DE's launcher.
    @Test func updates() async throws {
        try fixture.saveReadyState()
        fixture.appUpdate.set {
            $0.check = .success(.available(FakeAppUpdates.offer))
            $0.holdPrepare = true
        }
        fixture.engine.set {
            $0.feed = FakeEngine.feedURL
            $0.active = UpdatesTests.installed
            $0.prefixRuntime = UpdatesTests.installed.id
            $0.offer.installed = true
        }
        fixture.game.set { $0.updateOutcome = .updated }
        let model = fixture.makeModel()
        await model.launch()
        #expect(await eventually { model.updates.updateAvailable && !model.updates.checking })
        try render("09-updates-available", height: 640) { UpdatesView().environment(model) }
        model.updates.updateWarframe()
        #expect(await eventually { model.updates.warframe == .finished(updated: true) })
        model.updates.updateWarzag()
        #expect(await eventually { model.updates.progress(of: .warzag) != nil })
        try render("09-updates-downloading", height: 640) { UpdatesView().environment(model) }
        try render("09-updates-downloading-dark", height: 640, dark: true) { UpdatesView().environment(model) }
        fixture.appUpdate.set { $0.holdPrepare = false }
        #expect(await eventually { fixture.system.calls.contains("quit") })
    }

    /// What's New with the repository's CHANGELOG.md; a development build after two releases, with a code span; and a
    /// demo run without a changelog (`swift run`), with its badge and the sentence it shows instead.
    @Test func whatsNew() throws {
        let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let changelog = try String(contentsOf: repository.appending(path: "CHANGELOG.md"), encoding: .utf8)
        fixture.appUpdate.set { $0.changelog = changelog }
        let model = fixture.makeModel()
        #expect(!model.whatsNew.sections.isEmpty)
        try render("10-whats-new", height: 1300) { WhatsNewContent().environment(model) }
        let releases = AppFixture()
        releases.appUpdate.set { $0.changelog = WhatsNewTests.changelog }
        try render("10-whats-new-releases-dark", height: 640, dark: true) {
            WhatsNewContent().environment(releases.makeModel())
        }
        let home = try temporaryDirectory("render-whats-new-demo")
        defer { try? FileManager.default.removeItem(at: home) }
        let demo = AppModel.make(options: LaunchOptions(home: home, isDemo: true))
        try render("10-whats-new-demo", height: 200) { WhatsNewContent().environment(demo) }
    }

    /// Its checklist is a List (AppKit), drawn as a placeholder; the header, banners and buttons are real.
    /// (Settings is an AppKit-backed Form throughout, so it is not rendered here.)
    @Test func troubleshoot() async throws {
        try fixture.saveReadyState()
        let model = fixture.makeModel()
        await model.launch()
        await model.runDoctor()
        try render("07-troubleshoot", height: 640) { TroubleshootView().environment(model) }
    }
}
