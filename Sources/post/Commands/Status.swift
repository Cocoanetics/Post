import ArgumentParser
import Foundation
import PostServer

extension PostCLI {
    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get mailbox status")

        @Option(name: .long, help: "Server identifier")
        var server: String?

        @Option(name: .long, help: "Mailbox name")
        var mailbox: String = "INBOX"

        @OptionGroup
        var globals: GlobalOptions

        func run() async throws {
            try await PostProxy.withClient { client in
                let serverId = try await server.resolveServerID(using: client)
                let status = try await client.mailboxStatus(serverId: serverId, mailbox: mailbox)
                if globals.json {
                    status.printAsJSON()
                    return
                }
                status.printDetails()
            }
        }
    }
}
