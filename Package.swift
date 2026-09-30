// swift-tools-version: 6.3
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
        // 1.9.2 makes IDLE teardown stick: before 1.9.1, disconnect() only
        // closed the dedicated IDLE connection's socket and the self-healing
        // cycle task re-dialed the server, leaking the session's private
        // EventLoopGroup (the IMAP-side share of #30); 1.9.2 also closes the
        // post-cancellation reconnect window in that teardown. watchIdleEvents
        // ends its producers with `try? await idleSession.done()` from
        // already-cancelled tasks, which these releases pin as a tested
        // contract. Floor excludes the leaking 1.9.0 and the racy 1.9.1.
        // The floor has since moved past 1.9.2 for MSGParser (1.12.0): Outlook
        // `.msg` is an OLE2/MAPI container, not RFC 822, so `post msg` needs a
        // parser EMLParser cannot stand in for. 1.12.0 also stops
        // Message.bodies/.attachments/.cids reaching inside an attached
        // message/rfc822, which `post msg --json` relies on so a forwarded
        // mail's body and attachments are not reported as the outer message's
        // own — the normal shape of a saved Outlook message.
        // 1.13.0 reads every address through one RFC 5322 parser and formats
        // them one way for every source (IMAP ENVELOPE, EML, .msg): names are
        // quoted only where needed and `from` lists every From mailbox. The
        // floor keeps Post's address output identical across resolutions.
        .package(url: "https://github.com/Cocoanetics/SwiftMail", .upToNextMajor(from: "1.13.0")),
        // 2.2.0 replaced the revision-pinned ZIPFoundation with tagged
        // swift-archive, so SwiftText is a normal version requirement again.
        // It declares swift-tools-version 6.3, which sets Post's toolchain
        // floor. 2.3.0 subsets CFF fonts when embedding them, which `post pdf`
        // needs: before it, one line of CJK text embedded the whole 23 MB
        // Hiragino collection. Default traits on purpose: traits: ["HTML"]
        // would prune swift-archive, but SwiftPM then fails a fresh
        // `swift package update` with "exhausted attempts to resolve …
        // swift-archive".
        .package(url: "https://github.com/Cocoanetics/SwiftText", .upToNextMajor(from: "2.3.0")),
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
                .product(name: "SwiftTextRender", package: "SwiftText"),
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
                "PostServer",
                "post",
                "postd"
            ]
        )
    ]
)
