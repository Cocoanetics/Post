import Foundation
import Logging
import SwiftMCP
import SwiftMail
import SwiftTextHTML

public enum PostServerError: Error, LocalizedError, Sendable {
    case invalidLimit(Int)
    case invalidUID(Int)
    case invalidUIDSet(String)
    case invalidDate(String, String)
    case invalidFlagOperation(String)
    case invalidFlags(String)
    case messageNotFound(uid: Int, mailbox: String)
    case noAttachments(uid: Int)
    case attachmentNotFound(filename: String, uid: Int)
    case attachmentDataMissing(filename: String)
    case noIdleEnabledServers
    case emptyBody(uid: Int)
    case fileNotFound(String)
    case noGlobMatches(String)
    case unsupportedPlatform(String)
    case noSession
    case apiKeyRequired
    case invalidAPIKey
    case serverAccessDenied(serverId: String)
    case scopeRequired(scope: String)
    case noDraftsFolder(serverId: String)
    case smtpNotConfigured(serverId: String)

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
        case .invalidFlagOperation(let operation):
            return "Invalid flag operation '\(operation)'. Use 'add' or 'remove'."
        case .invalidFlags(let flags):
            return "Invalid flag list '\(flags)'. Use comma-separated names like seen,flagged,custom."
        case .messageNotFound(let uid, let mailbox):
            return "Message UID \(uid) was not found in mailbox '\(mailbox)'."
        case .noAttachments(let uid):
            return "Message UID \(uid) has no attachments."
        case .attachmentNotFound(let filename, let uid):
            return "Attachment '\(filename)' not found in message UID \(uid)."
        case .attachmentDataMissing(let filename):
            return "Could not decode attachment data for '\(filename)'."
        case .noIdleEnabledServers:
            return "No servers configured with `idle: true` in ~/.post.json."
        case .emptyBody(let uid):
            return "Message UID \(uid) has no text or HTML body to export."
        case .fileNotFound(let path):
            return "File not found: '\(path)'."
        case .noGlobMatches(let pattern):
            return "No files matched the pattern '\(pattern)'."
        case .unsupportedPlatform(let reason):
            return reason
        case .noSession:
            return "No active MCP session."
        case .apiKeyRequired:
            return "API key is required."
        case .invalidAPIKey:
            return "Invalid API key."
        case .serverAccessDenied(let serverId):
            return "API key is not authorized for server '\(serverId)'."
        case .scopeRequired(let scope):
            return "API key does not have required scope: '\(scope)'."
        case .noDraftsFolder(let serverId):
            return "No Drafts folder found on server '\(serverId)'. The server must have a mailbox with the \\Drafts special-use flag."
        case .smtpNotConfigured(let serverId):
            return """
            SMTP is not configured for server '\(serverId)'.
            
            Add SMTP configuration to ~/.post.json:
            {
              "servers": {
                "\(serverId)": {
                  "smtp": {
                    "host": "mail.example.com",
                    "port": 587,
                    "useTLS": false
                  }
                }
              }
            }
            """
        }
    }
}

