// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "UsageHUD",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "UsageCore"),
        .executableTarget(
            name: "UsageHUD",
            dependencies: ["UsageCore"]
        ),
        .testTarget(
            name: "UsageHUDTests",
            dependencies: ["UsageCore"],
            resources: [.copy("Fixtures")]
        )
    ]
)
