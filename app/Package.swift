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
        // SkyGlance is here so the alert-routing decision can be tested. It is an
        // executable target, which SwiftPM has allowed test targets to import
        // since Swift 5.5 because @main is on a type rather than a top-level
        // main.swift. Only `internal` and `public` symbols are reachable, so the
        // private machinery in SkyModel still is not — but the routing rules,
        // the popup anchor maths and the presence checks are, and those are the
        // parts where a silent mistake costs someone their alerts.
        .testTarget(name: "OverheadKitTests", dependencies: ["OverheadKit", "SkyGlance"]),
    ]
)
