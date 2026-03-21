import Foundation
import SwiftMCP

@Schema
public struct AttachmentData: Codable, Sendable {
    public let filename: String
    public let contentType: String
    /// Base64-encoded file content
    public let data: String
    public let size: Int

    public init(filename: String, contentType: String, data: String, size: Int) {
        self.filename = filename
        self.contentType = contentType
        self.data = data
        self.size = size
    }
}
