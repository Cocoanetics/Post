import Foundation

public struct PostConfiguration: Codable, Sendable {
    public struct IMAPServerConfiguration: Codable, Sendable {
        public let id: String
        public let name: String
        public let host: String
        public let port: Int
        public let username: String
        public let password: String
        public let command: String?
        public let idle: Bool?
        public let idleMailbox: String?

        public init(
            id: String,
            name: String,
            host: String,
            port: Int,
            username: String,
            password: String,
            command: String? = nil,
            idle: Bool? = nil,
            idleMailbox: String? = nil
        ) {
            self.id = id
            self.name = name
            self.host = host
            self.port = port
            self.username = username
            self.password = password
            self.command = command
            self.idle = idle
            self.idleMailbox = idleMailbox
        }
    }

    public let servers: [IMAPServerConfiguration]
    public let httpPort: Int?

    public init(servers: [IMAPServerConfiguration], httpPort: Int?) {
        self.servers = servers
        self.httpPort = httpPort
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

    public func server(withID id: String) -> IMAPServerConfiguration? {
        servers.first { $0.id == id }
    }

    public var defaultServerID: String? {
        servers.first?.id
    }
}

public enum PostConfigurationError: Error, LocalizedError, Sendable {
    case missingConfiguration(URL)
    case noServersConfigured
    case unknownServer(String)

    public var errorDescription: String? {
        switch self {
        case .missingConfiguration(let url):
            return "Configuration file not found at \(url.path)."
        case .noServersConfigured:
            return "No IMAP servers configured in ~/.post.json."
        case .unknownServer(let id):
            return "Unknown server ID '\(id)'."
        }
    }
}
