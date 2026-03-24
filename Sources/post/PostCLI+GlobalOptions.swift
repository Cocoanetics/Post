import ArgumentParser

extension PostCLI {
    struct GlobalOptions: ParsableArguments {
        @ArgumentParser.Flag(name: .long, help: "Output as JSON")
        var json: Bool = false

        @Option(name: .long, help: "Scoped API key token (overrides POST_API_KEY and .env)")
        var token: String?
    }
}
