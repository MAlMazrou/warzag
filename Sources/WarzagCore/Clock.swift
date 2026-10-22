import Foundation

/// Time side effects: what time it is, and waiting. Named to stay clear of the standard library's `Clock`.
public protocol WallClock: Sendable {
    var now: Date { get }
    func sleep(for duration: Duration) async throws
}

public struct SystemClock: WallClock {
    public init() {}

    public var now: Date { Date() }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
