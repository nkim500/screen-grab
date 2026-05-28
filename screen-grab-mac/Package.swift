// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "screen-grab-mac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "screen-grab-mac", targets: ["App"]),
    ],
    targets: [
        // Pure modules first (no AppKit imports = unit-testable).
        .target(name: "HotkeyListener"),
        .target(name: "ContextCapture"),
        .target(name: "IPCClient", dependencies: ["ContextCapture"]),
        .target(name: "HUDOverlay"),
        .target(name: "TextInserter"),
        .target(name: "BrainProcess"),
        .target(name: "AudioCapture"),
        .target(name: "Transcriber", dependencies: ["AudioCapture"]),

        // Executable target depends on all modules.
        .executableTarget(
            name: "App",
            dependencies: [
                "HotkeyListener", "ContextCapture", "IPCClient", "HUDOverlay",
                "TextInserter", "BrainProcess", "AudioCapture", "Transcriber",
            ]
        ),

        // Test targets, paired with the modules they exercise.
        .testTarget(name: "HotkeyListenerTests", dependencies: ["HotkeyListener"]),
        .testTarget(name: "ContextCaptureTests", dependencies: ["ContextCapture"]),
        .testTarget(name: "IPCClientTests", dependencies: ["IPCClient", "ContextCapture"]),
        .testTarget(name: "HUDOverlayTests", dependencies: ["HUDOverlay"]),
        .testTarget(name: "BrainProcessTests", dependencies: ["BrainProcess"]),
        .testTarget(name: "AudioCaptureTests", dependencies: ["AudioCapture"]),
        .testTarget(name: "TranscriberTests", dependencies: ["Transcriber", "AudioCapture"]),
        .testTarget(name: "TextInserterTests", dependencies: ["TextInserter"]),
    ]
)
