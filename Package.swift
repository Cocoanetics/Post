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
        .package(url: "https://github.com/Cocoanetics/SwiftMCP", .upToNextMajor(from: "1.9.0")),
        // Pinned to the 1.8.0 tag by revision: SwiftMail ≥ 1.7.0 depends on a
        // revision-pinned swift-nio-imap (no upstream release yet), and SwiftPM
        // refuses stable-version packages with unstable dependencies. Switch back
        // to .upToNextMajor once SwiftMail depends on a tagged swift-nio-imap.
        .package(url: "https://github.com/Cocoanetics/SwiftMail", revision: "dbb1d0bb6bc7742249cf4800513c5562d54fa734"),
        // Pinned to the 2.0.0 tag by revision: SwiftText 2.0.0 depends on a
        // revision-pinned ZIPFoundation, and SwiftPM refuses stable-version
        // packages with unstable dependencies. Switch back to .upToNextMajor
        // once SwiftText depends only on tagged releases.
        .package(url: "https://github.com/Cocoanetics/SwiftText", revision: "ec4dc821e00e80e4ddf81bfdaf42b72cc7d7235f"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        // Not used directly: SwiftPM fails to resolve this trait-gated transitive
        // dependency (via SwiftMCP → JSONFoundation) unless it is declared at the root.
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "0.5.0"),
        // Not used directly: SwiftMail ≥ 1.7.0 pins swift-nio-imap to a revision
        // (no upstream release yet), which SwiftPM only accepts when the root
        // declares the same unstable dependency. Keep in sync with SwiftMail.
        .package(url: "https://github.com/apple/swift-nio-imap", revision: "bcf875610ca56dfd7bae869fa19ca3149c075908")
    ],
    targets: [
        .plugin(
            name: "PostVersionGeneratorPlugin",
            capability: .buildTool()
        ),
        .target(
            name: "PostServer",
            dependencies: [
                .product(name: "SwiftMCP", package: "SwiftMCP"),
                .product(name: "SwiftMail", package: "SwiftMail"),
                .product(name: "SwiftTextHTML", package: "SwiftText"),
                .product(name: "SwiftTextCore", package: "SwiftText"),
                .product(name: "Logging", package: "swift-log")
            ],
            plugins: [
                .plugin(name: "PostVersionGeneratorPlugin")
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
        ),
        .testTarget(
            name: "PostCLITests",
            dependencies: [
                "post",
                "postd"
            ]
        )
    ]
)
