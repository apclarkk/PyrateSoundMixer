// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PyrateSounds",
    platforms: [.macOS("14.4")],
    products: [
        .executable(name: "PyrateSounds", targets: ["PyrateSounds"]),
    ],
    targets: [
        // Domain: identities, capabilities, operations, preferences. No Core Audio.
        .target(name: "PyrateCore"),
        // Lock-free primitives for handing parameters to the realtime thread (C11 atomics).
        .target(name: "PyrateAtomics"),
        // Audio services: Core Audio devices, process discovery, process taps, DSP.
        .target(name: "PyrateAudio", dependencies: ["PyrateCore", "PyrateAtomics"]),
        // Presentation: menu bar panel, settings, app state store.
        .executableTarget(name: "PyrateSounds", dependencies: ["PyrateCore", "PyrateAudio"]),
        .testTarget(name: "PyrateCoreTests", dependencies: ["PyrateCore"]),
        .testTarget(name: "PyrateAudioTests", dependencies: ["PyrateAudio", "PyrateCore"]),
    ]
)
