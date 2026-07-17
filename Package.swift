// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "CodexMicroBridge",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "CodexMicroBridge", targets: ["CodexMicroBridge"]),
    .executable(name: "codex-micro-hardware", targets: ["CodexMicroHardware"]),
    .executable(name: "codex-midi", targets: ["CodexMidi"]),
    .executable(name: "codex-ride", targets: ["CodexRide"]),
    .executable(name: "codex-micro-menu", targets: ["CodexMicroMenu"]),
  ],
  targets: [
    .target(name: "CodexMicroBridge"),
    .executableTarget(
      name: "CodexMicroHardware",
      dependencies: ["CodexMicroBridge"]
    ),
    .executableTarget(
      name: "CodexMidi",
      dependencies: ["CodexMicroBridge"],
      linkerSettings: [.linkedFramework("CoreMIDI")]
    ),
    .executableTarget(
      name: "CodexRide",
      dependencies: ["CodexMicroBridge"],
      linkerSettings: [.linkedFramework("CoreBluetooth")]
    ),
    .executableTarget(
      name: "CodexMicroMenu",
      dependencies: ["CodexMicroBridge"],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("AudioToolbox"),
        .linkedFramework("AVFoundation"),
        .linkedFramework("CoreAudio"),
        .linkedFramework("Security"),
        .linkedFramework("SwiftUI"),
      ]
    ),
    .testTarget(
      name: "CodexMicroBridgeTests",
      dependencies: ["CodexMicroBridge"]
    ),
  ],
  swiftLanguageModes: [.v5]
)
