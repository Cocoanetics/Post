import ArgumentParser
import Foundation
import PostServer

extension ConnectionSecurity: ExpressibleByArgument {}

/// Which login a Keychain credential is for.
enum CredentialProtocol: String, ExpressibleByArgument, CaseIterable {
    case imap
    case smtp

    var defaultPort: Int {
        switch self {
        case .imap: return 993
        case .smtp: return 465
        }
    }

    var label: String { rawValue.uppercased() }

    #if canImport(Security)
    var credentialType: KeychainCredentialStore.CredentialType {
        switch self {
        case .imap: return .imap
        case .smtp: return .smtp
        }
    }
    #endif

    /// Host, port, username and password already known from the config. SMTP prefers
    /// `smtp.credentials`, then the IMAP host and username; an IMAP port is never used for SMTP.
    static func fallbackCredentials(
        for credentialProtocol: CredentialProtocol,
        server: PostConfiguration.ServerConfiguration?
    ) -> (host: String?, port: Int?, username: String?, password: String?, security: ConnectionSecurity?) {
        let imap = server?.credentials
        switch credentialProtocol {
        case .imap:
            return (imap?.host, imap?.port, imap?.username, imap?.password, imap?.security)
        case .smtp:
            let smtp = server?.smtp?.credentials
            return (smtp?.host ?? imap?.host, smtp?.port, smtp?.username ?? imap?.username, smtp?.password, smtp?.security)
        }
    }
}

