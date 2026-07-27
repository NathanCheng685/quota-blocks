// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "QuotaBlocks",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "QuotaBlocks", targets: ["QuotaBlocks"]),
    ],
    targets: [
        .executableTarget(
            name: "QuotaBlocks",
            resources: [.process("Resources")]
        ),
    ]
)
