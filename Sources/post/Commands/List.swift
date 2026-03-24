import ArgumentParser
import Foundation
import PostServer

extension PostCLI {
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
            try await PostProxy.withClient { client in
                let serverId = try await server.resolveServerID(using: client)
                let messages = try await client.listMessages(serverId: serverId, mailbox: mailbox, limit: limit)
                if globals.json {
                    messages.map(JSONMessageHeader.init).printAsJSON()
                    return
                }
                messages.printHeaders()
            }
        }
    }
}
