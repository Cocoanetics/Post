import Foundation

/// OAuth 2.0 credentials for one mailbox, stored as JSON in the Keychain item's data.
///
/// The client ID (and secret, where the provider requires one) belong to the user:
/// Post ships no OAuth client of its own.
public struct OAuthCredentials: Codable, Sendable, Equatable {
    public var email: String
    public var clientID: String
    public var clientSecret: String?
    public var accessToken: String?
    public var refreshToken: String?
    public var expiresAt: Date?
    public var tokenEndpoint: URL
    /// SMTP server to use with this token, so one authorization covers sending too.
    public var smtpHost: String?
    public var smtpPort: Int?

    public init(
        email: String,
        clientID: String,
        clientSecret: String? = nil,
        accessToken: String? = nil,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        tokenEndpoint: URL,
        smtpHost: String? = nil,
        smtpPort: Int? = nil
    ) {
        self.email = email
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.tokenEndpoint = tokenEndpoint
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
    }

    /// Whether the access token can be used at `date` without refreshing first.
    ///
    /// A token without a known expiry is only trusted when there is no refresh token
    /// to fall back on; otherwise it is refreshed once and gets a real expiry.
    public func hasUsableAccessToken(at date: Date, leeway: TimeInterval) -> Bool {
        guard let accessToken, !accessToken.isEmpty else { return false }
        guard let expiresAt else { return refreshToken == nil }
        return expiresAt.timeIntervalSince(date) > leeway
    }
}

/// Identifies the Keychain item an OAuth token lives in.
public struct OAuthCredentialKey: Hashable, Sendable {
    public enum Service: String, Sendable {
        case imap
        case smtp
    }

    public let label: String
    public let service: Service

    public init(label: String, service: Service = .imap) {
        self.label = label
        self.service = service
    }
}

/// An OAuth 2.0 authorization server and the Gmail defaults to go with it.
public struct OAuthProvider: Sendable, Equatable {
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL
    public let scope: String
    public let imapHost: String
    public let imapPort: Int
    public let smtpHost: String
    public let smtpPort: Int

    public init(
        authorizationEndpoint: URL, tokenEndpoint: URL, scope: String,
        imapHost: String, imapPort: Int, smtpHost: String, smtpPort: Int
    ) {
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.scope = scope
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
    }

    /// Google, with the full-mailbox scope IMAP and SMTP require.
    public static let google = OAuthProvider(
        authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
        scope: "https://mail.google.com/",
        imapHost: "imap.gmail.com",
        imapPort: 993,
        smtpHost: "smtp.gmail.com",
        smtpPort: 465
    )
}

public enum OAuthError: Error, LocalizedError, Sendable, Equatable {
    /// The refresh token was revoked, expired or is missing: the user must authorize again.
    case reauthorizationRequired(label: String, reason: String)
    case tokenRequestFailed(String)
    case invalidTokenResponse
    case authorizationDenied(String)
    case callbackTimedOut
    case listenerFailed(String)
    case missingRefreshToken

    public var errorDescription: String? {
        switch self {
        case .reauthorizationRequired(let label, let reason):
            return "OAuth authorization for server '\(label)' is no longer valid (\(reason)). Run `post credential add-oauth --server \(label) …` again to authorize."
        case .tokenRequestFailed(let message):
            return "OAuth token request failed: \(message)"
        case .invalidTokenResponse:
            return "The OAuth token endpoint returned a response Post could not understand."
        case .authorizationDenied(let reason):
            return "Authorization was not granted: \(reason)"
        case .callbackTimedOut:
            return "Timed out waiting for the browser authorization to finish."
        case .listenerFailed(let message):
            return "Could not listen for the OAuth callback: \(message)"
        case .missingRefreshToken:
            return "The provider returned no refresh token, so Post could not keep the authorization alive. Revoke Post's access in your account settings and authorize again."
        }
    }
}
