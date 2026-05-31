// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AirPodsPosture",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AirPodsPosture",
            targets: ["AirPodsPosture"]
        ),
        .executable(
            name: "airpods-posture-lab",
            targets: ["AirPodsPostureLab"]
        )
    ],
    targets: [
        .target(
            name: "AirPodsPosture"
        ),
        .executableTarget(
            name: "AirPodsPostureLab",
            dependencies: ["AirPodsPosture"]
        ),
        .testTarget(
            name: "AirPodsPostureTests",
            dependencies: ["AirPodsPosture"]
        )
    ]
)
