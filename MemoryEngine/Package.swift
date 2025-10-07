// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MemoryEngine",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MemoryEngine", targets: ["MemoryEngine"])
    ],
    dependencies: [
        .package(url: "https://github.com/stephencelis/SQLite.swift", from: "0.13.3"),
        .package(url: "https://github.com/apple/swift-collections", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.5.4")
    ],
    targets: [
        .target(
            name: "MemoryEngine",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift"),
                .product(name: "OrderedCollections", package: "swift-collections"),
                .product(name: "Logging", package: "swift-log")
            ],
            path: "Sources/MemoryEngine",
            linkerSettings: [
                .linkedFramework("Accelerate", .when(platforms: [.macOS]))
            ]
        ),
        .testTarget(
            name: "MemoryEngineTests",
            dependencies: ["MemoryEngine"],
            path: "Tests/MemoryEngineTests"
        )
    ]
)
