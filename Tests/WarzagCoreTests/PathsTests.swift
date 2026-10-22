import Foundation
import Testing
@testable import WarzagCore

@Suite struct PathsTests {
    let paths = WarzagPaths(home: URL(filePath: "/Users/tenno", directoryHint: .isDirectory),
                            userCacheDirectory: URL(filePath: "/var/folders/xy/C", directoryHint: .isDirectory))

    @Test func locationLayoutUnderTheHome() {
        let support = "/Users/tenno/Library/Application Support/Warzag"
        #expect(paths.applicationSupport.plainPath == support)
        #expect(paths.setupStateFile.plainPath == "\(support)/State/setup.json")
        #expect(paths.activeRuntimePointer.plainPath == "\(support)/Runtimes.noindex/active.json")
        #expect(paths.runtimeStaging.plainPath == "\(support)/Runtimes.noindex/staging")
        #expect(paths.runtimeDownloads.plainPath == "/Users/tenno/Library/Caches/Warzag/runtime")
        #expect(paths.prefix(for: .n).plainPath == "\(support)/Prefixes/warframe-arm64")
        #expect(paths.identityFile.plainPath == "\(support)/Identity/identity.json")
        #expect(paths.warframeLibrary.plainPath == "\(support)/Library/Warframe.noindex")
        #expect(paths.caches.plainPath == "/Users/tenno/Library/Caches/Warzag")
        #expect(paths.logs.plainPath == "/Users/tenno/Library/Logs/Warzag")
        #expect(paths.dxmtShaderCache?.plainPath == "/var/folders/xy/C/dxmt/Warframe.x64.exe")
    }

