import ArgumentParser
import Foundation
import PostServer
import SwiftMail

extension PostCLI {
    /// The `.msg` counterpart of ``PostCLI/EML``.
    ///
    /// Outlook writes `.msg` when a message is saved or dragged out to
    /// Explorer, and it is the default on Windows. It is not RFC 822, so it
    /// needs its own parser — but it produces the same `Message`, which is why
    /// this command is the `eml` one with a different file format.
    struct MSG: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "msg",
            abstract: "Parse a local Outlook .msg file and output body or parts"
        )

        @Argument(help: "Path to the .msg file")
        var file: String

        @OptionGroup
        var options: LocalMessageFile.Options

        @OptionGroup
        var globals: GlobalOptions

        func run() async throws {
            let message = try LocalMessageFile.read(file, as: .msg)
            try await LocalMessageFile.run(message, options: options, json: globals.json)
        }
    }
}
