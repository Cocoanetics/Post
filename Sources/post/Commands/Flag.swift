import ArgumentParser
import Foundation
import PostServer
import SwiftMail

extension PostCLI {
    struct FlagMessages: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "flag",
            abstract: "Add/remove flags or set Mail.app flag color on messages"
        )

        @Argument(help: "Message UID set (e.g. 1,2,5-9)")
        var uids: String

        @Option(name: .long, help: "Comma-separated flags to add")
        var add: String?

        @Option(name: .long, help: "Comma-separated flags to remove")
        var remove: String?

        @Option(name: .long, help: "Set Mail.app flag color (red, orange, yellow, green, blue, purple, gray)")
        var color: String?

        @ArgumentParser.Flag(name: .long, help: "Remove \\Flagged and all Mail.app color bits")
        var unflag: Bool = false

        @Option(name: .long, help: "Server identifier")
        var server: String?

        @Option(name: .long, help: "Mailbox name")
        var mailbox: String = "INBOX"

        @OptionGroup
        var globals: GlobalOptions

        private enum Operation {
            case add(String)
            case remove(String)
            case color(MailFlagColor)
            case unflag
        }

        private static let mailFlagColorBits: [SwiftMail.Flag] = [
            .custom("$MailFlagBit0"),
            .custom("$MailFlagBit1"),
            .custom("$MailFlagBit2")
        ]

        private static var supportedColorNames: String {
            MailFlagColor.allCases.map(\.rawValue).joined(separator: ", ")
        }

        private func normalized(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        private func parsedColor() throws -> MailFlagColor? {
            guard let colorValue = normalized(color) else { return nil }
            let normalizedColor = colorValue.lowercased()
            guard let color = MailFlagColor(rawValue: normalizedColor) else {
                throw ValidationError("Invalid --color '\(colorValue)'. Allowed values: \(Self.supportedColorNames).")
            }
            return color
        }

        private func resolvedOperation() throws -> Operation {
            let addValue = normalized(add)
            let removeValue = normalized(remove)
            let colorValue = try parsedColor()
            let selectedCount = [addValue != nil, removeValue != nil, colorValue != nil, unflag]
                .filter { $0 }
                .count

            guard selectedCount == 1 else {
                throw ValidationError("Exactly one of --add, --remove, --color, or --unflag is required.")
            }

            if let addValue {
                return .add(addValue)
            }

            if let removeValue {
                return .remove(removeValue)
            }

            if let colorValue {
                return .color(colorValue)
            }

            return .unflag
        }

        private func applyFlags(
            _ flags: [SwiftMail.Flag],
            operation: String,
            client: PostProxy,
            serverId: String
        ) async throws {
            guard !flags.isEmpty else { return }
            let joinedFlags = flags.map { $0.description }.joined(separator: ",")
            _ = try await client.flagMessages(
                serverId: serverId,
                uids: uids,
                flags: joinedFlags,
                operation: operation,
                mailbox: mailbox
            )
        }

        func validate() throws {
            _ = try resolvedOperation()
        }

        func run() async throws {
            let operation = try resolvedOperation()

            try await withClient { client in
                let serverId = try await resolveServerID(explicit: server, client: client)
                let result: String

                switch operation {
                case .add(let flags):
                    result = try await client.flagMessages(
                        serverId: serverId,
                        uids: uids,
                        flags: flags,
                        operation: "add",
                        mailbox: mailbox
                    )
                case .remove(let flags):
                    result = try await client.flagMessages(
                        serverId: serverId,
                        uids: uids,
                        flags: flags,
                        operation: "remove",
                        mailbox: mailbox
                    )
                case .color(let color):
                    try await applyFlags(
                        Self.mailFlagColorBits,
                        operation: "remove",
                        client: client,
                        serverId: serverId
                    )
                    try await applyFlags(
                        [.flagged],
                        operation: "add",
                        client: client,
                        serverId: serverId
                    )
                    try await applyFlags(
                        color.flagBits,
                        operation: "add",
                        client: client,
                        serverId: serverId
                    )
                    result = "Set Mail.app flag color to \(color.rawValue)."
                case .unflag:
                    try await applyFlags(
                        [.flagged],
                        operation: "remove",
                        client: client,
                        serverId: serverId
                    )
                    try await applyFlags(
                        Self.mailFlagColorBits,
                        operation: "remove",
                        client: client,
                        serverId: serverId
                    )
                    result = "Removed \\Flagged and Mail.app color bits."
                }

                if globals.json {
                    outputJSON(ResultMessage(result: result))
                    return
                }
                print(result)
            }
        }
    }
}
