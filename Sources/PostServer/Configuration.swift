import Foundation

public struct PostConfiguration: Codable, Sendable {
    public struct ServerConfiguration: Codable, Sendable {
        public struct Credentials: Codable, Sendable {
            public let host: String
            public let port: Int
            public let username: String
            public let password: String

            public init(host: String, port: Int, username: String, password: String) {
                self.host = host
                self.port = port
                self.username = username
                self.password = password
            }
        }

        public let command: String?
        public let idle: Bool?
        public let idleMailbox: String?
        public let credentials: Credentials?

        public init(command: String? = nil, idle: Bool? = nil, idleMailbox: String? = nil, credentials: Credentials? = nil) {
            self.command = command
            self.idle = idle
            self.idleMailbox = idleMailbox
            self.credentials = credentials
        }
    }

    public struct ResolvedCredentials: Sendable {
        public let host: String
        public let port: Int
        public let username: String
        public let password: String

        public init(host: String, port: Int, username: String, password: String) {
            self.host = host
            self.port = port
            self.username = username
            self.password = password
        }
    }

    public let servers: [String: ServerConfiguration]
    public let httpPort: Int?

    public init(servers: [String: ServerConfiguration], httpPort: Int?) {
        self.servers = servers
        self.httpPort = httpPort
    }

    private enum CodingKeys: String, CodingKey {
        case servers
        case httpPort
    }

    private struct LegacyIMAPServerConfiguration: Decodable {
        let id: String
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        httpPort = try container.decodeIfPresent(Int.self, forKey: .httpPort)

        do {
            servers = try container.decode([String: ServerConfiguration].self, forKey: .servers)
        } catch {
            if let legacyServers = try? container.decode([LegacyIMAPServerConfiguration].self, forKey: .servers) {
                throw PostConfigurationError.legacyServerArrayFormatDetected(ids: legacyServers.map(\.id))
            }
            throw error
        }
    }

    public static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".post.json")
    }

    public static func load(from fileURL: URL = PostConfiguration.defaultFileURL) throws -> PostConfiguration {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw PostConfigurationError.missingConfiguration(fileURL)
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        let config = try decoder.decode(PostConfiguration.self, from: data)

        guard !config.servers.isEmpty else {
            throw PostConfigurationError.noServersConfigured
        }

        return config
    }

    public func server(withID id: String) -> ServerConfiguration? {
        servers[id]
    }

    public var defaultServerID: String? {
        servers.keys.sorted().first
    }

    public func resolveCredentials(forServer id: String) throws -> ResolvedCredentials {
        guard let server = server(withID: id) else {
            throw PostConfigurationError.unknownServer(id)
        }

        #if canImport(Security)
        let store = KeychainCredentialStore()
        if let keychainEntry = try store.fullCredentials(forLabel: id) {
            return ResolvedCredentials(
                host: keychainEntry.credential.host,
                port: keychainEntry.credential.port,
                username: keychainEntry.credential.username,
                password: keychainEntry.password
            )
        }
        #endif

        if let inline = server.credentials, !inline.password.isEmpty {
            return ResolvedCredentials(
                host: inline.host,
                port: inline.port,
                username: inline.username,
                password: inline.password
            )
        }

        throw PostConfigurationError.noCredentials(server: id)
    }
}

public enum PostConfigurationError: Error, LocalizedError, Sendable {
    case missingConfiguration(URL)
    case noServersConfigured
    case unknownServer(String)
    case noCredentials(server: String)
    case legacyServerArrayFormatDetected(ids: [String])

    public var errorDescription: String? {
        switch self {
        case .missingConfiguration(let url):
            return "Configuration file not found at \(url.path)."
        case .noServersConfigured:
            return "No IMAP servers configured in ~/.post.json."
        case .unknownServer(let id):
            return "Unknown server ID '\(id)'."
        case .noCredentials(let server):
            return "No credentials found for server '\(server)'. Use `post credential set --server \(server)` or add servers.\(server).credentials in ~/.post.json."
        case .legacyServerArrayFormatDetected(let ids):
            let listedIDs = ids.isEmpty ? "<none>" : ids.joined(separator: ", ")
            return """
            Detected legacy server format in ~/.post.json (`servers` as an array, IDs: \(listedIDs)).
            Please migrate to dictionary format:
            {
              "servers": {
                "<server-id>": {
                  "idle": true,
                  "idleMailbox": "INBOX",
                  "command": "/path/to/script.sh"
                }
              }
            }
            """
        }
    }
}
