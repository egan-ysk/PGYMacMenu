// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PGYMacMenu",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "PGYMacMenu", targets: ["PGYMacMenu"])
    ],
    targets: [
        .executableTarget(
            name: "PGYMacMenu",
            path: "Sources/PGYMacMenu"
        ),
        .testTarget(
            name: "PGYMacMenuTests",
            dependencies: ["PGYMacMenu"],
            path: "Tests/PGYMacMenuTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
