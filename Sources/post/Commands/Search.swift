import ArgumentParser
import Foundation
import PostServer

extension PostCLI {
    struct Search: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Search messages")

        @Option(name: .long, help: "Server identifier")
        var server: String?

        @Option(name: .long, help: "Mailbox name")
        var mailbox: String = "INBOX"

        @Option(name: .long, help: "Search in From field")
        var from: String?

        @Option(name: .long, help: "Search in Subject field")
        var subject: String?

        @Option(name: .long, help: "Search in text")
        var text: String?

        @Option(name: .long, help: "Search internal date since (ISO 8601)")
        var since: String?

        @Option(name: .long, help: "Search internal date before (ISO 8601)")
        var before: String?

        @Option(name: .long, help: "Search a header field, format: Name:Value")
        var header: String?

        @Option(name: .long, help: "Search by Message-Id header value")
        var messageId: String?

        @ArgumentParser.Flag(name: .long, help: "Only unseen (unread) messages")
        var unseen: Bool = false

        @ArgumentParser.Flag(name: .long, help: "Only seen (read) messages")
        var seen: Bool = false

        @ArgumentParser.Flag(name: .long, help: "Only flagged messages")
        var flagged: Bool = false

        @ArgumentParser.Flag(name: .long, help: "Only unflagged messages")
        var unflagged: Bool = false

        @Option(name: .long, help: "Maximum results to return (default: 100)")
        var limit: Int = 100

        @Option(name: .long, help: "Return UIDs greater than this (for pagination)")
        var afterUid: Int?

        @OptionGroup
        var globals: GlobalOptions

        func validate() throws {
            if unseen && seen {
                throw ValidationError("Only one of --unseen or --seen may be set.")
            }
            if flagged && unflagged {
                throw ValidationError("Only one of --flagged or --unflagged may be set.")
            }
            if header != nil && messageId != nil {
                throw ValidationError("Only one of --header or --message-id may be set.")
            }
            if let header {
                let parts = header.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                if parts.count != 2 || parts[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw ValidationError("--header must be in the form Name:Value (e.g. Message-Id:<...>)")
                }
            }
            if limit <= 0 {
                throw ValidationError("--limit must be greater than zero.")
            }
            if let afterUid, afterUid <= 0 {
                throw ValidationError("--after-uid must be greater than zero.")
            }
        }

        func run() async throws {
            try await withClient { client in
                let serverId = try await resolveServerID(explicit: server, client: client)
                var headerField: String?
                var headerValue: String?
                if let messageId {
                    headerField = "Message-Id"
                    headerValue = messageId
                } else if let header {
                    let parts = header.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    headerField = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                    headerValue = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                }

                let result = try await client.searchMessages(
                    serverId: serverId,
                    mailbox: mailbox,
                    from: from,
                    subject: subject,
                    text: text,
                    since: since,
                    before: before,
                    headerField: headerField,
                    headerValue: headerValue,
                    unseen: unseen ? true : nil,
                    seen: seen ? true : nil,
                    flagged: flagged ? true : nil,
                    unflagged: unflagged ? true : nil,
                    limit: limit,
                    afterUid: afterUid
                )
                if globals.json {
                    struct PageOutput: Codable {
                        let returned: Int
                        let hasMore: Bool
                        let next: NextOutput?
                    }
                    
                    struct NextOutput: Codable {
                        let afterUid: Int
                    }
                    
                    struct SearchJSONOutput: Codable {
                        let total: Int?
                        let messages: [JSONMessageHeader]
                        let page: PageOutput
                    }

                    let output = SearchJSONOutput(
                        total: result.total,
                        messages: result.messages.map(JSONMessageHeader.init),
                        page: PageOutput(
                            returned: result.page.returned,
                            hasMore: result.page.hasMore,
                            next: result.page.next.map { NextOutput(afterUid: $0.afterUid) }
                        )
                    )
                    outputJSON(output)
                    return
                }
                
                // Plain text output
                if let total = result.total {
                    print("Found \(total) message(s)")
                }
                print("Showing \(result.page.returned) result(s)")
                print()
                
                printMessageHeaders(result.messages)
                
                // Show next page hint
                if let next = result.page.next {
                    print()
                    var hintParts = [
                        "post search",
                        "--server \(serverId)",
                        "--mailbox \(mailbox)"
                    ]
                    
                    // Include active filters
                    if let from { hintParts.append("--from \(from)") }
                    if let subject { hintParts.append("--subject \(subject)") }
                    if let text { hintParts.append("--text \(text)") }
                    if let since { hintParts.append("--since \(since)") }
                    if let before { hintParts.append("--before \(before)") }
                    if let header { hintParts.append("--header \(header)") }
                    if let messageId { hintParts.append("--message-id \(messageId)") }
                    if unseen { hintParts.append("--unseen") }
                    if seen { hintParts.append("--seen") }
                    if flagged { hintParts.append("--flagged") }
                    if unflagged { hintParts.append("--unflagged") }
                    
                    hintParts.append("--limit \(limit)")
                    hintParts.append("--after-uid \(next.afterUid)")
                    
                    print("To see more: \(hintParts.joined(separator: " "))")
                }
            }
        }
    }
}
