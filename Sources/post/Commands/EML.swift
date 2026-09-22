import ArgumentParser
import Foundation
import PostServer
import SwiftMail

extension PostCLI {
    struct EML: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Parse a local .eml file and output body or parts")

        @Argument(help: "Path to the .eml file")
        var file: String

        @OptionGroup
        var options: LocalMessageFile.Options

        @OptionGroup
        var globals: GlobalOptions

        func run() async throws {
            let message = try LocalMessageFile.read(file, as: .eml)
            try await LocalMessageFile.run(message, options: options, json: globals.json)
        }
    }
}
