import Foundation
import Logging
import SwiftMail

public actor IMAPConnectionManager {
    private let configuration: PostConfiguration
    private var connections: [String: IMAPServer] = [:]
    /// In-flight connection tasks so concurrent callers share a single attempt.
    private var pendingConnections: [String: Task<IMAPServer, Error>] = [:]
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
    ///
    /// Multiple concurrent callers for the same server share a single in-flight
    /// connection attempt. The actor is released during network I/O (connect + login)
    /// so other callers can proceed.
    public func connection(for serverId: String) async throws -> IMAPServer {
        let resolved = try configuration.resolveCredentials(forServer: serverId)

        // Return cached connection if still alive
        if let existing = connections[serverId] {
            if await existing.isConnected {
                return existing
            }
            // Stale — remove it
            try? await existing.disconnect()
            connections.removeValue(forKey: serverId)
        }

        // If there's already a connection attempt in flight, join it
        if let pending = pendingConnections[serverId] {
            return try await pending.value
        }

        // Create the server and start connecting.
        // The await points in connect()/login() release the actor for other callers.
        let server = IMAPServer(host: resolved.host, port: resolved.port)

        // Wrap in a Task so concurrent callers can share the same attempt
        let task = Task {
            try await server.connect()
            try await server.login(username: resolved.username, password: resolved.password)
            return server
        }

        pendingConnections[serverId] = task

        do {
            let result = try await task.value
            connections[serverId] = result
            pendingConnections.removeValue(forKey: serverId)
            return result
        } catch {
            pendingConnections.removeValue(forKey: serverId)
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
        // Cancel any pending connection attempts
        for (_, task) in pendingConnections {
            task.cancel()
        }
        pendingConnections.removeAll()

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
}
