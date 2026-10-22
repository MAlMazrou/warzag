import Foundation
import GameKit
import WarzagCore

/// How far a long step has got: bytes (with a total when known) or a plain fraction, plus speed and time left.
struct ProgressSnapshot: Equatable, Sendable {
    var completed: Int64?
    var total: Int64?
    /// The total is an expected size (the game's Steam depot), not a number the download reported.
    var totalIsEstimate = false
    /// 0…1 when progress is not in bytes (DE's ContentUpdate applet).
    var fraction: Double?
    var bytesPerSecond: Double?
    /// Filled in by the model from the speed.
    var secondsRemaining: Double?

    static func bytes(_ completed: Int64, of total: Int64?, estimate: Bool = false,
                      bytesPerSecond: Double? = nil) -> ProgressSnapshot {
        ProgressSnapshot(completed: completed, total: total, totalIsEstimate: estimate, bytesPerSecond: bytesPerSecond)
    }

    /// For the bar. An estimated total never shows as finished: DE's launcher says when it is done.
    var displayFraction: Double? {
        if let fraction { return min(max(fraction, 0), 1) }
        guard let completed, let total, total > 0 else { return nil }
        let value = Double(completed) / Double(total)
        return min(max(value, 0), totalIsEstimate ? 0.99 : 1)
    }
}

/// What a running step is doing right now, beyond its title.
enum ActivityDetail: Equatable, Sendable {
    case downloadingInstaller
    case checkingInstaller
    case extractingInstaller
    case startingLauncher(restart: Int)
    case waitingForEULA
    /// DE's launcher went quiet at its start: it probably shows its EULA (a guess).
    case maybeWaitingForEULA
    case downloadingGame
    case preparingGameFiles
    case finishing
    case restartingLauncher(attempt: Int, stalled: Bool)
    case closingLauncher
    /// The engine from the release page: its signed manifest, the pack's download, its checks, the switch.
    case checkingForEngine
    case downloadingEngine
    case verifyingEngine
    case installingEngine
    case registeringEngine
    case settingUpWindows
    case installingSteam
    case startingSteam
    case checkingLicense
}

/// Something only the player can do while a step keeps running, in another app's window.
enum Attention: Equatable, Sendable {
    /// DE's launcher shows its EULA; the player reads it and clicks I AGREE there. Warzag never accepts it.
    case acceptEULAInDEWindow
    /// DE's launcher went quiet at its start and probably shows its EULA; said more softly, since it is a guess.
    case maybeAcceptEULAInDEWindow
}

/// The live state of a track's running step, reported by performers and shown under the step's row.
struct TrackActivity: Equatable, Sendable {
    var detail: ActivityDetail
    var progress: ProgressSnapshot?
    var attention: Attention?

    init(detail: ActivityDetail, progress: ProgressSnapshot? = nil, attention: Attention? = nil) {
        self.detail = detail
        self.progress = progress
        self.attention = attention
    }

    /// GameKit's content progress as the UI shows it; nil when there is nothing more to say than the step title.
    init?(_ state: ContentRunState) {
        switch state {
        case .downloadingInstaller(let received, let total):
            self.init(detail: .downloadingInstaller, progress: .bytes(received, of: total))
        case .checkingInstaller, .installerChecked:
            self.init(detail: .checkingInstaller)
        case .extractingInstaller:
            self.init(detail: .extractingInstaller)
        case .startingLauncher(let attempt):
            self.init(detail: .startingLauncher(restart: attempt))
        case .needsEULA:
            self.init(detail: .waitingForEULA, attention: .acceptEULAInDEWindow)
        case .mayNeedEULA:
            self.init(detail: .maybeWaitingForEULA, attention: .maybeAcceptEULAInDEWindow)
        case .downloading(let bytesThisRun, let bytesOnDisk, let expected, let rate):
            // A first install counts the whole library against a complete install; an update has no known size, so
            // it shows what this run added. DE's "MB/s" is decimal megabytes.
            self.init(detail: .downloadingGame,
                      progress: .bytes(expected == nil ? bytesThisRun : bytesOnDisk, of: expected, estimate: true,
                                       bytesPerSecond: rate.map { $0 * 1_000_000 }))
        case .preprocessing(let fraction):
            self.init(detail: .preparingGameFiles, progress: fraction.map { ProgressSnapshot(fraction: $0) })
        case .finishing, .complete:
            self.init(detail: .finishing)
        case .restartingLauncher(let attempt, let reason):
            self.init(detail: .restartingLauncher(attempt: attempt, stalled: reason == .stalled))
        case .closingLauncher:
            self.init(detail: .closingLauncher)
        case .stuck, .warning:
            // A stuck launcher ends the step (the failure says so); a passed tool deadline is only logged.
            return nil
        }
    }
}

struct ActivityUpdate: Equatable, Sendable {
    var track: SetupTrack
    var activity: TrackActivity?
}

/// Where performers and services report live progress; the model reads `updates` on the main actor, in order.
final class ActivitySink: Sendable {
    let updates: AsyncStream<ActivityUpdate>
    private let continuation: AsyncStream<ActivityUpdate>.Continuation

    init() {
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(512))
    }

    func report(_ track: SetupTrack, _ activity: TrackActivity?) {
        continuation.yield(ActivityUpdate(track: track, activity: activity))
    }

    func finish() { continuation.finish() }
}

/// Download speed from successive byte counts when the source reports none (Warframe.msi), smoothed over about
/// ten seconds, and the time left from it.
struct RateEstimator: Equatable, Sendable {
    private var lastBytes: Int64?
    private var lastTime: Date?
    private(set) var bytesPerSecond: Double?
    /// Weight of a new one-second sample.
    static let smoothing = 0.1

    /// Adds a sample; returns the smoothed speed (nil until two samples at least half a second apart).
    mutating func add(bytes: Int64, at time: Date) -> Double? {
        guard let lastBytes, let lastTime else {
            record(bytes, time)
            return bytesPerSecond
        }
        if bytes < lastBytes {
            // A new download started over.
            bytesPerSecond = nil
            record(bytes, time)
            return nil
        }
        let interval = time.timeIntervalSince(lastTime)
        guard interval >= 0.5 else { return bytesPerSecond }
        let sample = Double(bytes - lastBytes) / interval
        let weight = min(1, Self.smoothing * interval)
        bytesPerSecond = bytesPerSecond.map { $0 + (sample - $0) * weight } ?? sample
        record(bytes, time)
        return bytesPerSecond
    }

    private mutating func record(_ bytes: Int64, _ time: Date) {
        lastBytes = bytes
        lastTime = time
    }

    static func secondsRemaining(_ progress: ProgressSnapshot) -> Double? {
        guard let rate = progress.bytesPerSecond, rate > 1, let completed = progress.completed,
              let total = progress.total, total > completed else { return nil }
        return Double(total - completed) / rate
    }
}
