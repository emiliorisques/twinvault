// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TwinVault",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "TwinVault", targets: ["TwinVault"])],
    targets: [
        .executableTarget(
            name: "TwinVault",
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
