// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PastyCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PastyCore", targets: ["PastyCore"]),
    ],
    targets: [
        .target(
            name: "PastyCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "PastyCoreTests",
            dependencies: ["PastyCore"]
        ),
    ]
)
