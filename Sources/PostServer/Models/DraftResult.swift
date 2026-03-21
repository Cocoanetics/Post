import Foundation
import SwiftMCP

@Schema
public struct DraftResult: Codable, Sendable {
    public let mailbox: String
    public let uid: Int?

    public init(mailbox: String, uid: Int?) {
        self.mailbox = mailbox
        self.uid = uid
    }
}
