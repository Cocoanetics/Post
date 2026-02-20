#if canImport(Security)
import Foundation
import Security

private let keychainLock = NSLock()

/// Manages IMAP credentials in the user's default Keychain (login keychain).
///
/// Uses `kSecClassInternetPassword` entries with native attributes
/// (server, port, account, protocol, label) and tags items with
/// `kSecAttrDescription = "Post IMAP"` for filtering.
///
/// Note: Older versions of Post used a dedicated keychain file `~/.post.keychain-db`.
/// That approach requires deprecated `SecKeychain*` APIs and can lead to repeated
/// SecurityAgent prompts if the custom keychain is locked. The current implementation
/// stores secrets in the default keychain to avoid those issues.
public final class KeychainCredentialStore: Sendable {
    /// Human-readable tag used to filter Post credentials.
    public static let itemDescription = "Post IMAP"

    public init() {}

    // MARK: - Public API

    /// Stores or updates IMAP credentials for a server ID.
    public func store(id: String, host: String, port: Int, username: String, password: String) throws {
        keychainLock.lock()
        defer { keychainLock.unlock() }

        let protocolAttr = protocolAttribute(for: port)

        // Delete existing if present, then re-add
        try? delete(label: id)

        let attrs: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrPort as String: port,
            kSecAttrAccount as String: username,
            kSecAttrProtocol as String: protocolAttr,
            kSecAttrLabel as String: id,
            kSecAttrDescription as String: Self.itemDescription,
            kSecValueData as String: password.data(using: .utf8) ?? Data()
        ]

        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.operationFailed(status, "add")
        }
    }

    /// Retrieves a full credential by server ID label, including password.
    public func fullCredentials(forLabel id: String) throws -> (credential: FullCredential, password: String)? {
        keychainLock.lock()
        defer { keychainLock.unlock() }

        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrLabel as String: id,
            kSecAttrDescription as String: Self.itemDescription,
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

        guard let host = attrs[kSecAttrServer as String] as? String,
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
    public func delete(label: String) throws {
        keychainLock.lock()
        defer { keychainLock.unlock() }

        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrLabel as String: label,
            kSecAttrDescription as String: Self.itemDescription
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound {
            throw KeychainError.notFoundLabel(label)
        }
        guard status == errSecSuccess else {
            throw KeychainError.operationFailed(status, "delete")
        }
    }

    /// Lists all stored Post IMAP credentials (without passwords).
    public func list() throws -> [StoredCredential] {
        keychainLock.lock()
        defer { keychainLock.unlock() }

        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrDescription as String: Self.itemDescription,
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

    private func protocolAttribute(for port: Int) -> CFString {
        switch port {
        case 993: return kSecAttrProtocolIMAPS
        case 143: return kSecAttrProtocolIMAP
        default: return kSecAttrProtocolIMAPS
        }
    }
}
#endif