    @Test func runtimeHostsLiveUnderTheirChannelAndVersion() {
        #expect(paths.gameHost(.n, version: "0.2.0").plainPath
            == "/Users/tenno/Library/Application Support/Warzag/Runtimes.noindex/n/0.2.0/Warzag.app")
        #expect(paths.runtimeDirectory(.n).lastPathComponent == "n")
    }

    /// Every engine copy is an app bundle named Warzag: Spotlight (and the Apps view built on it) lists none of them
    /// only because each sits inside a folder whose name ends in .noindex.
    @Test func everyEngineCopyIsInsideANoindexFolder() {
        let copies = [paths.gameHost(.n, version: "0.3.0"), paths.gameHost(.n, version: "0.2.0-dev.20261017-120000"),
                      paths.runtimeStaging.appending(path: "n-0.3.0/Warzag.app"), paths.activeRuntimePointer]
        for copy in copies {
            #expect(copy.pathComponents.contains { $0.hasSuffix(".noindex") }, "\(copy.plainPath)")
            #expect(copy.plainPath.hasPrefix(paths.runtimes.plainPath + "/"))
        }
        #expect(paths.runtimes.lastPathComponent == WarzagPaths.runtimesFolderName)
        // Packs are files, not app bundles: they stay in the cache.
        #expect(!paths.runtimeDownloads.plainPath.contains(".noindex"))
    }

    /// The new Warzag an update downloads is an app bundle named Warzag too: it waits in a .noindex folder, in the cache.
    @Test func anUpdateCopyIsOutOfSpotlightsSight() {
        #expect(paths.appUpdates.plainPath == "/Users/tenno/Library/Caches/Warzag/AppUpdate.noindex")
        #expect(paths.appUpdates.appending(path: "staging/Warzag.app").pathComponents.contains { $0.hasSuffix(".noindex") })
        #expect(paths.appUpdateStateFile.plainPath
            == "/Users/tenno/Library/Application Support/Warzag/State/app-update.json")
    }

    @Test func everyNamedPathIsUnderTheInjectedHomeOrTheCacheDirectory() {
        #expect(paths.all.count == 13)
        for named in paths.all {
            let path = named.url.plainPath
            #expect(path.hasPrefix("/Users/tenno/") || path.hasPrefix("/var/folders/xy/C/"), "\(named.name)")
        }
        #expect(Set(paths.all.map(\.name)).count == paths.all.count)
    }

    @Test func noCacheDirectoryMeansNoDXMTCacheEntry() {
        let bare = WarzagPaths(home: URL(filePath: "/Users/tenno"), userCacheDirectory: nil)
        #expect(bare.dxmtShaderCache == nil)
        #expect(!bare.all.map(\.name).contains("dxmtCache"))
    }

    @Test func homeIsStandardized() {
        let messy = WarzagPaths(home: URL(filePath: "/Users/tenno/../tenno/"), userCacheDirectory: nil)
        #expect(messy.home.plainPath == "/Users/tenno")
        #expect(messy.logs.plainPath == "/Users/tenno/Library/Logs/Warzag")
    }

    @Test func realCacheDirectoryIsFound() {
        // confstr works on every Mac; the folder is per user under /var/folders.
        #expect(WarzagPaths.darwinUserCacheDirectory()?.plainPath.contains("/C") == true)
    }

    @Test func prefixLayout() {
        let prefix = PrefixLayout(root: URL(filePath: "/p", directoryHint: .isDirectory), windowsUserName: "tenno")
        #expect(prefix.eeConfig.plainPath == "/p/drive_c/users/tenno/AppData/Local/Warframe/EE.cfg")
        #expect(prefix.eeLog.lastPathComponent == "EE.log")
        #expect(prefix.launcherLog.lastPathComponent == "Launcher.log")
        #expect(prefix.preprocessLog.lastPathComponent == "Preprocess.log")
        #expect(prefix.steamDirectory.plainPath == "/p/drive_c/Program Files (x86)/Steam")
        #expect(prefix.libraryDrive.plainPath == "/p/dosdevices/x:")
    }

    @Test func windowsPathsOnlyExistInsideDriveC() {
        let prefix = PrefixLayout(root: URL(filePath: "/p q", directoryHint: .isDirectory), windowsUserName: "tenno")
        #expect(prefix.windowsPath(for: prefix.windowsTemp.appending(path: "warzag.reg")) == #"C:\windows\temp\warzag.reg"#)
        #expect(prefix.windowsPath(for: prefix.driveC) == #"C:\"#)
        #expect(prefix.windowsPath(for: URL(filePath: "/p q/drive_cx/file")) == nil)
        #expect(prefix.windowsPath(for: URL(filePath: "/elsewhere/file")) == nil)
        #expect(prefix.windowsPath(for: URL(filePath: "/p q/drive_c/windows/../users/x.txt")) == #"C:\users\x.txt"#)
    }

    @Test func windowsPathsOfExistingFilesUnderPrivate() throws {
        // A prefix spelled /private/tmp/… (scratch and QA prefixes): an existing file inside it must still map to C:\.
        let root = URL(filePath: "/private/tmp/warzag-prefix-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = PrefixLayout(root: root, windowsUserName: "tenno")
        let file = prefix.windowsTemp.appending(path: "warzag-template.reg")
        try LocalFileSystem().writeAtomically(Data("REGEDIT4\r\n".utf8), to: file)
        #expect(prefix.windowsPath(for: file) == #"C:\windows\temp\warzag-template.reg"#)
    }
}

@Suite struct VersionNumberTests {
    @Test(arguments: [
        ("15.0", "15", false, true),
        ("15.0", "15.1", true, false),
        ("1.10.0", "1.9.9", false, false),
        ("26.5.1", "26.5", false, false),
        ("1.1.0-b2", "1.1.0", false, true),
    ])
    func comparison(lhs: String, rhs: String, less: Bool, equal: Bool) throws {
        let left = try #require(VersionNumber(lhs))
        let right = try #require(VersionNumber(rhs))
        #expect((left < right) == less)
        #expect((left == right) == equal)
        if equal { #expect(left.hashValue == right.hashValue) }
    }

    @Test(arguments: ["", "abc", "1..2", "1.-2", "1.2.3.4.5", "v1.0", "1.2a"])
    func rejectsGarbage(_ text: String) {
        #expect(VersionNumber(text) == nil)
    }

    @Test func descriptions() {
        #expect(VersionNumber(OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 1)).description == "26.5.1")
        #expect(Platform.minimumMacOS.description == "15.0")
        #expect(VersionNumber("1.10.0")?.description == "1.10")
        #expect(VersionNumber("15")?.description == "15.0")
    }
}
