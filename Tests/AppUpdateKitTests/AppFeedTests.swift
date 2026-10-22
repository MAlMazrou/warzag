import Foundation
import Testing
@testable import AppUpdateKit

@Suite struct AppFeedTests {
    @Test func onlyHTTPSFeedsWithAHost() {
        #expect(AppFeed.url("https://example.org/Warzag.manifest.json", allowsLoopbackHTTP: false)?.host() == "example.org")
        #expect(AppFeed.url("  https://example.org/f.json \n", allowsLoopbackHTTP: false) != nil)
        for text in ["http://example.org/f.json", "ftp://example.org/f.json", "https:///f.json", "f.json", "", "   "] {
            #expect(AppFeed.url(text, allowsLoopbackHTTP: false) == nil, "\(text)")
        }
        #expect(AppFeed.url(nil as String?, allowsLoopbackHTTP: false) == nil)
    }

    @Test func loopbackHTTPOnlyWhenAllowed() {
        for text in ["http://127.0.0.1:8123/f.json", "http://localhost/f.json", "http://[::1]:80/f.json"] {
            #expect(AppFeed.url(text, allowsLoopbackHTTP: true) != nil, "\(text)")
            #expect(AppFeed.url(text, allowsLoopbackHTTP: false) == nil, "\(text)")
        }
        #expect(AppFeed.url("http://192.168.1.2/f.json", allowsLoopbackHTTP: true) == nil)
        #expect(AppFeed.url("http://127.0.0.1.example.org/f.json", allowsLoopbackHTTP: true) == nil)
    }

    /// SwiftPM defines DEBUG for `swift test`: the tests run a development build.
    @Test func thisTestBuildIsADevelopmentBuild() {
        #expect(AppFeed.allowsLoopbackHTTP)
    }

    @Test func theFeedComesFromInfoPlist() {
        #expect(AppFeed.url(in: [AppFeed.infoPlistKey: "https://example.org/a.json"]) == URL(string: "https://example.org/a.json"))
        #expect(AppFeed.url(in: [AppFeed.infoPlistKey: 42]) == nil)
        #expect(AppFeed.url(in: nil) == nil)
    }

    @Test func theAppAProgramShipsIn() {
        #expect(InstalledApp.bundle(containing: URL(filePath: "/Applications/Warzag.app/Contents/Helpers/warzagctl"))
            == URL(filePath: "/Applications/Warzag.app/", directoryHint: .isDirectory))
        #expect(InstalledApp.bundle(containing: URL(filePath: "/Users/tenno/Applications/Games/Warzag.app/Contents/MacOS/Warzag"))?
            .lastPathComponent == "Warzag.app")
        #expect(InstalledApp.bundle(containing: URL(filePath: "/Users/tenno/src/warzag/.build/debug/warzagctl")) == nil)
        #expect(InstalledApp.bundle(containing: URL(filePath: "/opt/Warzag.app/Contents/Resources/warzagctl")) == nil)
    }
}
