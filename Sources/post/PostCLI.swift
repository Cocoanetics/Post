import ArgumentParser
import Foundation
import PostServer
import SwiftMCP

@main
struct PostCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "post",
        abstract: "Post CLI client",
        subcommands: [Servers.self, List.self, Fetch.self, Folders.self, Search.self, Move.self, Trash.self, Archive.self, Junk.self, Attachment.self, Idle.self]
    )
}

extension PostCLI {
    struct Servers: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List configured IMAP servers")

        func run() async throws {
            try await withClient { client in
                let servers = try await client.listServers()
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

        func run() async throws {
            try await withClient { client in
                let serverId = try await resolveServerID(explicit: server, client: client)
                let messages = try await client.listMessages(serverId: serverId, mailbox: mailbox, limit: limit)
                printMessageHeaders(messages)
            }
        }
    }

    struct Fetch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Fetch a message by UID")

        @Argument(help: "Message UID")
        var uid: Int

        @Option(name: .long, help: "Server identifier")
        var server: String?

        @Option(name: .long, help: "Mailbox name")
        var mailbox: String = "INBOX"

        func run() async throws {
            try await withClient { client in
                let serverId = try await resolveServerID(explicit: server, client: client)
                let message = try await client.fetchMessage(serverId: serverId, uid: uid, mailbox: mailbox)
                printMessageDetail(message)
            }
        }
    }

    struct Folders: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List mailbox folders")

        @Option(name: .long, help: "Server identifier")
        var server: String?

        func run() async throws {
            try await withClient { client in
                let serverId = try await resolveServerID(explicit: server, client: client)
                let folders = try await client.listFolders(serverId: serverId)

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

        func run() async throws {
            try await withClient { client in
                let serverId = try await resolveServerID(explicit: server, client: client)
                let message = try await client.moveMessages(
                    serverId: serverId,
                    uids: uids,
                    targetMailbox: target,
                    mailbox: mailbox
                )
                print(message)
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

        func run() async throws {
            try await withClient { client in
                let serverId = try await resolveServerID(explicit: server, client: client)
                let result = try await client.trashMessages(serverId: serverId, uids: uids, mailbox: mailbox)
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

        func run() async throws {
            try await withClient { client in
                let serverId = try await resolveServerID(explicit: server, client: client)
                let result = try await client.archiveMessages(serverId: serverId, uids: uids, mailbox: mailbox)
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

        func run() async throws {
            try await withClient { client in
                let serverId = try await resolveServerID(explicit: server, client: client)
                let result = try await client.junkMessages(serverId: serverId, uids: uids, mailbox: mailbox)
                print(result)
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
        static let configuration = CommandConfiguration(abstract: "Watch for new messages (polls via MCP)")

        @Option(name: .long, help: "Server identifier")
        var server: String?

        @Option(name: .long, help: "Mailbox name")
        var mailbox: String = "INBOX"

        @Option(name: .long, help: "Poll interval in seconds")
        var interval: Int = 10

        @Option(name: .long, help: "Command to execute on new message (supports {uid}, {from}, {subject}, {date})")
        var exec: String?

        func run() async throws {
            try await withClient { client in
                let serverId = try await resolveServerID(explicit: server, client: client)
                print("Watching \(mailbox) on \(serverId) (poll every \(interval)s, Ctrl+C to stop)...")

                // Resolve command from flag or server config
                let servers = try await client.listServers()
                let configCommand = servers.first(where: { $0.id == serverId })?.command
                let activeCommand = exec ?? configCommand

                if let cmd = activeCommand {
                    print("Action: \(cmd)")
                }

                var knownUIDs: Set<Int> = []

                // Initial fetch to establish baseline
                let initial = try await client.listMessages(serverId: serverId, mailbox: mailbox, limit: 20)
                for msg in initial {
                    knownUIDs.insert(msg.uid)
                }
                print("Baseline: \(knownUIDs.count) messages")

                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)

                    let current = try await client.listMessages(serverId: serverId, mailbox: mailbox, limit: 20)
                    for msg in current {
                        if !knownUIDs.contains(msg.uid) {
                            knownUIDs.insert(msg.uid)
                            print("🔔 New: [\(msg.uid)] \(msg.date) - \(msg.from)")
                            print("   \(msg.subject)")

                            if let execCommand = activeCommand {
                                try await executeCommand(execCommand, message: msg)
                            }
                        }
                    }
                }
            }
        }

        private func executeCommand(_ command: String, message: MessageHeader) async throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            
            // Pass data via environment variables for safety
            var env = ProcessInfo.processInfo.environment
            env["POST_UID"] = String(message.uid)
            env["POST_FROM"] = message.from
            env["POST_SUBJECT"] = message.subject
            env["POST_DATE"] = message.date
            process.environment = env
            
            // Replace placeholders with environment variable references
            let safeCommand = command
                .replacingOccurrences(of: "{uid}", with: "$POST_UID")
                .replacingOccurrences(of: "{from}", with: "$POST_FROM")
                .replacingOccurrences(of: "{subject}", with: "$POST_SUBJECT")
                .replacingOccurrences(of: "{date}", with: "$POST_DATE")

            print("Executing: \(safeCommand)")
            
            process.arguments = ["-c", safeCommand]
            
            try process.run()
        }
    }
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
    let nameWidth = max("Name".count, servers.map { $0.name.count }.max() ?? 0)

    print("\(pad("ID", to: idWidth))  \(pad("Name", to: nameWidth))  Host")
    print("\(String(repeating: "-", count: idWidth))  \(String(repeating: "-", count: nameWidth))  \(String(repeating: "-", count: 4))")

    for server in servers {
        print("\(pad(server.id, to: idWidth))  \(pad(server.name, to: nameWidth))  \(server.host)")
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

    print("")
    if message.attachments.isEmpty {
        print("Attachments: none")
    } else {
        print("Attachments:")
        for attachment in message.attachments {
            print("- \(attachment.filename) (\(attachment.contentType))")
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
