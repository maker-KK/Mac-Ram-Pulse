// swift-tools-version:6.0
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "MacRamPulse",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MacRamPulse", targets: ["MacRamPulse"])],
    targets: [
        .target(name: "MacRamPulseKit", swiftSettings: v5),
        .executableTarget(name: "MacRamPulse", dependencies: ["MacRamPulseKit"], swiftSettings: v5),
        .testTarget(name: "MacRamPulseKitTests", dependencies: ["MacRamPulseKit"], swiftSettings: v5),
    ]
)
