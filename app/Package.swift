// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SkyGlance",
    platforms: [.macOS(.v13)],
    targets: [
        // Shared logic. The widget and the dome view will both depend on this.
        .target(name: "OverheadKit"),
        .executableTarget(name: "SkyGlance", dependencies: ["OverheadKit"]),
        .executableTarget(name: "skyprobe", dependencies: ["OverheadKit"]),
        .testTarget(name: "OverheadKitTests", dependencies: ["OverheadKit"]),
    ]
)
