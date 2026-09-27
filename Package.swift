// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TwinVault",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "TwinVault", targets: ["TwinVault"])],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", exact: "1.1.0")
    ],
    targets: [
        .executableTarget(
            name: "TwinVault",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ],
            path: "Sources/TwinVault",
            exclude: ["Resources/Info.plist"]
        ),
        .testTarget(
            name: "TwinVaultTests",
            dependencies: ["TwinVault"],
            path: "Tests/TwinVaultTests"
        )
    ]
)
