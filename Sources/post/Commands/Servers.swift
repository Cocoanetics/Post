import ArgumentParser
import Foundation
import PostServer

extension PostCLI {
    struct Servers: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List configured IMAP servers")

        @OptionGroup
        var globals: GlobalOptions

        func run() async throws {
            try await PostProxy.withClient { client in
                let servers = try await client.listServers()
                if globals.json {
                    servers.printAsJSON()
                    return
                }
                servers.printTable()
            }
        }
    }
}
