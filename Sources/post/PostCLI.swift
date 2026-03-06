import ArgumentParser
import Darwin
import Foundation
import PostServer
import SwiftMail
import SwiftMCP
import SwiftTextHTML
@preconcurrency import AnyCodable

/// Prints IDLE event log notifications from the daemon to stdout.
private final class IdleEventLogger: MCPServerProxyLogNotificationHandling, @unchecked Sendable {
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func writeStdoutLine(_ line: String) {
        if let data = (line + "\n").data(using: .utf8) {
            try? FileHandle.standardOutput.write(contentsOf: data)
        }
    }

    private func parseStructuredEvent(_ data: Any) -> (server: String, mailbox: String, event: String)? {
        if let dict = data as? [String: String],
           let server = dict["server"],
           let mailbox = dict["mailbox"],
           let event = dict["event"] {
            return (server, mailbox, event)
        }

        if let dict = data as? [String: Any],
           let server = dict["server"] as? String,
           let mailbox = dict["mailbox"] as? String,
           let event = dict["event"] as? String {
            return (server, mailbox, event)
        }

        if let dict = data as? [String: AnyCodable],
           let server = dict["server"]?.value as? String,
           let mailbox = dict["mailbox"]?.value as? String,
           let event = dict["event"]?.value as? String {
            return (server, mailbox, event)
        }

        return nil
    }

    func mcpServerProxy(_ proxy: MCPServerProxy, didReceiveLog message: LogMessage) async {
        let timestamp = dateFormatter.string(from: Date())

        // Try to extract structured data (server, mailbox, event)
        if let structured = parseStructuredEvent(message.data.value) {
            writeStdoutLine("[\(timestamp)] \(structured.server)/\(structured.mailbox): \(structured.event)")
        } else if let text = message.data.value as? String {
            writeStdoutLine("[\(timestamp)] \(text)")
        } else {
            writeStdoutLine("[\(timestamp)] \(message.data)")
        }
    }
}

@main
struct PostCLI: AsyncParsableCommand {
    private static var apiKeyCommandVisible: Bool {
        guard let value = ProcessInfo.processInfo.environment["POST_API_KEY"] else {
            return true
        }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? false
            : true
    }

    static let configuration = CommandConfiguration(
        commandName: "post",
        abstract: "Post CLI client",
        subcommands: operationalSubcommands + (apiKeyCommandVisible ? configurationSubcommands : []),
    )

    private static let operationalSubcommands: [ParsableCommand.Type] = [
            Servers.self,
            List.self,
            Fetch.self,
            EML.self,
            Folders.self,
            Create.self,
            Status.self,
            Search.self,
            Move.self,
            Copy.self,
            FlagMessages.self,
            Trash.self,
            Archive.self,
            Junk.self,
            Expunge.self,
            Quota.self,
            Attachment.self,
            Draft.self,
            Reply.self,
            PDF.self,
            Idle.self
        ]

    private static let configurationSubcommands: [ParsableCommand.Type] = [
            Credential.self,
            APIKey.self
        ]
    
}

extension PostCLI {
    struct GlobalOptions: ParsableArguments {
        @ArgumentParser.Flag(name: .long, help: "Output as JSON")
        var json: Bool = false

        @Option(name: .long, help: "Scoped API key token (overrides POST_API_KEY and .env)")
        var token: String?
    }

    struct Servers: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List configured IMAP servers")

        @OptionGroup
        var globals: GlobalOptions

        func run() async throws {
            try await withClient { client in
                let servers = try await client.listServers()
                if globals.json {
                    outputJSON(servers)
                    return
                }
                printServersTable(servers)
            }
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List messages")

        @Option(name: .long, help: "Server identifier")
        var server: String?

        @Option(name: .long, help: "Mailbox name")
        var mailbox: String = "INBOX"

        @Option(name: .long, help: "Maximum number of messages")
        var limit: Int = 10

        @OptionGroup
        var globals: GlobalOptions

        func run() async throws {
            try await withClient { client in
                let serverId = try await resolveServerID(explicit: server, client: client)
                let messages = try await client.listMessages(serverId: serverId, mailbox: mailbox, limit: limit)
                if globals.json {
                    outputJSON(messages.map(JSONMessageHeader.init))
                    return
                }
                printMessageHeaders(messages)
            }
        }
    }

    struct Fetch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Fetch message(s) by UID")

        enum BodyFormat: String, ExpressibleByArgument {
            case text, html, markdown
        }

        @Argument(help: "UID(s) of the message (comma-separated; ranges like 1-3 allowed)")
        var uid: String

        @ArgumentParser.Flag(help: "Download raw RFC 822 message as .eml file")
        var eml: Bool = false

        @Option(name: .long, help: "Body format: text, html, or markdown (default: markdown)")
        var body: BodyFormat = .markdown

        @Option(name: .long, help: "Output directory for .eml or text files")
        var out: String?

        @Option(name: .long, help: "Server identifier")
        var server: String?

        @Option(name: .long, help: "Mailbox name")
        var mailbox: String = "INBOX"

        @OptionGroup
        var globals: GlobalOptions

        func validate() throws {
            if eml && out == nil {
                throw ValidationError("--eml requires --out")
            }

            guard MessageIdentifierSet<UID>(string: uid) != nil else {
                throw ValidationError("Invalid UID set '\(uid)'. Use comma-separated values or ranges (e.g. 1-3,5,10-20).")
            }
        }

        private func formatBody(_ message: MessageDetail) async throws -> String {
            switch body {
            case .text:
                return message.textBody ?? ""
            case .html:
                return message.htmlBody ?? message.textBody ?? ""
            case .markdown:
                return try await message.markdown()
            }
        }

        private func resolveHeaders(
            for message: MessageDetail,
            client: PostProxy,
            serverId: String
        ) async -> [String: String] {
            let decoded = decodeFetchHeaders(message.additionalHeaders)
            if !decoded.isEmpty {
                return decoded
            }

            guard let emlData = try? await client.downloadEml(serverId: serverId, uid: message.uid, mailbox: mailbox),
                  !emlData.isEmpty else {
                return decoded
            }

            return decodeFetchHeaders(parseAdditionalHeaders(from: emlData))
        }

        struct FormattedMessage: Codable {
            let uid: Int
            let mailbox: String
            let from: String
            let to: [String]
            let subject: String
            let date: String
            let body: String
            let headers: [String: String]
            let attachments: [AttachmentInfo]?
            let additionalHeaders: [String: String]?

            init(detail: MessageDetail, mailbox: String, formattedBody: String, headers: [String: String]) {
                self.uid = detail.uid
                self.mailbox = mailbox
                self.from = detail.from
                self.to = detail.to
                self.subject = detail.subject
                self.date = detail.date
                self.body = formattedBody
                self.headers = headers
                self.attachments = detail.attachments.isEmpty ? nil : detail.attachments
                self.additionalHeaders = detail.additionalHeaders
            }
        }

