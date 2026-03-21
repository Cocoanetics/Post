import Foundation
import SwiftMCP

@Schema
public struct MessageHeader: Codable, Sendable {
    public let uid: Int
    public let from: String
    public let subject: String
    public let date: String
    public let flags: MessageFlags

    public init(uid: Int, from: String, subject: String, date: String, flags: MessageFlags) {
        self.uid = uid
        self.from = from
        self.subject = subject
        self.date = date
        self.flags = flags
    }
}
