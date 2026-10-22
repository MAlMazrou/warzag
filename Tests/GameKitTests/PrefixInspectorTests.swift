import Foundation
import Testing
import WarzagCore
import WineKit
@testable import GameKit

@Suite struct PrefixInspectorTests {
    func inspector(_ fixture: GameFixture) -> PrefixInspector {
        PrefixInspector(installation: fixture.installation, fileSystem: fixture.fileSystem, files: fixture.files,
                        probe: fixture.probe)
    }

    @Test func aPreparedPrefixIsReadyForEverything() {
        let fixture = GameFixture()
        fixture.addHost()
        fixture.addPrefix(eula: Fixtures.eulaHash)
        fixture.addGame()
        let inspector = inspector(fixture)
        #expect(inspector.issues(for: .extractInstaller).isEmpty)
        #expect(inspector.issues(for: .runLauncher).isEmpty)
        #expect(inspector.issues(for: .play(steam: true, renderer: .dxmt)).isEmpty)
        #expect(inspector.issues(for: .play(steam: false, renderer: .wined3d)).isEmpty)
    }

    @Test func nothingThereYet() {
        let fixture = GameFixture()
        #expect(inspector(fixture).issues(for: .runLauncher) == [
            .hostMissing(fixture.host.bundle.plainPath),
            .rendererMissing(fixture.host.contents.plainPath + "/renderers/dxmt/aarch64-windows"),
            .prefixMissing(fixture.prefixPath),
        ])
    }

    @Test func whatDEsLauncherNeeds() {
        let fixture = GameFixture()
        fixture.addHost()
        fixture.addPrefix(launcherOverrides: false, placeholders: false)
        #expect(inspector(fixture).issues(for: .runLauncher) == [
            .placeholderMissing(#"C:\windows\system32\winemetal.dll"#),
            .placeholderMissing(#"C:\windows\system32\nvapi64.dll"#),
            .placeholderMissing(#"C:\windows\system32\nvngx.dll"#),
            .launcherOverridesMissing(["dwrite", "libglesv2", "nvapi64", "nvngx"]),
            .launcherNotExtracted,
        ])
        // Extraction only needs the prefix and its X: drive.
        #expect(inspector(fixture).issues(for: .extractInstaller).isEmpty)
    }

    @Test func whatASteamSessionNeeds() {
        let fixture = GameFixture()
        fixture.addHost()
        fixture.addPrefix(steam: false)
        fixture.addLauncher()
        let issues = inspector(fixture).issues(for: .play(steam: true, renderer: .dxmt))
        #expect(issues == [
            .steamFileMissing(#"C:\Program Files (x86)\Steam\steam.exe"#),
            .steamFileMissing(#"C:\Program Files (x86)\Steam\steamclient64.dll"#),
            .placeholderMissing(#"C:\windows\system32\lsteamclient.dll"#),
            .steamRegistryMissing,
            .gameNotDownloaded,
        ])
        #expect(issues.filter(\.needsPrefixRepair).count == 4)
        // A Warframe-account session still goes through steam.exe, but needs nothing else of the bridge.
        #expect(inspector(fixture).issues(for: .play(steam: false, renderer: .dxmt)) == [
            .steamFileMissing(#"C:\Program Files (x86)\Steam\steam.exe"#), .gameNotDownloaded,
        ])
    }

    @Test func theXDriveMustBeTheLibrary() {
        let fixture = GameFixture()
        fixture.addHost()
        fixture.addPrefix()
        fixture.files.link(fixture.prefixPath + "/dosdevices/x:", to: "/Volumes/Other/Warframe")
        #expect(inspector(fixture).issues(for: .extractInstaller) == [
            .libraryDriveElsewhere(found: "/Volumes/Other/Warframe", expected: fixture.libraryPath),
        ])
        try? fixture.fileSystem.removeItem(at: URL(filePath: fixture.prefixPath + "/dosdevices/x:"))
        fixture.files.unlink(fixture.prefixPath + "/dosdevices/x:")
        #expect(inspector(fixture).issues(for: .extractInstaller) == [.libraryDriveMissing(expected: fixture.libraryPath)])
    }

    @Test func theRendererComesFromTheARM64Directory() {
        let fixture = GameFixture()
        let contents = fixture.host.contents.plainPath
        fixture.fileSystem.addFile(contents + "/MacOS/wine", "loader")
        fixture.fileSystem.addFile(contents + "/MacOS/wineserver", "server")
        fixture.addPrefix(eula: Fixtures.eulaHash)
        fixture.addGame()
        // No ARM64 DXMT in the host yet.
        #expect(inspector(fixture).issues(for: .runLauncher) == [.rendererMissing(contents + "/renderers/dxmt/aarch64-windows")])
        fixture.fileSystem.addDirectory(contents + "/renderers/dxmt/aarch64-windows")
        #expect(inspector(fixture).issues(for: .runLauncher).isEmpty)
        #expect(inspector(fixture).issues(for: .play(steam: true, renderer: .dxmt)).isEmpty)
    }

    @Test func aBusyPrefixIsReportedUnlessIgnored() {
        let fixture = GameFixture()
        fixture.addHost()
        fixture.addPrefix(eula: Fixtures.eulaHash)
        fixture.addGame()
        fixture.probe.setBusy(4242)
        #expect(inspector(fixture).issues(for: .runLauncher) == [.prefixBusy(wineserver: 4242)])
        #expect(inspector(fixture).issues(for: .runLauncher, ignoringActivity: true).isEmpty)
        #expect(PrefixIssue.prefixBusy(wineserver: 4242).description.contains("close Warframe"))
    }
}