        func run() async throws {
            try await withClient(quiet: globals.json) { client in
                let serverId = try await resolveServerID(explicit: server, client: client)
                guard let uidSet = MessageIdentifierSet<UID>(string: uid) else {
                    throw ValidationError("Invalid UID set '\(uid)'. Use comma-separated values or ranges (e.g. 1-3,5,10-20).")
                }

                let outputDir: URL?
                if let out, eml || !globals.json {
                    let directory = URL(fileURLWithPath: out, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    outputDir = directory
                } else {
                    outputDir = nil
                }

                var jsonMessages: [FormattedMessage] = []
                var foundCount = 0
                for messageUID in uidSet.toArray() {
                    let uidValue = Int(messageUID.value)

                    if eml {
                        guard let outputDir else {
                            throw ValidationError("--eml requires --out")
                        }

                        let emlData = try await client.downloadEml(serverId: serverId, uid: uidValue, mailbox: mailbox)
                        guard !emlData.isEmpty else { continue }
                        foundCount += 1
                        let filename = "\(uidValue).eml"
                        let destination = outputDir.appendingPathComponent(filename)
                        try emlData.write(to: destination)
                        print("Saved \(filename) to \(destination.path)")
                        continue
                    }

                    let messages = try await client.fetchMessage(
                        serverId: serverId,
                        uids: String(uidValue),
                        mailbox: mailbox
                    )

                    foundCount += messages.count

                    for message in messages {
                        let formattedBody = try await formatBody(message)

                        if globals.json {
                            let headers = await resolveHeaders(for: message, client: client, serverId: serverId)
                            jsonMessages.append(FormattedMessage(
                                detail: message,
                                mailbox: mailbox,
                                formattedBody: formattedBody,
                                headers: headers
                            ))
                        } else if let outputDir {
                            let filename = "\(message.uid).txt"
                            let destination = outputDir.appendingPathComponent(filename)
                            try formattedBody.write(to: destination, atomically: true, encoding: .utf8)
                            print("Saved \(filename) to \(destination.path)")
                        } else {
                            print("UID: \(message.uid)")
                            print("From: \(message.from)")
                            print("To: \(message.to.joined(separator: ", "))")
                            print("Subject: \(message.subject)")
                            print("Date: \(message.date)")
                            if !message.attachments.isEmpty {
                                print("Attachments: \(message.attachments.map(\.filename).joined(separator: ", "))")
                            }
                            print()
                            print(formattedBody)
                            print()
                        }
                    }
                }

                if foundCount == 0 {
                    fputs("Error: No messages found\n", stderr)
                    throw ExitCode.failure
                }

                if globals.json, !eml {
                    outputJSON(jsonMessages)
                }
            }
        }
    }

    struct EML: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Parse a local .eml file and output body")

        enum BodyFormat: String, ExpressibleByArgument {
            case text, html, markdown
        }

        @Argument(help: "Path to the .eml file")
        var file: String

        @Option(name: .long, help: "Body format: text, html, or markdown (default: markdown)")
        var body: BodyFormat = .markdown

        @OptionGroup
        var globals: GlobalOptions

