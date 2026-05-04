// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "PowerLens",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13),
    ],
    targets: [
        .executableTarget(
            name: "PowerLens",
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
