import Foundation
import Testing
import WarzagCore
@testable import WarzagApp

struct RedactorTests {
    let redactor = Redactor(home: "/Users/tenno", userName: "tenno")

    @Test func everyPatternCompiles() {
        for rule in Redactor.rules {
            #expect((try? NSRegularExpression(pattern: rule.pattern)) != nil, "\(rule.pattern)")
        }
    }

    @Test func personalDataIsRemoved() {
        let text = """
            12.3 Sys [Info]: Logged in ExampleTenno (5f0c3b9e2a)
            mail tenno.prime+wf@example.co.uk about it
            steam 76561190000000000 [U:1:10000]
            from 192.168.1.20 and fe80::1c2b:3a4d:5e6f:7a8b
            MachineGuid 0246cdda-9597-4817-832b-facf99e960fa
            token QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZWZnaGlqa2xtbm9w
            prefix /Users/tenno/Library/Application Support/Warzag/Prefixes/warframe-arm64 by tenno
            """
        let redacted = redactor.redact(text)
        for secret in ["ExampleTenno", "5f0c3b9e2a", "tenno.prime", "example.co.uk", "76561190000000000", "10000]",
                       "192.168.1.20", "fe80", "0246cdda", "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVph", "/Users/tenno", "tenno"] {
            #expect(!redacted.contains(secret), "\(secret) survived:\n\(redacted)")
        }
        #expect(redacted.contains("Logged in <redacted>"))
        #expect(redacted.contains("~/Library/Application Support/Warzag/Prefixes/warframe-arm64"))
        #expect(redacted.contains("<steamid> [U:1:<id>]"))
        #expect(redacted.contains("<ip>"))
    }

    @Test func ordinaryFactsSurvive() {
        let text = "macOS 26.5.1 at 2026-10-17T02:09:11Z, 12:04:05, runtime n-dev-20261017-000000, 55.7 GB, exit 24"
        #expect(redactor.redact(text) == text)
    }
}

struct DiagnosticsReportTests {
    @Test func theReportStatesTheFactsAndRedactsTheLogs() throws {
        let logs = try temporaryDirectory("logs")
        defer { try? FileManager.default.removeItem(at: logs) }
        let home = URL(filePath: "/Users/tenno", directoryHint: .isDirectory)
        try Data("2026-10-17T01:00:00Z setup: prefix created at /Users/tenno/Library/x for tenno@example.com\n".utf8)
            .write(to: logs.appending(path: "Warzag.log"))
        try Data("ignored".utf8).write(to: logs.appending(path: "notes.txt"))

        var setup = SetupState()
        setup.engine = TrackState(step: .createPrefix, status: .failed, attempts: 4,
                                  failure: SetupFailure(.transient, L10n.failurePrefix))
        let snapshot = DiagnosticsSnapshot(
            appVersion: "0.1.0", build: "42", demo: false, hardware: m2Air, settings: AppSettings(),
            setup: setup, runtime: FakeEngine.runtime(.n), steam: SteamSnapshot(installed: true, running: true, signedIn: false),
            content: nil, doctor: .finished([HealthCheck(id: "engine.dxmt", title: "Graphics", passed: false,
                                                         detail: "missing C:\\windows\\system32\\winemetal.dll")],
                                            at: Date(timeIntervalSince1970: 1_792_000_000)),
            lastSession: SessionResult(seconds: nil, problems: [], failure: L10n.playFailureSteam))
        let report = DiagnosticsReport.render(snapshot, logDirectory: logs, home: home, userName: "tenno")
        #expect(report.contains("app: 0.1.0 (42)"))
        #expect(report.contains("mac: Apple M2, 24 GB, Mac14,15, macOS 26.5.1"))
        #expect(report.contains("tier: T1"))
        #expect(report.contains("setup.engine: failed at createPrefix, attempts 4, failed (transient): "
            + L10n.failurePrefix))
        #expect(report.contains("steam: installed true, running true, signed in false"))
        #expect(report.contains("  FAIL  engine.dxmt: missing"))
        #expect(report.contains("== Warzag.log (last 300 lines) =="))
        #expect(report.contains("prefix created at ~/Library/x for <email>"))
        #expect(!report.contains("notes.txt"))
        #expect(!report.contains("tenno"))
    }

    @Test func onlyTheEndOfALongLogIsKept() throws {
        let logs = try temporaryDirectory("tail")
        defer { try? FileManager.default.removeItem(at: logs) }
        let lines = (1...1_000).map { "line \($0)" }.joined(separator: "\n")
        let url = logs.appending(path: "big.log")
        try Data(lines.utf8).write(to: url)
        let tail = DiagnosticsReport.tail(of: url)
        #expect(tail.count == DiagnosticsReport.logLinesKept)
        #expect(tail.last == "line 1000")
        #expect(tail.first == "line 701")
    }
}
