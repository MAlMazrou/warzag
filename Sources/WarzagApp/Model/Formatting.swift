import Foundation

/// Numbers as the UI shows them, with the system's formatters (decimal units, like Finder).
enum Formatting {
    /// "23.4 GB", "120 MB".
    static func bytes(_ count: Int64, locale: Locale = .current) -> String {
        let style = ByteCountFormatStyle(style: .file, allowedUnits: .all, spellsOutZero: false,
                                         includesActualByteCount: false, locale: locale)
        return Int64(max(0, count)).formatted(style)
    }

    /// "47 MB/s".
    static func rate(_ bytesPerSecond: Double, locale: Locale = .current) -> String {
        L10n.perSecond(bytes(Int64(bytesPerSecond.rounded()), locale: locale))
    }

    /// "12 min", "1 hr, 5 min", "40 sec".
    static func duration(_ seconds: Double, locale: Locale = .current) -> String {
        let rounded = seconds >= 120 ? (seconds / 60).rounded() * 60 : max(1, seconds.rounded())
        let units: Set<Duration.UnitsFormatStyle.Unit> = rounded >= 3600 ? [.hours, .minutes]
            : rounded >= 60 ? [.minutes] : [.seconds]
        return Duration.seconds(rounded).formatted(.units(allowed: units, width: .abbreviated).locale(locale))
    }

    /// The progress line of a byte download: "23.4 GB of 55.7 GB · 47 MB/s · about 12 min left". Parts that are not
    /// known are left out; an estimated total reads "of about 55.7 GB".
    static func progressLine(_ progress: ProgressSnapshot, locale: Locale = .current) -> String? {
        var parts: [String] = []
        if let completed = progress.completed {
            if let total = progress.total, total > 0 {
                let done = bytes(min(completed, total), locale: locale)
                let all = bytes(total, locale: locale)
                parts.append(progress.totalIsEstimate ? L10n.bytesOfAbout(done, all) : L10n.bytesOf(done, all))
            } else {
                parts.append(bytes(completed, locale: locale))
            }
        } else if let fraction = progress.fraction {
            parts.append(percent(fraction, locale: locale))
        }
        if let rate = progress.bytesPerSecond, rate > 0 {
            parts.append(Self.rate(rate, locale: locale))
        }
        if let remaining = progress.secondsRemaining, remaining > 0 {
            parts.append(L10n.timeLeft(duration(remaining, locale: locale)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The same for VoiceOver: "23.4 GB of 55.7 GB, 47 MB/s, about 12 min left".
    static func accessibilityProgress(_ progress: ProgressSnapshot, locale: Locale = .current) -> String? {
        progressLine(progress, locale: locale)?.replacingOccurrences(of: " · ", with: ", ")
    }

    /// "8 W".
    static func watts(_ watts: Int, locale: Locale = .current) -> String {
        Measurement(value: Double(watts), unit: UnitPower.watts)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided).locale(locale))
    }

    /// "42%".
    static func percent(_ fraction: Double, locale: Locale = .current) -> String {
        min(max(fraction, 0), 1).formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    /// "2 hours ago"; "just now" under a minute (the formatter would say "in 0 seconds").
    static func relative(_ date: Date, to now: Date, locale: Locale = .current) -> String {
        if abs(now.timeIntervalSince(date)) < 60 { return L10n.justNow }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }

    /// "October 20, 2026": a day with no time of day (a release's), the same in every time zone.
    static func day(_ day: DateComponents, locale: Locale = .current) -> String? {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = .gmt
        guard let date = gregorian.date(from: day) else { return nil }
        return date.formatted(Date.FormatStyle(date: .long, time: .omitted, locale: locale, calendar: locale.calendar,
                                               timeZone: .gmt))
    }

    /// "12:04" for a running session's elapsed time, "1:02:03" past an hour.
    static func elapsed(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}
