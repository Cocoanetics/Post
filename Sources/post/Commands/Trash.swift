import ArgumentParser
import Foundation
import PostServer

extension PostCLI {
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
            try await PostProxy.withClient { client in
                let serverId = try await server.resolveServerID(using: client)
                let result = try await client.trashMessages(serverId: serverId, uids: uids, mailbox: mailbox)
                if globals.json {
                    ResultMessage(result: result).printAsJSON()
                    return
                }
                print(result)
            }
        }
    }
}
