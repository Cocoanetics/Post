import ArgumentParser
import Foundation
import PostServer
import SwiftMCP

extension PostCLI {
    struct Idle: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Watch IMAP IDLE events in real time (debug tool)")

        @Option(name: .long, help: "Scoped API key token (overrides POST_API_KEY and .env)")
        var token: String?

        func run() async throws {
            let tcpConfig = MCPServerTcpConfig(serviceName: PostProxy.serverName)
            let proxy = MCPServerProxy(config: .tcp(config: tcpConfig))
            if let token = ProcessInfo.processInfo.resolvedPostAPIToken() {
                await proxy.setAccessTokenMeta(token)
            }

            await proxy.setLogNotificationHandler(IdleEventLogger())

            try await proxy.connect()
            try await proxy.setLogLevel(.debug)

            "Connected to postd. Watching IDLE events (Ctrl+C to stop)...\n".writeToStandardError()

            let client = PostProxy(proxy: proxy)
            do {
                try await client.watchIdleEvents()
            } catch is CancellationError {
                // Expected on Ctrl+C
            } catch {
                "\(error.localizedDescription)\n".writeToStandardError()
                await proxy.disconnect()
                _Exit(1)
            }

            await proxy.disconnect()
        }
    }
}
