import Foundation
import SwiftMCP

@Schema
public struct NamespaceInfo: Codable, Sendable {
    public let personal: [NamespaceEntry]
    public let otherUsers: [NamespaceEntry]
    public let shared: [NamespaceEntry]

    public init(personal: [NamespaceEntry], otherUsers: [NamespaceEntry], shared: [NamespaceEntry]) {
        self.personal = personal
        self.otherUsers = otherUsers
        self.shared = shared
    }
}
