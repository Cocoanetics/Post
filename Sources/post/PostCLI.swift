import ArgumentParser
#if canImport(Darwin)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import PostServer
import SwiftMail
import SwiftMCP
import SwiftTextHTML

/// Prints a message to standard error
func printError(_ message: String) {
    if let data = message.data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

/// Prints IDLE event log notifications from the daemon to stdout.
final class IdleEventLogger: MCPServerProxyLogNotificationHandling, @unchecked Sendable {
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

        if let dict = data as? JSONDictionary,
           let server = dict["server"]?.stringValue,
           let mailbox = dict["mailbox"]?.stringValue,
           let event = dict["event"]?.stringValue {
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
        version: postVersion,
        subcommands: operationalSubcommands + (apiKeyCommandVisible ? configurationSubcommands : [])
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
}

/// Reads a password from stdin with echo disabled.
func readPassword() -> String {
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

func resolveRequiredValue(explicit: String?, fallback: String?, prompt: String) throws -> String {
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

func resolvePort(explicit: Int?, fallback: Int?, prompt: String, defaultValue: Int) throws -> Int {
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

struct ResultMessage: Codable {
    let result: String
}

struct JSONMessageHeader: Codable {
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

func setProxyLogLevel(_ level: LogLevel, on proxy: MCPServerProxy) async throws {
    let request = JSONRPCMessage.request(
        id: UUID().uuidString,
        method: "logging/setLevel",
        params: [
            "level": .string(level.rawValue)
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

func withClient<T>(quiet: Bool = false, _ operation: (PostProxy) async throws -> T) async throws -> T {
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

func resolveAPIToken() -> String? {
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

extension MCPServerProxy {
    func setAccessTokenMeta(_ token: String) {
        meta["accessToken"] = .string(token)
    }
}

func outputJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(value), let string = String(data: data, encoding: .utf8) else {
        print("Error: Failed to encode JSON.")
        return
    }
    print(string)
}

func resolveServerID(explicit: String?, client: PostProxy) async throws -> String {
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

func printServersTable(_ servers: [ServerInfo]) {
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

func printMessageHeaders(_ messages: [MessageHeader]) {
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

func printMailboxStatus(_ status: Mailbox.Status) {
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

func printQuotaInfo(_ quota: Quota) {
    for resource in quota.resources {
        if resource.resourceName.uppercased() == "STORAGE" {
            print("\(resource.resourceName): \(resource.usage) / \(resource.limit) KB")
        } else {
            print("\(resource.resourceName): \(resource.usage) / \(resource.limit)")
        }
    }
}

func decodeFetchHeaders(_ additionalHeaders: [String: String]?) -> [String: String] {
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

func parseAdditionalHeaders(from emlData: Data) -> [String: String] {
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
        #"(?m)^\|.*\|$"#,
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

func pad(_ value: String, to width: Int) -> String {
    guard value.count < width else {
        return value
    }
    return value + String(repeating: " ", count: width - value.count)
}

func formatBytes(_ bytes: Int) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    let kb = Double(bytes) / 1024
    if kb < 1024 { return String(format: "%.1f KB", kb) }
    let mb = kb / 1024
    return String(format: "%.1f MB", mb)
}
