import Foundation

/// Download progress of DE's ContentUpdate applet, folded from log events. The launcher's bulk download before it
/// logs no counters, so that phase is measured by folder size instead.
public struct ContentProgress: Equatable, Sendable {
    /// The applet's latest "Downloaded x/y" byte counter (Preprocess.log, mirrored into Launcher.log).
    public var launcherDownloaded: Int64?
    public var launcherTotal: Int64?
    /// Preprocess.log's "N assets to download": the applet has work, before its byte counters start.
    public var assetsTotal: Int?
    public var preprocessFinished = false
    public var wastedCacheBytes: Int64?
    public var corruptionReported = false

    public init() {}

    public mutating func apply(_ event: ContentEvent) {
        switch event {
        case .launcherDownloaded(let downloaded, let total):
            launcherDownloaded = downloaded
            launcherTotal = total
        case .assetsToDownload(let count):
            assetsTotal = count
            preprocessFinished = false
        case .preprocessDone:
            preprocessFinished = true
        case .wastedCacheSpace(let bytes, _):
            wastedCacheBytes = bytes
        case .downloadCorrupted:
            corruptionReported = true
        case .logRestarted:
            self = ContentProgress()
        default:
            break
        }
    }

    /// 0…1 for whichever download is under way, or nil while there is nothing to measure.
    public var fraction: Double? {
        if preprocessFinished || assetsTotal == 0 { return 1 }
        // Bytes first: the applet reports them while it downloads.
        if let launcherDownloaded, let launcherTotal, launcherTotal > 0 {
            return min(1, Double(launcherDownloaded) / Double(launcherTotal))
        }
        return assetsTotal == nil ? nil : 0
    }
}
