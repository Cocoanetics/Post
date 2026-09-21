import ArgumentParser
import Foundation
import PostServer
import SwiftMail

extension PostCLI {
    struct EML: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Parse a local .eml file and output body")

        @Argument(help: "Path to the .eml file")
        var file: String

        @Option(name: .long, help: "Body format: text, html, or markdown (default: markdown)")
        var body: LocalMessageFile.BodyFormat = .markdown

        @OptionGroup
        var globals: GlobalOptions

        func run() async throws {
            let message = try LocalMessageFile.read(file, as: .eml)
            try await LocalMessageFile.emit(message, body: body, json: globals.json)
        }
    }
}
