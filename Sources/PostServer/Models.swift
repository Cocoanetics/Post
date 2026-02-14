import Foundation
import SwiftMCP
import SwiftTextHTML

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

@Schema
public struct MessageHeader: Codable, Sendable {
    public let uid: Int
    public let from: String
    public let subject: String
    public let date: String

    public init(uid: Int, from: String, subject: String, date: String) {
        self.uid = uid
        self.from = from
        self.subject = subject
        self.date = date
    }
}

@Schema
public struct MessageDetail: Codable, Sendable {
    public let uid: Int
    public let from: String
    public let to: [String]
    public let subject: String
    public let date: String
    public let textBody: String?
    public let htmlBody: String?
    public let attachments: [AttachmentInfo]

    public init(
        uid: Int,
        from: String,
        to: [String],
        subject: String,
        date: String,
        textBody: String?,
        htmlBody: String?,
        attachments: [AttachmentInfo]
    ) {
        self.uid = uid
        self.from = from
        self.to = to
        self.subject = subject
        self.date = date
        self.textBody = textBody
        self.htmlBody = htmlBody
        self.attachments = attachments
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

@Schema
public struct AttachmentInfo: Codable, Sendable {
    public let filename: String
    public let contentType: String

    public init(filename: String, contentType: String) {
        self.filename = filename
        self.contentType = contentType
    }
}

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

@Schema
public struct MailboxInfo: Codable, Sendable {
    public let name: String
    public let specialUse: String?

    public init(name: String, specialUse: String?) {
        self.name = name
        self.specialUse = specialUse
    }
}

// MailboxStatusInfo, QuotaInfo, QuotaResourceInfo removed — Post now returns
// Mailbox.Status and Quota from SwiftMail directly (both Codable + Sendable).
