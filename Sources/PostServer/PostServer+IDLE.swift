import Foundation
import Logging
import SwiftMail
import SwiftTextHTML

// MARK: - IDLE Watch & Hooks

extension PostServer {
    public func startIdleWatches() async {
        let watchConfigurations = await configuredIdleWatches()
        for watchConfiguration in watchConfigurations {
            if idleWatchTasks[watchConfiguration.serverId] != nil {
                Self.logDiagnostic("IDLE watch already running for server=\(watchConfiguration.serverId)")
                continue
            }

            Self.logDiagnostic("Starting IDLE watch for server=\(watchConfiguration.serverId) mailbox=\(watchConfiguration.mailbox) command=\(watchConfiguration.command ?? "<nil>")")
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
    internal func configuredIdleWatches() async -> [IdleWatchConfiguration] {
        let infos = await connectionManager.serverInfos()
        Self.logDiagnostic("startIdleWatches: found \(infos.count) servers")

        var watchConfigurations: [IdleWatchConfiguration] = []
        watchConfigurations.reserveCapacity(infos.count)

        for info in infos {
            guard let config = try? await connectionManager.resolveServerConfiguration(serverId: info.id) else {
                continue
            }

            guard config.idle == true else {
                Self.logDiagnostic("IDLE disabled for server=\(info.id)")
                continue
            }

            let mailbox = (config.idleMailbox?.isEmpty == false) ? (config.idleMailbox!) : "INBOX"
            watchConfigurations.append(IdleWatchConfiguration(serverId: info.id, mailbox: mailbox, command: config.command))
        }

        return watchConfigurations
    }

    /// Returns a cached fetch connection for `serverId/mailbox`, creating a fresh one if needed.
    fileprivate static func fetchConnection(
        cache: inout IMAPNamedConnection?,
        server: IMAPServer,
        serverId: String,
        mailbox: String
    ) async throws -> IMAPNamedConnection {
        if let existing = cache, await existing.isConnected {
            return existing
        }
        let conn = try await server.connection(named: "fetch-\(serverId)-\(mailbox)")
        cache = conn
        return conn
    }

    /// Runs IDLE watch off the actor so the event loop doesn't block MCP requests.
    /// Uses server-managed connections: one resilient IDLE stream + ephemeral fetch connections.
    fileprivate static func runIdleWatch(
        serverId: String,
        mailbox: String,
        command: String?,
        connectionManager: IMAPConnectionManager
    ) async {
        let logger = Logger(label: "com.cocoanetics.Post.IDLE.\(serverId)")
        var fetchCache: IMAPNamedConnection? = nil

        while !Task.isCancelled {
            do {
                // Get connection inside the detached task (async call to actor)
                Self.logDiagnostic("runIdleWatch: getting connection for \(serverId)")
                let server = try await connectionManager.connection(for: serverId)
                Self.logDiagnostic("runIdleWatch: got connection for \(serverId)")

                Self.logDiagnostic("runIdleWatch loop starting for \(serverId)/\(mailbox)")

                // Baseline: determine the current max UID from the SELECT response's UIDNEXT.
                // UIDNEXT - 1 is the highest possible UID (the UID may not exist if deleted,
                // but that's fine — we only use it as a high-water mark for new message detection).
                var lastSeenUID: Int = 0
                do {
                    let conn = try await Self.fetchConnection(cache: &fetchCache, server: server, serverId: serverId, mailbox: mailbox)
                    let status = try await conn.selectMailbox(mailbox)
                    let uidNextValue = Int(status.uidNext.value)
                    if uidNextValue > 1 {
                        lastSeenUID = uidNextValue - 1
                    }

                    Self.logDiagnostic("IDLE baseline for \(serverId)/\(mailbox): lastSeenUID=\(lastSeenUID) (from UIDNEXT)")
                    logger.info("IDLE baseline for \(serverId)/\(mailbox): lastSeenUID=\(lastSeenUID)")
                } catch {
                    Self.logDiagnostic("ERROR baseline failed for \(serverId)/\(mailbox): \(String(describing: error))")
                    logger.warning("Failed to build baseline for \(serverId)/\(mailbox): \(String(describing: error))")
                }

                // Start IDLE on the mailbox (IMAPServer creates a dedicated connection)
                let idleSession = try await server.idle(on: mailbox)
                Self.logDiagnostic("IDLE connection established for \(serverId)/\(mailbox)")
                logger.info("IDLE connected for \(serverId)/\(mailbox)")

                defer {
                    Task {
                        try? await idleSession.done()
                        Self.logDiagnostic("IDLE connection disconnected for \(serverId)/\(mailbox)")
                        logger.info("IDLE session closed for \(serverId)/\(mailbox)")
                    }
                }

                // Catch any messages that arrived during setup (between baseline and IDLE start),
                // including the baseline UID itself so restart does not skip it.
                // Skip catch-up entirely when baseline is unknown (0) — we have no reference point,
                // so fetching all messages would just spam hooks on already-read mail.
                if lastSeenUID > 0 {
                do {
                    let baselineUID = lastSeenUID
                    let catchUpMinUID = baselineUID
                    var baselineMessagePending = true
                    Self.logDiagnostic(
                        "IDLE catch-up fetch for \(serverId)/\(mailbox): minUID=\(catchUpMinUID) (inclusive baseline UID=\(baselineUID))"
                    )
                    let conn = try await Self.fetchConnection(cache: &fetchCache, server: server, serverId: serverId, mailbox: mailbox)
                    let caughtUp = try await Self.fetchNewMessages(using: conn, mailbox: mailbox, minUID: catchUpMinUID)
                    Self.logDiagnostic("IDLE catch-up for \(serverId)/\(mailbox): fetched \(caughtUp.count) messages since uid \(catchUpMinUID)")
                    for (msg, msgInfo) in caughtUp {
                        Self.logDiagnostic("IDLE catch-up examining message uid=\(msg.uid) vs lastSeenUID=\(lastSeenUID)")
                        let isBaselineMessage = baselineMessagePending && msg.uid == baselineUID
                        if msg.uid > lastSeenUID || isBaselineMessage {
                            if isBaselineMessage {
                                baselineMessagePending = false
                                Self.logDiagnostic("IDLE catch-up including baseline message for \(serverId)/\(mailbox): uid=\(msg.uid)")
                                logger.info("IDLE catch-up including baseline message on \(serverId)/\(mailbox): uid=\(msg.uid)")
                            }
                            lastSeenUID = max(lastSeenUID, msg.uid)
                            Self.logDiagnostic("New message (catch-up) \(serverId)/\(mailbox): uid=\(msg.uid) subject=\(msg.subject)")
                            logger.info("New message (catch-up) on \(serverId)/\(mailbox): uid=\(msg.uid) from=\(msg.from)")
                            if let command {
                                let hookConn = try await Self.fetchConnection(cache: &fetchCache, server: server, serverId: serverId, mailbox: mailbox)
                                let hookMessage = await Self.buildHookMessagePayload(using: hookConn, mailbox: mailbox, header: msg, messageInfo: msgInfo)
                                Self.executeHookCommand(command, serverId: serverId, mailbox: mailbox, message: hookMessage)
                            }
                        } else {
                            Self.logDiagnostic("IDLE catch-up SKIPPED message uid=\(msg.uid) because lastSeenUID=\(lastSeenUID)")
                        }
                    }
                } catch {
                    Self.logDiagnostic("ERROR catch-up fetch failed for \(serverId)/\(mailbox): \(String(describing: error))")
                    logger.warning("Catch-up fetch failed for \(serverId)/\(mailbox): \(String(describing: error))")
                }
                } else {
                    Self.logDiagnostic("IDLE catch-up skipped for \(serverId)/\(mailbox): no baseline UID known")
                    logger.info("IDLE catch-up skipped for \(serverId)/\(mailbox): no baseline UID known")
                }

                eventLoop: for await event in idleSession.events {
                    if Task.isCancelled { break }

                    // Log every IDLE event for diagnostics.
                    let eventDescription = Self.describeIdleEvent(event)
                    Self.logDiagnostic("IDLE event for \(serverId)/\(mailbox): \(eventDescription)")

                    switch event {
                    case .exists(let count):
                        Self.logDiagnostic("IDLE EXISTS for \(serverId)/\(mailbox): count=\(count) lastSeenUID=\(lastSeenUID)")
                        Self.logDiagnostic("Fetching new messages after EXISTS for \(serverId)/\(mailbox): minUID=\(lastSeenUID + 1)")

                        // Fetch with one retry: if the cached connection is stale, invalidate and retry.
                        let newMessages: [(header: MessageHeader, info: MessageInfo)]
                        do {
                            let conn = try await Self.fetchConnection(cache: &fetchCache, server: server, serverId: serverId, mailbox: mailbox)
                            newMessages = try await Self.fetchNewMessages(using: conn, mailbox: mailbox, minUID: lastSeenUID + 1)
                        } catch {
                            Self.logDiagnostic("EXISTS fetch failed for \(serverId)/\(mailbox), retrying with fresh connection: \(String(describing: error))")
                            fetchCache = nil
                            let conn = try await Self.fetchConnection(cache: &fetchCache, server: server, serverId: serverId, mailbox: mailbox)
                            newMessages = try await Self.fetchNewMessages(using: conn, mailbox: mailbox, minUID: lastSeenUID + 1)
                        }

                        Self.logDiagnostic("IDLE delta fetch for \(serverId)/\(mailbox): fetched \(newMessages.count) messages since uid \(lastSeenUID + 1)")
                        for (msg, msgInfo) in newMessages {
                            if msg.uid > lastSeenUID {
                                lastSeenUID = msg.uid
                                Self.logDiagnostic("New message \(serverId)/\(mailbox): uid=\(msg.uid) subject=\(msg.subject)")
                                logger.info("New message on \(serverId)/\(mailbox): uid=\(msg.uid) from=\(msg.from)")
                                if let command {
                                    let hookConn = try await Self.fetchConnection(cache: &fetchCache, server: server, serverId: serverId, mailbox: mailbox)
                                    let hookMessage = await Self.buildHookMessagePayload(using: hookConn, mailbox: mailbox, header: msg, messageInfo: msgInfo)
                                    Self.executeHookCommand(command, serverId: serverId, mailbox: mailbox, message: hookMessage)
                                }
                            }
                        }
                    case .expunge(let seq):
                        Self.logDiagnostic("IDLE EXPUNGE for \(serverId)/\(mailbox): seq=\(seq.value)")
                        // Sequence numbers can shift; UID-based high-water mark remains safe.
                    case .bye:
                        Self.logDiagnostic("IDLE BYE for \(serverId)/\(mailbox)")
                        Self.logDiagnostic("ERROR IDLE received BYE for \(serverId)/\(mailbox); reconnect requested")
                        logger.warning("IDLE received BYE for \(serverId)/\(mailbox); reconnecting")
                        break eventLoop
                    default:
                        break
                    }
                }

                // If stream ends, reconnect; discard cached fetch connection
                fetchCache = nil
                Self.logDiagnostic("IDLE stream ended for \(serverId)/\(mailbox); reconnecting")
                logger.warning("IDLE stream ended for \(serverId)/\(mailbox); reconnecting")
            } catch {
                fetchCache = nil
                Self.logDiagnostic("ERROR IDLE watch failed for \(serverId)/\(mailbox): \(String(describing: error))")
                logger.warning("IDLE watch failed for \(serverId)/\(mailbox): \(String(describing: error))")
            }

            // backoff
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    /// Returns a human-readable description of an IMAP IDLE event.
    internal static func describeIdleEvent(_ event: IMAPServerEvent) -> String {
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

    /// Fetches new messages using the IDLE watch's named command connection.
    fileprivate static func fetchNewMessages(using connection: IMAPNamedConnection, mailbox: String, minUID: Int) async throws -> [(header: MessageHeader, info: MessageInfo)] {
        _ = try await connection.selectMailbox(mailbox)
        let safeMinUID = max(1, minUID)
        let infos = try await connection.fetchMessageInfos(uidRange: UID(safeMinUID)...)
        return infos.compactMap { info -> (header: MessageHeader, info: MessageInfo)? in
            let uidInt = Int(info.uid?.value ?? 0)
            guard uidInt > 0, uidInt >= minUID else { return nil }
            let header = MessageHeader(
                uid: uidInt,
                from: info.from ?? "Unknown",
                subject: info.subject ?? "(No Subject)",
                date: formatHookDate(info.date),
                flags: MessageFlags(info.flags)
            )
            return (header: header, info: info)
        }
    }

    internal func stopIdleWatches() {
        for (serverId, task) in idleWatchTasks {
            Self.logDiagnostic("Stopping IDLE watch for server=\(serverId)")
            task.cancel()
        }
        idleWatchTasks.removeAll()
    }
}

// MARK: - Hook Payload Construction

extension PostServer {
    /// Formats dates for hook payloads in ISO 8601 format.
    fileprivate static func formatHookDate(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Resolves hook payload date with best-effort fallback from message date, header date, then Unix epoch.
    fileprivate static func resolveHookDate(messageDate: Date?, headerDate: String) -> Date {
        if let messageDate {
            return messageDate
        }

        if let parsedHeaderDate = parseISO8601HookDate(headerDate) {
            return parsedHeaderDate
        }

        return Date(timeIntervalSince1970: 0)
    }

    fileprivate static func parseISO8601HookDate(_ value: String) -> Date? {
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

    /// Builds a hook payload from an already-fetched MessageInfo, only fetching the body (markdown).
    fileprivate static func buildHookMessagePayload(
        using connection: IMAPNamedConnection,
        mailbox: String,
        header: MessageHeader,
        messageInfo: MessageInfo
    ) async -> HookMessagePayload {
        let markdown = await fetchHookMarkdown(using: connection, messageInfo: messageInfo)
        var decodedAdditionalHeaders = decodeAdditionalHeaders(messageInfo.additionalFields)
        
        // Explicitly add Message-ID if available (for threading/deduplication)
        if let messageId = messageInfo.messageId?.description {
            decodedAdditionalHeaders["message-id"] = messageId
        }
        
        let replyTo = extractReplyTo(from: decodedAdditionalHeaders)
        let decodedFrom = decodeHeaderValue(messageInfo.from ?? header.from)
        let decodedTo = decodeRecipientList(messageInfo.to)
        let decodedSubject = UnicodeAbuseSummary.sanitize(
            decodeHeaderValue(messageInfo.subject ?? header.subject),
            field: "Subject"
        )
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
            subject: decodedSubject.text,
            date: formatHookDate(resolvedDate)
        )
        return HookMessagePayload(
            uid: header.uid,
            mailbox: mailbox,
            from: decodedFrom,
            to: decodedTo,
            replyTo: replyTo,
            date: resolvedDate,
            subject: decodedSubject.text,
            markdown: markdown?.text,
            unicodeAbuse: UnicodeAbuseSummary.combine([decodedSubject.unicodeAbuse, markdown?.unicodeAbuse]),
            flags: messageInfo.flags.map(Self.flagToString),
            attachments: attachments,
            headers: headers
        )
    }

    /// Converts a SwiftMail Flag to its string representation.
    fileprivate static func flagToString(_ flag: Flag) -> String {
        switch flag {
        case .seen: return "\\Seen"
        case .answered: return "\\Answered"
        case .flagged: return "\\Flagged"
        case .deleted: return "\\Deleted"
        case .draft: return "\\Draft"
        case .custom(let value): return value
        }
    }

    /// Fetches all hook-relevant message fields (headers, markdown body, attachment names).
    /// Used only by MCP tools and other callers that don't already have a MessageInfo.
    fileprivate static func fetchHookMessagePayload(
        using connection: IMAPNamedConnection,
        mailbox: String,
        header: MessageHeader
    ) async -> HookMessagePayload {
        guard (1...Int(UInt32.max)).contains(header.uid) else {
            let subject = UnicodeAbuseSummary.sanitize(decodeHeaderValue(header.subject), field: "Subject")
            return HookMessagePayload(
                uid: header.uid,
                mailbox: mailbox,
                from: decodeHeaderValue(header.from),
                to: [],
                replyTo: nil,
                date: resolveHookDate(messageDate: nil, headerDate: header.date),
                subject: subject.text,
                markdown: nil,
                unicodeAbuse: subject.unicodeAbuse,
                flags: [],
                attachments: [],
                headers: [:]
            )
        }

        do {
            _ = try await connection.selectMailbox(mailbox)
            let identifier = UID(UInt32(header.uid))
            guard let messageInfo = try await connection.fetchMessageInfo(for: identifier) else {
                let subject = UnicodeAbuseSummary.sanitize(decodeHeaderValue(header.subject), field: "Subject")
                return HookMessagePayload(
                    uid: header.uid,
                    mailbox: mailbox,
                    from: decodeHeaderValue(header.from),
                    to: [],
                    replyTo: nil,
                    date: resolveHookDate(messageDate: nil, headerDate: header.date),
                    subject: subject.text,
                    markdown: nil,
                    unicodeAbuse: subject.unicodeAbuse,
                    flags: [],
                    attachments: [],
                    headers: [:]
                )
            }

            let markdown = await fetchHookMarkdown(using: connection, messageInfo: messageInfo)
            
            var decodedAdditionalHeaders = decodeAdditionalHeaders(messageInfo.additionalFields)
            
            // Explicitly add Message-ID if available (for threading/deduplication)
            if let messageId = messageInfo.messageId?.description {
                decodedAdditionalHeaders["message-id"] = messageId
            }
            
            let replyTo = extractReplyTo(from: decodedAdditionalHeaders)
            let decodedFrom = decodeHeaderValue(messageInfo.from ?? header.from)
            let decodedTo = decodeRecipientList(messageInfo.to)
            let decodedSubject = UnicodeAbuseSummary.sanitize(
                decodeHeaderValue(messageInfo.subject ?? header.subject),
                field: "Subject"
            )
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
                subject: decodedSubject.text,
                date: formatHookDate(resolvedDate)
            )
            return HookMessagePayload(
                uid: header.uid,
                mailbox: mailbox,
                from: decodedFrom,
                to: decodedTo,
                replyTo: replyTo,
                date: resolvedDate,
                subject: decodedSubject.text,
                markdown: markdown?.text,
                unicodeAbuse: UnicodeAbuseSummary.combine([decodedSubject.unicodeAbuse, markdown?.unicodeAbuse]),
                flags: messageInfo.flags.map(Self.flagToString),
                attachments: attachments,
                headers: headers
            )
        } catch {
            Self.logDiagnostic("ERROR failed to fetch hook message details for \(mailbox) uid=\(header.uid): \(String(describing: error))")
        }

        let subject = UnicodeAbuseSummary.sanitize(decodeHeaderValue(header.subject), field: "Subject")
        return HookMessagePayload(
            uid: header.uid,
            mailbox: mailbox,
            from: decodeHeaderValue(header.from),
            to: [],
            replyTo: nil,
            date: resolveHookDate(messageDate: nil, headerDate: header.date),
            subject: subject.text,
            markdown: nil,
            unicodeAbuse: subject.unicodeAbuse,
            flags: [],
            attachments: [],
            headers: [:]
        )
    }

    fileprivate static func canonicalAttachmentFilename(_ part: MessagePart) -> String {
        let filename = part.filename?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (filename?.isEmpty == false) ? filename! : part.suggestedFilename
    }

    /// Returns true if a message part should be treated as a file attachment.
    fileprivate static func isAttachmentPart(_ part: MessagePart) -> Bool {
        let disposition = part.disposition?.lowercased()
        let filename = part.filename?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasFilename = (filename?.isEmpty == false)
        let isAttachment = disposition == "attachment"
        let isInline = disposition == "inline"
        let isCidOnly = part.contentId != nil && !isAttachment
        return isAttachment || (hasFilename && !isInline && !isCidOnly)
    }

    /// Fetches ALL RFC 822 headers by fetching the raw message and parsing headers.
    /// This is a workaround for SwiftMail not populating MessageInfo.additionalFields.
    /// Produces markdown by fetching only text/html body parts (no attachment download).
    fileprivate static func fetchHookMarkdown(using connection: IMAPNamedConnection, messageInfo: MessageInfo) async -> SanitizedText? {
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
                let data = try await fetchAndDecodePartData(
                    using: connection,
                    messageInfo: messageInfo,
                    part: textPart
                )
                textBody = String(data: data, encoding: .utf8)
            }

            if let htmlPart {
                let data = try await fetchAndDecodePartData(
                    using: connection,
                    messageInfo: messageInfo,
                    part: htmlPart
                )
                htmlBody = String(data: data, encoding: .utf8)
            }
        } catch {
            Self.logDiagnostic("ERROR failed to fetch body parts for markdown uid=\(messageInfo.uid?.value ?? 0): \(String(describing: error))")
            return nil
        }

        guard textBody != nil || htmlBody != nil else { return nil }

        let messageId = messageInfo.messageId?.description
        let referencesString = messageInfo.references?.map { $0.description }.joined(separator: " ")

        let detail = MessageDetail(
            uid: Int(messageInfo.uid?.value ?? 0),
            from: messageInfo.from ?? "Unknown",
            to: messageInfo.to,
            cc: messageInfo.cc.isEmpty ? nil : messageInfo.cc,
            subject: messageInfo.subject ?? "(No Subject)",
            date: formatHookDate(messageInfo.date),
            textBody: textBody,
            htmlBody: htmlBody,
            attachments: [],
            additionalHeaders: messageInfo.additionalFields,
            messageId: messageId,
            references: referencesString
        )

        do {
            return try await detail.markdownSanitized()
        } catch {
            let uid = messageInfo.uid?.value ?? 0
            Self.logDiagnostic("ERROR failed to convert body to markdown uid=\(uid): \(String(describing: error))")
            
            // Preserve offending HTML for debugging
            if let htmlBody = htmlBody, !htmlBody.isEmpty {
                let debugDir = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("clawd/mail-room/log/markdown-failures")
                
                do {
                    try FileManager.default.createDirectory(at: debugDir, withIntermediateDirectories: true)
                    
                    let timestamp = ISO8601DateFormatter().string(from: Date())
                    let filename = "uid-\(uid)-\(timestamp).html"
                    let debugFile = debugDir.appendingPathComponent(filename)
                    
                    try htmlBody.write(to: debugFile, atomically: true, encoding: .utf8)
                    Self.logDiagnostic("Saved problematic HTML to \(debugFile.path)")
                } catch {
                    Self.logDiagnostic("ERROR failed to save debug HTML: \(String(describing: error))")
                }
            }
            
            return UnicodeAbuseSummary.sanitize(textBody ?? "", field: "Body")
        }
    }

    fileprivate static func fetchAndDecodePartData(
        using connection: IMAPNamedConnection,
        messageInfo: MessageInfo,
        part: MessagePart
    ) async throws -> Data {
        if let uid = messageInfo.uid {
            return try await connection.fetchPart(section: part.section, of: uid).decoded(for: part)
        }

        return try await connection.fetchPart(section: part.section, of: messageInfo.sequenceNumber).decoded(for: part)
    }

    /// Extracts Reply-To header value from normalized (lowercase) decoded header fields.
    fileprivate static func extractReplyTo(from additionalFields: [String: String]) -> String? {
        guard let value = additionalFields["reply-to"] else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Decodes and normalizes additional headers from IMAP into a lowercase-keyed dictionary.
    fileprivate static func decodeAdditionalHeaders(_ additionalFields: [String: String]?) -> [String: String] {
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
    fileprivate static func buildHookHeaders(
        additionalHeaders: [String: String],
        from: String,
        to: [String],
        replyTo: String?,
        subject: String,
        date: String
    ) -> [String: String] {
        var headers = filterNoiseHeaders(additionalHeaders)
        if !from.isEmpty { headers["from"] = from }
        if !to.isEmpty { headers["to"] = to.joined(separator: ", ") }
        if let replyTo, !replyTo.isEmpty { headers["reply-to"] = replyTo }
        if !subject.isEmpty { headers["subject"] = subject }
        if !date.isEmpty { headers["date"] = date }
        return headers
    }

    /// Filters out transport, routing, cryptographic, and ESP tracking headers
    internal static func filterNoiseHeaders(_ headers: [String: String]) -> [String: String] {
        let excludedPrefixes = [
            "received", "return-path", "delivered-to",           // Transport/routing
            "dkim-signature", "arc-",                             // Cryptographic
            "x-sg-", "x-ses-", "x-hs-", "x-sonic-", "x-ymail-",  // ESP tracking
            "cfbl-", "x-msg-", "x-pda-", "x-entity-",            // Metadata cruft
            "mime-version", "content-type", "content-transfer-encoding"  // Redundant (in body structure)
        ]

        return headers.filter { key, _ in
            !excludedPrefixes.contains { key.hasPrefix($0) }
        }
    }

    fileprivate static func decodeRecipientList(_ recipients: [String]) -> [String] {
        recipients
            .map(decodeHeaderValue)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    fileprivate static func normalizeHeaderKey(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    fileprivate static func decodeHeaderValue(_ value: String) -> String {
        let unfolded = unfoldHeaderValue(value)
        let decoded = unfolded.decodeMIMEHeader()
        return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Unfolds multiline header continuations into a single line before decoding.
    fileprivate static func unfoldHeaderValue(_ value: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\r?\\n[\\t ]+") else {
            return value
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(in: value, range: range, withTemplate: " ")
    }

    /// Fetches messages with UID >= minUID
    fileprivate func fetchMessagesSince(serverId: String, mailbox: String, minUID: Int) async throws -> [MessageHeader] {
        return try await withServer(serverId: serverId) { server in
            _ = try await server.selectMailbox(mailbox)
            
            let safeMinUID = max(1, minUID)
            // Fetch UID range as a single `UID FETCH <min>:*` (no expansion)
            let infos = try await server.fetchMessageInfos(uidRange: UID(safeMinUID)...)
            let headers: [MessageHeader] = infos.compactMap { info -> MessageHeader? in
                let uidInt = Int(info.uid?.value ?? 0)
                guard uidInt > 0 else { return nil }
                return MessageHeader(
                    uid: uidInt,
                    from: info.from ?? "Unknown",
                    subject: info.subject ?? "(No Subject)",
                    date: formatDate(info.date),
                    flags: MessageFlags(info.flags)
                )
            }
            return headers.sorted { $0.uid < $1.uid }
        }
    }

    fileprivate static func executeHookCommand(
        _ command: String,
        serverId: String,
        mailbox: String,
        message: HookMessagePayload
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

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

        Self.logDiagnostic("Executing hook command for \(serverId)/\(mailbox) uid=\(message.uid): \(command)")

        process.terminationHandler = { [serverId, mailbox, uid = message.uid] proc in
            let status = proc.terminationStatus
            let reason = proc.terminationReason

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

            if let stdoutText = String(data: stdoutData, encoding: .utf8) {
                let trimmed = stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    for line in trimmed.split(separator: "\n", omittingEmptySubsequences: true) {
                        let logLine = "Hook stdout for \(serverId)/\(mailbox) uid=\(uid): \(line)"
                        Self.logDiagnostic(logLine)
                    }
                }
            }

            if let stderrText = String(data: stderrData, encoding: .utf8) {
                let trimmed = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    for line in trimmed.split(separator: "\n", omittingEmptySubsequences: true) {
                        let logLine = "Hook stderr for \(serverId)/\(mailbox) uid=\(uid): \(line)"
                        Self.logDiagnostic(logLine)
                    }
                }
            }

            Self.logDiagnostic("Hook finished for \(serverId)/\(mailbox) uid=\(uid): status=\(status) reason=\(reason)")
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
            Self.logDiagnostic("ERROR failed to execute hook for \(serverId)/\(mailbox) uid=\(message.uid): \(String(describing: error))")
            try? stdinPipe.fileHandleForWriting.close()
        }
    }
}
