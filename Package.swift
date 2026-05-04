// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "PowerLens",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.1"),
    ],
    targets: [
        .executableTarget(
            name: "PowerLens",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "PowerLensTests",
            dependencies: ["PowerLens"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
