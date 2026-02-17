import ArgumentParser
import Foundation
import PostServer
import SwiftMail
import SwiftMCP
@preconcurrency import AnyCodable

/// Prints IDLE event log notifications from the daemon to stdout.
private final class IdleEventLogger: MCPServerProxyLogNotificationHandling, @unchecked Sendable {
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func mcpServerProxy(_ proxy: MCPServerProxy, didReceiveLog message: LogMessage) async {
        let timestamp = dateFormatter.string(from: Date())

        // Try to extract structured data (server, mailbox, event)
        if let dict = message.data.value as? [String: Any],
           let server = dict["server"] as? String,
           let mailbox = dict["mailbox"] as? String,
           let event = dict["event"] as? String {
            fputs("[\(timestamp)] \(server)/\(mailbox): \(event)\n", stderr)
        } else if let text = message.data.value as? String {
            fputs("[\(timestamp)] \(text)\n", stderr)
        } else {
            fputs("[\(timestamp)] \(message.data)\n", stderr)
        }
    }
}

@main
struct PostCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "post",
        abstract: "Post CLI client",
        subcommands: [
            Servers.self,
            List.self,
            Fetch.self,
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
            Idle.self,
            Credential.self
        ]
    )
}

extension PostCLI {
    struct GlobalOptions: ParsableArguments {
        @ArgumentParser.Flag(name: .long, help: "Output as JSON")
        var json: Bool = false
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
                    outputJSON(messages)
                    return
                }
                printMessageHeaders(messages)
            }
        }
    }

    struct Fetch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Fetch message(s) by UID")

        @Argument(help: "UID(s) of the message (comma-separated; ranges like 1-3 allowed)")
        var uid: String

        @ArgumentParser.Flag(help: "Download raw RFC 822 message as .eml file")
        var eml: Bool = false

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

        func run() async throws {
            try await withClient { client in
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

                var jsonMessages: [MessageDetail] = []
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

                    if globals.json {
                        jsonMessages.append(contentsOf: messages)
                    } else if let outputDir {
                        for message in messages {
                            let filename = "\(message.uid).txt"
                            let destination = outputDir.appendingPathComponent(filename)
                            let textBody = message.textBody ?? ""
                            try textBody.write(to: destination, atomically: true, encoding: .utf8)
                            print("Saved \(filename) to \(destination.path)")
                        }
                    } else {
                        for message in messages {
                            printMessageDetail(message)
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

        @OptionGroup
        var globals: GlobalOptions

        func run() async throws {
            try await withClient { client in
                let serverId = try await resolveServerID(explicit: server, client: client)
                let messages = try await client.searchMessages(
                    serverId: serverId,
                    mailbox: mailbox,
                    from: from,
                    subject: subject,
                    text: text,
                    since: since,
                    before: before
                )
                if globals.json {
                    outputJSON(messages)
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
            abstract: "Add or remove flags on messages"
        )

        @Argument(help: "Message UID set (e.g. 1,2,5-9)")
        var uids: String

        @Option(name: .long, help: "Comma-separated flags to add")
        var add: String?

        @Option(name: .long, help: "Comma-separated flags to remove")
        var remove: String?

        @Option(name: .long, help: "Server identifier")
        var server: String?

        @Option(name: .long, help: "Mailbox name")
        var mailbox: String = "INBOX"

        @OptionGroup
        var globals: GlobalOptions

        func validate() throws {
            let addValue = add?.trimmingCharacters(in: .whitespacesAndNewlines)
            let removeValue = remove?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasAdd = !(addValue ?? "").isEmpty
            let hasRemove = !(removeValue ?? "").isEmpty

            if hasAdd == hasRemove {
                throw ValidationError("Exactly one of --add or --remove is required.")
            }
        }

        func run() async throws {
            let addValue = add?.trimmingCharacters(in: .whitespacesAndNewlines)
            let removeValue = remove?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasAdd = !(addValue ?? "").isEmpty
            let hasRemove = !(removeValue ?? "").isEmpty

            guard hasAdd != hasRemove else {
                throw ValidationError("Exactly one of --add or --remove is required.")
            }

            let operation = hasAdd ? "add" : "remove"
            let flags = hasAdd ? addValue! : removeValue!

            try await withClient { client in
                let serverId = try await resolveServerID(explicit: server, client: client)
                let result = try await client.flagMessages(
                    serverId: serverId,
                    uids: uids,
                    flags: flags,
                    operation: operation,
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

    struct Idle: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Watch IMAP IDLE events in real time (debug tool)")

        func run() async throws {
            let tcpConfig = MCPServerTcpConfig(serviceName: PostProxy.serverName)
            let proxy = MCPServerProxy(config: .tcp(config: tcpConfig))

            await proxy.setLogNotificationHandler(IdleEventLogger())

            try await proxy.connect()

            fputs("Connected to postd. Watching IDLE events (Ctrl+C to stop)...\n", stderr)

            let client = PostProxy(proxy: proxy)
            do {
                _ = try await client.watchIdleEvents()
            } catch is CancellationError {
                // Expected on Ctrl+C
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
                print("Credential stored for server '\(server)' in \(KeychainCredentialStore.defaultPath.lastPathComponent).")
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

private func withClient<T>(_ operation: (PostProxy) async throws -> T) async throws -> T {
    let tcpConfig = MCPServerTcpConfig(serviceName: PostProxy.serverName)
    let proxy = MCPServerProxy(config: .tcp(config: tcpConfig))
    try await proxy.connect()

    defer {
        Task {
            await proxy.disconnect()
        }
    }

    let client = PostProxy(proxy: proxy)
    return try await operation(client)
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
    guard let first = servers.first else {
        throw PostCLIError.noServersConfigured
    }

    return first.id
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
