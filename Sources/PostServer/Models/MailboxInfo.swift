import Foundation
import SwiftMCP

@Schema
public struct MailboxInfo: Codable, Sendable {
    public let name: String
    public let specialUse: String?

    public init(name: String, specialUse: String?) {
        self.name = name
        self.specialUse = specialUse
    }
}
