#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import PostServer
import SwiftMCP

extension PostProxy {
    static func withClient<T>(quiet: Bool = false, _ operation: (PostProxy) async throws -> T) async throws -> T {
        var stderrSaved: Int32 = -1
        var devNull: Int32 = -1

        if quiet {
            stderrSaved = dup(STDERR_FILENO)
            devNull = open("/dev/null", O_WRONLY)
            if devNull != -1 {
                dup2(devNull, STDERR_FILENO)
            }
        }

        defer {
            if quiet && stderrSaved != -1 {
                dup2(stderrSaved, STDERR_FILENO)
                close(stderrSaved)
                if devNull != -1 {
                    close(devNull)
                }
            }
        }

        let tcpConfig = MCPServerTcpConfig(serviceName: PostProxy.serverName)
        let proxy = MCPServerProxy(config: .tcp(config: tcpConfig))
        if let token = ProcessInfo.processInfo.resolvedPostAPIToken() {
            await proxy.setAccessTokenMeta(token)
        }

        try await proxy.connect()

        if quiet {
            try? await proxy.setLogLevel(.error)
        }

        defer {
            Task {
                await proxy.disconnect()
            }
        }

        return try await operation(PostProxy(proxy: proxy))
    }
}
