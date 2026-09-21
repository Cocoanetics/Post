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

        // A one-element array, not a bare object: `post eml --json` has always
        // emitted one, and consumers that index or iterate the result would
        // break on every invocation. `post msg` matches it so the two commands
        // stay interchangeable.
        [Output(
            from: detail.from,
            to: detail.to,
            cc: detail.cc,
            subject: subject.text,
            date: detail.date,
            body: formattedBody.text,
            attachments: detail.attachments,
            embeddedMessages: embedded.isEmpty ? nil : embedded,
            unicodeAbuse: UnicodeAbuseSummary.combine([subject.unicodeAbuse, formattedBody.unicodeAbuse])
        )].printAsJSON()
    }

    /// What the command was asked to do with the file.
    ///
    /// Shared by `eml` and `msg` so the two cannot drift; each command is only
    /// the format it names.
    struct Options: ParsableArguments {
        @Option(name: .long, help: "Body format: text, html, or markdown (default: markdown)")
        var body: BodyFormat = .markdown

        @ArgumentParser.Flag(name: .long, help: "List the parts with the section that addresses each one")
        var listParts: Bool = false

        @Option(name: .long, help: "Section of a single part to write out, as `--list-parts` prints it (e.g. 4.2)")
        var part: String?

        @Option(name: .long, help: "Output path for --part — directory or filename (default: current directory)")
        var output: String = "."

        func validate() throws {
            if listParts && part != nil {
                throw ValidationError("Use either --list-parts or --part, not both.")
            }
        }
    }

    /// Run whichever of the three modes the options select.
    static func run(_ message: Message, options: Options, json: Bool) async throws {
        if options.listParts {
            printListing(message, json: json)
        } else if let section = options.part {
            try extract(message, section: section, to: options.output)
        } else {
            try await emit(message, body: options.body, json: json)
        }
    }

    // MARK: - Parts

    /// One row of the part listing.
    struct PartListing: Codable {
        let section: String
        let contentType: String
        let filename: String?
        let disposition: String?
        let contentId: String?
        let size: Int?
        /// The subject of the message this part carries, for `message/rfc822`.
        let embeddedSubject: String?
    }

    static func listings(for message: Message) -> [PartListing] {
        message.parts.map { part in
            PartListing(
                section: part.section.description,
                contentType: part.contentType,
                filename: part.filename,
                disposition: part.disposition,
                contentId: part.contentId,
                size: part.decodedData()?.count,
                embeddedSubject: part.embeddedMessageInfo?.subject
            )
        }
    }

    /// Print every part with the section that addresses it.
    static func printListing(_ message: Message, json: Bool) {
        let rows = listings(for: message)
        guard !json else {
            rows.printAsJSON()
            return
        }

        guard !rows.isEmpty else {
            print("No parts.")
            return
        }
        let width = rows.map(\.section.count).max() ?? 7
        for row in rows {
            let size = row.size.map { $0.formattedAsBytes() } ?? "—"
            let name = row.filename ?? row.embeddedSubject.map { "(\($0))" } ?? ""
            let disposition = row.disposition.map { " [\($0)]" } ?? ""
            print("\(row.section.padded(to: width))  "
                  + "\(row.contentType.padded(to: 34))  \(size.padded(to: 9))  \(name)\(disposition)")
        }
    }

    /// Write one part's decoded bytes to `output`.
    ///
    /// The section is the dotted number the listing prints, so `4.2` is the
    /// HTML body of the message attached at `4`. Transfer encoding is undone
    /// on the way out, so a base64 `.eml` attachment lands as its real bytes.
    static func extract(_ message: Message, section: String, to output: String) throws {
        guard let part = message.parts.first(where: { $0.section.description == section }) else {
            let available = message.parts.map(\.section.description).joined(separator: ", ")
            throw ValidationError("No part \(section). Available: \(available)")
        }

        guard let data = part.decodedData() else {
            // An embedded message is a container, not bytes; its content is
            // addressable one level down.
            let children = message.parts
                .map(\.section.description)
                .filter { $0.hasPrefix(section + ".") }
            let hint = children.isEmpty ? "" : " Its content is at: \(children.joined(separator: ", "))."
            throw ValidationError("Part \(section) (\(part.contentType)) carries no bytes of its own.\(hint)")
        }

        let outURL = URL(fileURLWithPath: output)
        let isExplicitFile = !outURL.pathExtension.isEmpty
        let directory = isExplicitFile ? outURL.deletingLastPathComponent() : outURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = isExplicitFile ? outURL : directory.appendingPathComponent(part.suggestedFilename)
        try data.write(to: destination)
        print("Saved \(destination.lastPathComponent) (\(part.contentType), \(data.count.formattedAsBytes())) "
              + "to \(destination.path)")
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
