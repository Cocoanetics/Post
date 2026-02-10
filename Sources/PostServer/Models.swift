import Foundation
import SwiftMCP

@Schema
public struct ServerInfo: Codable, Sendable {
    public let id: String
    public let name: String
    public let host: String

    public init(id: String, name: String, host: String) {
        self.id = id
        self.name = name
        self.host = host
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
public struct MailboxInfo: Codable, Sendable {
    public let name: String
    public let specialUse: String?

    public init(name: String, specialUse: String?) {
        self.name = name
        self.specialUse = specialUse
    }
}
