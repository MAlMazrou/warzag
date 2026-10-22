import Foundation
import ProfileKit
import WarzagCore

/// One thing about the Mac's power state worth telling the player before Play: its kind and the values it is about, so
/// the app writes its own localised sentence; `message` is the English one `warzagctl play` prints.
public struct PowerAdvice: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case lowPowerMode
        case battery
        case thermal
        /// An adapter is connected but supplies less than `PowerAdvisor.minimumAdapterWatts`.
        case weakCharger
        /// The battery is below `PowerAdvisor.lowBatteryPercent`, whatever adapter is connected.
        case lowBattery
    }

    public var kind: Kind
    /// The frame cap Warzag holds Warframe to because of this (ProfileKit's `FramePacing`), when it lowers the cap.
    public var frameRateCap: Int?
    /// weakCharger: what the connected adapter supplies.
    public var adapterWatts: Int?
    /// weakCharger: what a game needs from it (the Mac's own charger supplies at least this).
    public var recommendedWatts: Int?
    /// lowBattery: the battery's charge in percent.
    public var batteryPercent: Int?
    /// thermal: how hot the Mac is.
    public var thermalState: ThermalState?

    public init(kind: Kind, frameRateCap: Int? = nil, adapterWatts: Int? = nil, recommendedWatts: Int? = nil,
                batteryPercent: Int? = nil, thermalState: ThermalState? = nil) {
        self.kind = kind
        self.frameRateCap = frameRateCap
        self.adapterWatts = adapterWatts
        self.recommendedWatts = recommendedWatts
        self.batteryPercent = batteryPercent
        self.thermalState = thermalState
    }

    /// English, for `warzagctl play`.
    public var message: String {
        let cap = frameRateCap ?? FramePacing.coolCap
        switch kind {
        case .lowPowerMode:
            return "Low Power Mode is on: Warframe will be held to \(cap) fps and may stutter. Turn it off in System "
                + "Settings > Battery for the best experience."
        case .battery:
            return frameRateCap.map {
                "Running on battery: Warzag holds Warframe to \($0) fps on this fanless Mac to keep it cool. Plug in for "
                    + "60 fps."
            } ?? "Running on battery: Warframe runs best plugged in."
        case .thermal:
            return "The Mac is hot (thermal state \((thermalState ?? .serious).rawValue)): Warframe will be held to \(cap) "
                + "fps until it cools down."
        case .weakCharger:
            return "The charger supplies only \(adapterWatts ?? 0) W. Warframe needs about 20-30 W, so the battery "
                + "drains while you play and the Mac slows down when it gets low. Use the Mac's own charger "
                + "(\(recommendedWatts ?? PowerAdvisor.minimumAdapterWatts) W or more)."
        case .lowBattery:
            return "The battery is at \(batteryPercent ?? 0)%. When it is nearly empty, macOS slows the Mac down and "
                + "Warframe stutters: charge it, or plug in the Mac's own charger."
        }
    }
}

/// Reads Low Power Mode, the power source, the adapter's watts, the battery's charge and the thermal state, and says
/// before Play what they will do to the game. The advice matches the frame cap that ProfileKit's `FramePacing` sets.
public struct PowerAdvisor: Sendable {
    /// A weaker adapter cannot keep up with Warframe's draw (about 20-30 W), and the battery drains while playing.
    public static let minimumAdapterWatts = 30
    /// Below this the battery is close to the level where macOS throttles hard.
    public static let lowBatteryPercent = 20

    public let system: any SystemInfoProviding

    public init(system: any SystemInfoProviding = LiveSystemInfo()) {
        self.system = system
    }

    /// Desktops (no battery) get no charger or battery advice, and an adapter that does not report its wattage gets no
    /// charger advice. A battery under `lowBatteryPercent` is called out whatever the charger: under a game's load even
    /// a 30 W or stronger adapter may not keep up.
    public func advice(for tier: PerformanceTier) -> [PowerAdvice] {
        var advice: [PowerAdvice] = []
        let cap = FramePacing.coolCap
        if system.isLowPowerModeEnabled {
            advice.append(PowerAdvice(kind: .lowPowerMode, frameRateCap: cap))
        }
        if system.powerSource == .battery {
            advice.append(PowerAdvice(kind: .battery, frameRateCap: tier == .t1 ? cap : nil))
        }
        if let battery = system.batteryPercent {
            if let watts = system.powerAdapterWatts, watts < Self.minimumAdapterWatts {
                advice.append(PowerAdvice(kind: .weakCharger, adapterWatts: watts,
                                          recommendedWatts: Self.minimumAdapterWatts))
            }
            if battery < Self.lowBatteryPercent {
                advice.append(PowerAdvice(kind: .lowBattery, batteryPercent: battery))
            }
        }
        let thermal = system.thermalState
        if thermal >= .serious {
            advice.append(PowerAdvice(kind: .thermal, frameRateCap: cap, thermalState: thermal))
        }
        return advice
    }
}
