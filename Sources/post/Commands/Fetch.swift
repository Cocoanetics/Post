import ArgumentParser
import Foundation
import PostServer
import SwiftMail

extension PostCLI {
    struct Fetch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Fetch message(s) by UID")

        enum BodyFormat: String, ExpressibleByArgument {
            case text, html, markdown
        }

        @Argument(help: "UID(s) of the message (comma-separated; ranges like 1-3 allowed)")
        var uid: String

        @ArgumentParser.Flag(help: "Download raw RFC 822 message as .eml file")
        var eml: Bool = false

        @Option(name: .long, help: "Body format: text, html, or markdown (default: markdown)")
        var body: BodyFormat = .markdown

        @Option(name: .long, help: "Output path — directory or filename for .eml or text files")
        var output: String?

        @Option(name: .long, help: "Server identifier")
        var server: String?

        @Option(name: .long, help: "Mailbox name")
        var mailbox: String = "INBOX"

        @OptionGroup
        var globals: GlobalOptions

        func validate() throws {
            if eml && output == nil {
                throw ValidationError("--eml requires --output")
            }

            guard MessageIdentifierSet<UID>(string: uid) != nil else {
                throw ValidationError("Invalid UID set '\(uid)'. Use comma-separated values or ranges (e.g. 1-3,5,10-20).")
            }
        }

        private func formatBody(_ message: MessageDetail) async throws -> String {
            switch body {
            case .text:
                return message.textBody ?? ""
            case .html:
                return message.htmlBody ?? message.textBody ?? ""
            case .markdown:
                return try await message.markdown()
            }
        }

        private func resolveHeaders(
            for message: MessageDetail,
            client: PostProxy,
            serverId: String
        ) async -> [String: String] {
            let decoded = message.additionalHeaders.decodedFetchHeaders()
            if !decoded.isEmpty {
                return filterHeaders(decoded)
            }

            guard let emlData = try? await client.downloadEml(serverId: serverId, uid: message.uid, mailbox: mailbox),
                  !emlData.isEmpty else {
                return decoded
            }

            return filterHeaders(emlData.parsedAdditionalHeaders().decodedFetchHeaders())
        }

        /// Filters out transport, routing, cryptographic, and ESP tracking headers
        private func filterHeaders(_ headers: [String: String]) -> [String: String] {
            let excludedPrefixes = [
                "received", "return-path", "delivered-to",           // Transport/routing
                "dkim-signature", "arc-",                             // Cryptographic
                "x-sg-", "x-ses-", "x-hs-", "x-sonic-", "x-ymail-",  // ESP tracking
                "cfbl-", "x-msg-", "x-pda-", "x-entity-",            // Metadata cruft
                "mime-version", "content-type", "content-transfer-encoding"  // Redundant (in body structure)
            ]

            return headers.filter { key, _ in
                !excludedPrefixes.contains { key.hasPrefix($0) }
            }
        }

        struct FormattedMessage: Codable {
            let uid: Int
            let mailbox: String
            let from: String
            let to: [String]
            let subject: String
            let date: String
            let body: String
            let headers: [String: String]
            let attachments: [AttachmentInfo]?

            init(detail: MessageDetail, mailbox: String, formattedBody: String, headers: [String: String]) {
                self.uid = detail.uid
                self.mailbox = mailbox
                self.from = detail.from
                self.to = detail.to
                self.subject = detail.subject
                self.date = detail.date
                self.body = formattedBody
                self.headers = headers
                self.attachments = detail.attachments.isEmpty ? nil : detail.attachments
            }
        }

        func run() async throws {
            try await PostProxy.withClient(quiet: globals.json) { client in
                let serverId = try await server.resolveServerID(using: client)
                guard let uidSet = MessageIdentifierSet<UID>(string: uid) else {
                    throw ValidationError("Invalid UID set '\(uid)'. Use comma-separated values or ranges (e.g. 1-3,5,10-20).")
                }

                let outURL: URL? = output.map { URL(fileURLWithPath: $0) }
                let isExplicitFile = outURL?.pathExtension.count ?? 0 > 0
                let uidArray = uidSet.toArray()

                if isExplicitFile && uidArray.count > 1 {
                    throw ValidationError("Cannot use a filename for --output when exporting multiple UIDs. Use a directory instead.")
                }

                let outputDir: URL?
                if let outURL, eml || !globals.json {
                    let dir = isExplicitFile ? outURL.deletingLastPathComponent() : outURL
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    outputDir = dir
                } else {
                    outputDir = nil
                }

                var jsonMessages: [FormattedMessage] = []
                var foundCount = 0
                for messageUID in uidArray {
                    let uidValue = Int(messageUID.value)

                    if eml {
                        guard let outputDir else {
                            throw ValidationError("--eml requires --output")
                        }

                        let emlData = try await client.downloadEml(serverId: serverId, uid: uidValue, mailbox: mailbox)
                        guard !emlData.isEmpty else { continue }
                        foundCount += 1
                        let destination: URL
                        if isExplicitFile, let outURL {
                            destination = outURL
                        } else {
                            destination = outputDir.appendingPathComponent("\(uidValue).eml")
                        }
                        let displayName = destination.lastPathComponent
                        try emlData.write(to: destination)
                        print("Saved \(displayName) to \(destination.path)")
                        continue
                    }

                    let messages = try await client.fetchMessage(
                        serverId: serverId,
                        uids: String(uidValue),
                        mailbox: mailbox
                    )

                    foundCount += messages.count

                    for message in messages {
                        let formattedBody = try await formatBody(message)

                        if globals.json {
                            let headers = await resolveHeaders(for: message, client: client, serverId: serverId)
                            jsonMessages.append(FormattedMessage(
                                detail: message,
                                mailbox: mailbox,
                                formattedBody: formattedBody,
                                headers: headers
                            ))
                        } else if let outputDir {
                            let filename = "\(message.uid).txt"
                            let destination = outputDir.appendingPathComponent(filename)
                            try formattedBody.write(to: destination, atomically: true, encoding: .utf8)
                            print("Saved \(filename) to \(destination.path)")
                        } else {
                            print("UID: \(message.uid)")
                            print("From: \(message.from)")
                            print("To: \(message.to.joined(separator: ", "))")
                            print("Subject: \(message.subject)")
                            print("Date: \(message.date)")
                            if !message.attachments.isEmpty {
                                print("Attachments: \(message.attachments.map(\.filename).joined(separator: ", "))")
                            }
                            print()
                            print(formattedBody)
                            print()
                        }
                    }
                }

                if foundCount == 0 {
                    "Error: No messages found\n".writeToStandardError()
                    throw ExitCode.failure
                }

                if globals.json, !eml {
                    jsonMessages.printAsJSON()
                }
            }
        }
    }
}
