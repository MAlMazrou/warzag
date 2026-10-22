import Darwin
import Foundation
import Testing
import WarzagCore
@testable import AppUpdateKit

@Suite(.serialized) struct LocationAndLaunchTests {
    /// A scratch home whose Applications folder counts, and an app in it.
    func scratchHome() throws -> (home: URL, app: URL, inspector: LiveAppLocationInspector) {
        let home = try scratchDirectory("location")
        let app = try makeApp(at: home.appending(path: "Applications/Warzag.app", directoryHint: .isDirectory),
                              version: "0.1.0", build: "412")
        return (home, app, LiveAppLocationInspector(home: home))
    }

    @Test func anAppInAnApplicationsFolderCanBeReplaced() throws {
        let (home, app, inspector) = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(inspector.obstacle(replacing: app) == nil)
        let nested = try makeApp(at: home.appending(path: "Applications/Games/Warzag.app", directoryHint: .isDirectory),
                                 version: "0.1.0", build: "412")
        #expect(inspector.obstacle(replacing: nested) == nil)
        #expect(inspector.applicationFolders.first?.plainPath == "/Applications")
    }

    @Test func anywhereElseItCannot() throws {
        let (home, _, inspector) = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let downloads = try makeApp(at: home.appending(path: "Downloads/Warzag.app", directoryHint: .isDirectory),
                                    version: "0.1.0", build: "412")
        #expect(inspector.obstacle(replacing: downloads) == "\(downloads.plainPath) is not in an Applications folder")
        // A link from an Applications folder to elsewhere is judged by where it leads.
        let link = home.appending(path: "Applications/Linked.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: downloads)
        #expect(inspector.obstacle(replacing: link) == "\(link.plainPath) is not in an Applications folder")
        // An Applications folder by name only (a disk image's link, a folder elsewhere) is not one.
        let lookalike = try makeApp(at: home.appending(path: "Volumes/Warzag/Applications/Warzag.app",
                                                       directoryHint: .isDirectory), version: "0.1.0", build: "412")
        #expect(inspector.obstacle(replacing: lookalike)?.hasSuffix("is not in an Applications folder") == true)
    }

    @Test func appTranslocationIsNamed() {
        let inspector = LiveAppLocationInspector(home: URL(filePath: "/Users/tenno"))
        let translocated = URL(filePath: "/private/var/folders/xy/abc/T/AppTranslocation/1234-5678/d/Warzag.app")
        #expect(inspector.obstacle(replacing: translocated)?.contains("App Translocation") == true)
    }

    @Test func aFolderThisUserMayNotChange() throws {
        let (home, app, inspector) = try scratchHome()
        let folder = app.deletingLastPathComponent()
        defer {
            chmod(folder.plainPath, 0o755)
            try? FileManager.default.removeItem(at: home)
        }
        #expect(chmod(folder.plainPath, 0o555) == 0)
        #expect(inspector.obstacle(replacing: app) == "this user may not change \(folder.plainPath)")
    }

    @Test func aLockedAppCannotBeReplaced() throws {
        let (home, app, inspector) = try scratchHome()
        defer {
            chflags(app.plainPath, 0)
            try? FileManager.default.removeItem(at: home)
        }
        #expect(chflags(app.plainPath, UInt32(UF_IMMUTABLE)) == 0)
        #expect(inspector.obstacle(replacing: app) == "\(app.plainPath) is locked")
    }

    /// The helper outlives its starter: a session of its own, nothing inherited but /dev/null.
    @Test func theHelperStartsInASessionOfItsOwn() async throws {
        let directory = try scratchDirectory("launcher")
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "out.txt")
        // It says whether its stdout is a terminal or a pipe (it is /dev/null), then waits to be looked at.
        let pid = try PosixHelperLauncher().launch(Command(
            "/bin/sh", ["-c", "{ echo \"$WARZAG_PROBE\"; [ -p /dev/stdout ] && echo pipe; [ -t 1 ] && echo tty; } "
                + "> \"$0.tmp\"; mv \"$0.tmp\" \"$0\"; exec sleep 5", output.plainPath],
            environment: ["WARZAG_PROBE": "hello", "PATH": "/usr/bin:/bin"]))
        defer {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        #expect(pid > 0)
        var text = ""
        for _ in 0..<100 where text.isEmpty {
            text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
            if text.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(text == "hello\n")
        #expect(getsid(pid) == pid)
    }

    /// The process macOS holds responsible for the helper (TCC, so App Management, asks about that one) is the helper
    /// itself, for the probe as for the swap; a plain child answers to whoever its starter answers to.
    @Test(arguments: [true, false])
    func theHelperAnswersForItself(newSession: Bool) throws {
        let lookup = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid"))
        let responsible = unsafeBitCast(lookup, to: (@convention(c) (Int32) -> Int32).self)
        let helper = try PosixHelperLauncher.spawn(Command("/bin/sleep", ["5"]), newSession: newSession, output: nil)
        let plain = Process()
        plain.executableURL = URL(filePath: "/bin/sleep")
        plain.arguments = ["5"]
        try plain.run()
        defer {
            plain.terminate()
            kill(helper, SIGKILL)
            var status: Int32 = 0
            waitpid(helper, &status, 0)
        }
        #expect(responsible(helper) == helper)
        #expect(responsible(plain.processIdentifier) != plain.processIdentifier)
    }

    /// The probe: waited for, with its exit status and what it printed; one that passes its deadline is stopped.
    @Test func runWaitsForTheHelperAndReadsWhatItSaid() async throws {
        let launcher = PosixHelperLauncher()
        let output = try await launcher.run(Command("/bin/sh", ["-c", "echo said; echo why >&2; exit 65"],
                                                    timeout: .seconds(30)))
        #expect(output == ProcessOutput(exitCode: 65, stdout: Data("said\n".utf8), stderr: Data("why\n".utf8)))
        await #expect(throws: ProcessTimedOut.self) {
            try await launcher.run(Command("/bin/sleep", ["30"], timeout: .milliseconds(200)))
        }
    }

    @Test func helperLogLinesLookLikeWarzagsOwn() throws {
        let directory = try scratchDirectory("appending-log")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "Logs/Warzag.log")
        let log = AppendingLog(url: file, home: URL(filePath: "/Users/tenno", directoryHint: .isDirectory))
        log.write("update: one\ntwo", at: Date(timeIntervalSince1970: 1_792_000_000))
        log.write("update: replaced /Users/tenno/Applications/Warzag.app with Warzag 0.2.0 (build 413)",
                  at: Date(timeIntervalSince1970: 1_792_000_001))
        // The home folder never reaches Warzag.log: it names the user.
        #expect(try String(contentsOf: file, encoding: .utf8) == "2026-10-14T17:46:40Z update: one two\n"
            + "2026-10-14T17:46:41Z update: replaced ~/Applications/Warzag.app with Warzag 0.2.0 (build 413)\n")
        AppendingLog(url: nil).write("nowhere")
        #expect(AppendingLog(url: nil, home: URL(filePath: "/")).redacted("/Applications/Warzag.app") == "/Applications/Warzag.app")
    }

    /// Only a path that starts with the home folder: not a longer name, not the same letters inside a longer path.
    @Test(arguments: [
        ("/Users/tenno", "/Users/tenno", "~"),
        ("open '/Users/tenno/Applications/Warzag.app' failed", "/Users/tenno", "open '~/Applications/Warzag.app' failed"),
        ("/Users/tenno2/Applications", "/Users/tenno", "/Users/tenno2/Applications"),
        ("/private/var/x/home/Applications", "/var/x/home", "/private/var/x/home/Applications"),
        ("a /Users/tenno/x and /Users/tenno/y", "/Users/tenno", "a ~/x and ~/y"),
    ])
    func theHomeIsRedactedWhereAPathStartsWithIt(_ text: String, _ home: String, _ expected: String) {
        #expect(AppendingLog.replacing(home, in: text) == expected)
    }

    /// A home given as /var/... is also found as /private/var/... (the kernel's spelling), and the other way round.
    @Test func bothSpellingsOfATemporaryHome() throws {
        let home = try scratchDirectory("log-home")
        defer { try? FileManager.default.removeItem(at: home) }
        let short = home.plainPath.replacingOccurrences(of: "/private/var/", with: "/var/")
        let log = AppendingLog(url: nil, home: URL(filePath: short, directoryHint: .isDirectory))
        #expect(log.redacted("replaced \(home.plainPath)/Applications/Warzag.app") == "replaced ~/Applications/Warzag.app")
        #expect(log.redacted("replaced \(short)/Applications/Warzag.app") == "replaced ~/Applications/Warzag.app")
    }
}
