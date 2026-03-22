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
            1. Fetches the draft from the Drafts mailbox
            2. Sends it via SMTP (preserving threading headers)
            3. Appends the sent message to the Sent folder
            4. Permanently deletes the draft (EXPUNGE, not trash)
            
            Safety: Sending must be explicitly enabled in server configuration
            with `allowSending: true`. Use --yes to skip confirmation prompt.
            
            Examples:
              # Send draft 1234 (with confirmation)
              post send 1234 --server drobnik
              
              # Send without confirmation
              post send 1234 --server drobnik --yes
              
              # Custom mailbox names
              post send 1234 --server drobnik --draft-mailbox Drafts --sent-mailbox Sent
            """
        )

        @Argument(help: "UID of draft message to send")
        var uid: Int

        @Option(name: .long, help: "Server identifier")
        var server: String?

        @Option(name: .long, help: "Draft mailbox name (default: Drafts)")
        var draftMailbox: String = "Drafts"

        @Option(name: .long, help: "Sent mailbox name (default: Sent)")
        var sentMailbox: String = "Sent"

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
                1. Fetch draft message (UID \(uid)) from \(draftMailbox)
                2. Send via SMTP with updated Date and Message-Id headers
                3. APPEND to \(sentMailbox) with \\Seen flag
                4. Permanently EXPUNGE draft from \(draftMailbox)
                
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
