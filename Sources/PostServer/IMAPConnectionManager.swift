import Foundation
import Logging
import SwiftMail

public actor IMAPConnectionManager {
    /// Extra connections per account for searches and raw downloads, on top of the
    /// primary connection and any IDLE connections. Kept small: servers cap the
    /// connections per user (Dovecot 10 per IP, Gmail 15).
    public static let extraConnectionsPerServer = 2

    private let configuration: PostConfiguration
    private var connections: [String: IMAPServer] = [:]
    /// In-flight connection tasks so concurrent callers share a single attempt.
    private var pendingConnections: [String: Task<IMAPServer, Error>] = [:]
    private let logger = Logger(label: "com.cocoanetics.Post.IMAPConnectionManager")
    private let tokenService: OAuthTokenService

    #if canImport(Security)
    public init(configuration: PostConfiguration, tokenService: OAuthTokenService = OAuthTokenService(store: KeychainOAuthCredentialStore())) {
        self.configuration = configuration
        self.tokenService = tokenService
    }
    #else
    public init(configuration: PostConfiguration, tokenService: OAuthTokenService) {
        self.configuration = configuration
        self.tokenService = tokenService
    }
    #endif

    /// A current access token for an OAuth account, refreshed first when it is about to expire.
    public func accessToken(for key: OAuthCredentialKey) async throws -> String {
        try await tokenService.accessToken(for: key)
    }

    public func serverInfos() -> [ServerInfo] {
        configuration.servers
            .keys
            .sorted()
            .map { id in
                let config = configuration.server(withID: id)
                // Credentials may live in the keychain rather than inline config, so resolve
                // them the same way connections do instead of reading config.credentials directly.
                let resolved = try? configuration.resolveCredentials(forServer: id)
                return ServerInfo(
                    id: id,
                    host: resolved?.host,
                    port: resolved?.port,
                    username: resolved?.username,
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
    
    public func resolveCredentials(forServer serverId: String) throws -> PostConfiguration.ResolvedCredentials {
        try configuration.resolveCredentials(forServer: serverId)
    }
    
    public func resolveSMTPCredentials(forServer serverId: String) throws -> PostConfiguration.ResolvedCredentials {
        let serverConfig = try resolveServerConfiguration(serverId: serverId)
        
        // Try config credentials first
        if let smtp = serverConfig.smtp, let creds = smtp.credentials {
            return PostConfiguration.ResolvedCredentials(
                host: creds.host,
                port: creds.port,
                username: creds.username,
                password: creds.password
            )
        }
        
        // Fall back to keychain
        #if canImport(Security)
        let store = KeychainCredentialStore()
        let smtpKey = OAuthCredentialKey(label: serverId, service: .smtp)
        if let entry = try? store.oauthCredentials(forLabel: serverId, type: .smtp) {
            return PostConfiguration.ResolvedCredentials(
                host: entry.credential.host,
                port: entry.credential.port,
                username: entry.oauth.email,
                password: "",
                oauth: smtpKey
            )
        }
        if let (cred, password) = try? store.fullCredentials(forLabel: serverId, type: .smtp) {
            return PostConfiguration.ResolvedCredentials(
                host: cred.host,
                port: cred.port,
                username: cred.username,
                password: password
            )
        }
        // One OAuth authorization covers sending too, via the SMTP host stored with it.
        if let entry = try? store.oauthCredentials(forLabel: serverId, type: .imap),
           let smtpHost = entry.oauth.smtpHost {
            return PostConfiguration.ResolvedCredentials(
                host: smtpHost,
                port: entry.oauth.smtpPort ?? 465,
                username: entry.oauth.email,
                password: "",
                oauth: OAuthCredentialKey(label: serverId, service: .imap)
            )
        }
        #endif
        throw PostConfigurationError.noSMTPCredentials(serverId)
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
        let tokenService = self.tokenService
        let task = Task {
            try await server.connect()
            switch resolved.authentication {
            case .password(let password):
                try await server.login(username: resolved.username, password: password)
            case .xoauth2(let key):
                let token = try await tokenService.accessToken(for: key)
                try await server.authenticateXOAUTH2(email: resolved.username, accessToken: token)
                // Automatic re-authentication inside SwiftMail must not replay this token once it expires.
                await server.setXOAUTH2AccessTokenProvider(email: resolved.username) {
                    try await tokenService.accessToken(for: key)
                }
            }
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
