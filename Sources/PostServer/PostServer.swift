import Foundation
import Logging
import SwiftMCP
import SwiftMail

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
        }
    }
}

@MCPServer(name: "Post", generateClient: true)
public actor PostServer {
    private var connectionManager: IMAPConnectionManager
    private let logger = Logger(label: "com.cocoanetics.Post.PostServer")

    private var idleWatchTasks: [String: Task<Void, Never>] = [:]

    private static func stderr(_ message: String) {
        if let data = ("[postd] \(message)\n").data(using: .utf8) {
            try? FileHandle.standardError.write(contentsOf: data)
        }
    }

    private nonisolated func stderr(_ message: String) {
        Self.stderr(message)
    }

    public init(configuration: PostConfiguration) {
        self.connectionManager = IMAPConnectionManager(configuration: configuration)
    }

    /// Starts configured IMAP IDLE watches (dedicated connections via SwiftMail) for servers
    /// that have `idle: true` in ~/.post.json.
    public func startIdleWatches() async {
        let infos = await connectionManager.serverInfos()
        stderr("startIdleWatches: found \(infos.count) servers")

        for info in infos {
            guard let config = try? await connectionManager.resolveServerConfiguration(serverId: info.id) else {
                continue
            }

            guard config.idle == true else {
                stderr("IDLE disabled for server=\(info.id)")
                continue
            }

            let mailbox = (config.idleMailbox?.isEmpty == false) ? (config.idleMailbox!) : "INBOX"
            let command = config.command

            if idleWatchTasks[info.id] != nil {
                stderr("IDLE watch already running for server=\(info.id)")
                continue
            }

            stderr("Starting IDLE watch for server=\(info.id) mailbox=\(mailbox) command=\(command ?? "<nil>")")
            logger.info("Starting IDLE watch for server=\(info.id) mailbox=\(mailbox)")
            
            let manager = connectionManager
            idleWatchTasks[info.id] = Task.detached { [weak self] in
                await Self.runIdleWatch(
                    serverId: info.id,
                    mailbox: mailbox,
                    command: command,
                    connectionManager: manager,
                    postServer: self
                )
            }
        }
    }

    /// Runs IDLE watch off the actor so the event loop doesn't block MCP requests.
    /// Uses the shared IMAPServer instance (which manages its own IDLE connections internally).
    private static func runIdleWatch(
        serverId: String,
        mailbox: String,
        command: String?,
        connectionManager: IMAPConnectionManager,
        postServer: PostServer?
    ) async {
        let logger = Logger(label: "com.cocoanetics.Post.IDLE.\(serverId)")

        while !Task.isCancelled {
            do {
                // Get connection inside the detached task (async call to actor)
                Self.stderr("runIdleWatch: getting connection for \(serverId)")
                let server = try await connectionManager.connection(for: serverId)
                Self.stderr("runIdleWatch: got connection for \(serverId)")
                
                Self.stderr("runIdleWatch loop starting for \(serverId)/\(mailbox)")

                // Baseline: Get current max UID using primary connection
                var lastSeenUID: Int = 0
                do {
                    // Fetch latest 1 message to get the highest UID
                    // Use fetchMessageInfos with limit to avoid fetching all headers
                    // Note: fetchMessageInfos(uidRange:) requires a range.
                    // We need to list messages or status to find the latest.
                    // Let's use mailboxStatus to get uidNext or highestModSeq?
                    // Or just use listMessages from the server (which uses primary connection)
                    
                    // Since we are static, we call IMAPServer methods directly.
                    // We need to know the UIDNext or search for *
                    // Actually, let's just use selectMailbox to get the status, which often includes UIDs
                    
                    let status = try await server.selectMailbox(mailbox)
                    if let latest = status.latest(1) {
                        let infos = try await server.fetchMessageInfosBulk(using: latest)
                        if let uid = infos.first?.uid {
                            lastSeenUID = Int(uid.value)
                        }
                    }
                    
                    Self.stderr("IDLE baseline for \(serverId)/\(mailbox): lastSeenUID=\(lastSeenUID)")
                    logger.info("IDLE baseline for \(serverId)/\(mailbox): lastSeenUID=\(lastSeenUID)")
                } catch {
                    logger.warning("Failed to build baseline for \(serverId)/\(mailbox): \(String(describing: error))")
                }

                // Start IDLE on the mailbox (IMAPServer creates a dedicated connection)
                let idleSession = try await server.idle(on: mailbox)
                Self.stderr("IDLE connected for \(serverId)/\(mailbox)")
                logger.info("IDLE connected for \(serverId)/\(mailbox)")

                defer {
                    Task {
                        try? await idleSession.done()
                        logger.info("IDLE session closed for \(serverId)/\(mailbox)")
                    }
                }

                // Catch any messages that arrived during setup (between baseline and IDLE start)
                do {
                    let caughtUp = try await Self.fetchNewMessages(using: server, mailbox: mailbox, minUID: lastSeenUID + 1)
                    Self.stderr("IDLE catch-up for \(serverId)/\(mailbox): fetched \(caughtUp.count) messages since uid \(lastSeenUID + 1)")
                    for msg in caughtUp {
                        if msg.uid > lastSeenUID {
                            lastSeenUID = msg.uid
                            Self.stderr("New message (catch-up) \(serverId)/\(mailbox): uid=\(msg.uid) subject=\(msg.subject)")
                            logger.info("New message (catch-up) on \(serverId)/\(mailbox): uid=\(msg.uid) from=\(msg.from)")
                            if let command {
                                Self.executeHookCommand(command, serverId: serverId, mailbox: mailbox, message: msg)
                            }
                        }
                    }
                } catch {
                    logger.warning("Catch-up fetch failed for \(serverId)/\(mailbox): \(String(describing: error))")
                }

                for await event in idleSession.events {
                    if Task.isCancelled { break }

                    switch event {
                    case .exists(let count):
                        Self.stderr("IDLE EXISTS for \(serverId)/\(mailbox): count=\(count) lastSeenUID=\(lastSeenUID)")
                        let newMessages = try await Self.fetchNewMessages(using: server, mailbox: mailbox, minUID: lastSeenUID + 1)
                        Self.stderr("IDLE delta fetch for \(serverId)/\(mailbox): fetched \(newMessages.count) messages since uid \(lastSeenUID + 1)")
                        for msg in newMessages {
                            if msg.uid > lastSeenUID {
                                lastSeenUID = msg.uid
                                Self.stderr("New message \(serverId)/\(mailbox): uid=\(msg.uid) subject=\(msg.subject)")
                                logger.info("New message on \(serverId)/\(mailbox): uid=\(msg.uid) from=\(msg.from)")
                                if let command {
                                    Self.executeHookCommand(command, serverId: serverId, mailbox: mailbox, message: msg)
                                }
                            }
                        }
                    case .expunge(_):
                        // Sequence numbers can shift; UID-based high-water mark remains safe.
                        break
                    case .bye:
                        Self.stderr("IDLE BYE for \(serverId)/\(mailbox)")
                        logger.warning("IDLE received BYE for \(serverId)/\(mailbox); reconnecting")
                        return
                    default:
                        break
                    }
                }

                // If stream ends, reconnect
                Self.stderr("IDLE stream ended for \(serverId)/\(mailbox); reconnecting")
                logger.warning("IDLE stream ended for \(serverId)/\(mailbox); reconnecting")
            } catch {
                Self.stderr("IDLE watch failed for \(serverId)/\(mailbox): \(String(describing: error))")
                logger.warning("IDLE watch failed for \(serverId)/\(mailbox): \(String(describing: error))")
            }

            // backoff
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    /// Fetches new messages using a dedicated IDLE connection (no actor hop).
    private static func fetchNewMessages(using server: IMAPServer, mailbox: String, minUID: Int) async throws -> [MessageHeader] {
        _ = try await server.selectMailbox(mailbox)
        let safeMinUID = max(1, minUID)
        let infos = try await server.fetchMessageInfos(uidRange: UID(safeMinUID)...)
        return infos.compactMap { info in
            let uidInt = Int(info.uid?.value ?? 0)
            guard uidInt > 0 else { return nil }
            return MessageHeader(
                uid: uidInt,
                from: info.from ?? "Unknown",
                subject: info.subject ?? "(No Subject)",
                date: info.date?.description ?? ""
            )
        }
    }

    /// Fetches messages with UID >= minUID
    private func fetchMessagesSince(serverId: String, mailbox: String, minUID: Int) async throws -> [MessageHeader] {
        return try await withServer(serverId: serverId) { server in
            _ = try await server.selectMailbox(mailbox)
            
            let safeMinUID = max(1, minUID)
            // Fetch UID range as a single `UID FETCH <min>:*` (no expansion)
            let infos = try await server.fetchMessageInfos(uidRange: UID(safeMinUID)...)
            let headers: [MessageHeader] = infos.compactMap { info in
                let uidInt = Int(info.uid?.value ?? 0)
                guard uidInt > 0 else { return nil }
                return MessageHeader(
                    uid: uidInt,
                    from: info.from ?? "Unknown",
                    subject: info.subject ?? "(No Subject)",
                    date: formatDate(info.date)
                )
            }
            return headers.sorted { $0.uid < $1.uid }
        }
    }

    private static func executeHookCommand(_ command: String, serverId: String, mailbox: String, message: MessageHeader) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")

        var env = ProcessInfo.processInfo.environment
        env["POST_UID"] = String(message.uid)
        env["POST_FROM"] = message.from
        env["POST_SUBJECT"] = message.subject
        env["POST_DATE"] = message.date
        env["POST_SERVER"] = serverId
        env["POST_MAILBOX"] = mailbox
        process.environment = env

        process.arguments = ["-c", command]

        stderr("Executing hook for \(serverId)/\(mailbox) uid=\(message.uid): \(command)")

        process.terminationHandler = { [serverId, mailbox, uid = message.uid] proc in
            let status = proc.terminationStatus
            let reason = proc.terminationReason
            if let data = ("[postd] Hook finished for \(serverId)/\(mailbox) uid=\(uid): status=\(status) reason=\(reason)\n").data(using: .utf8) {
                try? FileHandle.standardError.write(contentsOf: data)
            }
        }

        do {
            try process.run()
        } catch {
            Self.stderr("Failed to execute hook for \(serverId)/\(mailbox) uid=\(message.uid): \(String(describing: error))")
        }
    }

    public func shutdown() async {
        stopIdleWatches()
        await connectionManager.shutdown()
    }

    /// Reloads configuration from disk, restarts IDLE watches and connections.
    public func reloadConfiguration() async {
        stderr("Reloading configuration...")

        do {
            let newConfig = try PostConfiguration.load()

            // Stop all IDLE watches
            stopIdleWatches()

            // Shut down existing connections
            await connectionManager.shutdown()

            // Replace connection manager with new config
            connectionManager = IMAPConnectionManager(configuration: newConfig)

            stderr("Configuration reloaded. \(newConfig.servers.count) server(s) configured.")

            // Restart IDLE watches
            await startIdleWatches()
        } catch {
            stderr("Failed to reload configuration: \(error.localizedDescription)")
        }
    }

    private func stopIdleWatches() {
        for (id, task) in idleWatchTasks {
            task.cancel()
            stderr("Stopped IDLE watch for server=\(id)")
        }
        idleWatchTasks.removeAll()
    }

    /// Lists all configured IMAP servers with IDs and resolved connection info.
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
                messages.append(messageDetail(from: message))
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
            attachments: attachments,
            additionalHeaders: message.header.additionalFields
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

    private func parseFlags(_ value: String) throws -> [Flag] {
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

    private func parseFlag(_ value: String) -> Flag {
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
