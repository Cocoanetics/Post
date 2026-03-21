import Foundation
import SwiftMCP
import SwiftTextHTML

@Schema
public struct MessageDetail: Codable, Sendable {
    public let uid: Int
    public let from: String
    public let to: [String]
    public let cc: [String]?
    public let subject: String
    public let date: String
    public let textBody: String?
    public let htmlBody: String?
    public let attachments: [AttachmentInfo]
    /// Additional RFC 822 headers not covered by the envelope (e.g. List-Unsubscribe, X-Spam-Score).
    public let additionalHeaders: [String: String]?
    /// The Message-ID header value (RFC 822)
    public let messageId: String?
    /// The References header value (RFC 822, space-separated Message-IDs)
    public let references: String?

    public init(
        uid: Int,
        from: String,
        to: [String],
        cc: [String]? = nil,
        subject: String,
        date: String,
        textBody: String?,
        htmlBody: String?,
        attachments: [AttachmentInfo],
        additionalHeaders: [String: String]? = nil,
        messageId: String? = nil,
        references: String? = nil
    ) {
        self.uid = uid
        self.from = from
        self.to = to
        self.cc = cc
        self.subject = subject
        self.date = date
        self.textBody = textBody
        self.htmlBody = htmlBody
        self.attachments = attachments
        self.additionalHeaders = additionalHeaders
        self.messageId = messageId
        self.references = references
    }
}

extension MessageDetail {
    /// Returns the message body as markdown.
    /// Converts HTML to markdown when available, falls back to plain text.
    public func markdown() async throws -> String {
        if let htmlBody, !htmlBody.isEmpty {
            let converter = HTMLToMarkdown(data: Data(htmlBody.utf8))
            return try await converter.markdown()
        }

        if let textBody, !textBody.isEmpty {
            return textBody
        }

        return ""
    }
}
