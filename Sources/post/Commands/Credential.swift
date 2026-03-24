import ArgumentParser
import Foundation
import PostServer

extension PostCLI {
    struct Credential: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manage IMAP credentials in the Keychain",
            subcommands: [Set.self, Delete.self, List.self]
        )

        struct Set: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "set",
                abstract: "Store IMAP credentials in the Keychain"
            )

            @Option(name: .long, help: "Server identifier")
            var server: String

            @Option(name: .long, help: "IMAP host")
            var host: String?

            @Option(name: .long, help: "IMAP port")
            var port: Int?

            @Option(name: .long, help: "IMAP username")
            var username: String?

            @Option(name: .long, help: "IMAP password")
            var password: String?

            func run() throws {
                #if canImport(Security)
                let config = try? PostConfiguration.load()
                if let config, config.server(withID: server) == nil {
                    throw PostConfigurationError.unknownServer(server)
                }

                let fallbackCredentials = config?.server(withID: server)?.credentials
                let resolvedHost = try host.resolvedRequiredValue(fallback: fallbackCredentials?.host, prompt: "Host")

                let resolvedPort = try port.resolvedPort(fallback: fallbackCredentials?.port, prompt: "Port", defaultValue: 993)

                let resolvedUsername = try username.resolvedRequiredValue(fallback: fallbackCredentials?.username, prompt: "Username")

                let resolvedPassword: String
                if let explicitPassword = password?.trimmingCharacters(in: .whitespacesAndNewlines), !explicitPassword.isEmpty {
                    resolvedPassword = explicitPassword
                } else if let fallbackPassword = fallbackCredentials?.password, !fallbackPassword.isEmpty {
                    resolvedPassword = fallbackPassword
                } else {
                    print("Password: ", terminator: "")
                    resolvedPassword = String.readPassword()
                }

                guard !resolvedPassword.isEmpty else {
                    print("Password cannot be empty.")
                    throw ExitCode.failure
                }

                let store = KeychainCredentialStore()
                try store.store(
                    id: server,
                    host: resolvedHost,
                    port: resolvedPort,
                    username: resolvedUsername,
                    password: resolvedPassword
                )
                print("Credential stored for server '\(server)' in the login keychain.")
                #else
                print("Keychain is not available on this platform.")
                throw ExitCode.failure
                #endif
            }
        }

        struct Delete: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "delete",
                abstract: "Remove IMAP credentials from the Keychain"
            )

            @Option(name: .long, help: "Server identifier")
            var server: String

            func run() throws {
                #if canImport(Security)
                let store = KeychainCredentialStore()
                try store.delete(label: server)
                print("Credential deleted.")
                #else
                print("Keychain is not available on this platform.")
                throw ExitCode.failure
                #endif
            }
        }

        struct List: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "list",
                abstract: "List stored IMAP credentials"
            )

            func run() throws {
                #if canImport(Security)
                let store = KeychainCredentialStore()
                let credentials = try store.list()

                if credentials.isEmpty {
                    print("No credentials stored.")
                    return
                }

                let idWidth = max("ID".count, credentials.map { $0.id.count }.max() ?? 0)
                let userWidth = max("Username".count, credentials.map { $0.username.count }.max() ?? 0)

                print("\("ID".padded(to: idWidth))  \("Username".padded(to: userWidth))  Host")
                print("\(String(repeating: "-", count: idWidth))  \(String(repeating: "-", count: userWidth))  \(String(repeating: "-", count: 4))")

                for cred in credentials {
                    print("\(cred.id.padded(to: idWidth))  \(cred.username.padded(to: userWidth))  \(cred.host):\(cred.port)")
                }
                #else
                print("Keychain is not available on this platform.")
                throw ExitCode.failure
                #endif
            }
        }

    }
}
