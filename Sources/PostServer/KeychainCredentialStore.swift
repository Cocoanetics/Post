#if canImport(Security)
import Foundation
import Security

/// Recursive so `store` can call `delete` while holding the lock.
private let keychainLock = NSRecursiveLock()

/// Manages IMAP and SMTP credentials in the user's default Keychain (login keychain).
///
/// Uses `kSecClassInternetPassword` entries with native attributes
/// (server, port, account, protocol, label) and tags items with
/// `kSecAttrDescription = "Post IMAP"` or `"Post SMTP"` for filtering.
///
/// Note: Older versions of Post used a dedicated keychain file `~/.post.keychain-db`.
/// That approach requires deprecated `SecKeychain*` APIs and can lead to repeated
/// SecurityAgent prompts if the custom keychain is locked. The current implementation
/// stores secrets in the default keychain to avoid those issues.
public final class KeychainCredentialStore: Sendable {
    /// Credential type for keychain entries
    public enum CredentialType: String, Sendable {
        case imap = "Post IMAP"
        case smtp = "Post SMTP"
    }
    
    /// Human-readable tag used to filter Post IMAP credentials.
    public static let itemDescription = "Post IMAP"

    public init() {}

    // MARK: - Public API

    /// Stores or updates credentials for a server ID.
    public func store(id: String, host: String, port: Int, username: String, password: String, type: CredentialType = .imap) throws {
        keychainLock.lock()
        defer { keychainLock.unlock() }

        let protocolAttr = protocolAttribute(for: port, type: type)

        // Delete existing if present, then re-add
        try? delete(label: id, type: type)

        let attrs: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrPort as String: port,
            kSecAttrAccount as String: username,
            kSecAttrProtocol as String: protocolAttr,
            kSecAttrLabel as String: id,
            kSecAttrDescription as String: type.rawValue,
            kSecValueData as String: password.data(using: .utf8) ?? Data()
        ]

        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.operationFailed(status, "add")
        }
    }

    /// `kSecAttrComment` value marking an item whose data is OAuth JSON, not a password.
    public static let oauthComment = "oauth"

    /// Stores or replaces OAuth credentials for a server ID. The item's data is the
    /// credentials as JSON; the account is the email address.
    public func storeOAuth(id: String, host: String, port: Int, credentials: OAuthCredentials, type: CredentialType = .imap) throws {
        keychainLock.lock()
        defer { keychainLock.unlock() }

        try? delete(label: id, type: type)

        let attrs: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrPort as String: port,
            kSecAttrAccount as String: credentials.email,
            kSecAttrProtocol as String: protocolAttribute(for: port, type: type),
            kSecAttrLabel as String: id,
            kSecAttrDescription as String: type.rawValue,
            kSecAttrComment as String: Self.oauthComment,
            kSecValueData as String: try Self.encode(credentials)
        ]

        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.operationFailed(status, "add")
        }
    }

    /// Retrieves OAuth credentials by server ID label, or nil if the item is missing
    /// or holds a password.
    public func oauthCredentials(forLabel id: String, type: CredentialType = .imap) throws -> (credential: FullCredential, oauth: OAuthCredentials)? {
        keychainLock.lock()
        defer { keychainLock.unlock() }

        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrLabel as String: id,
            kSecAttrDescription as String: type.rawValue,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let attrs = result as? [String: Any] else {
            throw KeychainError.operationFailed(status, "find")
        }

        guard attrs[kSecAttrComment as String] as? String == Self.oauthComment,
              let host = attrs[kSecAttrServer as String] as? String,
              let username = attrs[kSecAttrAccount as String] as? String,
              let data = attrs[kSecValueData as String] as? Data else {
            return nil
        }

        let port = attrs[kSecAttrPort as String] as? Int ?? 993
        let oauth = try Self.decode(data)
        return (FullCredential(id: id, host: host, port: port, username: username), oauth)
    }

    /// Replaces the stored OAuth credentials in place, keeping the item's other attributes.
    public func updateOAuth(label: String, credentials: OAuthCredentials, type: CredentialType = .imap) throws {
        keychainLock.lock()
        defer { keychainLock.unlock() }

        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrLabel as String: label,
            kSecAttrDescription as String: type.rawValue,
            kSecAttrComment as String: Self.oauthComment
        ]
        let update: [String: Any] = [kSecValueData as String: try Self.encode(credentials)]

        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            throw KeychainError.notFoundLabel(label)
        }
        guard status == errSecSuccess else {
            throw KeychainError.operationFailed(status, "update")
        }
    }

    private static func encode(_ credentials: OAuthCredentials) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(credentials)
    }

    private static func decode(_ data: Data) throws -> OAuthCredentials {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(OAuthCredentials.self, from: data)
    }

    /// Retrieves a full credential by server ID label, including password.
    /// OAuth items are not returned here; use `oauthCredentials(forLabel:)`.
    public func fullCredentials(forLabel id: String, type: CredentialType = .imap) throws -> (credential: FullCredential, password: String)? {
        keychainLock.lock()
        defer { keychainLock.unlock() }

        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrLabel as String: id,
            kSecAttrDescription as String: type.rawValue,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let attrs = result as? [String: Any] else {
            throw KeychainError.operationFailed(status, "find")
        }

        guard attrs[kSecAttrComment as String] as? String != Self.oauthComment,
              let host = attrs[kSecAttrServer as String] as? String,
              let username = attrs[kSecAttrAccount as String] as? String,
              let passwordData = attrs[kSecValueData as String] as? Data,
              let password = String(data: passwordData, encoding: .utf8) else {
            return nil
        }

        let port = attrs[kSecAttrPort as String] as? Int ?? 993
        let credential = FullCredential(id: id, host: host, port: port, username: username)
        return (credential, password)
    }

    /// Deletes the credential for a server ID label.
    public func delete(label: String, type: CredentialType = .imap) throws {
        keychainLock.lock()
        defer { keychainLock.unlock() }

        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrLabel as String: label,
            kSecAttrDescription as String: type.rawValue
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound {
            throw KeychainError.notFoundLabel(label)
        }
        guard status == errSecSuccess else {
            throw KeychainError.operationFailed(status, "delete")
        }
    }

    /// Lists all stored Post credentials (without passwords).
    public func list(type: CredentialType = .imap) throws -> [StoredCredential] {
        keychainLock.lock()
        defer { keychainLock.unlock() }

        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrDescription as String: type.rawValue,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw KeychainError.operationFailed(status, "list")
        }

        return items.compactMap { attrs in
            guard let host = attrs[kSecAttrServer as String] as? String,
                  let username = attrs[kSecAttrAccount as String] as? String else {
                return nil
            }
            let label = attrs[kSecAttrLabel as String] as? String ?? ""
            let port = attrs[kSecAttrPort as String] as? Int ?? 993
            return StoredCredential(id: label, host: host, port: port, username: username)
        }
        .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    // MARK: - Types

    public struct FullCredential: Sendable {
        public let id: String
        public let host: String
        public let port: Int
        public let username: String
    }

    public struct StoredCredential: Sendable {
        public let id: String
        public let host: String
        public let port: Int
        public let username: String
    }

    public enum KeychainError: Error, LocalizedError {
        case operationFailed(OSStatus, String)
        case notFoundLabel(String)

        public var errorDescription: String? {
            switch self {
            case .operationFailed(let status, let operation):
                return "Keychain \(operation) failed with status \(status)."
            case .notFoundLabel(let label):
                return "No credential found for server ID '\(label)'."
            }
        }
    }

    // MARK: - Private

    private func protocolAttribute(for port: Int, type: CredentialType) -> CFString {
        switch type {
        case .imap:
            switch port {
            case 993: return kSecAttrProtocolIMAPS
            case 143: return kSecAttrProtocolIMAP
            default: return kSecAttrProtocolIMAPS
            }
        case .smtp:
            // Note: Security framework only defines kSecAttrProtocolSMTP (no SMTPS variant)
            return kSecAttrProtocolSMTP
        }
    }
}

/// Keeps OAuth tokens in the login keychain next to the account's other settings.
public struct KeychainOAuthCredentialStore: OAuthCredentialStoring {
    public init() {}

    public func load(_ key: OAuthCredentialKey) throws -> OAuthCredentials? {
        try KeychainCredentialStore().oauthCredentials(forLabel: key.label, type: key.service.credentialType)?.oauth
    }

    public func save(_ credentials: OAuthCredentials, for key: OAuthCredentialKey) throws {
        try KeychainCredentialStore().updateOAuth(label: key.label, credentials: credentials, type: key.service.credentialType)
    }
}

extension OAuthCredentialKey.Service {
    var credentialType: KeychainCredentialStore.CredentialType {
        switch self {
        case .imap: return .imap
        case .smtp: return .smtp
        }
    }
}
#endif
