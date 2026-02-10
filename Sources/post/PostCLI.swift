import ArgumentParser
import Foundation
import PostServer
import SwiftMCP

@main
struct PostCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "post",
        abstract: "Post CLI client",
        subcommands: [Servers.self, List.self, Fetch.self, Folders.self, Search.self, Move.self]
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
