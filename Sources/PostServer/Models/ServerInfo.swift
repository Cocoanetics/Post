import Foundation
import SwiftMCP

@Schema
public struct ServerInfo: Codable, Sendable {
    public let id: String
    public let host: String?
    public let port: Int?
    public let username: String?
    public let command: String?

    public init(id: String, host: String?, port: Int?, username: String?, command: String? = nil) {
        self.id = id
        self.host = host
        self.port = port
        self.username = username
        self.command = command
    }
}
