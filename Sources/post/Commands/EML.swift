import ArgumentParser
import Foundation
import PostServer
import SwiftMail

extension PostCLI {
    struct EML: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Parse a local .eml file and output body")

        enum BodyFormat: String, ExpressibleByArgument {
            case text, html, markdown
        }

        @Argument(help: "Path to the .eml file")
        var file: String

        @Option(name: .long, help: "Body format: text, html, or markdown (default: markdown)")
        var body: BodyFormat = .markdown

        @OptionGroup
        var globals: GlobalOptions

        private struct EMLOutput: Codable {
            let from: String
            let to: [String]
            let subject: String
            let date: String
            let body: String
        }

        func run() async throws {
            let fileURL = URL(fileURLWithPath: file)

            guard FileManager.default.fileExists(atPath: file) else {
                throw ValidationError("File not found: \(file)")
            }

            let emlData = try Data(contentsOf: fileURL)
            let message = try EMLParser.parse(emlData)

            // Convert to MessageDetail format
            let textBody = message.parts.first { $0.contentType.lowercased().hasPrefix("text/plain") }
                .flatMap { part -> String? in
                    guard let data = part.data else { return nil }
                    return String(data: data, encoding: .utf8)
                }

            let htmlBody = message.parts.first { $0.contentType.lowercased().hasPrefix("text/html") }
                .flatMap { part -> String? in
                    guard let data = part.data else { return nil }
                    return String(data: data, encoding: .utf8)
                }

            let detail = MessageDetail(
                uid: 0,
                from: message.from ?? "Unknown",
                to: message.to,
                subject: message.subject ?? "(No Subject)",
                date: ISO8601DateFormatter().string(from: message.date ?? Date()),
                textBody: textBody,
                htmlBody: htmlBody,
                attachments: [],
                additionalHeaders: [:]
            )

            // Format body according to option
            let formattedBody: String
            switch body {
            case .text:
                formattedBody = detail.textBody ?? ""
            case .html:
                formattedBody = detail.htmlBody ?? detail.textBody ?? ""
            case .markdown:
                formattedBody = try await detail.markdown()
            }

            if globals.json {
                let output = EMLOutput(
                    from: detail.from,
                    to: detail.to,
                    subject: detail.subject,
                    date: detail.date,
                    body: formattedBody
                )
                outputJSON([output])
            } else {
                print(formattedBody)
            }
        }
    }
}