extension PostCLI {
    struct Credential: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manage IMAP and SMTP credentials in the Keychain",
            subcommands: [Set.self, AddOAuth.self, Delete.self, List.self]
        )

        struct Set: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "set",
                abstract: "Store IMAP or SMTP credentials in the Keychain",
                discussion: """
                    --protocol selects which login this is (default imap). For smtp the default port is 465. \
                    Missing values fall back to the server's smtp.credentials in ~/.post.json, then to its \
                    IMAP host and username. --security tls|starttls is stored with the credential; when \
                    omitted, the mode follows the port (IMAP 993 / SMTP 465 use TLS, otherwise STARTTLS).
                    """
            )

            @Option(name: .long, help: "Server identifier")
            var server: String

            @Option(name: .customLong("protocol"), help: "Which login this is: imap or smtp [default: imap]")
            var credentialProtocol: CredentialProtocol = .imap

            @Option(name: .long, help: "Connection mode: tls or starttls [default: from the port]")
            var security: ConnectionSecurity?

            @Option(name: .long, help: "IMAP or SMTP host")
            var host: String?

            @Option(name: .long, help: "IMAP or SMTP port [default: 993 for imap, 465 for smtp]")
            var port: Int?

            @Option(name: .long, help: "IMAP or SMTP username")
            var username: String?

            @Option(name: .long, help: "IMAP or SMTP password")
            var password: String?

            func run() throws {
                #if canImport(Security)
                let config = try? PostConfiguration.load()
                if let config, config.server(withID: server) == nil {
                    throw PostConfigurationError.unknownServer(server)
                }

                let fallbackCredentials = CredentialProtocol.fallbackCredentials(
                    for: credentialProtocol, server: config?.server(withID: server))
                let resolvedHost = try host.resolvedRequiredValue(fallback: fallbackCredentials.host, prompt: "Host")

                let resolvedPort = try port.resolvedPort(
                    fallback: fallbackCredentials.port, prompt: "Port", defaultValue: credentialProtocol.defaultPort)

                let resolvedUsername = try username.resolvedRequiredValue(fallback: fallbackCredentials.username, prompt: "Username")

                let resolvedPassword: String
                if let explicitPassword = password?.trimmingCharacters(in: .whitespacesAndNewlines), !explicitPassword.isEmpty {
                    resolvedPassword = explicitPassword
                } else if let fallbackPassword = fallbackCredentials.password, !fallbackPassword.isEmpty {
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
                    password: resolvedPassword,
                    type: credentialProtocol.credentialType,
                    security: security ?? fallbackCredentials.security
                )
                print("\(credentialProtocol.label) credential stored for server '\(server)' in the login keychain.")
                #else
                print("Keychain is not available on this platform.")
                throw ExitCode.failure
                #endif
            }
        }

        struct AddOAuth: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "add-oauth",
                abstract: "Authorize an account with OAuth 2.0 (XOAUTH2) and store the tokens in the Keychain",
                discussion: """
                    Without --refresh-token or --access-token, opens the provider's consent page in \
                    your browser and receives the result on a short-lived 127.0.0.1 listener (PKCE S256). \
                    You bring your own OAuth client ID: create a "Desktop app" client in the Google Cloud \
                    console. With --refresh-token (and/or --access-token) the tokens are imported as given.
                    """
            )

            @Option(name: .long, help: "Server identifier")
            var server: String

            @Option(name: .long, help: "Full mailbox address, used as the XOAUTH2 user")
            var email: String

            @Option(name: .long, help: "OAuth client ID (Google Cloud 'Desktop app' client)")
            var clientId: String?

            @Option(name: .long, help: "OAuth client secret, if the provider requires one")
            var clientSecret: String?

            @Option(name: .long, help: "IMAP host [default: imap.gmail.com]")
            var host: String?

            @Option(name: .long, help: "IMAP port [default: 993]")
            var port: Int?

            @Option(name: .long, help: "SMTP host used for sending with this token [default: smtp.gmail.com]")
            var smtpHost: String?

            @Option(name: .long, help: "SMTP port [default: 465]")
            var smtpPort: Int?

            @Option(name: .long, help: "OAuth scope [default: https://mail.google.com/]")
            var scope: String?

            @Option(name: .long, help: "Authorization endpoint [default: Google]")
            var authorizationEndpoint: String?

            @Option(name: .long, help: "Token endpoint [default: Google]")
            var tokenEndpoint: String?

            @Option(name: .long, help: "Import an existing refresh token instead of opening the browser")
            var refreshToken: String?

            @Option(name: .long, help: "Import an existing access token (expires within the hour; give --refresh-token too)")
            var accessToken: String?

            @Option(name: .long, help: "Seconds to wait for the browser authorization")
            var timeout: Int = 300

            @Flag(name: .long, help: "Print the authorization URL instead of opening the browser")
            var noBrowser = false

            func run() async throws {
                #if canImport(Security) && canImport(CryptoKit) && canImport(Network)
                let google = OAuthProvider.google
                func endpoint(_ value: String?, default fallback: URL) throws -> URL {
                    guard let value else { return fallback }
                    guard let url = URL(string: value), url.scheme == "https" else {
                        throw ValidationError("'\(value)' is not an https URL.")
                    }
                    return url
                }
                let provider = OAuthProvider(
                    authorizationEndpoint: try endpoint(authorizationEndpoint, default: google.authorizationEndpoint),
                    tokenEndpoint: try endpoint(tokenEndpoint, default: google.tokenEndpoint),
                    scope: scope ?? google.scope,
                    imapHost: host ?? google.imapHost,
                    imapPort: port ?? google.imapPort,
                    smtpHost: smtpHost ?? google.smtpHost,
                    smtpPort: smtpPort ?? google.smtpPort
                )

                let resolvedClientID = try clientId.resolvedRequiredValue(fallback: nil, prompt: "OAuth client ID")
                let secret = clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
                let credentials: OAuthCredentials

                let importedRefresh = refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines)
                let importedAccess = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines)
                if (importedRefresh?.isEmpty == false) || (importedAccess?.isEmpty == false) {
                    credentials = OAuthCredentials(
                        email: email,
                        clientID: resolvedClientID,
                        clientSecret: secret?.isEmpty == false ? secret : nil,
                        accessToken: importedAccess?.isEmpty == false ? importedAccess : nil,
                        refreshToken: importedRefresh?.isEmpty == false ? importedRefresh : nil,
                        expiresAt: nil,
                        tokenEndpoint: provider.tokenEndpoint,
                        smtpHost: provider.smtpHost,
                        smtpPort: provider.smtpPort
                    )
                } else {
                    let request = OAuthAuthorizationFlow.Request(
                        email: email,
                        clientID: resolvedClientID,
                        clientSecret: secret?.isEmpty == false ? secret : nil,
                        provider: provider,
                        smtpHost: provider.smtpHost,
                        smtpPort: provider.smtpPort,
                        timeout: TimeInterval(timeout)
                    )
                    let openBrowser = !noBrowser
                    credentials = try await OAuthAuthorizationFlow.authorize(request) { url in
                        print("Authorize Post in your browser:\n\n  \(url.absoluteString)\n")
                        if openBrowser {
                            let open = Process()
                            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                            open.arguments = [url.absoluteString]
                            try? open.run()
                        }
                        print("Waiting for the authorization to finish…")
                    }
                }

                let store = KeychainCredentialStore()
                try store.storeOAuth(id: server, host: provider.imapHost, port: provider.imapPort, credentials: credentials)
                print("OAuth credential stored for server '\(server)' in the login keychain.")
                #else
                print("OAuth is not available on this platform.")
                throw ExitCode.failure
                #endif
            }
        }

        struct Delete: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "delete",
                abstract: "Remove IMAP or SMTP credentials from the Keychain"
            )

            @Option(name: .long, help: "Server identifier")
            var server: String

            @Option(name: .customLong("protocol"), help: "Which login to remove: imap or smtp [default: imap]")
            var credentialProtocol: CredentialProtocol = .imap

            func run() throws {
                #if canImport(Security)
                let store = KeychainCredentialStore()
                try store.delete(label: server, type: credentialProtocol.credentialType)
                print("\(credentialProtocol.label) credential deleted.")
                #else
                print("Keychain is not available on this platform.")
                throw ExitCode.failure
                #endif
            }
        }

        struct List: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "list",
                abstract: "List stored IMAP and SMTP credentials"
            )

            @Option(name: .customLong("protocol"), help: "Only list this kind: imap or smtp [default: both]")
            var credentialProtocol: CredentialProtocol?

            func run() throws {
                #if canImport(Security)
                let store = KeychainCredentialStore()
                let protocols = credentialProtocol.map { [$0] } ?? CredentialProtocol.allCases
                let credentials = try protocols
                    .flatMap { try store.list(type: $0.credentialType) }
                    .sorted {
                        let order = $0.id.localizedCaseInsensitiveCompare($1.id)
                        return order == .orderedSame ? $0.type.rawValue < $1.type.rawValue : order == .orderedAscending
                    }

                if credentials.isEmpty {
                    print("No credentials stored.")
                    return
                }

                func protocolName(_ credential: KeychainCredentialStore.StoredCredential) -> String {
                    credential.type == .smtp ? "smtp" : "imap"
                }
                func securityName(_ credential: KeychainCredentialStore.StoredCredential) -> String {
                    credential.security?.rawValue ?? "auto"
                }

                let idWidth = max("ID".count, credentials.map { $0.id.count }.max() ?? 0)
                let protocolWidth = max("Protocol".count, credentials.map { protocolName($0).count }.max() ?? 0)
                let userWidth = max("Username".count, credentials.map { $0.username.count }.max() ?? 0)
                let securityWidth = max("Security".count, credentials.map { securityName($0).count }.max() ?? 0)

                print("\("ID".padded(to: idWidth))  \("Protocol".padded(to: protocolWidth))  \("Username".padded(to: userWidth))  \("Security".padded(to: securityWidth))  Host")
                print([idWidth, protocolWidth, userWidth, securityWidth, 4].map { String(repeating: "-", count: $0) }.joined(separator: "  "))

                for cred in credentials {
                    print("\(cred.id.padded(to: idWidth))  \(protocolName(cred).padded(to: protocolWidth))  \(cred.username.padded(to: userWidth))  \(securityName(cred).padded(to: securityWidth))  \(cred.host):\(cred.port)")
                }
                #else
                print("Keychain is not available on this platform.")
                throw ExitCode.failure
                #endif
            }
        }

    }
}
