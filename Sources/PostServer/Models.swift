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
    public let flag: String?

    public init(uid: Int, from: String, subject: String, date: String, flag: String? = nil) {
        self.uid = uid
        self.from = from
        self.subject = subject
        self.date = date
        self.flag = flag
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

@Schema
public struct RawMessage: Codable, Sendable {
    public let uid: Int
    public let rawData: Data
    public let size: Int

    public init(uid: Int, rawData: Data) {
        self.uid = uid
        self.rawData = rawData
        self.size = rawData.count
    }
}

@Schema
public struct DraftResult: Codable, Sendable {
    public let mailbox: String
    public let uid: Int?

    public init(mailbox: String, uid: Int?) {
        self.mailbox = mailbox
        self.uid = uid
    }
}

// MailboxStatusInfo, QuotaInfo, QuotaResourceInfo removed — Post now returns
// Mailbox.Status and Quota from SwiftMail directly (both Codable + Sendable).

@Schema
public struct NamespaceEntry: Codable, Sendable {
    public let prefix: String
    public let delimiter: String?

    public init(prefix: String, delimiter: String?) {
        self.prefix = prefix
        self.delimiter = delimiter
    }
}

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

@Schema
public struct SearchCount: Codable, Sendable {
    public let count: Int?
    public let minUID: Int?
    public let maxUID: Int?
    public let all: [Int]?

    public init(count: Int?, minUID: Int?, maxUID: Int?, all: [Int]?) {
        self.count = count
        self.minUID = minUID
        self.maxUID = maxUID
        self.all = all
    }
}
