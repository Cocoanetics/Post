import Foundation
import Logging
import SwiftMCP
import SwiftMail
import SwiftTextHTML
@preconcurrency import AnyCodable

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
        }
    }
}

@MCPServer(name: "Post", generateClient: true)
public actor PostServer {
    private struct HookAttachmentPayload: Encodable, Sendable {
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

    private struct HookMessagePayload: Encodable, Sendable {
        let uid: Int
        let mailbox: String
        let from: String
        let to: [String]
        let replyTo: String?
        let date: Date
        let subject: String
        let markdown: String?
        let attachments: [HookAttachmentPayload]
        let headers: [String: String]

        private enum CodingKeys: String, CodingKey {
            case uid
            case from
            case to
            case date
            case subject
            case markdown
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
            try container.encode(headers, forKey: .headers)
        }
    }

    private struct HookPayload: Encodable, Sendable {
        let server: String
        let mailbox: String
        let message: HookMessagePayload
    }

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
        let watchConfigurations = await configuredIdleWatches()
        for watchConfiguration in watchConfigurations {
            if idleWatchTasks[watchConfiguration.serverId] != nil {
                stderr("IDLE watch already running for server=\(watchConfiguration.serverId)")
                continue
            }

            stderr("Starting IDLE watch for server=\(watchConfiguration.serverId) mailbox=\(watchConfiguration.mailbox) command=\(watchConfiguration.command ?? "<nil>")")
            logger.info("Starting IDLE watch for server=\(watchConfiguration.serverId) mailbox=\(watchConfiguration.mailbox)")

            let manager = connectionManager
            idleWatchTasks[watchConfiguration.serverId] = Task.detached {
                await Self.runIdleWatch(
                    serverId: watchConfiguration.serverId,
                    mailbox: watchConfiguration.mailbox,
                    command: watchConfiguration.command,
                    connectionManager: manager
                )
            }
        }
    }

    /// Resolves all configured daemon IDLE watches from current configuration.
    private func configuredIdleWatches() async -> [IdleWatchConfiguration] {
        let infos = await connectionManager.serverInfos()
        stderr("startIdleWatches: found \(infos.count) servers")

        var watchConfigurations: [IdleWatchConfiguration] = []
        watchConfigurations.reserveCapacity(infos.count)

        for info in infos {
            guard let config = try? await connectionManager.resolveServerConfiguration(serverId: info.id) else {
                continue
            }

            guard config.idle == true else {
                stderr("IDLE disabled for server=\(info.id)")
                continue
            }

            let mailbox = (config.idleMailbox?.isEmpty == false) ? (config.idleMailbox!) : "INBOX"
            watchConfigurations.append(IdleWatchConfiguration(serverId: info.id, mailbox: mailbox, command: config.command))
        }

        return watchConfigurations
    }

    /// Runs IDLE watch off the actor so the event loop doesn't block MCP requests.
    /// Uses the shared IMAPServer instance (which manages its own IDLE connections internally).
    private static func runIdleWatch(
        serverId: String,
        mailbox: String,
        command: String?,
        connectionManager: IMAPConnectionManager
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
                                let hookMessage = await Self.fetchHookMessagePayload(using: server, mailbox: mailbox, header: msg)
                                Self.executeHookCommand(command, serverId: serverId, mailbox: mailbox, message: hookMessage)
                            }
                        }
                    }
                } catch {
                    logger.warning("Catch-up fetch failed for \(serverId)/\(mailbox): \(String(describing: error))")
                }

                for await event in idleSession.events {
                    if Task.isCancelled { break }

                    // Log every event to stderr
                    let eventDescription = Self.describeIdleEvent(event)
                    Self.stderr("IDLE event for \(serverId)/\(mailbox): \(eventDescription)")

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
                                    let hookMessage = await Self.fetchHookMessagePayload(using: server, mailbox: mailbox, header: msg)
                                    Self.executeHookCommand(command, serverId: serverId, mailbox: mailbox, message: hookMessage)
                                }
                            }
                        }
                    case .expunge(let seq):
                        Self.stderr("IDLE EXPUNGE for \(serverId)/\(mailbox): seq=\(seq.value)")
                        // Sequence numbers can shift; UID-based high-water mark remains safe.
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

    /// Returns a human-readable description of an IMAP IDLE event.
    private static func describeIdleEvent(_ event: IMAPServerEvent) -> String {
        switch event {
        case .exists(let count):
            return "EXISTS count=\(count)"
        case .expunge(let seq):
            return "EXPUNGE seq=\(seq.value)"
        case .recent(let count):
            return "RECENT count=\(count)"
        case .fetch(let seq, let attributes):
            let attrDesc = attributes.map { String(describing: $0) }.joined(separator: ", ")
            return "FETCH seq=\(seq.value) attributes=[\(attrDesc)]"
        case .alert(let message):
            return "ALERT \(message)"
        case .capability(let caps):
            return "CAPABILITY [\(caps.joined(separator: ", "))]"
        case .bye(let message):
            return "BYE \(message ?? "")"
        case .vanished(let identifiers):
            return "VANISHED ids=\(identifiers)"
        case .flags(let flags):
            let list = flags.map { String(describing: $0) }.joined(separator: ", ")
            return "FLAGS [\(list)]"
        case .fetchUID(let uid, let attributes):
            let attrDesc = attributes.map { String(describing: $0) }.joined(separator: ", ")
            return "FETCH UID=\(uid.value) attributes=[\(attrDesc)]"
        @unknown default:
            return "UNKNOWN EVENT: \(String(describing: event))"
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
                date: formatHookDate(info.date)
            )
        }
    }

    /// Formats dates for hook payloads in ISO 8601 format.
    private static func formatHookDate(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Resolves hook payload date with best-effort fallback from message date, header date, then Unix epoch.
    private static func resolveHookDate(messageDate: Date?, headerDate: String) -> Date {
        if let messageDate {
            return messageDate
        }

        if let parsedHeaderDate = parseISO8601HookDate(headerDate) {
            return parsedHeaderDate
        }

        return Date(timeIntervalSince1970: 0)
    }

    private static func parseISO8601HookDate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: trimmed) {
            return date
        }

        let withoutFractional = ISO8601DateFormatter()
        withoutFractional.formatOptions = [.withInternetDateTime]
        return withoutFractional.date(from: trimmed)
    }

    /// Fetches all hook-relevant message fields (headers, markdown body, attachment names).
    private static func fetchHookMessagePayload(
        using server: IMAPServer,
        mailbox: String,
        header: MessageHeader
    ) async -> HookMessagePayload {
        guard (1...Int(UInt32.max)).contains(header.uid) else {
            return HookMessagePayload(
                uid: header.uid,
                mailbox: mailbox,
                from: decodeHeaderValue(header.from),
                to: [],
                replyTo: nil,
                date: resolveHookDate(messageDate: nil, headerDate: header.date),
                subject: decodeHeaderValue(header.subject),
                markdown: nil,
                attachments: [],
                headers: [:]
            )
        }

        do {
            _ = try await server.selectMailbox(mailbox)
            let identifier = UID(UInt32(header.uid))
            guard let messageInfo = try await server.fetchMessageInfo(for: identifier) else {
                return HookMessagePayload(
                    uid: header.uid,
                    mailbox: mailbox,
                    from: decodeHeaderValue(header.from),
                    to: [],
                    replyTo: nil,
                    date: resolveHookDate(messageDate: nil, headerDate: header.date),
                    subject: decodeHeaderValue(header.subject),
                    markdown: nil,
                    attachments: [],
                    headers: [:]
                )
            }

            let markdown = await fetchHookMarkdown(using: server, messageInfo: messageInfo)
            let decodedAdditionalHeaders = decodeAdditionalHeaders(messageInfo.additionalFields)
            let replyTo = extractReplyTo(from: decodedAdditionalHeaders)
            let decodedFrom = decodeHeaderValue(messageInfo.from ?? header.from)
            let decodedTo = decodeRecipientList(messageInfo.to)
            let decodedSubject = decodeHeaderValue(messageInfo.subject ?? header.subject)
            let attachmentParts = messageInfo.parts.filter(isAttachmentPart)
            let attachments: [HookAttachmentPayload] = attachmentParts.map { part in
                let filename = canonicalAttachmentFilename(part)
                return HookAttachmentPayload(
                    filename: filename,
                    contentType: part.contentType,
                    disposition: part.disposition,
                    section: part.section.description,
                    contentId: part.contentId,
                    encoding: part.encoding,
                    size: nil
                )
            }

            let resolvedDate = resolveHookDate(messageDate: messageInfo.date, headerDate: header.date)
            let headers = buildHookHeaders(
                additionalHeaders: decodedAdditionalHeaders,
                from: decodedFrom,
                to: decodedTo,
                replyTo: replyTo,
                subject: decodedSubject,
                date: formatHookDate(resolvedDate)
            )
            return HookMessagePayload(
                uid: header.uid,
                mailbox: mailbox,
                from: decodedFrom,
                to: decodedTo,
                replyTo: replyTo,
                date: resolvedDate,
                subject: decodedSubject,
                markdown: markdown,
                attachments: attachments,
                headers: headers
            )
        } catch {
            Self.stderr("Failed to fetch hook message details for \(mailbox) uid=\(header.uid): \(String(describing: error))")
        }

        return HookMessagePayload(
            uid: header.uid,
            mailbox: mailbox,
            from: decodeHeaderValue(header.from),
            to: [],
            replyTo: nil,
            date: resolveHookDate(messageDate: nil, headerDate: header.date),
            subject: decodeHeaderValue(header.subject),
            markdown: nil,
            attachments: [],
            headers: [:]
        )
    }

    private static func canonicalAttachmentFilename(_ part: MessagePart) -> String {
        let filename = part.filename?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (filename?.isEmpty == false) ? filename! : part.suggestedFilename
    }

    /// Returns true if a message part should be treated as a file attachment.
    private static func isAttachmentPart(_ part: MessagePart) -> Bool {
        let disposition = part.disposition?.lowercased()
        let filename = part.filename?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasFilename = (filename?.isEmpty == false)
        let isAttachment = disposition == "attachment"
        let isInline = disposition == "inline"
        let isCidOnly = part.contentId != nil && !isAttachment
        return isAttachment || (hasFilename && !isInline && !isCidOnly)
    }

    /// Produces markdown by fetching only text/html body parts (no attachment download).
    private static func fetchHookMarkdown(using server: IMAPServer, messageInfo: MessageInfo) async -> String? {
        let textPart = messageInfo.parts.first { part in
            part.contentType.lowercased().hasPrefix("text/plain")
                && part.disposition?.lowercased() != "attachment"
        }

        let htmlPart = messageInfo.parts.first { part in
            part.contentType.lowercased().hasPrefix("text/html")
                && part.disposition?.lowercased() != "attachment"
        }

        var textBody: String?
        var htmlBody: String?

        do {
            if let textPart {
                let data = try await server.fetchAndDecodeMessagePartData(messageInfo: messageInfo, part: textPart)
                textBody = String(data: data, encoding: .utf8)
            }

            if let htmlPart {
                let data = try await server.fetchAndDecodeMessagePartData(messageInfo: messageInfo, part: htmlPart)
                htmlBody = String(data: data, encoding: .utf8)
            }
        } catch {
            Self.stderr("Failed to fetch body parts for markdown uid=\(messageInfo.uid?.value ?? 0): \(String(describing: error))")
            return nil
        }

        guard textBody != nil || htmlBody != nil else { return nil }

        let detail = MessageDetail(
            uid: Int(messageInfo.uid?.value ?? 0),
            from: messageInfo.from ?? "Unknown",
            to: messageInfo.to,
            subject: messageInfo.subject ?? "(No Subject)",
            date: formatHookDate(messageInfo.date),
            textBody: textBody,
            htmlBody: htmlBody,
            attachments: [],
            additionalHeaders: messageInfo.additionalFields
        )

        do {
            return try await detail.markdown()
        } catch {
            Self.stderr("Failed to convert body to markdown uid=\(messageInfo.uid?.value ?? 0): \(String(describing: error))")
            return textBody
        }
    }

    /// Extracts Reply-To header value from normalized (lowercase) decoded header fields.
    private static func extractReplyTo(from additionalFields: [String: String]) -> String? {
        guard let value = additionalFields["reply-to"] else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Decodes and normalizes additional headers from IMAP into a lowercase-keyed dictionary.
    private static func decodeAdditionalHeaders(_ additionalFields: [String: String]?) -> [String: String] {
        guard let additionalFields else { return [:] }

        var decoded: [String: String] = [:]
        decoded.reserveCapacity(additionalFields.count)

        for (rawKey, rawValue) in additionalFields {
            let key = normalizeHeaderKey(rawKey)
            let value = decodeHeaderValue(rawValue)
            guard !key.isEmpty, !value.isEmpty else { continue }
            decoded[key] = value
        }

        return decoded
    }

    /// Builds the hook JSON headers map with decoded RFC2047 values.
    private static func buildHookHeaders(
        additionalHeaders: [String: String],
        from: String,
        to: [String],
        replyTo: String?,
        subject: String,
        date: String
    ) -> [String: String] {
        var headers = additionalHeaders
        if !from.isEmpty { headers["from"] = from }
        if !to.isEmpty { headers["to"] = to.joined(separator: ", ") }
        if let replyTo, !replyTo.isEmpty { headers["reply-to"] = replyTo }
        if !subject.isEmpty { headers["subject"] = subject }
        if !date.isEmpty { headers["date"] = date }
        return headers
    }

    private static func decodeRecipientList(_ recipients: [String]) -> [String] {
        recipients
            .map(decodeHeaderValue)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func normalizeHeaderKey(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func decodeHeaderValue(_ value: String) -> String {
        let unfolded = unfoldHeaderValue(value)
        let decoded = unfolded.decodeMIMEHeader()
        return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Unfolds multiline header continuations into a single line before decoding.
    private static func unfoldHeaderValue(_ value: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\r?\\n[\\t ]+") else {
            return value
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(in: value, range: range, withTemplate: " ")
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

    private static func executeHookCommand(
        _ command: String,
        serverId: String,
        mailbox: String,
        message: HookMessagePayload
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe

        var env = ProcessInfo.processInfo.environment
        env["POST_UID"] = String(message.uid)
        env["POST_FROM"] = message.from
        env["POST_TO"] = message.to.joined(separator: ", ")
        if let replyTo = message.replyTo {
            env["POST_REPLY_TO"] = replyTo
        }
        env["POST_SUBJECT"] = message.subject
        env["POST_DATE"] = formatHookDate(message.date)
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
            let payload = HookPayload(server: serverId, mailbox: mailbox, message: message)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let json = try encoder.encode(payload)
            try stdinPipe.fileHandleForWriting.write(contentsOf: json)
            try stdinPipe.fileHandleForWriting.write(contentsOf: Data([0x0A]))
            try stdinPipe.fileHandleForWriting.close()
        } catch {
            Self.stderr("Failed to execute hook for \(serverId)/\(mailbox) uid=\(message.uid): \(String(describing: error))")
            try? stdinPipe.fileHandleForWriting.close()
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
        before: String? = nil,
        headerField: String? = nil,
        headerValue: String? = nil,
        unseen: Bool? = nil,
        seen: Bool? = nil
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

            if let headerField, !headerField.isEmpty, let headerValue, !headerValue.isEmpty {
                criteria.append(.header(headerField, headerValue))
            }

            if unseen == true {
                criteria.append(.unseen)
            }
            if seen == true {
                criteria.append(.seen)
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

    /// Creates a new email draft and appends it to the Drafts mailbox.
    /// - Parameter serverId: The server identifier
    /// - Parameter from: Sender email address
    /// - Parameter to: Comma-separated recipient email addresses
    /// - Parameter subject: Email subject
    /// - Parameter body: The body content
    /// - Parameter format: Body format: "text" (default), "html", or "markdown"
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
        format: String = "text",
        cc: String? = nil,
        bcc: String? = nil,
        attachments: String? = nil,
        mailbox: String? = nil
    ) async throws -> DraftResult {
        let sender = EmailAddress(address: from)
        let recipients = to.split(separator: ",").map { EmailAddress(address: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let ccRecipients = cc?.split(separator: ",").map { EmailAddress(address: $0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? []
        let bccRecipients = bcc?.split(separator: ",").map { EmailAddress(address: $0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? []

        let textBody: String
        let htmlBody: String?

        switch format.lowercased() {
        case "html":
            htmlBody = body
            textBody = body.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        case "markdown":
            htmlBody = MarkdownToHTML.convert(body)
            textBody = MarkdownToHTML.stripToPlainText(body)
        default:
            textBody = body
            htmlBody = nil
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

        let email = Email(
            sender: sender,
            recipients: recipients,
            ccRecipients: ccRecipients,
            bccRecipients: bccRecipients,
            subject: subject,
            textBody: textBody,
            htmlBody: htmlBody,
            attachments: emailAttachments
        )

        return try await withServer(serverId: serverId) { server in
            _ = try await server.listSpecialUseMailboxes()
            let result = try await server.createDraft(from: email, in: mailbox)
            let targetMailbox = mailbox ?? "Drafts"
            let uid = result.firstUID.map { Int($0.value) }
            return DraftResult(mailbox: targetMailbox, uid: uid)
        }
    }

    /// Watches IMAP IDLE events in real time. Events are delivered as MCP log notifications.
    /// This is a long-running tool call — it blocks until the client disconnects.
    @MCPTool
    public func watchIdleEvents() async throws {
        guard let session = Session.current else {
            throw PostServerError.noSession
        }

        let watchConfigurations = await configuredIdleWatches()
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
            data: AnyCodable("Subscribed to IDLE events. Waiting for changes...")
        ))
        await session.sendLogNotification(LogMessage(
            level: .info,
            logger: "idle",
            data: AnyCodable("Watching raw IDLE events on \(watchConfigurations.count) mailbox(es): \(activeTargets)")
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
                data: AnyCodable([
                    "server": rawEvent.serverId,
                    "mailbox": rawEvent.mailbox,
                    "event": Self.describeIdleEvent(rawEvent.event)
                ] as [String: String])
            ))
        }
    }

    /// Sanitizes a string for use as a filename.
    private static func sanitizeFilename(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "[/\\\\:*?\"<>|]", with: "-", options: .regularExpression)
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "message" : String(trimmed.prefix(100))
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
        for i in 0..<Int(gt.gl_matchc) {
            if let cStr = gt.gl_pathv[i] {
                results.append(String(cString: cStr))
            }
        }
        return results.sorted()
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
