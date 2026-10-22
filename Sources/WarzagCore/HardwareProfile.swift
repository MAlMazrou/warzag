import Darwin
import Foundation
import IOKit
import IOKit.ps

public enum ThermalState: String, Codable, Sendable, Comparable, CaseIterable {
    case nominal, fair, serious, critical

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }

    public static func < (lhs: ThermalState, rhs: ThermalState) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

public enum PowerSource: String, Codable, Sendable {
    case ac, battery, unknown
}

/// The Mac as performance tiers see it.
public struct HardwareProfile: Codable, Equatable, Sendable {
    /// `machdep.cpu.brand_string`, for example "Apple M2" or "Apple M3 Pro".
    public var chip: String
    /// `hw.model`, for example "Mac14,15".
    public var modelIdentifier: String
    /// Marketing name from the device tree, for example "MacBook Air (15-inch, M2, 2023)".
    public var productName: String?
    public var performanceCores: Int
    public var efficiencyCores: Int
    public var gpuCores: Int?
    public var memoryGB: Int
    public var isAppleSilicon: Bool
    public var macOSVersion: String
    public var lowPowerMode: Bool
    public var thermalState: ThermalState
    public var powerSource: PowerSource

    public init(
        chip: String, modelIdentifier: String, productName: String? = nil,
        performanceCores: Int, efficiencyCores: Int, gpuCores: Int?, memoryGB: Int,
        isAppleSilicon: Bool = true, macOSVersion: String = "26.0",
        lowPowerMode: Bool = false, thermalState: ThermalState = .nominal, powerSource: PowerSource = .ac
    ) {
        self.chip = chip
        self.modelIdentifier = modelIdentifier
        self.productName = productName
        self.performanceCores = performanceCores
        self.efficiencyCores = efficiencyCores
        self.gpuCores = gpuCores
        self.memoryGB = memoryGB
        self.isAppleSilicon = isAppleSilicon
        self.macOSVersion = macOSVersion
        self.lowPowerMode = lowPowerMode
        self.thermalState = thermalState
        self.powerSource = powerSource
    }

    /// Apple silicon MacBook Airs are the only fanless Macs. Newer models report "MacXX,YY" identifiers, so the
    /// product name and a table of known Air identifiers back up the old "MacBookAir" prefix.
    public var isFanless: Bool {
        modelIdentifier.hasPrefix("MacBookAir")
            || productName?.hasPrefix("MacBook Air") == true
            || Self.fanlessModelIdentifiers.contains(modelIdentifier)
    }

    static let fanlessModelIdentifiers: Set<String> = [
        "Mac14,2", "Mac14,15",   // M2, 13- and 15-inch
        "Mac15,12", "Mac15,13",  // M3
        "Mac16,12", "Mac16,13",  // M4
    ]

    public static func detect(using system: some SystemInfoProviding = LiveSystemInfo()) -> HardwareProfile {
        let levels = system.integer(sysctl: "hw.nperflevels") ?? 1
        let performance = system.integer(sysctl: "hw.perflevel0.physicalcpu")
            ?? system.integer(sysctl: "hw.physicalcpu") ?? 0
        let efficiency = levels > 1 ? system.integer(sysctl: "hw.perflevel1.physicalcpu") ?? 0 : 0
        let bytes = system.integer(sysctl: "hw.memsize") ?? 0
        let os = system.operatingSystemVersion
        return HardwareProfile(
            chip: system.string(sysctl: "machdep.cpu.brand_string") ?? "unknown",
            modelIdentifier: system.string(sysctl: "hw.model") ?? "unknown",
            productName: system.productName,
            performanceCores: Int(performance),
            efficiencyCores: Int(efficiency),
            gpuCores: system.gpuCoreCount,
            memoryGB: Int((Double(bytes) / 1_073_741_824).rounded()),
            isAppleSilicon: system.integer(sysctl: "hw.optional.arm64") == 1,
            // Formatted as sw_vers does: "26.5.1", but "14.7" rather than "14.7.0".
            macOSVersion: "\(os.majorVersion).\(os.minorVersion)" + (os.patchVersion == 0 ? "" : ".\(os.patchVersion)"),
            lowPowerMode: system.isLowPowerModeEnabled,
            thermalState: system.thermalState,
            powerSource: system.powerSource
        )
    }
}

/// Where hardware facts come from: sysctl, IOKit and ProcessInfo on a real Mac, a fake in tests.
public protocol SystemInfoProviding: Sendable {
    func string(sysctl name: String) -> String?
    func integer(sysctl name: String) -> Int64?
    var gpuCoreCount: Int? { get }
    var productName: String? { get }
    var isLowPowerModeEnabled: Bool { get }
    var thermalState: ThermalState { get }
    var powerSource: PowerSource { get }
    /// What the connected power adapter supplies, in watts; nil when none is connected or it does not say.
    var powerAdapterWatts: Int? { get }
    /// The internal battery's charge in percent; nil on a Mac without a battery.
    var batteryPercent: Int? { get }
    var operatingSystemVersion: OperatingSystemVersion { get }
}

public struct LiveSystemInfo: SystemInfoProviding {
    public init() {}

    public func string(sysctl name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public func integer(sysctl name: String) -> Int64? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
        switch size {
        case MemoryLayout<Int32>.size:
            var value: Int32 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return Int64(value)
        case MemoryLayout<Int64>.size:
            var value: Int64 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return value
        default:
            return nil
        }
    }

    /// `gpu-core-count` of the AGX accelerator (Apple GPUs only).
    public var gpuCoreCount: Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"), &iterator)
            == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service) }
            if let value = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString,
                                                           kCFAllocatorDefault, 0)?.takeRetainedValue(),
               let count = (value as? NSNumber)?.intValue {
                return count
            }
            service = IOIteratorNext(iterator)
        }
        return nil
    }

    public var productName: String? {
        let product = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard product != 0 else { return nil }
        defer { IOObjectRelease(product) }
        guard let data = IORegistryEntryCreateCFProperty(product, "product-name" as CFString,
                                                         kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data
        else { return nil }
        let name = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        return name.isEmpty ? nil : name
    }

    public var isLowPowerModeEnabled: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
    public var thermalState: ThermalState { ThermalState(ProcessInfo.processInfo.thermalState) }
    public var operatingSystemVersion: OperatingSystemVersion { ProcessInfo.processInfo.operatingSystemVersion }

    public var powerSource: PowerSource {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else { return .unknown }
        switch type {
        case kIOPMACPowerKey: return .ac
        case kIOPMBatteryPowerKey: return .battery
        default: return .unknown
        }
    }

    /// `kIOPSPowerAdapterWattsKey` of `IOPSCopyExternalPowerAdapterDetails` (what `system_profiler SPPowerDataType`
    /// shows as "Wattage (W)").
    public var powerAdapterWatts: Int? {
        guard let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any],
              let watts = (details[kIOPSPowerAdapterWattsKey] as? NSNumber)?.intValue, watts > 0 else { return nil }
        return watts
    }

    /// Current over maximum capacity of the internal battery among IOKit's power sources.
    public var batteryPercent: Int? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue,
                  let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue, maximum > 0
            else { continue }
            return min(100, max(0, Int((current * 100 / maximum).rounded())))
        }
        return nil
    }
}
