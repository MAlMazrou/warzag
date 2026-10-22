import Foundation
import Synchronization
import WarzagCore

/// Records every command instead of running it; a handler decides each result.
public final class RecordingProcessRunner: ProcessRunning {
    public typealias Handler = @Sendable (Command) throws -> ProcessOutput

    private let recorded = Mutex<[Command]>([])
    private let handler: Handler

    public init(handler: @escaping Handler = { _ in ProcessOutput(exitCode: 0) }) {
        self.handler = handler
    }

    public func run(_ command: Command) async throws -> ProcessOutput {
        recorded.withLock { $0.append(command) }
        return try handler(command)
    }

    public var commands: [Command] { recorded.withLock { $0 } }

    /// Each command as `basename arg1 arg2 …`, for compact assertions.
    public var commandLines: [String] {
        commands.map { ([$0.executable.lastPathComponent] + $0.arguments).joined(separator: " ") }
    }
}

/// A clock whose sleeps return at once and advance `now`, so back-offs run instantly but stay observable.
public final class ManualClock: WallClock {
    private struct State {
        var now: Date
        var sleeps: [Duration] = []
    }

    private let state: Mutex<State>

    public init(now: Date = Date(timeIntervalSince1970: 1_792_000_000)) {
        state = Mutex(State(now: now))
    }

    public var now: Date { state.withLock { $0.now } }
    public var sleeps: [Duration] { state.withLock { $0.sleeps } }

    public func advance(by interval: TimeInterval) {
        state.withLock { $0.now = $0.now.addingTimeInterval(interval) }
    }

    public func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        state.withLock {
            $0.sleeps.append(duration)
            $0.now = $0.now.addingTimeInterval(Double(duration.components.seconds)
                + Double(duration.components.attoseconds) / 1e18)
        }
        await Task.yield()
    }
}

/// Serves canned responses; downloads are written into a (usually in-memory) file system.
public final class FakeHTTPClient: HTTPClient {
    private struct State {
        var responses: [URL: Result<Data, HTTPError>] = [:]
        var requests: [URL] = []
    }

    private let state = Mutex(State())
    private let fileSystem: (any FileSystem)?

    public init(fileSystem: (any FileSystem)? = nil) {
        self.fileSystem = fileSystem
    }

    public func respond(to url: URL, with data: Data) {
        state.withLock { $0.responses[url] = .success(data) }
    }

    public func fail(_ url: URL, status: Int = 404) {
        state.withLock { $0.responses[url] = .failure(.status(status, url)) }
    }

    public var requests: [URL] { state.withLock { $0.requests } }

    public func data(from url: URL) async throws -> Data {
        let response = state.withLock {
            $0.requests.append(url)
            return $0.responses[url]
        }
        guard let response else { throw HTTPError.status(404, url) }
        return try response.get()
    }

    public func download(from url: URL, to destination: URL) async throws {
        let data = try await data(from: url)
        guard let fileSystem else { fatalError("FakeHTTPClient needs a file system for downloads") }
        try fileSystem.writeAtomically(data, to: destination)
    }
}

/// A process table for tests.
public struct FakeProcessInspector: ProcessInspecting {
    public struct Entry: Sendable {
        public var path: String
        public var start: Date?

        public init(path: String, start: Date?) {
            self.path = path
            self.start = start
        }
    }

    public var processes: [Int32: Entry]

    public init(_ processes: [Int32: Entry] = [:]) {
        self.processes = processes
    }

    public func isAlive(_ pid: Int32) -> Bool { processes[pid] != nil }
    public func executablePath(of pid: Int32) -> String? { processes[pid]?.path }
    public func startDate(of pid: Int32) -> Date? { processes[pid]?.start }
    public func processIdentifiers() -> [Int32] { processes.keys.sorted() }
}

/// sysctl, IOKit and ProcessInfo values for an imaginary Mac.
public struct FakeSystemInfo: SystemInfoProviding {
    public var strings: [String: String]
    public var integers: [String: Int64]
    public var gpuCoreCount: Int?
    public var productName: String?
    public var isLowPowerModeEnabled = false
    public var thermalState = ThermalState.nominal
    public var powerSource = PowerSource.ac
    /// nil: no adapter connected, or one that does not say.
    public var powerAdapterWatts: Int?
    /// nil: a Mac without a battery.
    public var batteryPercent: Int?
    public var operatingSystemVersion = OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 1)

    public init(strings: [String: String], integers: [String: Int64], gpuCoreCount: Int?, productName: String?) {
        self.strings = strings
        self.integers = integers
        self.gpuCoreCount = gpuCoreCount
        self.productName = productName
    }

    /// An Apple silicon Mac with two performance levels.
    public static func mac(chip: String, model: String, product: String?, performanceCores: Int,
                           efficiencyCores: Int, gpuCores: Int?, memoryGB: Int) -> FakeSystemInfo {
        FakeSystemInfo(
            strings: ["machdep.cpu.brand_string": chip, "hw.model": model],
            integers: [
                "hw.nperflevels": 2,
                "hw.perflevel0.physicalcpu": Int64(performanceCores),
                "hw.perflevel1.physicalcpu": Int64(efficiencyCores),
                "hw.memsize": Int64(memoryGB) << 30,
                "hw.optional.arm64": 1,
            ],
            gpuCoreCount: gpuCores,
            productName: product
        )
    }

    public func string(sysctl name: String) -> String? { strings[name] }
    public func integer(sysctl name: String) -> Int64? { integers[name] }
}
