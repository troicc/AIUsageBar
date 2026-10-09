// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AIUsageBar",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "AIUsageBar", targets: ["AIUsageBar"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
    ],
    targets: [
        .executableTarget(
            name: "AIUsageBar",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/AIUsageBar"
        ),
        .testTarget(
            name: "AIUsageBarTests",
            dependencies: ["AIUsageBar"],
            path: "Tests/AIUsageBarTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
