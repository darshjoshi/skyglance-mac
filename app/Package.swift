// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SkyGlance",
    platforms: [.macOS(.v13)],
    dependencies: [
        // The only third-party code in the app. Updating a menu bar app by hand
        // means noticing a release you were never told about, which in practice
        // means never — and the people who download the disk image have no
        // `brew upgrade` to fall back on.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.8.0"),
    ],
    targets: [
        // Shared logic. The widget and the dome view will both depend on this.
        // Deliberately free of Sparkle: nothing here should know about updates.
        .target(name: "OverheadKit"),
        .executableTarget(name: "SkyGlance",
                          dependencies: ["OverheadKit",
                                         .product(name: "Sparkle", package: "Sparkle")]),
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
