// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "NetNewsWireMCP",
    platforms: [
        .macOS("13.0")
    ],
    products: [
        .executable(name: "NetNewsWireMCP", targets: ["NetNewsWireMCP"]),
        .library(name: "NetNewsWireMCPCore", targets: ["NetNewsWireMCPCore"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/modelcontextprotocol/swift-sdk",
            exact: "0.12.1"
        )
    ],
    targets: [
        .target(
            name: "NetNewsWireMCPCore",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk")
            ]
        ),
        .executableTarget(
            name: "NetNewsWireMCP",
            dependencies: [
                "NetNewsWireMCPCore",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .testTarget(
            name: "NetNewsWireMCPTests",
            dependencies: ["NetNewsWireMCPCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
