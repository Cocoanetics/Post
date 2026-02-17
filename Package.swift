// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Post",
    platforms: [
        .macOS("14.0")
    ],
    products: [
        .library(
            name: "PostServer",
            targets: ["PostServer"]
        ),
        .executable(
            name: "postd",
            targets: ["postd"]
        ),
        .executable(
            name: "post",
            targets: ["post"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/Cocoanetics/SwiftMCP", branch: "main"),
        .package(url: "https://github.com/Cocoanetics/SwiftMail", branch: "main"),
        .package(url: "https://github.com/Cocoanetics/SwiftText", branch: "main"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "PostServer",
            dependencies: [
                .product(name: "SwiftMCP", package: "SwiftMCP"),
                .product(name: "SwiftMail", package: "SwiftMail"),
                .product(name: "SwiftTextHTML", package: "SwiftText"),
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .executableTarget(
            name: "postd",
            dependencies: [
                "PostServer",
                .product(name: "SwiftMCP", package: "SwiftMCP"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .executableTarget(
            name: "post",
            dependencies: [
                "PostServer",
                .product(name: "SwiftMCP", package: "SwiftMCP"),
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        )
    ]
)
