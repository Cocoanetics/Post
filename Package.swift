// swift-tools-version: 6.2
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
        // 1.10.1 fixes the TCP transport leaking one file descriptor per inbound
        // connection (which wedged postd once its descriptor table filled, #30)
        // and makes run() throw on unrecoverable listener failure instead of
        // parking forever. The floor excludes 1.10.0 so no resolution can pick
        // the leaking release again.
        .package(url: "https://github.com/Cocoanetics/SwiftMCP", .upToNextMajor(from: "1.10.1")),
        // 1.9.0 depends on a tagged swift-nio-imap (0.3.0) again, so SwiftMail is
        // back on a version requirement — no revision pin, and no root
        // swift-nio-imap declaration needed to satisfy SwiftPM.
        .package(url: "https://github.com/Cocoanetics/SwiftMail", .upToNextMajor(from: "1.9.0")),
        // Only the HTML trait: Post uses just SwiftTextHTML/SwiftTextCore, and
        // dropping the default CLI/DOCX/EPUB/PAGES traits prunes the
        // revision-pinned ZIPFoundation from the graph — the dependency that
        // previously forced this package to be revision-pinned too (SwiftPM
        // refuses stable-version packages with unstable dependencies).
        .package(url: "https://github.com/Cocoanetics/SwiftText", .upToNextMajor(from: "2.1.0"), traits: ["HTML"]),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        // Not used directly: SwiftPM fails to resolve this trait-gated transitive
        // dependency (via SwiftMCP → JSONFoundation) unless it is declared at the root.
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "0.5.0")
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
