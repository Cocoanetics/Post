import Foundation
import Logging
import SwiftMCP
import SwiftMail

public enum PostServerError: Error, LocalizedError, Sendable {
    case invalidLimit(Int)
    case invalidUID(Int)
    case invalidUIDSet(String)
    case invalidDate(String, String)
    case messageNotFound(uid: Int, mailbox: String)

    public var errorDescription: String? {
        switch self {
        case .invalidLimit(let value):
            return "Limit must be greater than zero. Received: \(value)."
        case .invalidUID(let uid):
            return "UID must be between 1 and \(UInt32.max). Received: \(uid)."
        case .invalidUIDSet(let value):
            return "Invalid UID set '\(value)'. Use comma-separated values or ranges (e.g. 1,2,5-9)."
        case .invalidDate(let field, let value):
            return "Invalid ISO 8601 date for \(field): '\(value)'."
        case .messageNotFound(let uid, let mailbox):
            return "Message UID \(uid) was not found in mailbox '\(mailbox)'."
        }
    }
}

@MCPServer(name: "Post", generateClient: true)
public actor PostServer {
    private let connectionManager: IMAPConnectionManager
    private let logger = Logger(label: "com.cocoanetics.Post.PostServer")

    public init(configuration: PostConfiguration) {
        self.connectionManager = IMAPConnectionManager(configuration: configuration)
    }

    public func shutdown() async {
        await connectionManager.shutdown()
    }

    /// Lists all configured IMAP servers with their IDs and names
    @MCPTool
    public func listServers() async -> [ServerInfo] {
        await connectionManager.serverInfos()
    }

    /// Lists emails in a mailbox on the specified server
    /// - Parameter serverId: The server identifier from config
    /// - Parameter mailbox: Mailbox name (default: "INBOX")
    /// - Parameter limit: Number of messages to list (default: 10)
    @MCPTool
    public func listMessages(serverId: String, mailbox: String = "INBOX", limit: Int = 10) async throws -> [MessageHeader] {
        guard limit > 0 else {
            throw PostServerError.invalidLimit(limit)
        }

        return try await withServer(serverId: serverId) { server in
            let status = try await server.selectMailbox(mailbox)
            guard let latest = status.latest(limit) else {
                return []
            }

            let headers = try await collectHeaders(from: server.fetchMessages(using: latest))
            return headers.sorted { $0.uid > $1.uid }
        }
    }

    /// Fetches a specific email by UID
    /// - Parameter serverId: The server identifier
    /// - Parameter uid: The message UID
    /// - Parameter mailbox: Mailbox name (default: "INBOX")
    @MCPTool
    public func fetchMessage(serverId: String, uid: Int, mailbox: String = "INBOX") async throws -> MessageDetail {
        guard (1...Int(UInt32.max)).contains(uid) else {
            throw PostServerError.invalidUID(uid)
        }

        return try await withServer(serverId: serverId) { server in
            _ = try await server.selectMailbox(mailbox)
            let set = MessageIdentifierSet<UID>(UID(UInt32(uid)))

            for try await message in server.fetchMessages(using: set) {
                return messageDetail(from: message)
            }

            throw PostServerError.messageNotFound(uid: uid, mailbox: mailbox)
        }
    }

    /// Lists mailbox folders on the specified server
    /// - Parameter serverId: The server identifier
    @MCPTool
    public func listFolders(serverId: String) async throws -> [MailboxInfo] {
        try await withServer(serverId: serverId) { server in
            let folders = try await server.listMailboxes()

            return folders
                .map {
                    MailboxInfo(
                        name: $0.name,
                        specialUse: specialUseDescription(for: $0.attributes)
                    )
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    /// Searches emails on the specified server
    /// - Parameter serverId: The server identifier
    /// - Parameter mailbox: Mailbox name (default: "INBOX")
    /// - Parameter from: Search in From field
    /// - Parameter subject: Search in Subject field
    /// - Parameter text: Full-text search
    /// - Parameter since: Messages since date (ISO 8601)
    /// - Parameter before: Messages before date (ISO 8601)
    @MCPTool
    public func searchMessages(
        serverId: String,
        mailbox: String = "INBOX",
        from fromAddress: String? = nil,
        subject: String? = nil,
        text: String? = nil,
        since: String? = nil,
        before: String? = nil
    ) async throws -> [MessageHeader] {
        try await withServer(serverId: serverId) { server in
            _ = try await server.selectMailbox(mailbox)

            var criteria: [SearchCriteria] = []

            if let fromAddress, !fromAddress.isEmpty {
                criteria.append(.from(fromAddress))
            }

            if let subject, !subject.isEmpty {
                criteria.append(.subject(subject))
            }

            if let text, !text.isEmpty {
                criteria.append(.text(text))
            }

            if let since, !since.isEmpty {
                criteria.append(.since(try parseISO8601Date(since, field: "since")))
            }

            if let before, !before.isEmpty {
                criteria.append(.before(try parseISO8601Date(before, field: "before")))
            }

            if criteria.isEmpty {
                criteria.append(.all)
            }

            let matches: MessageIdentifierSet<UID> = try await server.search(criteria: criteria)
            guard !matches.isEmpty else {
                return []
            }

            let headers = try await collectHeaders(from: server.fetchMessages(using: matches))
            return headers.sorted { $0.uid > $1.uid }
        }
    }

    /// Moves messages to another folder
    /// - Parameter serverId: The server identifier
    /// - Parameter uids: Comma-separated UIDs
    /// - Parameter targetMailbox: Target folder
    /// - Parameter mailbox: Source mailbox (default: "INBOX")
    @MCPTool
    public func moveMessages(serverId: String, uids: String, targetMailbox: String, mailbox: String = "INBOX") async throws -> String {
        guard let set = MessageIdentifierSet<UID>(string: uids) else {
            throw PostServerError.invalidUIDSet(uids)
        }

        return try await withServer(serverId: serverId) { server in
            _ = try await server.selectMailbox(mailbox)
            try await server.move(messages: set, to: targetMailbox)
            return "Moved \(set.count) message(s) from \(mailbox) to \(targetMailbox)."
        }
    }

    private func withServer<T>(serverId: String, operation: (IMAPServer) async throws -> T) async throws -> T {
        do {
            let server = try await connectionManager.connection(for: serverId)
            return try await operation(server)
        } catch {
            guard shouldReconnect(after: error) else {
                throw error
            }

            logger.warning("Operation failed for \(serverId), reconnecting: \(String(describing: error))")
            let server = try await connectionManager.reconnect(for: serverId)
            return try await operation(server)
        }
    }

    private func shouldReconnect(after error: Error) -> Bool {
        if let imapError = error as? IMAPError {
            switch imapError {
            case .connectionFailed, .greetingFailed, .timeout:
                return true
            default:
                break
            }
        }

        let message = String(describing: error).lowercased()
        return message.contains("connection") || message.contains("broken pipe") || message.contains("not connected")
    }

    private func collectHeaders(from stream: AsyncThrowingStream<Message, Error>) async throws -> [MessageHeader] {
        var headers: [MessageHeader] = []

        for try await message in stream {
            headers.append(messageHeader(from: message))
        }

        return headers
    }

    private func messageHeader(from message: Message) -> MessageHeader {
        MessageHeader(
            uid: messageUID(from: message),
            from: message.from ?? "Unknown",
            subject: message.subject ?? "(No Subject)",
            date: formatDate(message.date)
        )
    }

    private func messageDetail(from message: Message) -> MessageDetail {
        let attachments = message.attachments.map {
            AttachmentInfo(
                filename: $0.filename ?? $0.suggestedFilename,
                contentType: $0.contentType
            )
        }

        return MessageDetail(
            uid: messageUID(from: message),
            from: message.from ?? "Unknown",
            to: message.to,
            subject: message.subject ?? "(No Subject)",
            date: formatDate(message.date),
            textBody: message.textBody,
            htmlBody: message.htmlBody,
            attachments: attachments
        )
    }

    private func messageUID(from message: Message) -> Int {
        if let uid = message.uid {
            return Int(uid.value)
        }
        return Int(message.sequenceNumber.value)
    }

    private func formatDate(_ date: Date?) -> String {
        guard let date else {
            return ""
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func parseISO8601Date(_ value: String, field: String) throws -> Date {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: trimmed) {
            return date
        }

        let withoutFractional = ISO8601DateFormatter()
        withoutFractional.formatOptions = [.withInternetDateTime]
        if let date = withoutFractional.date(from: trimmed) {
            return date
        }

        throw PostServerError.invalidDate(field, value)
    }

    private func specialUseDescription(for attributes: Mailbox.Info.Attributes) -> String? {
        var tags: [String] = []

        if attributes.contains(.inbox) { tags.append("\\Inbox") }
        if attributes.contains(.archive) { tags.append("\\Archive") }
        if attributes.contains(.drafts) { tags.append("\\Drafts") }
        if attributes.contains(.flagged) { tags.append("\\Flagged") }
        if attributes.contains(.junk) { tags.append("\\Junk") }
        if attributes.contains(.sent) { tags.append("\\Sent") }
        if attributes.contains(.trash) { tags.append("\\Trash") }

        guard !tags.isEmpty else {
            return nil
        }

        return tags.joined(separator: ",")
    }
}

public typealias PostProxy = PostServer.Client

public extension PostServer.Client {
    static var serverName: String { "Post" }
}
