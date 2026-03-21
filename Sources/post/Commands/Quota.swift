import ArgumentParser
import Foundation
import PostServer

extension PostCLI {
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
}
