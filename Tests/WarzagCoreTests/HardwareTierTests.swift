import Foundation
import Testing
import WarzagTestSupport
@testable import WarzagCore

@Suite struct HardwareTierTests {
    /// A MacBook Air 15" M2 with 24 GB.
    static let m2Air = FakeSystemInfo.mac(chip: "Apple M2", model: "Mac14,15", product: "MacBook Air (15-inch, M2, 2023)",
                                           performanceCores: 4, efficiencyCores: 4, gpuCores: 10, memoryGB: 24)

    @Test func detectsEveryFieldThroughTheProvider() {
        var system = Self.m2Air
        system.isLowPowerModeEnabled = true
        system.thermalState = .fair
        system.powerSource = .battery
        let profile = HardwareProfile.detect(using: system)
        #expect(profile == HardwareProfile(
            chip: "Apple M2", modelIdentifier: "Mac14,15", productName: "MacBook Air (15-inch, M2, 2023)",
            performanceCores: 4, efficiencyCores: 4, gpuCores: 10, memoryGB: 24, isAppleSilicon: true,
            macOSVersion: "26.5.1", lowPowerMode: true, thermalState: .fair, powerSource: .battery
        ))
        #expect(profile.isFanless)
        #expect(profile.tierClassification == TierClassification(
            tier: .t1, lowMemory: false, fanless: true, reason: "Apple M2: base chip, fanless"))
    }

    @Test func intelLikeMachineWithoutPerformanceLevels() {
        let system = FakeSystemInfo(
            strings: ["machdep.cpu.brand_string": "Intel(R) Core(TM) i7", "hw.model": "MacBookPro16,1"],
            integers: ["hw.physicalcpu": 8, "hw.memsize": 16 << 30],
            gpuCoreCount: nil, productName: nil)
        let profile = HardwareProfile.detect(using: system)
        #expect(profile.performanceCores == 8)
        #expect(profile.efficiencyCores == 0)
        #expect(!profile.isAppleSilicon)
        #expect(profile.memoryGB == 16)
    }

    struct Case: Sendable, CustomTestStringConvertible {
        var chip: String
        var model: String
        var product: String?
        var gpu: Int?
        var memory: Int
        var tier: PerformanceTier
        var lowMemory: Bool
        var testDescription: String { "\(chip) \(model) \(memory) GB" }
    }

    @Test(arguments: [
        Case(chip: "Apple M1", model: "MacBookAir10,1", product: nil, gpu: 7, memory: 8, tier: .t1, lowMemory: true),
        Case(chip: "Apple M2", model: "Mac14,2", product: nil, gpu: 8, memory: 16, tier: .t1, lowMemory: false),
        Case(chip: "Apple M3", model: "Mac15,13", product: nil, gpu: 10, memory: 24, tier: .t1, lowMemory: false),
        Case(chip: "Apple M5", model: "Mac17,9", product: "MacBook Air (13-inch, M5, 2026)", gpu: 10, memory: 16,
             tier: .t1, lowMemory: false),
        Case(chip: "Apple M4", model: "Mac16,10", product: "Mac mini (2024)", gpu: 10, memory: 16, tier: .t2, lowMemory: false),
        Case(chip: "Apple M3", model: "Mac15,3", product: "MacBook Pro (14-inch, Nov 2023)", gpu: 10, memory: 8,
             tier: .t2, lowMemory: true),
        Case(chip: "Apple M3 Pro", model: "Mac15,6", product: nil, gpu: 18, memory: 18, tier: .t3, lowMemory: false),
        Case(chip: "Apple M4 Pro", model: "Mac16,11", product: "Mac mini (2024)", gpu: 16, memory: 24, tier: .t3, lowMemory: false),
        Case(chip: "Apple M2 Max", model: "Mac14,13", product: nil, gpu: 38, memory: 32, tier: .t4, lowMemory: false),
        Case(chip: "Apple M2 Ultra", model: "Mac14,14", product: nil, gpu: 76, memory: 64, tier: .t4, lowMemory: false),
        // Unrecognised chips are placed by GPU size, and by cooling without one.
        Case(chip: "Apple M9 Hyper", model: "Mac30,1", product: nil, gpu: 30, memory: 64, tier: .t4, lowMemory: false),
        Case(chip: "Apple M9 Hyper", model: "Mac30,1", product: nil, gpu: 16, memory: 32, tier: .t3, lowMemory: false),
        Case(chip: "Apple A18 Pro", model: "Mac17,1", product: "MacBook (13-inch, 2026)", gpu: 5, memory: 8,
             tier: .t2, lowMemory: true),
        Case(chip: "Apple M9 Hyper", model: "MacBookAir30,1", product: nil, gpu: nil, memory: 16, tier: .t1, lowMemory: false),
    ])
    func classification(_ c: Case) {
        let profile = HardwareProfile(chip: c.chip, modelIdentifier: c.model, productName: c.product, performanceCores: 4,
                                      efficiencyCores: 4, gpuCores: c.gpu, memoryGB: c.memory)
        let result = TierClassifier.classify(profile)
        #expect(result.tier == c.tier)
        #expect(result.lowMemory == c.lowMemory)
    }

    @Test(arguments: [
        ("Apple M1", ChipClass.base), ("Apple M10", .base), ("Apple M3 Pro", .pro), ("Apple M4 Max", .max),
        ("Apple M2 Ultra", .ultra), ("Apple M2 Turbo", .unknown), ("Apple A18 Pro", .unknown), ("Apple M", .unknown),
        ("Intel(R) Core(TM) i9", .unknown), ("", .unknown), ("Apple M3 Pro Max", .unknown),
    ])
    func chipClass(_ brand: String, _ expected: ChipClass) {
        #expect(ChipClass(brand: brand) == expected)
    }

    @Test func fanlessDetection() {
        func profile(_ model: String, _ product: String?) -> HardwareProfile {
            HardwareProfile(chip: "Apple M2", modelIdentifier: model, productName: product, performanceCores: 4,
                            efficiencyCores: 4, gpuCores: 8, memoryGB: 8)
        }
        #expect(profile("MacBookAir10,1", nil).isFanless)
        #expect(profile("Mac16,12", nil).isFanless)
        #expect(profile("Mac99,1", "MacBook Air (13-inch, M9, 2031)").isFanless)
        #expect(!profile("Mac14,7", "MacBook Pro (13-inch, M2, 2022)").isFanless)
        #expect(!profile("Mac14,3", "Mac mini (2023)").isFanless)
    }

    @Test func thermalStatesAreOrdered() {
        #expect(ThermalState.nominal < .fair)
        #expect(ThermalState.fair < .serious)
        #expect(ThermalState.serious < .critical)
        #expect(ThermalState(ProcessInfo.ThermalState.critical) == .critical)
    }

    /// Read-only IOKit queries; a desktop or an unplugged Mac answers nil.
    @Test func livePowerReadingsAreSane() {
        let system = LiveSystemInfo()
        if let percent = system.batteryPercent { #expect((0...100).contains(percent)) }
        if let watts = system.powerAdapterWatts { #expect(watts > 0) }
        #expect(FakeSystemInfo(strings: [:], integers: [:], gpuCoreCount: nil, productName: nil).batteryPercent == nil)
    }

    @Test func liveDetectionOnThisMacIsSane() {
        let profile = HardwareProfile.detect()
        #expect(profile.memoryGB > 0)
        #expect(profile.performanceCores > 0)
        #expect(!profile.chip.isEmpty)
        #expect(!profile.modelIdentifier.isEmpty)
    }
}
