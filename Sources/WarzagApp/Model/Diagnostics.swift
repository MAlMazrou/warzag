import Foundation
import WarzagCore

/// On-device redaction for exported diagnostics: emails, IPv4/IPv6 addresses, Steam IDs (64-bit `7656119…` and
/// `[U:1:…]`), UUIDs (Wine's MachineGuid), long tokens, the home folder and the user name, and the name after EE.log's
/// "Logged in".
struct Redactor: Sendable {
    var home: String?
    var userName: String?

    /// Pattern and replacement, applied in order (RedactorTests checks that every pattern compiles).
    static let rules: [(pattern: String, replacement: String)] = [
        (#"Logged in [^\r\n]*"#, "Logged in <redacted>"),
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<email>"),
        (#"7656119\d{10}"#, "<steamid>"),
        (#"\[U:1:\d+\]"#, "[U:1:<id>]"),
        (#"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#, "<uuid>"),
        (#"\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b"#, "<ip>"),
        // IPv6 with or without "::"; needs "::" or four full groups, so clock times (12:04:05) are left alone.
        (#"(?<![\w:.])(?=[0-9a-fA-F:]*::|(?:[0-9a-fA-F]{1,4}:){4})[0-9a-fA-F]{0,4}(?::[0-9a-fA-F]{0,4}){2,7}(?![\w:])"#,
         "<ip>"),
        (#"[A-Za-z0-9+=_-]{40,}"#, "<token>"),
    ]

    /// The home folder first (paths stay readable), then the patterns (an email containing the user name is still an
    /// email), then any other mention of the user name.
    func redact(_ text: String) -> String {
        var result = text
        if let home, home.count > 1 {
            result = result.replacingOccurrences(of: home, with: "~")
        }
        for rule in Self.rules {
            guard let expression = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = expression.stringByReplacingMatches(
                in: result, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: rule.replacement))
        }
        if let userName, userName.count >= 3 {
            result = result.replacingOccurrences(of: "/Users/\(userName)", with: "/Users/<user>")
            result = result.replacingOccurrences(of: userName, with: "<user>")
        }
        return result
    }
}

/// Everything the report states, collected on the main actor.
struct DiagnosticsSnapshot: Sendable {
    var appVersion: String
    var build: String
    var demo: Bool
    var hardware: HardwareProfile
    var settings: AppSettings
    var setup: SetupState
    var runtime: RuntimeSummary?
    var steam: SteamSnapshot
    var content: ContentSummary?
    var doctor: DoctorState
    var lastSession: SessionResult?
}

/// The text Export Diagnostics saves: facts first, then the tails of Warzag's own logs, all redacted. DE's logs are
/// left out (EE.log names the player); the GameKit signals Warzag read from them are in the last session line.
enum DiagnosticsReport {
    static let logTailBytes = 128 * 1024
    static let logLinesKept = 300

    static func render(_ snapshot: DiagnosticsSnapshot, logDirectory: URL, home: URL,
                       userName: String = NSUserName()) -> String {
        var lines: [String] = []
        func row(_ name: String, _ value: String) { lines.append("\(name): \(value)") }

        lines.append("Warzag diagnostics")
        row("app", "\(snapshot.appVersion) (\(snapshot.build))" + (snapshot.demo ? " DEMO" : ""))
        let hardware = snapshot.hardware
        row("mac", "\(hardware.chip), \(hardware.memoryGB) GB, \(hardware.modelIdentifier), macOS \(hardware.macOSVersion)")
        row("tier", "\(hardware.tierClassification.tier.rawValue) (\(hardware.tierClassification.reason))")
        row("power", "\(hardware.powerSource.rawValue), Low Power Mode \(hardware.lowPowerMode ? "on" : "off"), "
            + "thermal \(hardware.thermalState.rawValue)")
        row("settings", "graphics " + (snapshot.settings.graphics?.rawValue ?? "recommended")
            + ", HUD \(snapshot.settings.performanceHUD)"
            + (snapshot.settings.developmentRuntimePath == nil ? "" : ", development engine set"))
        row("login", snapshot.setup.loginMode.rawValue)
        for track in SetupPresentation.tracks {
            let state = snapshot.setup[track]
            var text = "\(state.status.rawValue) at \(state.step.rawValue), attempts \(state.attempts)"
            if let action = state.action { text += ", waiting for \(action.rawValue)" }
            if let failure = state.failure { text += ", failed (\(failure.kind.rawValue)): \(failure.message)" }
            row("setup.\(track.rawValue)", text)
        }
        if let runtime = snapshot.runtime {
            row("runtime", "\(runtime.id) \(runtime.version) channel \(runtime.channel.rawValue)"
                + (runtime.development ? " (development)" : "") + " at \(runtime.hostPath)")
        } else {
            row("runtime", "none")
        }
        row("steam", "installed \(snapshot.steam.installed), running \(snapshot.steam.running), "
            + "signed in \(snapshot.steam.signedIn)")
        if let content = snapshot.content {
            row("content", "\(content.state.rawValue)"
                + (content.lastUpdate.map { ", last update \($0.formatted(.iso8601))" } ?? "")
                + (content.libraryBytes.map { ", \(Formatting.bytes($0, locale: Locale(identifier: "en_US_POSIX")))" } ?? ""))
        }
        if case .finished(let checks, let date) = snapshot.doctor {
            row("doctor", date.formatted(.iso8601))
            for check in checks {
                lines.append("  \(check.passed ? "PASS" : "FAIL")  \(check.id): \(check.detail)")
            }
        }
        if let session = snapshot.lastSession {
            row("last session", (session.seconds.map { "\(Int($0)) s" } ?? "did not start")
                + (session.problems.isEmpty ? "" : ", problems: " + session.problems.map(\.rawValue).joined(separator: ", "))
                + (session.failure.map { ", \($0)" } ?? ""))
        }

        let logNames = ((try? FileManager.default.contentsOfDirectory(atPath: logDirectory.plainPath)) ?? [])
            .filter { $0.hasSuffix(".log") }.sorted()
        for name in logNames {
            lines.append("")
            lines.append("== \(name) (last \(logLinesKept) lines) ==")
            lines.append(contentsOf: tail(of: logDirectory.appending(path: name)))
        }
        let redactor = Redactor(home: home.plainPath, userName: userName)
        return redactor.redact(lines.joined(separator: "\n")) + "\n"
    }

    static func tail(of url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(logTailBytes) ? size - UInt64(logTailBytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        return Array(lines.suffix(logLinesKept))
    }
}
