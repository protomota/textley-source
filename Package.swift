// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Textley",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Textley", targets: ["Textley"])],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.17.0"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.105.0")
    ],
    targets: [
        .target(name: "TextleyCore"),
        .executableTarget(name: "Textley", dependencies: [
            "TextleyCore",
            .product(name: "MCP", package: "swift-sdk"),
            .product(name: "Logging", package: "swift-log"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio")
        ]),
        .testTarget(name: "TextleyCoreTests", dependencies: [
            "TextleyCore", "Textley", .product(name: "MCP", package: "swift-sdk")
        ])
    ]
)
