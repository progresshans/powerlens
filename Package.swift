// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PowerLens",
    defaultLocalization: "en",
    platforms: [
        .macOS("26.0"),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6"),
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
