// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AirPodsPostureLab",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AirPodsPostureCore",
            targets: ["AirPodsPostureCore"]
        ),
        .executable(
            name: "airpods-posture-lab",
            targets: ["AirPodsPostureLab"]
        )
    ],
    targets: [
        .target(
            name: "AirPodsPostureCore"
        ),
        .executableTarget(
            name: "AirPodsPostureLab",
            dependencies: ["AirPodsPostureCore"]
        ),
        .testTarget(
            name: "AirPodsPostureCoreTests",
            dependencies: ["AirPodsPostureCore"]
        )
    ]
)
