import Foundation

/// Performance tier of a Mac; it picks the graphics preset.
public enum PerformanceTier: String, Codable, Sendable, CaseIterable, Comparable {
    /// Base chip in a fanless MacBook Air: thermals and bandwidth limit everything.
    case t1 = "T1"
    /// Base chip with active cooling (Mac mini, iMac, base MacBook Pro).
    case t2 = "T2"
    /// Pro chips.
    case t3 = "T3"
    /// Max and Ultra chips.
    case t4 = "T4"

    public static func < (lhs: PerformanceTier, rhs: PerformanceTier) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// The variant of an Apple silicon chip, read from its brand string.
public enum ChipClass: String, Codable, Sendable {
    case base, pro, max, ultra, unknown

    /// "Apple M2" -> base, "Apple M3 Pro" -> pro, "Apple M4 Max" -> max, "Apple M2 Ultra" -> ultra.
    public init(brand: String) {
        let words = brand.split(separator: " ")
        guard words.count >= 2, words[0] == "Apple", words[1].count > 1, words[1].first == "M",
              words[1].dropFirst().allSatisfy(\.isNumber) else {
            self = .unknown
            return
        }
        switch words.count {
        case 2: self = .base
        case 3:
            switch words[2] {
            case "Pro": self = .pro
            case "Max": self = .max
            case "Ultra": self = .ultra
            default: self = .unknown
            }
        default: self = .unknown
        }
    }
}

public struct TierClassification: Codable, Equatable, Sendable {
    public var tier: PerformanceTier
    /// The 8 GB overlay: low textures and particles on any tier.
    public var lowMemory: Bool
    public var fanless: Bool
    /// One sentence on why, for `warzagctl profile` and diagnostics.
    public var reason: String

    public init(tier: PerformanceTier, lowMemory: Bool, fanless: Bool, reason: String) {
        self.tier = tier
        self.lowMemory = lowMemory
        self.fanless = fanless
        self.reason = reason
    }
}

public enum TierClassifier {
    /// Macs at or below this much memory get the low-memory overlay.
    public static let lowMemoryThresholdGB = 8
    /// GPU core counts that stand in for the chip class when the brand string is not recognised.
    public static let proGPUCores = 14
    public static let maxGPUCores = 24

    public static func classify(_ hardware: HardwareProfile) -> TierClassification {
        let lowMemory = hardware.memoryGB <= lowMemoryThresholdGB
        let fanless = hardware.isFanless
        let chipClass = ChipClass(brand: hardware.chip)
        let tier: PerformanceTier
        let reason: String
        switch chipClass {
        case .max, .ultra:
            tier = .t4
            reason = "\(hardware.chip): Max/Ultra chip"
        case .pro:
            tier = .t3
            reason = "\(hardware.chip): Pro chip"
        case .base:
            tier = fanless ? .t1 : .t2
            reason = "\(hardware.chip): base chip, " + (fanless ? "fanless" : "actively cooled")
        case .unknown:
            // An unrecognised chip is placed by its GPU core count; without one, it counts as a base chip.
            if let gpu = hardware.gpuCores, gpu >= maxGPUCores {
                tier = .t4
                reason = "\(hardware.chip): \(gpu) GPU cores"
            } else if let gpu = hardware.gpuCores, gpu >= proGPUCores {
                tier = .t3
                reason = "\(hardware.chip): \(gpu) GPU cores"
            } else {
                tier = fanless ? .t1 : .t2
                reason = "\(hardware.chip): unrecognised chip, treated as a base chip"
            }
        }
        return TierClassification(
            tier: tier, lowMemory: lowMemory, fanless: fanless,
            reason: reason + (lowMemory ? "; \(hardware.memoryGB) GB memory overlay" : "")
        )
    }
}

extension HardwareProfile {
    public var tierClassification: TierClassification { TierClassifier.classify(self) }
}
