import ArgumentParser
import Foundation
import PostServer

extension PostCLI {
    struct Folders: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List mailbox folders")

        @Option(name: .long, help: "Server identifier")
        var server: String?

        @OptionGroup
        var globals: GlobalOptions

        func run() async throws {
            try await PostProxy.withClient { client in
                let serverId = try await server.resolveServerID(using: client)
                let folders = try await client.listFolders(serverId: serverId)

                if globals.json {
                    folders.printAsJSON()
                    return
                }

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
}
