import ArgumentParser
import Foundation
import PostServer
import SwiftMail

extension PostCLI {
    struct PDF: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "pdf",
            abstract: "Export message body as PDF"
        )

        @Argument(help: "Message UID(s) (comma-separated; ranges like 1-3 allowed)")
        var uid: String

        @Option(name: .long, help: "Server identifier")
        var server: String?

        @Option(name: .long, help: "Mailbox name")
        var mailbox: String = "INBOX"

        @Option(name: .long, help: "Output path — directory or filename ending in .pdf (default: current directory)")
        var output: String = "."

        func validate() throws {
            guard MessageIdentifierSet<UID>(string: uid) != nil else {
                throw ValidationError("Invalid UID set '\(uid)'. Use comma-separated values or ranges (e.g. 1-3,5,10-20).")
            }
        }

        func run() async throws {
            try await PostProxy.withClient { client in
                let serverId = try await server.resolveServerID(using: client)
                guard let uidSet = MessageIdentifierSet<UID>(string: uid) else {
                    throw ValidationError("Invalid UID set '\(uid)'.")
                }

                let outURL = URL(fileURLWithPath: output)
                let isExplicitFile = outURL.pathExtension.lowercased() == "pdf"
                let uidArray = uidSet.toArray()

                if isExplicitFile && uidArray.count > 1 {
                    throw ValidationError("Cannot use a filename for --output when exporting multiple UIDs. Use a directory instead.")
                }

                let outputDir = isExplicitFile ? outURL.deletingLastPathComponent() : outURL
                try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

                var foundCount = 0
                for messageUID in uidArray {
                    let uidValue = Int(messageUID.value)
                    let result = try await client.exportPDF(serverId: serverId, uid: uidValue, mailbox: mailbox)
                    guard let data = Data(base64Encoded: result.data) else {
                        "Error: Failed to decode PDF for UID \(uidValue)\n".writeToStandardError()
                        continue
                    }

                    let destination = isExplicitFile ? outURL : outputDir.appendingPathComponent(result.filename)
                    let displayName = destination.lastPathComponent
                    try data.write(to: destination)
                    print("Saved \(displayName) (\(result.size.formattedAsBytes())) to \(destination.path)")
                    foundCount += 1
                }

                if foundCount == 0 {
                    "Error: No PDFs exported\n".writeToStandardError()
                    throw ExitCode.failure
                }
            }
        }
    }
}
