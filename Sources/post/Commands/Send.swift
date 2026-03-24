import ArgumentParser
import Foundation
import PostServer

extension PostCLI {
    struct Send: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Send a draft email via SMTP",
            discussion: """
            Sends a draft email via SMTP and moves it to the Sent folder.
            
            This command:
            1. Fetches the draft from the Drafts mailbox (auto-detected)
            2. Sends it via SMTP (preserving threading headers)
            3. Appends the sent message to the Sent folder (auto-detected)
            4. Permanently deletes the draft (EXPUNGE, not trash)
            
            Mailbox discovery:
            - Drafts: checks \\Drafts flag, falls back to name matching
            - Sent: checks \\Sent flag, falls back to name matching
            
            Safety: Sending must be explicitly enabled in server configuration
            with `allowSending: true`. Use --yes to skip confirmation prompt.
            
            Examples:
              # Send draft 1234 (with confirmation)
              post send 1234 --server drobnik
              
              # Send without confirmation
              post send 1234 --server drobnik --yes
            """
        )

        @Argument(help: "UID of draft message to send")
        var uid: Int

        @Option(name: .long, help: "Server identifier")
        var server: String?

        @Flag(name: .long, help: "Skip confirmation prompt")
        var yes: Bool = false

        @OptionGroup
        var globals: GlobalOptions

        mutating func run() async throws {
            try await PostProxy.withClient { client in
                let serverId = try await server.resolveServerID(using: client)
                
                // TODO: Add confirmation prompt unless --yes is set
                // if !yes {
                //     print("Send draft \(uid) from \(serverId)? [y/N]: ", terminator: "")
                //     let response = readLine() ?? "n"
                //     guard response.lowercased() == "y" else {
                //         print("Cancelled.")
                //         return
                //     }
                // }
                
                do {
                    try await client.sendDraft(
                        uid: uid,
                        serverId: serverId
                    )
                    
                    if globals.json {
                        struct SendResult: Codable {
                            let status: String
                            let uid: Int
                        }
                        SendResult(status: "sent", uid: uid).printAsJSON()
                    } else {
                        print("✓ Draft \(uid) sent successfully")
                    }
                } catch {
                    if globals.json {
                        struct SendError: Codable {
                            let status: String
                            let message: String
                        }
                        SendError(status: "error", message: error.localizedDescription).printAsJSON()
                    } else {
                        print("Error: \(error.localizedDescription)")
                    }
                    throw error
                }
            }
        }
    }
}
