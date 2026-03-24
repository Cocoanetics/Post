import ArgumentParser
import Foundation
import PostServer

@main
struct PostCLI: AsyncParsableCommand {
    private static var apiKeyCommandVisible: Bool {
        guard let value = ProcessInfo.processInfo.environment["POST_API_KEY"] else {
            return true
        }

        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static let configuration = CommandConfiguration(
        commandName: "post",
        abstract: "Post CLI client",
        version: postVersion,
        subcommands: operationalSubcommands + (apiKeyCommandVisible ? configurationSubcommands : [])
    )

    private static let operationalSubcommands: [ParsableCommand.Type] = [
        Servers.self,
        List.self,
        Fetch.self,
        EML.self,
        Folders.self,
        Create.self,
        Status.self,
        Search.self,
        Move.self,
        Copy.self,
        FlagMessages.self,
        Trash.self,
        Archive.self,
        Junk.self,
        Expunge.self,
        Quota.self,
        Attachment.self,
        Draft.self,
        Send.self,
        PDF.self,
        Idle.self
    ]

    private static let configurationSubcommands: [ParsableCommand.Type] = [
        Credential.self,
        APIKey.self
    ]
}