        func run() async throws {
            let fileURL = URL(fileURLWithPath: file)
            
            guard FileManager.default.fileExists(atPath: file) else {
                throw ValidationError("File not found: \(file)")
            }
            
            let emlData = try Data(contentsOf: fileURL)
            let message = try EMLParser.parse(emlData)
            
            // Convert to MessageDetail format
            let textBody = message.parts.first { $0.contentType.lowercased().hasPrefix("text/plain") }
                .flatMap { part -> String? in
                    guard let data = part.data else { return nil }
                    return String(data: data, encoding: .utf8)
                }
            
            let htmlBody = message.parts.first { $0.contentType.lowercased().hasPrefix("text/html") }
                .flatMap { part -> String? in
                    guard let data = part.data else { return nil }
                    return String(data: data, encoding: .utf8)
                }
            
            let detail = MessageDetail(
                uid: 0,
                from: message.from ?? "Unknown",
                to: message.to,
                subject: message.subject ?? "(No Subject)",
                date: ISO8601DateFormatter().string(from: message.date ?? Date()),
                textBody: textBody,
                htmlBody: htmlBody,
                attachments: [],
                additionalHeaders: [:]
            )
            
            // Format body according to option
            let formattedBody: String
            switch body {
            case .text:
                formattedBody = detail.textBody ?? ""
            case .html:
                formattedBody = detail.htmlBody ?? detail.textBody ?? ""
            case .markdown:
                formattedBody = try await detail.markdown()
            }
            
            if globals.json {
                struct EMLOutput: Codable {
                    let from: String
                    let to: [String]
                    let subject: String
                    let date: String
                    let body: String
                }
                
                let output = EMLOutput(
                    from: detail.from,
                    to: detail.to,
                    subject: detail.subject,
                    date: detail.date,
                    body: formattedBody
                )
                outputJSON([output])
            } else {
                print(formattedBody)
            }
        }
    }

    struct Folders: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List mailbox folders")

        @Option(name: .long, help: "Server identifier")
        var server: String?

        @OptionGroup
        var globals: GlobalOptions

        func run() async throws {
            try await withClient { client in
                let serverId = try await resolveServerID(explicit: server, client: client)
                let folders = try await client.listFolders(serverId: serverId)

                if globals.json {
                    outputJSON(folders)
                    return
                }

                if folders.isEmpty {
                    print("No folders found.")
                    return
                }

                for folder in folders {
                    if let specialUse = folder.specialUse, !specialUse.isEmpty {
                        print("- \(folder.name) (\(specialUse))")
                    } else {
                        print("- \(folder.name)")
                    }
                }
            }
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a mailbox folder")

        @Argument(help: "Mailbox name")
        var name: String

        @Option(name: .long, help: "Server identifier")
        var server: String?

        @OptionGroup
        var globals: GlobalOptions

        func run() async throws {
            try await withClient { client in
                let serverId = try await resolveServerID(explicit: server, client: client)
                let result = try await client.createMailbox(serverId: serverId, name: name)
                if globals.json {
                    outputJSON(ResultMessage(result: result))
                    return
                }
                print(result)
            }
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get mailbox status")

        @Option(name: .long, help: "Server identifier")
        var server: String?

        @Option(name: .long, help: "Mailbox name")
        var mailbox: String = "INBOX"

        @OptionGroup
        var globals: GlobalOptions

        func run() async throws {
            try await withClient { client in
                let serverId = try await resolveServerID(explicit: server, client: client)
                let status = try await client.mailboxStatus(serverId: serverId, mailbox: mailbox)
                if globals.json {
                    outputJSON(status)
                    return
                }
                printMailboxStatus(status)
            }
        }
    }

    struct Search: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Search messages")

        @Option(name: .long, help: "Server identifier")
        var server: String?

        @Option(name: .long, help: "Mailbox name")
        var mailbox: String = "INBOX"

        @Option(name: .long, help: "Search in From field")
        var from: String?

        @Option(name: .long, help: "Search in Subject field")
        var subject: String?

        @Option(name: .long, help: "Search in text")
        var text: String?

        @Option(name: .long, help: "Search internal date since (ISO 8601)")
        var since: String?

        @Option(name: .long, help: "Search internal date before (ISO 8601)")
        var before: String?

        @Option(name: .long, help: "Search a header field, format: Name:Value")
        var header: String?

        @Option(name: .long, help: "Search by Message-Id header value")
        var messageId: String?

        @ArgumentParser.Flag(name: .long, help: "Only unseen (unread) messages")
        var unseen: Bool = false

        @ArgumentParser.Flag(name: .long, help: "Only seen (read) messages")
        var seen: Bool = false

        @ArgumentParser.Flag(name: .long, help: "Only flagged messages")
        var flagged: Bool = false

        @ArgumentParser.Flag(name: .long, help: "Only unflagged messages")
        var unflagged: Bool = false

        @OptionGroup
        var globals: GlobalOptions

        func validate() throws {
            if unseen && seen {
                throw ValidationError("Only one of --unseen or --seen may be set.")
            }
            if flagged && unflagged {
                throw ValidationError("Only one of --flagged or --unflagged may be set.")
            }
            if header != nil && messageId != nil {
                throw ValidationError("Only one of --header or --message-id may be set.")
            }
            if let header {
                let parts = header.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                if parts.count != 2 || parts[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw ValidationError("--header must be in the form Name:Value (e.g. Message-Id:<...>)")
                }
            }
        }

        func run() async throws {
            try await withClient { client in
                let serverId = try await resolveServerID(explicit: server, client: client)
                var headerField: String?
                var headerValue: String?
                if let messageId {
                    headerField = "Message-Id"
                    headerValue = messageId
                } else if let header {
                    let parts = header.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    headerField = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                    headerValue = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                }

                let messages = try await client.searchMessages(
                    serverId: serverId,
                    mailbox: mailbox,
                    from: from,
                    subject: subject,
                    text: text,
                    since: since,
                    before: before,
                    headerField: headerField,
                    headerValue: headerValue,
                    unseen: unseen ? true : nil,
                    seen: seen ? true : nil,
                    flagged: flagged ? true : nil,
                    unflagged: unflagged ? true : nil
                )
                if globals.json {
                    outputJSON(messages.map(JSONMessageHeader.init))
                    return
                }
                printMessageHeaders(messages)
            }
        }
    }

    struct Move: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Move messages to another mailbox")

        @Argument(help: "Message UID set (e.g. 1,2,5-9)")
        var uids: String

        @Argument(help: "Target mailbox")
        var target: String

        @Option(name: .long, help: "Server identifier")
        var server: String?

        @Option(name: .long, help: "Source mailbox")
        var mailbox: String = "INBOX"

        @OptionGroup
        var globals: GlobalOptions

        func run() async throws {
            try await withClient { client in
                let serverId = try await resolveServerID(explicit: server, client: client)
                let message = try await client.moveMessages(
                    serverId: serverId,
                    uids: uids,
                    targetMailbox: target,
                    mailbox: mailbox
                )
                if globals.json {
                    outputJSON(ResultMessage(result: message))
                    return
                }
                print(message)
            }
        }
    }

    struct Copy: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Copy messages to another mailbox")

        @Argument(help: "Message UID set (e.g. 1,2,5-9)")
        var uids: String

        @Argument(help: "Target mailbox")
        var target: String

        @Option(name: .long, help: "Server identifier")
        var server: String?

        @Option(name: .long, help: "Source mailbox")
        var mailbox: String = "INBOX"

        @OptionGroup
        var globals: GlobalOptions

        func run() async throws {
            try await withClient { client in
                let serverId = try await resolveServerID(explicit: server, client: client)
                let result = try await client.copyMessages(
                    serverId: serverId,
                    uids: uids,
                    targetMailbox: target,
                    mailbox: mailbox
                )
                if globals.json {
                    outputJSON(ResultMessage(result: result))
                    return
                }
                print(result)
            }
        }
    }

    struct FlagMessages: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "flag",
            abstract: "Add/remove flags or set Mail.app flag color on messages"
        )

        @Argument(help: "Message UID set (e.g. 1,2,5-9)")
        var uids: String

        @Option(name: .long, help: "Comma-separated flags to add")
        var add: String?

        @Option(name: .long, help: "Comma-separated flags to remove")
        var remove: String?

        @Option(name: .long, help: "Set Mail.app flag color (red, orange, yellow, green, blue, purple, gray)")
        var color: String?

        @ArgumentParser.Flag(name: .long, help: "Remove \\Flagged and all Mail.app color bits")
        var unflag: Bool = false

        @Option(name: .long, help: "Server identifier")
        var server: String?

        @Option(name: .long, help: "Mailbox name")
        var mailbox: String = "INBOX"

        @OptionGroup
        var globals: GlobalOptions

        private enum Operation {
            case add(String)
            case remove(String)
            case color(MailFlagColor)
            case unflag
        }

        private static let mailFlagColorBits: [SwiftMail.Flag] = [
            .custom("$MailFlagBit0"),
            .custom("$MailFlagBit1"),
            .custom("$MailFlagBit2")
        ]

        private static var supportedColorNames: String {
            MailFlagColor.allCases.map(\.rawValue).joined(separator: ", ")
        }

        private func normalized(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        private func parsedColor() throws -> MailFlagColor? {
            guard let colorValue = normalized(color) else { return nil }
            let normalizedColor = colorValue.lowercased()
            guard let color = MailFlagColor(rawValue: normalizedColor) else {
                throw ValidationError("Invalid --color '\(colorValue)'. Allowed values: \(Self.supportedColorNames).")
            }
            return color
        }

        private func resolvedOperation() throws -> Operation {
            let addValue = normalized(add)
            let removeValue = normalized(remove)
            let colorValue = try parsedColor()
            let selectedCount = [addValue != nil, removeValue != nil, colorValue != nil, unflag]
                .filter { $0 }
                .count

            guard selectedCount == 1 else {
                throw ValidationError("Exactly one of --add, --remove, --color, or --unflag is required.")
            }

            if let addValue {
                return .add(addValue)
            }

            if let removeValue {
                return .remove(removeValue)
            }

            if let colorValue {
                return .color(colorValue)
            }

            return .unflag
        }

        private func applyFlags(
            _ flags: [SwiftMail.Flag],
            operation: String,
            client: PostProxy,
            serverId: String
        ) async throws {
            guard !flags.isEmpty else { return }
            let joinedFlags = flags.map { $0.description }.joined(separator: ",")
            _ = try await client.flagMessages(
                serverId: serverId,
                uids: uids,
                flags: joinedFlags,
                operation: operation,
                mailbox: mailbox
            )
        }

        func validate() throws {
            _ = try resolvedOperation()
        }

        func run() async throws {
            let operation = try resolvedOperation()

            try await withClient { client in
                let serverId = try await resolveServerID(explicit: server, client: client)
                let result: String

                switch operation {
                case .add(let flags):
                    result = try await client.flagMessages(
                        serverId: serverId,
                        uids: uids,
                        flags: flags,
                        operation: "add",
                        mailbox: mailbox
                    )
                case .remove(let flags):
                    result = try await client.flagMessages(
                        serverId: serverId,
                        uids: uids,
                        flags: flags,
                        operation: "remove",
                        mailbox: mailbox
                    )
                case .color(let color):
                    try await applyFlags(
                        Self.mailFlagColorBits,
                        operation: "remove",
                        client: client,
                        serverId: serverId
                    )
                    try await applyFlags(
                        [.flagged],
                        operation: "add",
                        client: client,
                        serverId: serverId
                    )
                    try await applyFlags(
                        color.flagBits,
                        operation: "add",
                        client: client,
                        serverId: serverId
                    )
                    result = "Set Mail.app flag color to \(color.rawValue)."
                case .unflag:
                    try await applyFlags(
                        [.flagged],
                        operation: "remove",
                        client: client,
                        serverId: serverId
                    )
                    try await applyFlags(
                        Self.mailFlagColorBits,
                        operation: "remove",
                        client: client,
                        serverId: serverId
                    )
                    result = "Removed \\Flagged and Mail.app color bits."
                }

                if globals.json {
                    outputJSON(ResultMessage(result: result))
                    return
                }
                print(result)
            }
        }
    }

    struct Trash: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Move messages to trash")

        @Argument(help: "Message UID set (e.g. 1,2,5-9)")
        var uids: String

        @Option(name: .long, help: "Server identifier")
        var server: String?

        @Option(name: .long, help: "Source mailbox")
        var mailbox: String = "INBOX"

        @OptionGroup
        var globals: GlobalOptions

        func run() async throws {
            try await withClient { client in
                let serverId = try await resolveServerID(explicit: server, client: client)
                let result = try await client.trashMessages(serverId: serverId, uids: uids, mailbox: mailbox)
                if globals.json {
                    outputJSON(ResultMessage(result: result))
                    return
                }
                print(result)
            }
        }
    }

    struct Archive: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Archive messages")

        @Argument(help: "Message UID set (e.g. 1,2,5-9)")
        var uids: String

        @Option(name: .long, help: "Server identifier")
        var server: String?

        @Option(name: .long, help: "Source mailbox")
        var mailbox: String = "INBOX"

        @OptionGroup
        var globals: GlobalOptions

        func run() async throws {
            try await withClient { client in
                let serverId = try await resolveServerID(explicit: server, client: client)
                let result = try await client.archiveMessages(serverId: serverId, uids: uids, mailbox: mailbox)
                if globals.json {
                    outputJSON(ResultMessage(result: result))
                    return
                }
                print(result)
            }
        }
    }

    struct Junk: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Mark messages as junk")

        @Argument(help: "Message UID set (e.g. 1,2,5-9)")
        var uids: String

        @Option(name: .long, help: "Server identifier")
        var server: String?

        @Option(name: .long, help: "Source mailbox")
        var mailbox: String = "INBOX"

        @OptionGroup
        var globals: GlobalOptions

        func run() async throws {
            try await withClient { client in
                let serverId = try await resolveServerID(explicit: server, client: client)
                let result = try await client.junkMessages(serverId: serverId, uids: uids, mailbox: mailbox)
                if globals.json {
                    outputJSON(ResultMessage(result: result))
                    return
                }
                print(result)
            }
        }
    }

    struct Expunge: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Expunge deleted messages")

        @Option(name: .long, help: "Server identifier")
        var server: String?

        @Option(name: .long, help: "Mailbox name")
        var mailbox: String = "INBOX"

        @OptionGroup
        var globals: GlobalOptions

        func run() async throws {
            try await withClient { client in
                let serverId = try await resolveServerID(explicit: server, client: client)
                let result = try await client.expungeMessages(serverId: serverId, mailbox: mailbox)
                if globals.json {
                    outputJSON(ResultMessage(result: result))
                    return
                }
                print(result)
            }
        }
    }

    struct Quota: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show storage quota")

        @Option(name: .long, help: "Server identifier")
        var server: String?

        @Option(name: .long, help: "Mailbox name")
        var mailbox: String = "INBOX"

        @OptionGroup
        var globals: GlobalOptions

        func run() async throws {
            try await withClient { client in
                let serverId = try await resolveServerID(explicit: server, client: client)
                let quota = try await client.getQuota(serverId: serverId, mailbox: mailbox)
                if globals.json {
                    outputJSON(quota)
                    return
                }
                printQuotaInfo(quota)
            }
        }
    }

    struct Attachment: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Download attachment from a message")

        @Argument(help: "Message UID")
        var uid: Int

        @Option(name: .long, help: "Attachment filename (downloads first if omitted)")
        var filename: String?

        @Option(name: .long, help: "Server identifier")
        var server: String?

        @Option(name: .long, help: "Mailbox name")
        var mailbox: String = "INBOX"

        @Option(name: .long, help: "Output directory (default: current directory)")
        var out: String = "."

        func run() async throws {
            try await withClient { client in
                let serverId = try await resolveServerID(explicit: server, client: client)
                let attachment = try await client.downloadAttachment(serverId: serverId, uid: uid, filename: filename, mailbox: mailbox)

                guard let data = Data(base64Encoded: attachment.data) else {
                    print("Error: Failed to decode attachment data.")
                    return
                }

                let outputDir = URL(fileURLWithPath: out, isDirectory: true)
                try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
                let destination = outputDir.appendingPathComponent(attachment.filename)
                try data.write(to: destination)
                print("Saved \(attachment.filename) (\(attachment.contentType), \(formatBytes(attachment.size))) to \(destination.path)")
            }
        }
    }

    struct PDF: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "pdf",
            abstract: "Export message body as PDF"
        )

        @Argument(help: "Message UID(s) (comma-separated; ranges like 1-3 allowed)")
        var uid: String

        @Option(name: .long, help: "Server identifier")
        var server: String?

        @Option(name: .long, help: "Mailbox name")
        var mailbox: String = "INBOX"

        @Option(name: .long, help: "Output path: directory or filename (default: current directory)")
        var out: String = "."

        func validate() throws {
            guard MessageIdentifierSet<UID>(string: uid) != nil else {
                throw ValidationError("Invalid UID set '\(uid)'. Use comma-separated values or ranges (e.g. 1-3,5,10-20).")
            }
        }

        func run() async throws {
            try await withClient { client in
                let serverId = try await resolveServerID(explicit: server, client: client)
                guard let uidSet = MessageIdentifierSet<UID>(string: uid) else {
                    throw ValidationError("Invalid UID set '\(uid)'.")
                }

                let outURL = URL(fileURLWithPath: out)
                let isExplicitFile = outURL.pathExtension.lowercased() == "pdf"
                let uidArray = uidSet.toArray()

                if isExplicitFile && uidArray.count > 1 {
                    throw ValidationError("Cannot use a filename for --out when exporting multiple UIDs. Use a directory instead.")
                }

                let outputDir = isExplicitFile ? outURL.deletingLastPathComponent() : outURL
                try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

                var foundCount = 0
                for messageUID in uidArray {
                    let uidValue = Int(messageUID.value)
                    let result = try await client.exportPDF(serverId: serverId, uid: uidValue, mailbox: mailbox)
                    guard let data = Data(base64Encoded: result.data) else {
                        fputs("Error: Failed to decode PDF for UID \(uidValue)\n", stderr)
                        continue
                    }

                    let destination = isExplicitFile ? outURL : outputDir.appendingPathComponent(result.filename)
                    let displayName = destination.lastPathComponent
                    try data.write(to: destination)
                    print("Saved \(displayName) (\(formatBytes(result.size))) to \(destination.path)")
                    foundCount += 1
                }

                if foundCount == 0 {
                    fputs("Error: No PDFs exported\n", stderr)
                    throw ExitCode.failure
                }
            }
        }
    }

    struct Draft: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a new email draft")

        @Option(name: .long, help: "Sender email address")
        var from: String

        @Option(name: .long, help: "Comma-separated recipient addresses")
        var to: String

        @Option(name: .long, help: "Email subject")
        var subject: String

        @Option(
            name: .long,
            help: "Body text or file path. Existing files are read; inline values decode escapes and auto-detect as HTML, Markdown, or plain text.",
            transform: resolveDraftBodyInputForCLI
        )
        var body: String

        @Option(name: .long, help: "Comma-separated CC addresses")
        var cc: String?

        @Option(name: .long, help: "Comma-separated BCC addresses")
        var bcc: String?

        @Option(name: .long, parsing: .upToNextOption, help: "File paths or glob patterns to attach (repeatable)")
        var attach: [String] = []

        @Option(name: .long, help: "Server identifier")
        var server: String?

        @Option(name: .long, help: "Target mailbox (default: server's Drafts folder)")
        var mailbox: String?

        @OptionGroup
        var globals: GlobalOptions

        func run() async throws {
            let format: String
            switch detectDraftBodyInputFormat(body) {
            case .html:
                format = "html"
            case .markdown:
                format = "markdown"
            case .plainText:
                format = "text"
            }

            try await withClient { client in
                let serverId = try await resolveServerID(explicit: server, client: client)
                let attachments = attach.isEmpty ? nil : attach.joined(separator: ",")
                let result = try await client.createDraft(
                    serverId: serverId,
                    from: from,
                    to: to,
                    subject: subject,
                    body: body,
                    format: format,
                    cc: cc,
                    bcc: bcc,
                    attachments: attachments,
                    mailbox: mailbox
                )
                if globals.json {
                    outputJSON(result)
                    return
                }
                if let uid = result.uid {
                    print("Draft created in '\(result.mailbox)' (UID \(uid)).")
                } else {
                    print("Draft created in '\(result.mailbox)'.")
                }
            }
        }
    }

    struct Reply: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a reply draft to an existing message")

        @Argument(help: "UID of the message to reply to")
        var uid: Int

        @Option(name: .long, help: "Reply text body (will be placed before quoted original; omit to create empty draft for inline editing)")
        var body: String?

        @ArgumentParser.Flag(name: .long, help: "Reply-all to all recipients")
        var all: Bool = false

        @Option(name: .long, help: "Server identifier")
        var server: String?

        @Option(name: .long, help: "Source mailbox containing the original message")
        var mailbox: String = "INBOX"

        @Option(name: .long, help: "Comma-separated CC addresses (optional, only for reply-all)")
        var cc: String?

        @Option(name: .long, parsing: .upToNextOption, help: "File paths or glob patterns to attach (repeatable)")
        var attach: [String] = []

        @OptionGroup
        var globals: GlobalOptions

        func run() async throws {
            try await withClient(quiet: globals.json) { client in
                let serverId = try await resolveServerID(explicit: server, client: client)
                
                // Fetch the original message
                let messages = try await client.fetchMessage(
                    serverId: serverId,
                    uids: String(uid),
                    mailbox: mailbox
                )
                
                guard let original = messages.first else {
                    throw ValidationError("Message UID \(uid) not found in \(mailbox)")
                }
                
                // Format the reply
                let replySubject = original.subject.hasPrefix("Re: ") ? original.subject : "Re: \(original.subject)"
                let quotedBody = try await formatQuotedReply(original: original)
                
                // If body is provided, place it before the quote; otherwise just the quote (for inline editing)
                let fullBody: String
                if let replyText = body, !replyText.isEmpty {
                    fullBody = "\(replyText)\n\(quotedBody)"
                } else {
                    fullBody = quotedBody
                }
                
                // Determine recipients
                let toAddress = original.from
                let ccAddresses = all ? original.to.filter({ $0 != toAddress }).joined(separator: ",") : (cc ?? "")
                
                // Get sender from original "to" (user's address)
                guard let fromAddress = original.to.first else {
                    throw ValidationError("Cannot determine sender address from original message")
                }
                
                // Create the reply draft
                let attachments = attach.isEmpty ? nil : attach.joined(separator: ",")
                let result = try await client.createDraft(
                    serverId: serverId,
                    from: fromAddress,
                    to: toAddress,
                    subject: replySubject,
                    body: fullBody,
                    format: "text",
                    cc: ccAddresses.isEmpty ? nil : ccAddresses,
                    bcc: nil,
                    attachments: attachments,
                    mailbox: nil  // Use server's Drafts folder
                )
                
                if globals.json {
                    outputJSON(result)
                    return
                }
                if let draftUID = result.uid {
                    print("Reply draft created in '\(result.mailbox)' (UID \(draftUID)).")
                } else {
                    print("Reply draft created in '\(result.mailbox)'.")
                }
            }
        }
        
        private func formatQuotedReply(original: MessageDetail) async throws -> String {
            // Get markdown body
            let body = try await original.markdown()
            
            return formatQuotedBody(from: original.from, date: original.date, body: body)
        }
        
        private func formatQuotedBody(from: String, date: String, body: String) -> String {
            // Parse the date from ISO8601 and format as German DD.MM.YYYY, HH:MM
            let dateFormatter = ISO8601DateFormatter()
            dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            
            let germanFormatter = DateFormatter()
            germanFormatter.dateFormat = "dd.MM.yyyy, 'at' HH:mm"
            germanFormatter.locale = Locale(identifier: "en_US")
            
            let dateString: String
            if let parsedDate = dateFormatter.date(from: date) {
                dateString = germanFormatter.string(from: parsedDate)
            } else {
                dateString = date
            }
            
            // Build quote header: "> On DD.MM.YYYY, at HH:MM, sender@email.com wrote:"
            let quoteHeader = "> On \(dateString), \(from) wrote:"
            
            // Quote the body (each line prefixed with "> ")
            let bodyLines = body.components(separatedBy: "\n")
            let quotedLines = bodyLines.map { line in
                line.isEmpty ? ">" : "> \(line)"
            }
            
            // Combine: header + blank quote line + quoted body
            return "\(quoteHeader)\n>\n\(quotedLines.joined(separator: "\n"))"
        }
    }

    struct Idle: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Watch IMAP IDLE events in real time (debug tool)")

        @Option(name: .long, help: "Scoped API key token (overrides POST_API_KEY and .env)")
        var token: String?

        func run() async throws {
            let tcpConfig = MCPServerTcpConfig(serviceName: PostProxy.serverName)
            let proxy = MCPServerProxy(config: .tcp(config: tcpConfig))
            if let token = resolveAPIToken() {
                await proxy.setAccessTokenMeta(token)
            }

            await proxy.setLogNotificationHandler(IdleEventLogger())

            try await proxy.connect()
            try await setProxyLogLevel(.debug, on: proxy)

            fputs("Connected to postd. Watching IDLE events (Ctrl+C to stop)...\n", stderr)

            let client = PostProxy(proxy: proxy)
            do {
                try await client.watchIdleEvents()
            } catch is CancellationError {
                // Expected on Ctrl+C
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                await proxy.disconnect()
                Darwin.exit(1)
            }

            await proxy.disconnect()
        }
    }

    struct Credential: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manage IMAP credentials in the Keychain",
            subcommands: [Set.self, Delete.self, List.self]
        )

        struct Set: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "set",
                abstract: "Store IMAP credentials in the Keychain"
            )

            @Option(name: .long, help: "Server identifier")
            var server: String

            @Option(name: .long, help: "IMAP host")
            var host: String?

            @Option(name: .long, help: "IMAP port")
            var port: Int?

            @Option(name: .long, help: "IMAP username")
            var username: String?

            @Option(name: .long, help: "IMAP password")
            var password: String?

            func run() throws {
                #if canImport(Security)
                let config = try? PostConfiguration.load()
                if let config, config.server(withID: server) == nil {
                    throw PostConfigurationError.unknownServer(server)
                }

                let fallbackCredentials = config?.server(withID: server)?.credentials
                let resolvedHost = try resolveRequiredValue(
                    explicit: host,
                    fallback: fallbackCredentials?.host,
                    prompt: "Host"
                )

                let resolvedPort = try resolvePort(
                    explicit: port,
                    fallback: fallbackCredentials?.port,
                    prompt: "Port",
                    defaultValue: 993
                )

                let resolvedUsername = try resolveRequiredValue(
                    explicit: username,
                    fallback: fallbackCredentials?.username,
                    prompt: "Username"
                )

                let resolvedPassword: String
                if let explicitPassword = password?.trimmingCharacters(in: .whitespacesAndNewlines), !explicitPassword.isEmpty {
                    resolvedPassword = explicitPassword
                } else if let fallbackPassword = fallbackCredentials?.password, !fallbackPassword.isEmpty {
                    resolvedPassword = fallbackPassword
                } else {
                    print("Password: ", terminator: "")
                    resolvedPassword = readPassword()
                }

                guard !resolvedPassword.isEmpty else {
                    print("Password cannot be empty.")
                    throw ExitCode.failure
                }

                let store = KeychainCredentialStore()
                try store.store(
                    id: server,
                    host: resolvedHost,
                    port: resolvedPort,
                    username: resolvedUsername,
                    password: resolvedPassword
                )
                print("Credential stored for server '\(server)' in the login keychain.")
                #else
                print("Keychain is not available on this platform.")
                throw ExitCode.failure
                #endif
            }
        }

        struct Delete: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "delete",
                abstract: "Remove IMAP credentials from the Keychain"
            )

            @Option(name: .long, help: "Server identifier")
            var server: String

            func run() throws {
                #if canImport(Security)
                let store = KeychainCredentialStore()
                try store.delete(label: server)
                print("Credential deleted.")
                #else
                print("Keychain is not available on this platform.")
                throw ExitCode.failure
                #endif
            }
        }

        struct List: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "list",
                abstract: "List stored IMAP credentials"
            )

            func run() throws {
                #if canImport(Security)
                let store = KeychainCredentialStore()
                let credentials = try store.list()

                if credentials.isEmpty {
                    print("No credentials stored.")
                    return
                }

                let idWidth = max("ID".count, credentials.map { $0.id.count }.max() ?? 0)
                let userWidth = max("Username".count, credentials.map { $0.username.count }.max() ?? 0)

                print("\(pad("ID", to: idWidth))  \(pad("Username", to: userWidth))  Host")
                print("\(String(repeating: "-", count: idWidth))  \(String(repeating: "-", count: userWidth))  \(String(repeating: "-", count: 4))")

                for cred in credentials {
                    print("\(pad(cred.id, to: idWidth))  \(pad(cred.username, to: userWidth))  \(cred.host):\(cred.port)")
                }
                #else
                print("Keychain is not available on this platform.")
                throw ExitCode.failure
                #endif
            }
        }

    }

    struct APIKey: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "api-key",
            abstract: "Manage scoped API keys for MCP access",
            subcommands: [Create.self, List.self, Delete.self]
        )

        struct Create: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Create an API key scoped to selected servers")

            @Option(name: .long, help: "Allowed server IDs (comma-separated)")
            var servers: String

            func run() throws {
                #if canImport(Security)
                let serverIDs = servers
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                guard !serverIDs.isEmpty else {
                    throw ValidationError("At least one server ID is required.")
                }

                let store = APIKeyStore()
                let record = try store.createKey(allowedServerIDs: serverIDs)
                print("API key: \(record.token)")
                print("Allowed servers: \(record.allowedServerIDs.joined(separator: ", "))")
                #else
                print("API key management is not available on this platform.")
                throw ExitCode.failure
                #endif
            }
        }

        struct List: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "List stored API keys")

            func run() throws {
                #if canImport(Security)
                let store = APIKeyStore()
                let keys = try store.listKeys()

                if keys.isEmpty {
                    print("No API keys stored.")
                    return
                }

                for key in keys {
                    let iso = ISO8601DateFormatter().string(from: key.createdAt)
                    let servers = key.allowedServerIDs.joined(separator: ", ")
                    print("\(key.token)  \(iso)  [\(servers)]")
                }
                #else
                print("API key management is not available on this platform.")
                throw ExitCode.failure
                #endif
            }
        }

        struct Delete: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Delete a stored API key")

            @Option(name: .long, help: "API key token (UUID)")
            var token: String

            func run() throws {
                #if canImport(Security)
                let store = APIKeyStore()
                try store.delete(token: token)
                print("API key deleted.")
                #else
                print("API key management is not available on this platform.")
                throw ExitCode.failure
                #endif
            }
        }
    }
}

