import ArgumentParser
import Foundation
import PostServer

extension PostCLI {
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
}
