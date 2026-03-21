import Foundation
import SwiftMCP

@Schema
public struct AttachmentInfo: Codable, Sendable {
    public let filename: String
    public let contentType: String

    public init(filename: String, contentType: String) {
        self.filename = filename
        self.contentType = contentType
    }
}
