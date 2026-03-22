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
            let serverId = try resolveServerID(from: server)

            // TODO: Implement once SwiftMail #132 (SMTP support) lands
            throw PostError.notImplemented(
                """
                The 'post send' command requires SMTP support in SwiftMail.
                
                Dependency: https://github.com/Cocoanetics/SwiftMail/issues/132
                
                Once SwiftMail #132 is merged, this command will:
                1. Auto-detect Drafts folder (\\Drafts flag or name matching)
                2. Fetch draft message (UID \(uid))
                3. Send via SMTP with updated Date and Message-Id headers
                4. Auto-detect Sent folder (\\Sent flag or name matching)
                5. APPEND to Sent with \\Seen flag
                6. Permanently EXPUNGE draft from Drafts
                
                Server configuration required:
                {
                  "servers": {
                    "\(serverId)": {
                      "smtp": {
                        "host": "mail.example.com",
                        "port": 587,
                        "useTLS": false  // STARTTLS
                      },
                      "allowSending": true  // Safety: must opt-in
                    }
                  }
                }
                """
            )
        }

        private func resolveServerID(from server: String?) throws -> String {
            if let server {
                return server
            }
            throw PostError.validationError("No server specified. Use --server <id>")
        }
    }
}
