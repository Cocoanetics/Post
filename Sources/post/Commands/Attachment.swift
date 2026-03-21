import ArgumentParser
import Foundation
import PostServer

extension PostCLI {
    struct Attachment: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Download attachment from a message")

        @Argument(help: "Message UID")
        var uid: Int

        @Option(name: .long, help: "Attachment filename (downloads first if omitted)")
        var filename: String?

        @Option(name: .long, help: "Server identifier")
        var server: String?

        @Option(name: .long, help: "Mailbox name")
        var mailbox: String = "INBOX"

        @Option(name: .long, help: "Output path — directory or filename (default: current directory)")
        var output: String = "."

        func run() async throws {
            try await withClient { client in
                let serverId = try await resolveServerID(explicit: server, client: client)
                let attachment = try await client.downloadAttachment(serverId: serverId, uid: uid, filename: filename, mailbox: mailbox)

                guard let data = Data(base64Encoded: attachment.data) else {
                    print("Error: Failed to decode attachment data.")
                    return
                }

                let outURL = URL(fileURLWithPath: output)
                let isExplicitFile = outURL.pathExtension.count > 0
                let outputDir = isExplicitFile ? outURL.deletingLastPathComponent() : outURL
                try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
                let destination = isExplicitFile ? outURL : outputDir.appendingPathComponent(attachment.filename)
                let displayName = destination.lastPathComponent
                try data.write(to: destination)
                print("Saved \(displayName) (\(attachment.contentType), \(formatBytes(attachment.size))) to \(destination.path)")
            }
        }
    }
}
