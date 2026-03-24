import Foundation

extension ProcessInfo {
    func resolvedPostAPIToken() -> String? {
        if let token = CommandLine.arguments.value(forOptionNamed: "--token"), !token.isEmpty {
            return token
        }

        if let envToken = environment["POST_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envToken.isEmpty {
            return envToken
        }

        if let dotEnvToken = URL.currentDirectory.dotEnvValue(named: "POST_API_KEY"), !dotEnvToken.isEmpty {
            return dotEnvToken
        }

        return nil
    }
}
