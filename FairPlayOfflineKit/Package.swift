// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "FairPlayOfflineKit",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "FairPlayOfflineKit",
            targets: ["FairPlayOfflineKit"]
        )
    ],
    targets: [
        .target(
            name: "FairPlayOfflineKit",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "FairPlayOfflineKitTests",
            dependencies: ["FairPlayOfflineKit"]
        )
    ]
)
