import ArgumentParser
import Foundation
import PostServer

extension PostCLI {
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
}
