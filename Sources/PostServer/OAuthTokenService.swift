import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Persistence for OAuth credentials; the Keychain in production, memory in tests.
public protocol OAuthCredentialStoring: Sendable {
    func load(_ key: OAuthCredentialKey) throws -> OAuthCredentials?
    func save(_ credentials: OAuthCredentials, for key: OAuthCredentialKey) throws
}

/// Sends a token endpoint request; replaceable so tests never touch the network.
public typealias OAuthHTTPTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

/// A parsed token endpoint response (RFC 6749 §5.1).
struct OAuthTokenResponse: Equatable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: TimeInterval?
}

/// The JSON a token endpoint answers with; `expires_in` is a number, or a string from some providers.
private struct TokenPayload: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: TimeInterval?
    let error: String?
    let errorDescription: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case error
        case errorDescription = "error_description"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try? container.decode(String.self, forKey: .accessToken)
        refreshToken = try? container.decode(String.self, forKey: .refreshToken)
        error = try? container.decode(String.self, forKey: .error)
        errorDescription = try? container.decode(String.self, forKey: .errorDescription)
        if let number = try? container.decode(Double.self, forKey: .expiresIn) {
            expiresIn = number
        } else if let text = try? container.decode(String.self, forKey: .expiresIn) {
            expiresIn = Double(text)
        } else {
            expiresIn = nil
        }
    }
}

/// Used where there is no Keychain: every account then needs to be authorized again.
public struct UnavailableOAuthCredentialStore: OAuthCredentialStoring {
    public init() {}
    public func load(_ key: OAuthCredentialKey) throws -> OAuthCredentials? { nil }
    public func save(_ credentials: OAuthCredentials, for key: OAuthCredentialKey) throws {}
}

/// Talks to an OAuth token endpoint.
public enum OAuthTokenEndpoint {
    public static let defaultTransport: OAuthHTTPTransport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OAuthError.invalidTokenResponse }
        return (data, http)
    }

    /// Percent-encodes per application/x-www-form-urlencoded.
    static func formEncoded(_ fields: [(String, String)]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let body = fields.map { name, value in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(name)=\(encoded)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    static func request(endpoint: URL, fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formEncoded(fields)
        return request
    }

    /// Sends the request and returns the token response, or throws the endpoint's error.
    /// `invalid_grant` is surfaced as `.reauthorizationRequired` when a `label` is given.
    static func perform(
        _ request: URLRequest, transport: OAuthHTTPTransport, label: String?
    ) async throws -> OAuthTokenResponse {
        let (data, http) = try await transport(request)
        let object = try? JSONDecoder().decode(TokenPayload.self, from: data)

        guard (200..<300).contains(http.statusCode) else {
            let code = object?.error
            let description = object?.errorDescription
            let reason = [code, description].compactMap { $0 }.joined(separator: ": ")
            if code == "invalid_grant", let label {
                throw OAuthError.reauthorizationRequired(label: label, reason: reason)
            }
            throw OAuthError.tokenRequestFailed(reason.isEmpty ? "HTTP \(http.statusCode)" : reason)
        }

        guard let accessToken = object?.accessToken, !accessToken.isEmpty else {
            throw OAuthError.invalidTokenResponse
        }
        return OAuthTokenResponse(
            accessToken: accessToken,
            refreshToken: object?.refreshToken,
            expiresIn: object?.expiresIn
        )
    }
}

/// Hands out access tokens, refreshing them shortly before they expire.
///
/// Concurrent callers for the same credential share one refresh. A refreshed token
/// (and a rotated refresh token, if the provider sent one) is written back to the
/// store before it is returned.
public actor OAuthTokenService {
    /// How long before expiry a token counts as expired, so it outlives the request it is used for.
    public static let defaultLeeway: TimeInterval = 120

    private let store: any OAuthCredentialStoring
    private let transport: OAuthHTTPTransport
    private let now: @Sendable () -> Date
    private let leeway: TimeInterval
    private var refreshes: [OAuthCredentialKey: Task<OAuthCredentials, Error>] = [:]

    public init(
        store: any OAuthCredentialStoring,
        transport: @escaping OAuthHTTPTransport = OAuthTokenEndpoint.defaultTransport,
        now: @escaping @Sendable () -> Date = { Date() },
        leeway: TimeInterval = OAuthTokenService.defaultLeeway
    ) {
        self.store = store
        self.transport = transport
        self.now = now
        self.leeway = leeway
    }

    public func accessToken(for key: OAuthCredentialKey) async throws -> String {
        guard let credentials = try store.load(key) else {
            throw OAuthError.reauthorizationRequired(label: key.label, reason: "no stored OAuth credentials")
        }
        if credentials.hasUsableAccessToken(at: now(), leeway: leeway), let token = credentials.accessToken {
            return token
        }

        if let running = refreshes[key] {
            return try await Self.token(from: running)
        }
        let task = Task { try await self.refresh(key) }
        refreshes[key] = task
        defer { refreshes[key] = nil }
        return try await Self.token(from: task)
    }

    private static func token(from task: Task<OAuthCredentials, Error>) async throws -> String {
        let refreshed = try await task.value
        guard let token = refreshed.accessToken else { throw OAuthError.invalidTokenResponse }
        return token
    }

    private func refresh(_ key: OAuthCredentialKey) async throws -> OAuthCredentials {
        // Reload: another process (the CLI next to the daemon) may have refreshed already.
        guard var credentials = try store.load(key) else {
            throw OAuthError.reauthorizationRequired(label: key.label, reason: "no stored OAuth credentials")
        }
        if credentials.hasUsableAccessToken(at: now(), leeway: leeway) {
            return credentials
        }
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            throw OAuthError.reauthorizationRequired(label: key.label, reason: "no refresh token")
        }

        var fields = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", credentials.clientID)
        ]
        if let secret = credentials.clientSecret, !secret.isEmpty {
            fields.append(("client_secret", secret))
        }
        let request = OAuthTokenEndpoint.request(endpoint: credentials.tokenEndpoint, fields: fields)
        let response = try await OAuthTokenEndpoint.perform(request, transport: transport, label: key.label)

        credentials.accessToken = response.accessToken
        credentials.expiresAt = response.expiresIn.map { now().addingTimeInterval($0) }
        if let rotated = response.refreshToken, !rotated.isEmpty {
            credentials.refreshToken = rotated
        }
        try store.save(credentials, for: key)
        return credentials
    }
}
