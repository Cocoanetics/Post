import ArgumentParser
import Foundation
import PostServer

extension PostCLI {
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
            try await PostProxy.withClient { client in
                let serverId = try await server.resolveServerID(using: client)
                let result = try await client.copyMessages(
                    serverId: serverId,
                    uids: uids,
                    targetMailbox: target,
                    mailbox: mailbox
                )
                if globals.json {
                    ResultMessage(result: result).printAsJSON()
                    return
                }
                print(result)
            }
        }
    }
}
