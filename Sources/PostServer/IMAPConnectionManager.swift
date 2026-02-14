import Foundation
import Logging
import SwiftMail

public actor IMAPConnectionManager {
    private let configuration: PostConfiguration
    private var connections: [String: IMAPServer] = [:]
    private let logger = Logger(label: "com.cocoanetics.Post.IMAPConnectionManager")

    public init(configuration: PostConfiguration) {
        self.configuration = configuration
    }

    public func serverInfos() -> [ServerInfo] {
        configuration.servers
            .keys
            .sorted()
            .map { id in
                let config = configuration.server(withID: id)
                return ServerInfo(
                    id: id,
                    host: config?.credentials?.host,
                    port: config?.credentials?.port,
                    username: config?.credentials?.username,
                    command: config?.command
                )
            }
    }

    public func defaultServerID() -> String? {
        configuration.defaultServerID
    }

    public func resolveServerConfiguration(serverId: String) throws -> PostConfiguration.ServerConfiguration {
        guard let config = configuration.server(withID: serverId) else {
            throw PostConfigurationError.unknownServer(serverId)
        }
        return config
    }

    /// Returns a cached primary IMAPServer instance for the given serverId.
    /// This connection is used for normal commands.
    public func connection(for serverId: String) async throws -> IMAPServer {
        let resolved = try configuration.resolveCredentials(forServer: serverId)

        if let existing = connections[serverId] {
            if await existing.isConnected {
                return existing
            }

            do {
                try await connect(existing, using: resolved)
                return existing
            } catch {
                logger.warning("Reconnection failed for \(serverId): \(String(describing: error))")
                try? await existing.disconnect()
                connections.removeValue(forKey: serverId)
            }
        }

        let server = IMAPServer(host: resolved.host, port: resolved.port)
        do {
            try await connect(server, using: resolved)
            connections[serverId] = server
            return server
        } catch {
            try? await server.disconnect()
            throw error
        }
    }

    public func reconnect(for serverId: String) async throws -> IMAPServer {
        if let existing = connections.removeValue(forKey: serverId) {
            try? await existing.disconnect()
        }

        return try await connection(for: serverId)
    }

    public func shutdown() async {
        let activeConnections = connections
        connections.removeAll()

        for (serverId, server) in activeConnections {
            do {
                try await server.disconnect()
            } catch {
                logger.warning("Disconnect failed for \(serverId): \(String(describing: error))")
            }
        }
    }

    private func connect(_ server: IMAPServer, using credentials: PostConfiguration.ResolvedCredentials) async throws {
        try await server.connect()
        try await server.login(username: credentials.username, password: credentials.password)
    }
}
