// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iosgpsspoof",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "iosgpsspoof", targets: ["iosgpsspoof"]),
        .executable(name: "iosgpsspoofer-gui", targets: ["iosgpsspooferGUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "SpooferCore"
        ),
        .executableTarget(
            name: "iosgpsspoof",
            dependencies: [
                "SpooferCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "iosgpsspooferGUI",
            dependencies: ["SpooferCore"],
            path: "Sources/iosgpsspoofer-gui"
        ),
    ]
)