@MCPServer(name: "Post", generateClient: true)
public actor PostServer {
    /// Override macro-generated version with the shared version constant.
    public nonisolated var serverVersion: String { postVersion }

    internal struct HookAttachmentPayload: Encodable, Sendable {
        let filename: String
        let contentType: String
        let disposition: String?
        let section: String
        let contentId: String?
        let encoding: String?
        let size: Int?

        private enum CodingKeys: String, CodingKey {
            case filename
            case contentType
            case disposition
            case section
            case contentId
            case encoding
            case size
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(filename, forKey: .filename)
            try container.encode(contentType, forKey: .contentType)
            try container.encodeIfPresent(disposition, forKey: .disposition)
            try container.encode(section, forKey: .section)
            try container.encodeIfPresent(contentId, forKey: .contentId)
            try container.encodeIfPresent(encoding, forKey: .encoding)
            try container.encodeIfPresent(size, forKey: .size)
        }
    }

    internal struct HookMessagePayload: Encodable, Sendable {
        let uid: Int
        let mailbox: String
        let from: String
        let to: [String]
        let replyTo: String?
        let date: Date
        let subject: String
        let markdown: String?
        let flags: [String]
        let attachments: [HookAttachmentPayload]
        let headers: [String: String]

        private enum CodingKeys: String, CodingKey {
            case uid
            case from
            case to
            case date
            case subject
            case markdown
            case flags
            case attachments
            case headers
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(uid, forKey: .uid)
            try container.encode(from, forKey: .from)
            try container.encode(to, forKey: .to)
            try container.encode(date, forKey: .date)
            try container.encode(subject, forKey: .subject)
            try container.encode(markdown ?? "", forKey: .markdown)
            try container.encode(flags, forKey: .flags)
            try container.encode(attachments, forKey: .attachments)
            try container.encode(headers, forKey: .headers)
        }
    }

    internal struct HookPayload: Encodable, Sendable {
        let server: String
        let mailbox: String
        let message: HookMessagePayload
    }

    internal var connectionManager: IMAPConnectionManager
    private let apiKeyStore = APIKeyStore()
    private var scopedServerIDsByToken: [String: Set<String>] = [:]
    private var scopesByToken: [String: Set<String>] = [:]
    private var apiKeyScopesPrimed = false
    private var apiKeyRequiredForMCP = false
    internal let logger = Logger(label: "com.cocoanetics.Post.PostServer")

    internal var idleWatchTasks: [String: Task<Void, Never>] = [:]
    private static let idleDiagnosticLogger = Logger(label: "com.cocoanetics.Post.IDLE.Diagnostics")

    /// Emits IDLE diagnostics through swift-log so daemon log routing can handle persistence.
    internal static func logDiagnostic(_ message: String) {
        let logger = idleDiagnosticLogger
        if message.hasPrefix("ERROR ") {
            logger.error("\(message)")
        } else {
            logger.trace("\(message)")
        }
    }

    public init(configuration: PostConfiguration) {
        self.connectionManager = IMAPConnectionManager(configuration: configuration)
    }

    /// Preloads all API key scopes from Keychain into memory.
    /// This is useful at daemon startup to trigger a single keychain authorization prompt.
    /// - Returns: Number of API keys loaded
    public func primeAPIKeyScopes() throws -> Int {
        let records = try apiKeyStore.listKeys()
        var serverMapping: [String: Set<String>] = [:]
        var scopeMapping: [String: Set<String>] = [:]
        serverMapping.reserveCapacity(records.count)
        scopeMapping.reserveCapacity(records.count)

        for record in records {
            serverMapping[record.token] = Set(record.allowedServerIDs)
            scopeMapping[record.token] = record.effectiveScopes
        }

        scopedServerIDsByToken = serverMapping
        scopesByToken = scopeMapping
        apiKeyScopesPrimed = true
        apiKeyRequiredForMCP = !records.isEmpty
        return records.count
    }

    /// Starts configured IMAP IDLE watches (dedicated connections via SwiftMail) for servers
    /// that have `idle: true` in ~/.post.json.
    public func shutdown() async {
        stopIdleWatches()
        await connectionManager.shutdown()
    }

    /// Reloads configuration from disk, restarts IDLE watches and connections.
    public func reloadConfiguration() async {
        logger.info("Reloading configuration...")

        do {
            let newConfig = try PostConfiguration.load()

            // Stop all IDLE watches
            stopIdleWatches()

            // Shut down existing connections
            await connectionManager.shutdown()

            // Replace connection manager with new config
            connectionManager = IMAPConnectionManager(configuration: newConfig)
            do {
                let keyCount = try primeAPIKeyScopes()
                logger.info("API key scopes refreshed (\(keyCount) key(s)).")
            } catch {
                logger.error("Failed to refresh API key scopes: \(error.localizedDescription)")
            }

            logger.info("Configuration reloaded. \(newConfig.servers.count) server(s) configured.")

            // Restart IDLE watches
            await startIdleWatches()
        } catch {
            logger.error("Failed to reload configuration: \(error.localizedDescription)")
        }
    }

    /// Lists all configured IMAP servers with their connection details
    @MCPTool
    public func listServers() async throws -> [ServerInfo] {
        let infos = await connectionManager.serverInfos()
        guard let allowed = try await allowedServerIDsForCurrentSession() else {
            return infos
        }
        return infos.filter { allowed.contains($0.id) }
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

    /// Fetches one or more emails by UID set.
    /// - Parameter serverId: The server identifier
    /// - Parameter uids: UID(s) to fetch, comma-separated, ranges allowed e.g. 1,3,5-10
    /// - Parameter mailbox: Mailbox name (default: "INBOX")
    @MCPTool
    public func fetchMessage(serverId: String, uids: String, mailbox: String = "INBOX") async throws -> [MessageDetail] {
        guard let set = MessageIdentifierSet<UID>(string: uids) else {
            throw PostServerError.invalidUIDSet(uids)
        }

        return try await withServer(serverId: serverId) { server in
            _ = try await server.selectMailbox(mailbox)
            var messages: [MessageDetail] = []

            for try await message in server.fetchMessages(using: set) {
                let additionalHeaders = await fetchAdditionalHeaders(for: message, using: server)

                messages.append(messageDetail(from: message, additionalHeaders: additionalHeaders))
            }

            return messages.sorted { $0.uid < $1.uid }
        }
    }

    /// Fetches raw RFC 822 message data for one or more UIDs.
    /// - Parameter serverId: The server identifier
    /// - Parameter uids: UID(s) to fetch, comma-separated, ranges allowed e.g. 1,3,5-10
    /// - Parameter mailbox: Mailbox name (default: "INBOX")
    @MCPTool
    public func fetchRawMessages(serverId: String, uids: String, mailbox: String = "INBOX") async throws -> [RawMessage] {
        guard let set = MessageIdentifierSet<UID>(string: uids) else {
            throw PostServerError.invalidUIDSet(uids)
        }

        return try await withServer(serverId: serverId) { server in
            _ = try await server.selectMailbox(mailbox)
            var results: [RawMessage] = []

            for uid in set.toArray() {
                let data = try await server.fetchRawMessage(identifier: uid)
                results.append(RawMessage(uid: Int(uid.value), rawData: data))
            }

            return results.sorted { $0.uid < $1.uid }
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

    /// Creates a mailbox folder on the specified server
    /// - Parameter serverId: The server identifier
    /// - Parameter name: Mailbox name to create
    @MCPTool
    public func createMailbox(serverId: String, name: String) async throws -> String {
        try await withServer(serverId: serverId) { server in
            try await server.createMailbox(name)
            return "Created mailbox '\(name)'."
        }
    }

    /// Gets mailbox status information without selecting the mailbox
    /// - Parameter serverId: The server identifier
    /// - Parameter mailbox: Mailbox name (default: "INBOX")
    @MCPTool
    public func mailboxStatus(serverId: String, mailbox: String = "INBOX") async throws -> Mailbox.Status {
        try await withServer(serverId: serverId) { server in
            try await server.mailboxStatus(mailbox)
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
    /// - Parameter flagged: Only flagged messages when true
    /// - Parameter unflagged: Only unflagged messages when true
    @MCPTool
    public func searchMessages(
        serverId: String,
        mailbox: String = "INBOX",
        from fromAddress: String? = nil,
        subject: String? = nil,
        text: String? = nil,
        since: String? = nil,
        before: String? = nil,
        headerField: String? = nil,
        headerValue: String? = nil,
        unseen: Bool? = nil,
        seen: Bool? = nil,
        flagged: Bool? = nil,
        unflagged: Bool? = nil,
        limit: Int = 100,
        afterUid: Int? = nil
    ) async throws -> SearchResult {
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

            if let headerField, !headerField.isEmpty, let headerValue, !headerValue.isEmpty {
                criteria.append(.header(headerField, headerValue))
            }

            if unseen == true {
                criteria.append(.unseen)
            }
            if seen == true {
                criteria.append(.seen)
            }
            if flagged == true {
                criteria.append(.flagged)
            }
            if unflagged == true {
                criteria.append(.unflagged)
            }

            if criteria.isEmpty {
                criteria.append(.all)
            }

            // Build UID range for cursor-based pagination
            var identifierSet: MessageIdentifierSet<UID>?
            if let afterUid {
                // Validate cursor bounds (IMAP UID max is UInt32.max)
                guard afterUid >= 0, afterUid < Int(UInt32.max) else {
                    throw IMAPError.invalidArgument("afterUid \(afterUid) exceeds IMAP UID bounds (0..\(UInt32.max))")
                }
                // Only search UIDs greater than the cursor
                identifierSet = MessageIdentifierSet(UID(UInt32(afterUid + 1))...)
            }

            // Use extended search with PARTIAL for server-side paging.
            // RFC 9394 window is 1-based relative to the current scoped search result set.
            let result = try await server.extendedSearch(
                identifierSet: identifierSet,
                criteria: criteria,
                partialRange: makeFirstPartialRange(limit: limit)
            )

            let limitedUIDs: [UID]
            if let partial = result.partial {
                limitedUIDs = partial.results.toArray()
            } else if let uidSet = result.all {
                // Fallback for servers that ignore PARTIAL / lack ESEARCH support.
                limitedUIDs = Array(uidSet.toArray().prefix(limit))
            } else {
                limitedUIDs = []
            }

            // Extract metadata
            let totalCount = result.count
            
            // Get the limited UIDs
            guard !limitedUIDs.isEmpty else {
                // No results
                return SearchResult(
                    total: totalCount,
                    messages: [],
                    page: SearchResultPage(returned: 0, hasMore: false, next: nil)
                )
            }

            // Fetch headers for the limited UIDs
            let uidSet = MessageIdentifierSet(limitedUIDs)
            let headers = try await collectHeaders(from: server.fetchMessages(using: uidSet))
            let sortedHeaders = headers.sorted { $0.uid > $1.uid }
            
            // Calculate returned range
            let returnedUIDs = sortedHeaders.map(\.uid)
            let returnedMax = returnedUIDs.max()
            
            // Check if there are more results and prepare next cursor
            let hasMore = limitedUIDs.count == limit
            let next = hasMore && returnedMax != nil ? SearchResultNext(afterUid: returnedMax!) : nil

            return SearchResult(
                total: totalCount,
                messages: sortedHeaders,
                page: SearchResultPage(
                    returned: sortedHeaders.count,
                    hasMore: hasMore,
                    next: next
                )
            )
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

    /// Copies messages to another folder
    /// - Parameter serverId: The server identifier
    /// - Parameter uids: Comma-separated UIDs
    /// - Parameter targetMailbox: Target folder
    /// - Parameter mailbox: Source mailbox (default: "INBOX")
    @MCPTool
    public func copyMessages(serverId: String, uids: String, targetMailbox: String, mailbox: String = "INBOX") async throws -> String {
        guard let set = MessageIdentifierSet<UID>(string: uids) else {
            throw PostServerError.invalidUIDSet(uids)
        }

        return try await withServer(serverId: serverId) { server in
            _ = try await server.selectMailbox(mailbox)
            try await server.copy(messages: set, to: targetMailbox)
            return "Copied \(set.count) message(s) from \(mailbox) to \(targetMailbox)."
        }
    }

    /// Adds or removes flags on messages
    /// - Parameter serverId: The server identifier
    /// - Parameter uids: Comma-separated UIDs
    /// - Parameter flags: Comma-separated flag names
    /// - Parameter operation: "add" or "remove"
    /// - Parameter mailbox: Source mailbox (default: "INBOX")
    @MCPTool
    public func flagMessages(
        serverId: String,
        uids: String,
        flags: String,
        operation: String,
        mailbox: String = "INBOX"
    ) async throws -> String {
        guard let set = MessageIdentifierSet<UID>(string: uids) else {
            throw PostServerError.invalidUIDSet(uids)
        }

        let parsedFlags = try parseFlags(flags)
        let operationValue = operation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let flagLabel = parsedFlags.map(\.description).joined(separator: ", ")

        return try await withServer(serverId: serverId) { server in
            _ = try await server.selectMailbox(mailbox)

            switch operationValue {
            case "add":
                try await server.store(flags: parsedFlags, on: set, operation: .add)
                return "Added flags [\(flagLabel)] on \(set.count) message(s)."
            case "remove":
                try await server.store(flags: parsedFlags, on: set, operation: .remove)
                return "Removed flags [\(flagLabel)] on \(set.count) message(s)."
            default:
                throw PostServerError.invalidFlagOperation(operation)
            }
        }
    }

    /// Moves messages to the trash folder
    /// - Parameter serverId: The server identifier
    /// - Parameter uids: Comma-separated UIDs
    /// - Parameter mailbox: Source mailbox (default: "INBOX")
    @MCPTool
    public func trashMessages(serverId: String, uids: String, mailbox: String = "INBOX") async throws -> String {
        guard let set = MessageIdentifierSet<UID>(string: uids) else {
            throw PostServerError.invalidUIDSet(uids)
        }

        return try await withServer(serverId: serverId) { server in
            _ = try await server.listSpecialUseMailboxes()
            _ = try await server.selectMailbox(mailbox)
            try await server.moveToTrash(messages: set)
            return "Trashed \(set.count) message(s)."
        }
    }

    /// Archives messages (marks as read, moves to archive folder)
    /// - Parameter serverId: The server identifier
    /// - Parameter uids: Comma-separated UIDs
    /// - Parameter mailbox: Source mailbox (default: "INBOX")
    @MCPTool
    public func archiveMessages(serverId: String, uids: String, mailbox: String = "INBOX") async throws -> String {
        guard let set = MessageIdentifierSet<UID>(string: uids) else {
            throw PostServerError.invalidUIDSet(uids)
        }

        return try await withServer(serverId: serverId) { server in
            _ = try await server.listSpecialUseMailboxes()
            _ = try await server.selectMailbox(mailbox)
            try await server.archive(messages: set)
            return "Archived \(set.count) message(s)."
        }
    }

    /// Marks messages as junk and moves to junk folder
    /// - Parameter serverId: The server identifier
    /// - Parameter uids: Comma-separated UIDs
    /// - Parameter mailbox: Source mailbox (default: "INBOX")
    @MCPTool
    public func junkMessages(serverId: String, uids: String, mailbox: String = "INBOX") async throws -> String {
        guard let set = MessageIdentifierSet<UID>(string: uids) else {
            throw PostServerError.invalidUIDSet(uids)
        }

        return try await withServer(serverId: serverId) { server in
            _ = try await server.listSpecialUseMailboxes()
            _ = try await server.selectMailbox(mailbox)
            try await server.markAsJunk(messages: set)
            return "Marked \(set.count) message(s) as junk."
        }
    }

    /// Permanently removes deleted messages from a mailbox
    /// - Parameter serverId: The server identifier
    /// - Parameter mailbox: Mailbox name (default: "INBOX")
    @MCPTool
    public func expungeMessages(serverId: String, mailbox: String = "INBOX") async throws -> String {
        try await withServer(serverId: serverId) { server in
            _ = try await server.selectMailbox(mailbox)
            try await server.expunge()
            return "Expunged deleted messages from \(mailbox)."
        }
    }

    /// Gets quota information for the mailbox quota root
    /// - Parameter serverId: The server identifier
    /// - Parameter mailbox: Mailbox name (default: "INBOX")
    @MCPTool
    public func getQuota(serverId: String, mailbox: String = "INBOX") async throws -> Quota {
        try await withServer(serverId: serverId) { server in
            try await server.getQuotaRoot(mailboxName: mailbox)
        }
    }

    /// Lists IMAP namespaces for a server (personal, other users, shared).
    /// Useful for discovering mailbox hierarchies and path separators.
    /// - Parameter serverId: The server identifier
    @MCPTool
    public func listNamespaces(serverId: String) async throws -> NamespaceInfo {
        try await withServer(serverId: serverId) { server in
            let response = try await server.fetchNamespaces()
            let personal = response.personal.map { NamespaceEntry(prefix: $0.prefix, delimiter: $0.delimiter.map(String.init)) }
            let otherUsers = response.otherUsers.map { NamespaceEntry(prefix: $0.prefix, delimiter: $0.delimiter.map(String.init)) }
            let shared = response.shared.map { NamespaceEntry(prefix: $0.prefix, delimiter: $0.delimiter.map(String.init)) }
            return NamespaceInfo(personal: personal, otherUsers: otherUsers, shared: shared)
        }
    }

    /// Counts messages matching search criteria using ESEARCH (efficient server-side count).
    /// Returns count, min UID, and max UID without transferring all matching UIDs.
    /// - Parameter serverId: The server identifier
    /// - Parameter mailbox: Mailbox name (default: "INBOX")
    /// - Parameter from: Search in From field
    /// - Parameter subject: Search in Subject field
    /// - Parameter text: Full-text search
    /// - Parameter since: Messages since date (ISO 8601)
    /// - Parameter before: Messages before date (ISO 8601)
    /// - Parameter unseen: Only unseen messages when true
    /// - Parameter seen: Only seen messages when true
    /// - Parameter flagged: Only flagged messages when true
    @MCPTool
    public func countMessages(
        serverId: String,
        mailbox: String = "INBOX",
        from fromAddress: String? = nil,
        subject: String? = nil,
        text: String? = nil,
        since: String? = nil,
        before: String? = nil,
        unseen: Bool? = nil,
        seen: Bool? = nil,
        flagged: Bool? = nil
    ) async throws -> SearchCount {
        try await withServer(serverId: serverId) { server in
            _ = try await server.selectMailbox(mailbox)

            var criteria: [SearchCriteria] = []
            if let fromAddress, !fromAddress.isEmpty { criteria.append(.from(fromAddress)) }
            if let subject, !subject.isEmpty { criteria.append(.subject(subject)) }
            if let text, !text.isEmpty { criteria.append(.text(text)) }
            if let since, !since.isEmpty { criteria.append(.since(try parseISO8601Date(since, field: "since"))) }
            if let before, !before.isEmpty { criteria.append(.before(try parseISO8601Date(before, field: "before"))) }
            if unseen == true { criteria.append(.unseen) }
            if seen == true { criteria.append(.seen) }
            if flagged == true { criteria.append(.flagged) }
            if criteria.isEmpty { criteria.append(.all) }

            let result: ExtendedSearchResult<UID> = try await server.extendedSearch(criteria: criteria)
            return SearchCount(
                count: result.count,
                minUID: result.min.map { Int($0.value) },
                maxUID: result.max.map { Int($0.value) },
                all: result.all.map { $0.toArray().map { Int($0.value) } }
            )
        }
    }

    /// Downloads an attachment from a message
    /// - Parameter serverId: The server identifier
    /// - Parameter uid: The message UID
    /// - Parameter filename: Attachment filename to download (optional, downloads first if omitted)
    /// - Parameter mailbox: Mailbox name (default: "INBOX")
    /// - Returns: Base64-encoded attachment data with metadata
    @MCPTool
    public func downloadAttachment(serverId: String, uid: Int, filename: String? = nil, mailbox: String = "INBOX") async throws -> AttachmentData {
        guard (1...Int(UInt32.max)).contains(uid) else {
            throw PostServerError.invalidUID(uid)
        }

        return try await withServer(serverId: serverId) { server in
            _ = try await server.selectMailbox(mailbox)
            let set = MessageIdentifierSet<UID>(UID(UInt32(uid)))

            for try await message in server.fetchMessages(using: set) {
                let attachments = message.attachments

                guard !attachments.isEmpty else {
                    throw PostServerError.noAttachments(uid: uid)
                }

                let part: MessagePart
                if let filename {
                    guard let match = attachments.first(where: {
                        ($0.filename ?? $0.suggestedFilename).lowercased() == filename.lowercased()
                    }) else {
                        throw PostServerError.attachmentNotFound(filename: filename, uid: uid)
                    }
                    part = match
                } else {
                    part = attachments[0]
                }

                guard let data = part.decodedData() ?? part.data else {
                    throw PostServerError.attachmentDataMissing(filename: part.suggestedFilename)
                }

                return AttachmentData(
                    filename: part.filename ?? part.suggestedFilename,
                    contentType: part.contentType,
                    data: data.base64EncodedString(),
                    size: data.count
                )
            }

            throw PostServerError.messageNotFound(uid: uid, mailbox: mailbox)
        }
    }

    /// Downloads the raw RFC 822 source of a single message as .eml data.
    /// - Parameter serverId: The server identifier
    /// - Parameter uid: The message UID
    /// - Parameter mailbox: Mailbox name (default: "INBOX")
    @MCPTool
    public func downloadEml(serverId: String, uid: Int, mailbox: String = "INBOX") async throws -> Data {
        guard (1...Int(UInt32.max)).contains(uid) else {
            throw PostServerError.invalidUID(uid)
        }
        return try await withServer(serverId: serverId) { server in
            _ = try await server.selectMailbox(mailbox)
            let uid = UID(UInt32(uid))
            return try await server.fetchRawMessage(identifier: uid)
        }
    }

    /// Exports a message body as PDF data (base64-encoded).
    /// Uses HTML body if available, otherwise converts text body from Markdown to HTML first.
    /// - Parameter serverId: The server identifier
    /// - Parameter uid: The message UID
    /// - Parameter mailbox: Mailbox name (default: "INBOX")
    /// - Returns: Base64-encoded PDF data
    @MCPTool
    public func exportPDF(serverId: String, uid: Int, mailbox: String = "INBOX") async throws -> AttachmentData {
        #if os(macOS)
        guard (1...Int(UInt32.max)).contains(uid) else {
            throw PostServerError.invalidUID(uid)
        }

        return try await withServer(serverId: serverId) { server in
            _ = try await server.selectMailbox(mailbox)
            let set = MessageIdentifierSet<UID>(UID(UInt32(uid)))

            for try await message in server.fetchMessages(using: set) {
                let html: String

                if let htmlBody = message.htmlBody, !htmlBody.isEmpty {
                    html = htmlBody
                } else if let textBody = message.textBody, !textBody.isEmpty {
                    html = MarkdownToHTML.convert(textBody)
                } else {
                    throw PostServerError.emptyBody(uid: uid)
                }

                let subject = message.subject ?? "message-\(uid)"
                let filename = Self.sanitizeFilename(subject) + ".pdf"

                let pdfData = try await HTMLToPDF.render(html: html)
                return AttachmentData(
                    filename: filename,
                    contentType: "application/pdf",
                    data: pdfData.base64EncodedString(),
                    size: pdfData.count
                )
            }

            throw PostServerError.messageNotFound(uid: uid, mailbox: mailbox)
        }
        #else
        throw PostServerError.unsupportedPlatform("PDF export requires macOS")
        #endif
    }

    /// Body format for composing emails.
    public enum BodyFormat: String, Sendable, CaseIterable {
        case text
        case html
        case markdown
    }

    /// Creates a new email draft and appends it to the Drafts mailbox.
    /// - Parameter serverId: The server identifier
    /// - Parameter from: Sender email address
    /// - Parameter to: Comma-separated recipient email addresses
    /// - Parameter subject: Email subject
    /// - Parameter body: The body content
    /// - Parameter format: Body format: text (default), html, or markdown
    /// - Parameter cc: Optional comma-separated CC addresses
    /// - Parameter bcc: Optional comma-separated BCC addresses
    /// - Parameter attachments: Optional comma-separated file paths to attach
    /// - Parameter mailbox: Optional custom mailbox (defaults to server's Drafts folder)
    @MCPTool
    public func createDraft(
        serverId: String,
        from: String,
        to: String,
        subject: String,
        body: String,
        format: BodyFormat = .text,
        cc: String? = nil,
        bcc: String? = nil,
        attachments: String? = nil,
        mailbox: String? = nil,
        inReplyTo: String? = nil,
        references: String? = nil
    ) async throws -> DraftResult {
        let sender = EmailAddress(address: from)
        let recipients = to.split(separator: ",").map { EmailAddress(address: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let ccRecipients = cc?.split(separator: ",").map { EmailAddress(address: $0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? []
        let bccRecipients = bcc?.split(separator: ",").map { EmailAddress(address: $0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? []

        let textBody: String
        let htmlBody: String?

        switch format {
        case .html:
            htmlBody = body
            let converter = HTMLToMarkdown(data: Data(body.utf8))
            textBody = try await converter.markdown()
        case .markdown:
            htmlBody = MarkdownToHTML.document(body, stylesheet: Self.emailStylesheet)
            textBody = body
        case .text:
            textBody = body
            let plainHTML = Self.plainTextToHTML(body)
            htmlBody = Self.wrapHTMLDocument(plainHTML)
        }

        var emailAttachments: [Attachment]?
        if let attachments, !attachments.isEmpty {
            let resolvedPaths = try attachments
                .split(separator: ",")
                .flatMap { segment -> [String] in
                    let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
                    let expanded = NSString(string: trimmed).expandingTildeInPath
                    if expanded.contains("*") || expanded.contains("?") || expanded.contains("[") {
                        let matches = Self.expandGlob(expanded)
                        guard !matches.isEmpty else {
                            throw PostServerError.noGlobMatches(expanded)
                        }
                        return matches
                    }
                    return [expanded]
                }

            emailAttachments = try resolvedPaths.map { path in
                let url = URL(fileURLWithPath: path)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw PostServerError.fileNotFound(url.path)
                }
                return try Attachment(fileURL: url)
            }
        }

        var additionalHeaders: [String: String]?
        if let inReplyTo {
            additionalHeaders = (additionalHeaders ?? [:])
            additionalHeaders?["In-Reply-To"] = inReplyTo
        }
        if let references {
            additionalHeaders = (additionalHeaders ?? [:])
            additionalHeaders?["References"] = references
        }

        var email = Email(
            sender: sender,
            recipients: recipients,
            ccRecipients: ccRecipients,
            bccRecipients: bccRecipients,
            subject: subject,
            textBody: textBody,
            htmlBody: htmlBody,
            attachments: emailAttachments
        )
        email.additionalHeaders = additionalHeaders

        return try await withServer(serverId: serverId) { server in
            _ = try await server.listSpecialUseMailboxes()
            
            // Determine target mailbox and validate Drafts exists if needed
            let targetMailbox: String
            if let mailbox {
                targetMailbox = mailbox
            } else {
                // Validate that a Drafts folder exists (checks both \Drafts flag and common names)
                do {
                    let draftsMailbox = try await server.draftsFolder
                    targetMailbox = draftsMailbox.name
                } catch {
                    throw PostServerError.noDraftsFolder(serverId: serverId)
                }
            }
            
            let result = try await server.createDraft(from: email, in: mailbox)
            let uid = result.firstUID.map { Int($0.value) }
            return DraftResult(mailbox: targetMailbox, uid: uid)
        }
    }
    
    /// Sends a draft email via SMTP.
    /// 
    /// This method orchestrates the full send workflow:
    /// 1. Auto-detects Drafts folder (checks \\Drafts flag, falls back to name matching)
    /// 2. Fetches the draft message
    /// 3. Sends via SMTP (preserving threading headers)
    /// 4. Auto-detects Sent folder (checks \\Sent flag, falls back to name matching)
    /// 5. Appends the sent message to Sent with \\Seen flag
    /// 6. Permanently expunges the draft from Drafts
    ///
    /// - Parameters:
    ///   - uid: UID of the draft message to send
    ///   - serverId: Server identifier
    ///
    /// - Throws: `PostServerError` if the server is not found or SMTP is not configured
    @MCPTool
    public func sendDraft(
        uid: Int,
        serverId: String
    ) async throws {
        // Check SMTP scope
        try await assertScopeAllowed("smtp")
        
        // Get server configuration
        let serverConfig = try await connectionManager.resolveServerConfiguration(serverId: serverId)
        
        guard let smtpConfig = serverConfig.smtp else {
            throw PostServerError.smtpNotConfigured(serverId: serverId)
        }
        
        // Get credentials (checks SMTP keychain first, falls back to IMAP)
        let credentials = try await connectionManager.resolveSMTPCredentials(forServer: serverId)
        
        // Create SMTP server instance
        let smtp = SMTPServer(
            host: smtpConfig.host,
            port: smtpConfig.port ?? (smtpConfig.useTLS ? 465 : 587)
        )
        
        // Connect and authenticate with SMTP
        try await smtp.connect()
        try await smtp.login(username: credentials.username, password: credentials.password)
        
        // Send the draft via SwiftMail's sendDraft orchestrator
        _ = try await withServer(serverId: serverId) { server in
            try await server.sendDraft(
                uid: UID(UInt32(uid)),
                via: smtp
            )
        }
        
        // Disconnect SMTP
        try await smtp.disconnect()
    }

    /// Watches IMAP IDLE events in real time. Events are delivered as MCP log notifications.
    /// This is a long-running tool call — it blocks until the client disconnects.
    @MCPTool
    public func watchIdleEvents() async throws {
        guard let session = Session.current else {
            throw PostServerError.noSession
        }

        let allowedServerIDs = try await allowedServerIDsForCurrentSession()
        let watchConfigurations = await configuredIdleWatches().filter { config in
            guard let allowedServerIDs else { return true }
            return allowedServerIDs.contains(config.serverId)
        }
        guard !watchConfigurations.isEmpty else {
            throw PostServerError.noIdleEnabledServers
        }

        let activeTargets = watchConfigurations
            .map { "\($0.serverId)/\($0.mailbox)" }
            .sorted()
            .joined(separator: ", ")

        await session.sendLogNotification(LogMessage(
            level: .info,
            logger: "idle",
            data: "Subscribed to IDLE events. Waiting for changes..."
        ))
        await session.sendLogNotification(LogMessage(
            level: .info,
            logger: "idle",
            data: .string("Watching raw IDLE events on \(watchConfigurations.count) mailbox(es): \(activeTargets)")
        ))

        let eventStream = watchConfigurations
            .idleEventStreams(using: connectionManager)
            .mergedIdleEventStream()

        // Forward raw IDLE events while the tool call is active.
        for await rawEvent in eventStream {
            if Task.isCancelled { break }
            await session.sendLogNotification(LogMessage(
                level: .info,
                logger: "idle",
                data: [
                    "server": .string(rawEvent.serverId),
                    "mailbox": .string(rawEvent.mailbox),
                    "event": .string(Self.describeIdleEvent(rawEvent.event))
                ]
            ))
        }
    }

    /// Wraps Markdown-converted HTML with styling for proper email rendering.
    /// Email-safe stylesheet for Markdown-rendered HTML.
    private static let emailStylesheet = """
    body {
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
        line-height: 1.6;
        color: #333;
    }
    blockquote {
        border-left: 4px solid #ccc;
        margin: 0.5em 0;
        padding: 0.25em 0 0.25em 1em;
        color: #666;
    }
    blockquote p {
        margin: 0.5em 0 0 0;
    }
    blockquote p:first-child {
        margin-top: 0;
    }
    code {
        background: #f5f5f5;
        border: 1px solid #ddd;
        border-radius: 3px;
        padding: 0.1em 0.3em;
        font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace;
        font-size: 0.9em;
    }
    pre {
        background: #f5f5f5;
        border: 1px solid #ddd;
        border-radius: 4px;
        padding: 0.8em;
        overflow: auto;
    }
    pre code {
        background: none;
        border: none;
        padding: 0;
    }
    h1, h2, h3, h4, h5, h6 {
        margin-top: 1em;
        margin-bottom: 0.5em;
        font-weight: 600;
    }
    h1 { font-size: 1.8em; }
    h2 { font-size: 1.5em; }
    h3 { font-size: 1.3em; }
    table { border-collapse: collapse; width: 100%; margin: 0.8em 0; font-size: 0.95em; }
    th, td { border: 1px solid #999; padding: 0.4em 0.7em; }
    th { background: #dcdcdc; font-weight: 600; }
    tr:nth-child(even) td { background: #f9f9f9; }
    hr {
        border: none;
        border-top: 1px solid #ddd;
        margin: 1em 0;
    }
    a {
        color: #0366d6;
        text-decoration: none;
    }
    a:hover {
        text-decoration: underline;
    }
    """

    /// Wraps plain-text-converted HTML in a minimal email-safe document.
    /// Wraps an HTML fragment in a full document with the email stylesheet.
    private static func wrapHTMLDocument(_ html: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
        \(emailStylesheet)
        </style>
        </head>
        <body>
        \(html)
        </body>
        </html>
        """
    }

    /// Converts plain text into simple HTML paragraphs while preserving newlines.
    private static func plainTextToHTML(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let lines = normalized.components(separatedBy: "\n")
        var paragraphs: [String] = []
        var currentParagraph: [String] = []

        for line in lines {
            if line.isEmpty {
                if !currentParagraph.isEmpty {
                    paragraphs.append(currentParagraph.joined(separator: "\n"))
                    currentParagraph.removeAll(keepingCapacity: true)
                }
                continue
            }
            currentParagraph.append(line)
        }

        if !currentParagraph.isEmpty {
            paragraphs.append(currentParagraph.joined(separator: "\n"))
        }

        if paragraphs.isEmpty {
            return "<p></p>"
        }

        return paragraphs
            .map { paragraph in
                let escaped = Self.escapeHTML(paragraph)
                    .replacingOccurrences(of: "\n", with: "<br>\n")
                return "<p>\(escaped)</p>"
            }
            .joined(separator: "\n")
    }

    

    private static func escapeHTML(_ text: String) -> String {
        var escaped = text
        escaped = escaped.replacingOccurrences(of: "&", with: "&amp;")
        escaped = escaped.replacingOccurrences(of: "<", with: "&lt;")
        escaped = escaped.replacingOccurrences(of: ">", with: "&gt;")
        escaped = escaped.replacingOccurrences(of: "\"", with: "&quot;")
        escaped = escaped.replacingOccurrences(of: "'", with: "&#39;")
        return escaped
    }

    /// Sanitizes a string for use as a filename.
    private static func sanitizeFilename(_ name: String) -> String {
        // Strip control characters (0x00-0x1F, 0x7F)
        var cleaned = name.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }.map(String.init).joined()
        // Replace filesystem-unsafe characters (Unix + Windows)
        cleaned = cleaned.replacingOccurrences(of: "[/\\\\:*?\"<>|]", with: "-", options: .regularExpression)
        // Collapse multiple consecutive dashes
        cleaned = cleaned.replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
        // Trim leading/trailing whitespace, periods, and dashes
        let trimChars = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".-"))
        let trimmed = cleaned.trimmingCharacters(in: trimChars)
        // Guard against empty or Windows-reserved names
        let reserved: Set<String> = ["CON", "PRN", "AUX", "NUL",
            "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
            "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"]
        if trimmed.isEmpty || reserved.contains(trimmed.uppercased()) {
            return "message"
        }
        return String(trimmed.prefix(100))
    }

    /// Expands a glob pattern (e.g. `~/docs/*.pdf`) into matching file paths.
    private static func expandGlob(_ pattern: String) -> [String] {
        var gt = glob_t()
        defer { globfree(&gt) }

        let flags = GLOB_TILDE | GLOB_BRACE
        guard glob(pattern, flags, nil, &gt) == 0 else {
            return []
        }

        var results: [String] = []
        #if os(macOS)
        let count = Int(gt.gl_matchc)
        #else
        let count = Int(gt.gl_pathc)
        #endif
        for i in 0..<count {
            if let cStr = gt.gl_pathv[i] {
                results.append(String(cString: cStr))
            }
        }
        return results.sorted()
    }

    internal func withServer<T: Sendable>(serverId: String, operation: (SwiftMail.IMAPServer) async throws -> T) async throws -> T {
        try await assertScopeAllowed("imap")
        try await assertServerAccessAllowed(serverId)

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

    private func assertServerAccessAllowed(_ serverId: String) async throws {
        guard let allowedServerIDs = try await allowedServerIDsForCurrentSession() else {
            return
        }

        guard allowedServerIDs.contains(serverId) else {
            throw PostServerError.serverAccessDenied(serverId: serverId)
        }
    }

    internal func allowedServerIDsForCurrentSession() async throws -> Set<String>? {
        guard let session = Session.current else {
            return nil
        }

        guard let accessToken = await session.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else {
            if apiKeyRequiredForMCP {
                throw PostServerError.apiKeyRequired
            }
            return nil
        }

        if let cached = scopedServerIDsByToken[accessToken] {
            return cached
        }

        // If startup preflight already loaded all known keys, a cache miss means invalid key.
        if apiKeyScopesPrimed {
            throw PostServerError.invalidAPIKey
        }

        guard let allowedServerIDs = try apiKeyStore.allowedServerIDs(forToken: accessToken) else {
            throw PostServerError.invalidAPIKey
        }

        let allowedSet = Set(allowedServerIDs)
        scopedServerIDsByToken[accessToken] = allowedSet
        return allowedSet
    }
    
    private func assertScopeAllowed(_ scope: String) async throws {
        guard let session = Session.current else {
            return  // No session = no API key required
        }
        
        guard let accessToken = await session.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else {
            if apiKeyRequiredForMCP {
                throw PostServerError.apiKeyRequired
            }
            return
        }
        
        // Check cached scopes first
        if let cached = scopesByToken[accessToken] {
            guard cached.contains(scope) else {
                throw PostServerError.scopeRequired(scope: scope)
            }
            return
        }
        
        // Load from keychain if not cached
        guard let record = try apiKeyStore.listKeys().first(where: { $0.token == accessToken }) else {
            throw PostServerError.invalidAPIKey
        }
        
        let scopes = record.effectiveScopes
        scopesByToken[accessToken] = scopes
        
        guard scopes.contains(scope) else {
            throw PostServerError.scopeRequired(scope: scope)
        }
    }

    internal func fetchAdditionalHeaders(for message: Message, using server: SwiftMail.IMAPServer) async -> [String: String]? {
        // SwiftMail 1.3.1+ populates additionalFields during fetchMessages
        return message.header.additionalFields
    }

    internal func collectHeaders(from stream: AsyncThrowingStream<Message, Error>) async throws -> [MessageHeader] {
        var headers: [MessageHeader] = []

        for try await message in stream {
            headers.append(messageHeader(from: message))
        }

        return headers
    }

    internal func messageHeader(from message: Message) -> MessageHeader {
        MessageHeader(
            uid: messageUID(from: message),
            from: message.from ?? "Unknown",
            subject: message.subject ?? "(No Subject)",
            date: formatDate(message.date),
            flags: MessageFlags(message.flags)
        )
    }

    internal func messageDetail(from message: Message, additionalHeaders: [String: String]? = nil) -> MessageDetail {
        let attachments = message.attachments.map {
            AttachmentInfo(
                filename: $0.filename ?? $0.suggestedFilename,
                contentType: $0.contentType
            )
        }

        let messageId = message.header.messageId?.description
        let referencesString = message.header.references?.map { $0.description }.joined(separator: " ")

        let filteredHeaders = Self.filterNoiseHeaders(additionalHeaders ?? message.header.additionalFields ?? [:])

        return MessageDetail(
            uid: messageUID(from: message),
            from: message.from ?? "Unknown",
            to: message.to,
            cc: message.cc.isEmpty ? nil : message.cc,
            subject: message.subject ?? "(No Subject)",
            date: formatDate(message.date),
            textBody: message.textBody,
            htmlBody: message.htmlBody,
            attachments: attachments,
            additionalHeaders: filteredHeaders.isEmpty ? nil : filteredHeaders,
            messageId: messageId,
            references: referencesString
        )
    }

    private func messageUID(from message: Message) -> Int {
        if let uid = message.uid {
            return Int(uid.value)
        }
        return Int(message.sequenceNumber.value)
    }

    internal func formatDate(_ date: Date?) -> String {
        guard let date else {
            return ""
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    internal func parseISO8601Date(_ value: String, field: String) throws -> Date {
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

        let dateOnly = ISO8601DateFormatter()
        dateOnly.formatOptions = [.withFullDate]
        if let date = dateOnly.date(from: trimmed) {
            return date
        }

        throw PostServerError.invalidDate(field, value)
    }

    internal func parseFlags(_ value: String) throws -> [SwiftMail.Flag] {
        let parsed = value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map(parseFlag)

        guard !parsed.isEmpty else {
            throw PostServerError.invalidFlags(value)
        }

        return parsed
    }

    private func parseFlag(_ value: String) -> SwiftMail.Flag {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.hasPrefix("\\") ? String(trimmed.dropFirst()) : trimmed

        switch normalized.lowercased() {
        case "seen":
            return .seen
        case "answered":
            return .answered
        case "flagged":
            return .flagged
        case "deleted":
            return .deleted
        case "draft":
            return .draft
        default:
            return .custom(normalized)
        }
    }

    internal func specialUseDescription(for attributes: Mailbox.Info.Attributes) -> String? {
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
