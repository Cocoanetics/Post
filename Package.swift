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
        // 1.9.1 makes IDLE teardown stick: before it, disconnect() only closed
        // the dedicated IDLE connection's socket and the self-healing cycle task
        // re-dialed the server, leaking the session's private EventLoopGroup
        // (the IMAP-side share of #30). watchIdleEvents ends its producers with
        // `try? await idleSession.done()` from already-cancelled tasks, which
        // 1.9.1 pins as a tested contract. Floor excludes the leaking 1.9.0.
        .package(url: "https://github.com/Cocoanetics/SwiftMail", .upToNextMajor(from: "1.9.1")),
        // Pinned to the 2.1.0 tag by revision: SwiftText still depends on a
        // revision-pinned ZIPFoundation, and SwiftPM refuses stable-version
        // packages with unstable dependencies. Swift 6.3 would accept a version
        // requirement with traits: ["HTML"] (trait pruning drops ZIPFoundation
        // before the check), but CI's Swift 6.2 checks before pruning. Switch
        // back to .upToNextMajor once SwiftText depends only on tagged releases
        // or CI moves to Swift 6.3.
        .package(url: "https://github.com/Cocoanetics/SwiftText", revision: "8093c0d3b22754bdbde895230f0f72dbfde6c69d"),
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
