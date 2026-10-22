// swift-tools-version: 6.0
// Warzag.app, warzagctl and the libraries they share. GPL-3.0; no third-party dependencies.
import PackageDescription

let package = Package(
    name: "Warzag",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "WarzagApp", targets: ["WarzagApp"]),
        .executable(name: "warzagctl", targets: ["warzagctl"]),
    ],
    targets: [
        // Paths, side-effect protocols, hardware tiers and the resumable first-run state machine.
        .target(name: "WarzagCore", linkerSettings: [.linkedFramework("IOKit")]),
        // Read-only detection of the user's native Mac Steam, plus installing/starting it when missing.
        .target(name: "SteamHostKit", dependencies: ["WarzagCore"]),
        // Signed runtime and app manifests and the on-disk runtime store (atomic activation, rollback to the previous
        // runtime).
        .target(name: "RuntimeKit", dependencies: ["WarzagCore"], linkerSettings: [.linkedFramework("Security")]),
        // Warzag's own updates: the signed app feed, the download and its checks, the swap the new app's helper makes,
        // and the changelog that says what each release changed.
        .target(name: "AppUpdateKit", dependencies: ["WarzagCore", "RuntimeKit"],
                linkerSettings: [.linkedFramework("Security")]),
        // Wine environments, .reg files and the prefix template, Wine tool invocations.
        .target(name: "WineKit", dependencies: ["WarzagCore"]),
        // Tailing and parsing Digital Extremes' own logs (Launcher.log, Preprocess.log, EE.log).
        .target(name: "ContentKit", dependencies: ["WarzagCore"]),
        // Per-tier graphics presets: frame cap, Retina mode, upscaler, EE.cfg seed (NVEXT off by default).
        .target(name: "ProfileKit", dependencies: ["WarzagCore"]),
        // Integration: runtime packs, prefix creation/repair, Steam bridge files.
        .target(name: "EngineKit", dependencies: ["WarzagCore", "RuntimeKit", "WineKit"]),
        // Integration: Warframe install/update through DE's tools, Play sessions and supervision.
        .target(name: "GameKit", dependencies: ["WarzagCore", "WineKit", "ContentKit", "SteamHostKit", "ProfileKit", "EngineKit"]),

        .executableTarget(
            name: "warzagctl",
            dependencies: ["WarzagCore", "SteamHostKit", "RuntimeKit", "WineKit", "ProfileKit", "EngineKit", "GameKit",
                           "AppUpdateKit"]
        ),
        // Release engineering: runtime pack and app manifests, Ed25519 signing.
        .executableTarget(name: "warzag-release", dependencies: ["WarzagCore", "RuntimeKit", "AppUpdateKit"]),
        // The SwiftUI app: setup, Play, settings and troubleshooting on top of the kits.
        .executableTarget(
            name: "WarzagApp",
            dependencies: ["WarzagCore", "SteamHostKit", "RuntimeKit", "WineKit", "ContentKit", "ProfileKit",
                           "EngineKit", "GameKit", "AppUpdateKit"]
        ),

        // Fakes shared by the test targets (never linked into shipping products).
        .target(name: "WarzagTestSupport", dependencies: ["WarzagCore"]),

        .testTarget(name: "WarzagCoreTests", dependencies: ["WarzagCore", "WarzagTestSupport"]),
        .testTarget(name: "SteamHostKitTests", dependencies: ["SteamHostKit", "WarzagTestSupport"]),
        .testTarget(name: "RuntimeKitTests", dependencies: ["RuntimeKit", "WarzagTestSupport"]),
        .testTarget(name: "AppUpdateKitTests", dependencies: ["AppUpdateKit", "WarzagTestSupport"]),
        .testTarget(name: "WarzagReleaseTests", dependencies: ["warzag-release", "RuntimeKit", "WarzagTestSupport"]),
        .testTarget(name: "WineKitTests", dependencies: ["WineKit", "WarzagTestSupport"]),
        .testTarget(name: "ContentKitTests", dependencies: ["ContentKit", "WarzagTestSupport"]),
        .testTarget(name: "GameKitTests", dependencies: ["GameKit", "WarzagTestSupport"]),
        .testTarget(name: "ProfileKitTests", dependencies: ["ProfileKit", "WarzagTestSupport"]),
        .testTarget(name: "warzagctlTests", dependencies: ["warzagctl", "WarzagTestSupport"]),
        // EngineKit's services and their `warzagctl runtime|prefix` front end (EngineCommands.swift).
        .testTarget(name: "EngineKitTests", dependencies: ["EngineKit", "warzagctl", "WarzagTestSupport"]),
        // The app's model, step performers and adapters against fakes (no Wine, Steam or DE's launcher).
        .testTarget(name: "WarzagAppTests", dependencies: ["WarzagApp", "WarzagTestSupport"]),
    ],
    swiftLanguageModes: [.v6]
)
