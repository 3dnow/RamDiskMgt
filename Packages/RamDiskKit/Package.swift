// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RamDiskKit",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "RamDiskKit", targets: ["RamDiskKit"]),
        .executable(name: "rdmctl", targets: ["rdmctl"]),
    ],
    targets: [
        .target(name: "RamDiskKit"),
        .executableTarget(name: "rdmctl", dependencies: ["RamDiskKit"]),
        .testTarget(name: "RamDiskKitTests", dependencies: ["RamDiskKit"]),
    ]
)
