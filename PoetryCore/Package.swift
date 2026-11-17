// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PoetryCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PoetryCore", targets: ["PoetryCore"]),
        .executable(name: "shici-mcp", targets: ["ShiCiMCP"]),
    ],
    targets: [
        .target(
            name: "PoetryCore",
            resources: [.copy("Resources")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "ShiCiMCP",
            dependencies: ["PoetryCore"]
        ),
        .testTarget(
            name: "PoetryCoreTests",
            dependencies: ["PoetryCore"]
        ),
    ]
)
