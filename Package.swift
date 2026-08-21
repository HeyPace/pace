// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PaceKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .watchOS(.v10),
    ],
    products: [
        .library(name: "PaceKit", targets: ["PaceKit"]),
    ],
    targets: [
        .target(
            name: "PaceKit",
            path: "leanring-buddy/PaceKit"
        ),
        .testTarget(
            name: "PaceKitTests",
            dependencies: ["PaceKit"],
            path: "PaceKitTests"
        ),
    ]
)