/// Reads a password from stdin with echo disabled.
private func readPassword() -> String {
    #if canImport(Darwin)
    var oldTermios = termios()
    tcgetattr(STDIN_FILENO, &oldTermios)
    var newTermios = oldTermios
    newTermios.c_lflag &= ~UInt(ECHO)
    tcsetattr(STDIN_FILENO, TCSANOW, &newTermios)
    defer {
        tcsetattr(STDIN_FILENO, TCSANOW, &oldTermios)
        print() // newline after hidden input
    }
    #endif
    return (readLine(strippingNewline: true) ?? "")
}

private func resolveRequiredValue(explicit: String?, fallback: String?, prompt: String) throws -> String {
    if let explicit = explicit?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
        return explicit
    }

    if let fallback = fallback?.trimmingCharacters(in: .whitespacesAndNewlines), !fallback.isEmpty {
        return fallback
    }

    print("\(prompt): ", terminator: "")
    let value = (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else {
        print("\(prompt) cannot be empty.")
        throw ExitCode.failure
    }
    return value
}

private func resolvePort(explicit: Int?, fallback: Int?, prompt: String, defaultValue: Int) throws -> Int {
    if let explicit {
        return explicit
    }

    if let fallback {
        return fallback
    }

    print("\(prompt) [\(defaultValue)]: ", terminator: "")
    let raw = (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if raw.isEmpty {
        return defaultValue
    }

    guard let value = Int(raw) else {
        print("Invalid \(prompt.lowercased()).")
        throw ExitCode.failure
    }

    return value
}

private enum PostCLIError: Error, LocalizedError {
    case noServersConfigured

    var errorDescription: String? {
        switch self {
        case .noServersConfigured:
            return "No IMAP servers are configured in the daemon."
        }
    }
}

private struct ResultMessage: Codable {
    let result: String
}

private struct JSONMessageHeader: Codable {
    let uid: Int
    let from: String
    let subject: String
    let date: String
    let flag: String?

    init(_ message: MessageHeader) {
        uid = message.uid
        from = message.from
        subject = message.subject
        date = message.date
        flag = message.flagColor?.rawValue
    }
}

private extension MessageHeader {
    var flagColor: MailFlagColor? {
        guard let flag else { return nil }
        return MailFlagColor(rawValue: flag)
    }
}

private func setProxyLogLevel(_ level: LogLevel, on proxy: MCPServerProxy) async throws {
    let request = JSONRPCMessage.request(
        id: UUID().uuidString,
        method: "logging/setLevel",
        params: [
            "level": AnyCodable(level.rawValue)
        ]
    )

    let response = try await proxy.send(request)
    switch response {
    case .response:
        return
    case .errorResponse(let error):
        throw ValidationError("Failed to configure MCP log level to '\(level.rawValue)': \(error.error.message)")
    default:
        throw ValidationError("Unexpected response while configuring MCP log level to '\(level.rawValue)'.")
    }
}

private func withClient<T>(quiet: Bool = false, _ operation: (PostProxy) async throws -> T) async throws -> T {
    var stderrSaved: Int32 = -1
    var devNull: Int32 = -1

    if quiet {
        // Save original stderr
        stderrSaved = dup(STDERR_FILENO)
        // Open /dev/null
        devNull = open("/dev/null", O_WRONLY)
        if devNull != -1 {
            // Redirect stderr to /dev/null
            dup2(devNull, STDERR_FILENO)
        }
    }

    defer {
        if quiet && stderrSaved != -1 {
            // Restore original stderr
            dup2(stderrSaved, STDERR_FILENO)
            close(stderrSaved)
            if devNull != -1 {
                close(devNull)
            }
        }
    }

    let tcpConfig = MCPServerTcpConfig(serviceName: PostProxy.serverName)
    let proxy = MCPServerProxy(config: .tcp(config: tcpConfig))
    if let token = resolveAPIToken() {
        await proxy.setAccessTokenMeta(token)
    }
    try await proxy.connect()

    if quiet {
        try? await setProxyLogLevel(.error, on: proxy)
    }

    defer {
        Task {
            await proxy.disconnect()
        }
    }

    let client = PostProxy(proxy: proxy)
    return try await operation(client)
}

private func resolveAPIToken() -> String? {
    if let token = commandLineToken(), !token.isEmpty {
        return token
    }

    if let envToken = ProcessInfo.processInfo.environment["POST_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !envToken.isEmpty {
        return envToken
    }

    if let dotEnvToken = loadDotEnvValue(named: "POST_API_KEY"), !dotEnvToken.isEmpty {
        return dotEnvToken
    }

    return nil
}

private func commandLineToken() -> String? {
    let args = CommandLine.arguments

    for (index, arg) in args.enumerated() {
        if arg == "--token", args.indices.contains(index + 1) {
            return args[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if arg.hasPrefix("--token=") {
            let value = String(arg.dropFirst("--token=".count))
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    return nil
}

private func loadDotEnvValue(named key: String) -> String? {
    let envURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env")
    guard let raw = try? String(contentsOf: envURL, encoding: .utf8) else {
        return nil
    }

    for line in raw.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("#") {
            continue
        }

        let withoutExport: String
        if trimmed.hasPrefix("export ") {
            withoutExport = String(trimmed.dropFirst("export ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            withoutExport = trimmed
        }

        guard let separatorIndex = withoutExport.firstIndex(of: "=") else {
            continue
        }

        let name = withoutExport[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        guard name == key else {
            continue
        }

        var value = withoutExport[withoutExport.index(after: separatorIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        } else if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }
        return value
    }

    return nil
}

private extension MCPServerProxy {
    func setAccessTokenMeta(_ token: String) {
        meta["accessToken"] = AnyCodable(token)
    }
}

private func outputJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(value), let string = String(data: data, encoding: .utf8) else {
        print("Error: Failed to encode JSON.")
        return
    }
    print(string)
}

private func resolveServerID(explicit: String?, client: PostProxy) async throws -> String {
    if let explicit {
        return explicit
    }

    let servers = try await client.listServers()
    guard !servers.isEmpty else {
        throw PostCLIError.noServersConfigured
    }

    if servers.count == 1, let only = servers.first {
        return only.id
    }

    let available = servers.map(\.id).sorted().joined(separator: ", ")
    throw ValidationError("Multiple servers configured (\(servers.count)): --server is required. Available: \(available)")
}

private func printServersTable(_ servers: [ServerInfo]) {
    guard !servers.isEmpty else {
        print("No servers configured.")
        return
    }

    let idWidth = max("ID".count, servers.map { $0.id.count }.max() ?? 0)
    let userWidth = max("Username".count, servers.map { ($0.username ?? "<unresolved>").count }.max() ?? 0)

    print("\(pad("ID", to: idWidth))  \(pad("Username", to: userWidth))  Host")
    print("\(String(repeating: "-", count: idWidth))  \(String(repeating: "-", count: userWidth))  \(String(repeating: "-", count: 4))")

    for server in servers {
        let host: String
        if let resolvedHost = server.host, let resolvedPort = server.port {
            host = "\(resolvedHost):\(resolvedPort)"
        } else if let resolvedHost = server.host {
            host = resolvedHost
        } else {
            host = "<unresolved>"
        }

        let username = server.username ?? "<unresolved>"
        print("\(pad(server.id, to: idWidth))  \(pad(username, to: userWidth))  \(host)")
    }
}

private func printMessageHeaders(_ messages: [MessageHeader]) {
    guard !messages.isEmpty else {
        print("No messages found.")
        return
    }

    for message in messages {
        let dateText = message.date.isEmpty ? "Unknown Date" : message.date
        let fromText = message.from.isEmpty ? "Unknown" : message.from
        let subjectText = message.subject.isEmpty ? "(No Subject)" : message.subject

        print("[\(message.uid)] \(dateText) - \(fromText)")
        print("   \(subjectText)")
    }
}

private func printMessageDetail(_ message: MessageDetail) {
    print("UID: \(message.uid)")
    print("From: \(message.from)")
    print("To: \(message.to.joined(separator: ", "))")
    print("Subject: \(message.subject)")
    print("Date: \(message.date)")
    print("")

    if let textBody = message.textBody, !textBody.isEmpty {
        print(textBody)
    } else if let htmlBody = message.htmlBody, !htmlBody.isEmpty {
        print("(HTML Body)")
        print(htmlBody)
    } else {
        print("(No body available)")
    }

    if let headers = message.additionalHeaders, !headers.isEmpty {
        print("Headers:")
        for key in headers.keys.sorted() {
            print("  \(key): \(headers[key]!)")
        }
        print("")
    }

    if message.attachments.isEmpty {
        print("Attachments: none")
    } else {
        print("Attachments:")
        for attachment in message.attachments {
            print("- \(attachment.filename) (\(attachment.contentType))")
        }
    }
}

private func printMailboxStatus(_ status: Mailbox.Status) {
    if let messageCount = status.messageCount {
        print("Messages: \(messageCount)")
    }
    if let recentCount = status.recentCount {
        print("Recent: \(recentCount)")
    }
    if let unseenCount = status.unseenCount {
        print("Unseen: \(unseenCount)")
    }
    if let uidNext = status.uidNext {
        print("UID Next: \(uidNext)")
    }
    if let uidValidity = status.uidValidity {
        print("UID Validity: \(uidValidity)")
    }
}

private func printQuotaInfo(_ quota: Quota) {
    for resource in quota.resources {
        if resource.resourceName.uppercased() == "STORAGE" {
            print("\(resource.resourceName): \(resource.usage) / \(resource.limit) KB")
        } else {
            print("\(resource.resourceName): \(resource.usage) / \(resource.limit)")
        }
    }
}

private func decodeFetchHeaders(_ additionalHeaders: [String: String]?) -> [String: String] {
    guard let additionalHeaders else { return [:] }

    var decoded: [String: String] = [:]
    decoded.reserveCapacity(additionalHeaders.count)

    for (rawKey, rawValue) in additionalHeaders {
        let key = normalizeFetchHeaderKey(rawKey)
        let value = decodeFetchHeaderValue(rawValue)
        guard !key.isEmpty, !value.isEmpty else { continue }
        decoded[key] = value
    }

    return decoded
}

private func parseAdditionalHeaders(from emlData: Data) -> [String: String] {
    guard let content = String(data: emlData, encoding: .utf8)
            ?? String(data: emlData, encoding: .isoLatin1) else {
        return [:]
    }

    let headerBlock: Substring
    if let split = content.range(of: "\r\n\r\n") {
        headerBlock = content[..<split.lowerBound]
    } else if let split = content.range(of: "\n\n") {
        headerBlock = content[..<split.lowerBound]
    } else {
        headerBlock = content[content.startIndex..<content.endIndex]
    }

    var parsed: [String: String] = [:]
    var currentKey: String?
    var currentValue = ""

    for line in headerBlock.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init) {
        if line.isEmpty {
            continue
        }

        if let first = line.first, first == " " || first == "\t" {
            currentValue += "\r\n" + line
            continue
        }

        if let currentKey {
            parsed[currentKey] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let colonIndex = line.firstIndex(of: ":") else {
            currentKey = nil
            currentValue = ""
            continue
        }

        currentKey = normalizeFetchHeaderKey(String(line[..<colonIndex]))
        currentValue = String(line[line.index(after: colonIndex)...])
    }

    if let currentKey {
        parsed[currentKey] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    let standardKeys: Set<String> = [
        "from", "to", "cc", "bcc", "subject", "date", "message-id",
        "content-type", "content-transfer-encoding", "mime-version"
    ]
    return parsed.filter { !standardKeys.contains($0.key) }
}

private func normalizeFetchHeaderKey(_ key: String) -> String {
    key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

private func decodeFetchHeaderValue(_ value: String) -> String {
    let unfolded = unfoldFetchHeaderValue(value)
    let decoded = unfolded.decodeMIMEHeader()
    return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func unfoldFetchHeaderValue(_ value: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: "\\r?\\n[\\t ]+") else {
        return value
    }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return regex.stringByReplacingMatches(in: value, range: range, withTemplate: " ")
}

enum DraftBodyInputFormat {
    case html
    case markdown
    case plainText
}

func resolveDraftBodyInputForCLI(_ value: String) throws -> String {
    let expandedPath = NSString(string: value).expandingTildeInPath
    var isDirectory = ObjCBool(false)
    if FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory) {
        guard !isDirectory.boolValue else {
            throw ValidationError("--body path '\(value)' is a directory.")
        }

        let url = URL(fileURLWithPath: expandedPath)
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            guard let data = try? Data(contentsOf: url),
                  let fallback = String(data: data, encoding: .isoLatin1) else {
                throw ValidationError("Failed to read --body file '\(value)': \(error.localizedDescription)")
            }
            return fallback
        }
    }

    return decodeBodyEscapesForCLI(value)
}

func detectDraftBodyInputFormat(_ content: String) -> DraftBodyInputFormat {
    if looksLikeHTML(content) {
        return .html
    }
    if looksLikeMarkdown(content) {
        return .markdown
    }
    return .plainText
}

private func looksLikeHTML(_ content: String) -> Bool {
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return false
    }

    let pattern = #"(?is)<!DOCTYPE\s+html|<\s*/?\s*(html|head|body|div|span|p|br|h[1-6]|ul|ol|li|table|tr|td|th|a|img|strong|em|b|i|blockquote|pre|code)\b[^>]*>"#
    return matchesPattern(content, pattern: pattern)
}

private func looksLikeMarkdown(_ content: String) -> Bool {
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return false
    }

    let patterns = [
        #"(?m)^\s{0,3}#{1,6}\s+\S"#,
        #"(?m)^\s{0,3}[-*+]\s+\S"#,
        #"(?m)^\s{0,3}\d+\.\s+\S"#,
        #"(?m)^>\s+\S"#,
        #"(?m)^(```|~~~)"#,
        #"(?m)^([-*_])\1{2,}\s*$"#,
        #"\[[^\]]+\]\([^)]+\)"#,
        #"!\[[^\]]*\]\([^)]+\)"#,
        #"`[^`\n]+`"#,
        #"\*\*[^*\n]+\*\*|__[^_\n]+__"#
    ]

    return patterns.contains { matchesPattern(content, pattern: $0) }
}

private func matchesPattern(_ content: String, pattern: String) -> Bool {
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return false
    }
    let range = NSRange(content.startIndex..<content.endIndex, in: content)
    return regex.firstMatch(in: content, range: range) != nil
}

private func decodeBodyEscapesForCLI(_ value: String) -> String {
    guard value.contains("\\") else {
        return value
    }

    var decoded = String()
    decoded.reserveCapacity(value.count)
    var index = value.startIndex

    while index < value.endIndex {
        let character = value[index]
        guard character == "\\" else {
            decoded.append(character)
            value.formIndex(after: &index)
            continue
        }

        let nextIndex = value.index(after: index)
        guard nextIndex < value.endIndex else {
            decoded.append("\\")
            index = nextIndex
            continue
        }

        let next = value[nextIndex]
        switch next {
        case "n":
            decoded.append("\n")
        case "r":
            decoded.append("\r")
        case "t":
            decoded.append("\t")
        case "\\":
            decoded.append("\\")
        case "\"":
            decoded.append("\"")
        case "'":
            decoded.append("'")
        default:
            decoded.append("\\")
            decoded.append(next)
        }

        index = value.index(after: nextIndex)
    }

    return decoded
}

private func pad(_ value: String, to width: Int) -> String {
    guard value.count < width else {
        return value
    }
    return value + String(repeating: " ", count: width - value.count)
}

private func formatBytes(_ bytes: Int) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    let kb = Double(bytes) / 1024
    if kb < 1024 { return String(format: "%.1f KB", kb) }
    let mb = kb / 1024
    return String(format: "%.1f MB", mb)
}
