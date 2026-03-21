import Foundation
import SwiftMCP

@Schema
public struct NamespaceEntry: Codable, Sendable {
    public let prefix: String
    public let delimiter: String?

    public init(prefix: String, delimiter: String?) {
        self.prefix = prefix
        self.delimiter = delimiter
    }
}
