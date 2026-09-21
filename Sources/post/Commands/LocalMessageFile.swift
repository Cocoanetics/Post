import ArgumentParser
import Foundation
import PostServer
import SwiftMail

/// Reading a message from a file on disk, shared by `post eml` and `post msg`.
///
/// The two formats differ only in how the bytes become a `Message`: `.eml` is
/// RFC 822, `.msg` is Outlook's MAPI container. Everything after that — the
/// body format, sanitization, JSON shape — is identical, so it lives here
/// rather than once per command.
enum LocalMessageFile {

    /// Which representation of the body to print.
    enum BodyFormat: String, ExpressibleByArgument, CaseIterable {
        case text, html, markdown
    }

    /// How a local file is parsed.
    enum Format: String {
        case eml, msg

        /// The magic that opens every OLE2 compound file (MS-CFB §2.2).
        static let compoundFileSignature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

        func parse(_ data: Data) throws -> Message {
            switch self {
                case .eml: return try EMLParser.parse(data)
                case .msg: return try MSGParser.parse(data)
            }
        }
    }

    struct Output: Codable {
        let from: String
        let to: [String]
        let cc: [String]?
        let subject: String
        let date: String
        let body: String
        let attachments: [AttachmentInfo]
        let embeddedMessages: [Embedded]?
        let unicodeAbuse: String?

        /// A message carried inside this one, as `.msg` files routinely do for
        /// forwarded mail.
        struct Embedded: Codable {
            let section: String
            let from: String
            let subject: String
            let date: String
            let attachments: [AttachmentInfo]
        }
    }

    /// Read and parse a file, failing with a usable message if it is missing
    /// or is not the format the command expects.
    static func read(_ path: String, as format: Format) throws -> Message {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ValidationError("File not found: \(path)")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))

        // An OLE2 container fed to the RFC 822 parser does not fail — it finds
        // no headers and prints the compound file as if it were a body. Catch
        // it here and name the command that does read it.
        if format == .eml && data.starts(with: Format.compoundFileSignature) {
            throw ValidationError("\(path) is an Outlook .msg container, not RFC 822. Use: post msg \(path)")
        }

        do {
            return try format.parse(data)
        } catch {
            throw ValidationError("Could not parse \(path) as .\(format.rawValue): \(error.localizedDescription)")
        }
    }

    /// Print a parsed message: the chosen body alone, or the whole envelope as JSON.
    static func emit(_ message: Message, body format: BodyFormat, json: Bool) async throws {
        let detail = detail(for: message)

        let formattedBody: SanitizedText
        switch format {
            case .text: formattedBody = detail.sanitizedTextBody()
            case .html: formattedBody = detail.sanitizedHTMLBody()
            case .markdown: formattedBody = try await detail.markdownSanitized()
        }

        guard json else {
            print(formattedBody.text)
            return
        }

        let subject = detail.sanitizedSubject()
        let embedded = message.embeddedMessages.enumerated().map { index, nested in
            Output.Embedded(
                section: message.parts
                    .filter { $0.embeddedMessageInfo != nil }[index].section.description,
                from: nested.from ?? "Unknown",
                subject: nested.subject ?? "(No Subject)",
                date: nested.date.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                attachments: attachmentInfo(for: nested)
            )
        }

        Output(
            from: detail.from,
            to: detail.to,
            cc: detail.cc,
            subject: subject.text,
            date: detail.date,
            body: formattedBody.text,
            attachments: detail.attachments,
            embeddedMessages: embedded.isEmpty ? nil : embedded,
            unicodeAbuse: UnicodeAbuseSummary.combine([subject.unicodeAbuse, formattedBody.unicodeAbuse])
        ).printAsJSON()
    }

    // MARK: - Conversion

    static func detail(for message: Message) -> MessageDetail {
        MessageDetail(
            uid: 0,
            from: message.from ?? "Unknown",
            to: message.to,
            cc: message.cc.isEmpty ? nil : message.cc,
            subject: message.subject ?? "(No Subject)",
            date: message.date.map { ISO8601DateFormatter().string(from: $0) } ?? "",
            textBody: text(of: message, matching: "text/plain"),
            htmlBody: text(of: message, matching: "text/html"),
            attachments: attachmentInfo(for: message),
            additionalHeaders: message.header.additionalFields,
            messageId: message.header.messageId?.description
        )
    }

    private static func attachmentInfo(for message: Message) -> [AttachmentInfo] {
        message.attachments.map {
            AttachmentInfo(
                filename: $0.suggestedFilename,
                contentType: $0.contentType.components(separatedBy: ";").first?
                    .trimmingCharacters(in: .whitespaces) ?? $0.contentType
            )
        }
    }

    /// The decoded text of the first body part of a given type.
    ///
    /// `Message.bodies` already excludes the bodies of any message carried as
    /// an attachment, so a forwarded mail cannot stand in for this one's body.
    private static func text(of message: Message, matching contentType: String) -> String? {
        message.bodies
            .first { $0.contentType.lowercased().hasPrefix(contentType) }?
            .textContent
    }
}
