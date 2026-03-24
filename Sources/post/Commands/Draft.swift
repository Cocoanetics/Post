import ArgumentParser
import Foundation
import PostServer

extension PostCLI {
    struct Draft: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a new email draft")

        @Option(name: .long, help: "Sender email address (auto-derived from original when using --replying-to)")
        var from: String?

        @Option(name: .long, help: "Comma-separated recipient addresses (auto-derived from original when using --replying-to)")
        var to: String?

        @Option(name: .long, help: "Email subject (auto-derived from original when using --replying-to)")
        var subject: String?

        @Option(
            name: .long,
            help: "Body text or file path. Existing files are read; inline values decode escapes and auto-detect as HTML, Markdown, or plain text. Optional when using --replying-to (creates empty draft for inline editing).",
            transform: { try $0.resolvedDraftBodyInputForCLI() }
        )
        var body: String?

        @Option(name: .long, help: "Comma-separated CC addresses")
        var cc: String?

        @Option(name: .long, help: "Comma-separated BCC addresses")
        var bcc: String?

        @Option(name: .long, parsing: .upToNextOption, help: "File paths or glob patterns to attach (repeatable)")
        var attach: [String] = []

        @Option(name: .long, help: "Server identifier")
        var server: String?

        @Option(name: .long, help: "Mailbox containing the message referenced by --replying-to (default: INBOX)")
        var mailbox: String?

        @Option(name: .long, help: "UID of an existing message to reply to (sets In-Reply-To and References headers)")
        var replyingTo: Int?

        @ArgumentParser.Flag(name: .long, help: "Reply-all: include all original recipients in CC (only with --replying-to)")
        var replyAll: Bool = false

        @OptionGroup
        var globals: GlobalOptions

        func run() async throws {
            // Validate: body is required unless --replying-to is used
            guard body != nil || replyingTo != nil else {
                throw ValidationError("Missing required option '--body' (omit only when using --replying-to for inline editing)")
            }

            try await PostProxy.withClient { client in
                let serverId = try await server.resolveServerID(using: client)
                let attachments = attach.isEmpty ? nil : attach.joined(separator: ",")

                // Resolve reply threading headers and auto-derive fields if --replying-to is set
                var inReplyTo: String? = nil
                var references: String? = nil
                var derivedFrom: String? = nil
                var derivedTo: String? = nil
                var derivedSubject: String? = nil
                var derivedCC: String? = nil
                var derivedBody: String? = nil

                if let replyUID = replyingTo {
                    let sourceMailbox = mailbox ?? "INBOX"
                    let messages = try await client.fetchMessage(
                        serverId: serverId,
                        uids: String(replyUID),
                        mailbox: sourceMailbox
                    )

                    guard let original = messages.first else {
                        throw ValidationError("Message UID \(replyUID) not found in mailbox '\(sourceMailbox)'")
                    }

                    // Threading headers
                    inReplyTo = original.messageId

                    if let originalRefs = original.references, !originalRefs.isEmpty {
                        if let msgId = original.messageId {
                            references = "\(originalRefs) \(msgId)"
                        } else {
                            references = originalRefs
                        }
                    } else if let msgId = original.messageId {
                        references = msgId
                    }

                    // Auto-derive from, to, subject if not explicitly provided
                    if from == nil {
                        derivedFrom = original.to.first
                        guard derivedFrom != nil else {
                            throw ValidationError("Cannot auto-derive sender from original message (no recipient found)")
                        }
                    }

                    if to == nil {
                        derivedTo = original.from
                    }

                    if subject == nil {
                        derivedSubject = original.subject.hasPrefix("Re: ") ? original.subject : "Re: \(original.subject)"
                    }

                    // Handle reply-all: include all original recipients in CC (except sender and primary recipient)
                    if replyAll && cc == nil {
                        let allRecipients = original.to + (original.cc ?? [])
                        let excludeSender = derivedFrom ?? from ?? ""
                        let excludePrimary = derivedTo ?? to ?? ""

                        let ccAddresses = allRecipients.filter { recipient in
                            recipient != excludeSender && recipient != excludePrimary
                        }

                        if !ccAddresses.isEmpty {
                            derivedCC = ccAddresses.joined(separator: ", ")
                        }
                    }

                    // Auto-quote original when body is omitted (like Mail.app Reply behavior)
                    if body == nil {
                        derivedBody = try await formatQuotedReply(original: original)
                    }
                }

                // Validate required fields
                let finalFrom = from ?? derivedFrom
                let finalTo = to ?? derivedTo
                let finalSubject = subject ?? derivedSubject

                guard let fromAddress = finalFrom else {
                    throw ValidationError("Missing required option '--from' (cannot auto-derive without --replying-to)")
                }
                guard let toAddress = finalTo else {
                    throw ValidationError("Missing required option '--to' (cannot auto-derive without --replying-to)")
                }
                guard let subjectText = finalSubject else {
                    throw ValidationError("Missing required option '--subject' (cannot auto-derive without --replying-to)")
                }

                // Resolve final body and detect format
                let finalBody = body ?? derivedBody ?? ""
                let format: PostServer.BodyFormat
                switch finalBody.detectedDraftBodyInputFormat() {
                case .html:
                    format = .html
                case .markdown:
                    format = .markdown
                case .plainText:
                    format = .text
                }

                // Drafts always go to default Drafts folder
                // --mailbox only specifies source mailbox when using --replying-to
                let result = try await client.createDraft(
                    serverId: serverId,
                    from: fromAddress,
                    to: toAddress,
                    subject: subjectText,
                    body: finalBody,
                    format: format,
                    cc: cc ?? derivedCC,
                    bcc: bcc,
                    attachments: attachments,
                    mailbox: nil,
                    inReplyTo: inReplyTo,
                    references: references
                )
                if globals.json {
                    result.printAsJSON()
                    return
                }
                if let uid = result.uid {
                    print("Draft created in '\(result.mailbox)' (UID \(uid)).")
                } else {
                    print("Draft created in '\(result.mailbox)'.")
                }
            }
        }

        private func formatQuotedReply(original: MessageDetail) async throws -> String {
            // Use HTML→Markdown conversion (preserves formatting better than plain text)
            let markdown = try await original.markdown()

            // Format attribution header
            let dateFormatter = ISO8601DateFormatter()
            dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            let germanFormatter = DateFormatter()
            germanFormatter.dateFormat = "dd.MM.yyyy, 'at' HH:mm"
            germanFormatter.locale = Locale(identifier: "en_US")

            let dateString: String
            if let parsedDate = dateFormatter.date(from: original.date) {
                dateString = germanFormatter.string(from: parsedDate)
            } else {
                dateString = original.date
            }

            // Build quote header (will be inside blockquote)
            let quoteHeader = "> On \(dateString), \(original.from) wrote:"

            // Quote the body with paragraph breaks preserved
            let bodyLines = markdown.components(separatedBy: "\n")
            let quotedLines = bodyLines.map { line in
                line.isEmpty ? ">" : "> \(line)"
            }

            // Combine: two blank lines (for empty paragraphs) + quoted header + blank quote line + quoted body
            return "\n\n\(quoteHeader)\n>\n\(quotedLines.joined(separator: "\n"))"
        }
    }
}
