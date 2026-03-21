import ArgumentParser
import Foundation
import PostServer

extension PostCLI {
    struct APIKey: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "api-key",
            abstract: "Manage scoped API keys for MCP access",
            subcommands: [Create.self, List.self, Delete.self]
        )

        struct Create: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Create an API key scoped to selected servers")

            @Option(name: .long, help: "Allowed server IDs (comma-separated)")
            var servers: String

            func run() throws {
                #if canImport(Security)
                let serverIDs = servers
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                guard !serverIDs.isEmpty else {
                    throw ValidationError("At least one server ID is required.")
                }

                let store = APIKeyStore()
                let record = try store.createKey(allowedServerIDs: serverIDs)
                print("API key: \(record.token)")
                print("Allowed servers: \(record.allowedServerIDs.joined(separator: ", "))")
                #else
                print("API key management is not available on this platform.")
                throw ExitCode.failure
                #endif
            }
        }

        struct List: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "List stored API keys")

            func run() throws {
                #if canImport(Security)
                let store = APIKeyStore()
                let keys = try store.listKeys()

                if keys.isEmpty {
                    print("No API keys stored.")
                    return
                }

                for key in keys {
                    let iso = ISO8601DateFormatter().string(from: key.createdAt)
                    let servers = key.allowedServerIDs.joined(separator: ", ")
                    print("\(key.token)  \(iso)  [\(servers)]")
                }
                #else
                print("API key management is not available on this platform.")
                throw ExitCode.failure
                #endif
            }
        }

        struct Delete: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Delete a stored API key")

            @Option(name: .long, help: "API key token (UUID)")
            var token: String

            func run() throws {
                #if canImport(Security)
                let store = APIKeyStore()
                try store.delete(token: token)
                print("API key deleted.")
                #else
                print("API key management is not available on this platform.")
                throw ExitCode.failure
                #endif
            }
        }
    }
}
