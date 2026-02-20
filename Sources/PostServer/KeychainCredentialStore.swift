#if canImport(Security)
import Foundation
import Security
import CommonCrypto

private let keychainLock = NSLock()

/// Manages IMAP credentials in a dedicated keychain file.
///
/// Uses `kSecClassInternetPassword` entries with native attributes
/// (server, port, account, protocol, label). The keychain file is
/// unlocked with a passphrase derived from the machine's hardware UUID.
public final class KeychainCredentialStore: Sendable {
    /// Default keychain file path next to config
    public static let defaultPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".post.keychain-db")

    private let path: String

    public init(path: URL = KeychainCredentialStore.defaultPath) {
        self.path = path.path
    }

    // MARK: - Public API

    /// Stores or updates IMAP credentials for a server ID.
    public func store(id: String, host: String, port: Int, username: String, password: String) throws {
        let keychain = try openOrCreate()
        let protocolAttr = protocolAttribute(for: port)

        // Delete existing if present, then re-add
        if try findItem(in: keychain, label: id) != nil {
            try deleteItem(in: keychain, label: id)
        }
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecUseKeychain as String: keychain,
            kSecAttrServer as String: host,
            kSecAttrPort as String: port,
            kSecAttrAccount as String: username,
            kSecAttrProtocol as String: protocolAttr,
            kSecAttrLabel as String: id,
            kSecAttrDescription as String: "Post IMAP",
            kSecValueData as String: password.data(using: .utf8) ?? Data()
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.operationFailed(status, "add")
        }
    }

    /// Retrieves a full credential by server ID label, including password.
    public func fullCredentials(forLabel id: String) throws -> (credential: FullCredential, password: String)? {
        let keychain = try openOrCreate()

        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecMatchSearchList as String: [keychain],
            kSecAttrLabel as String: id,
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
        let keychain = try openOrCreate()
        try deleteItem(in: keychain, label: label)
    }

    /// Lists all stored Post IMAP credentials (without passwords).
    public func list() throws -> [StoredCredential] {
        let keychain = try openOrCreate()

        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecMatchSearchList as String: [keychain],
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
        case hardwareUUIDUnavailable

        public var errorDescription: String? {
            switch self {
            case .operationFailed(let status, let operation):
                return "Keychain \(operation) failed with status \(status)."
            case .notFoundLabel(let label):
                return "No credential found for server ID '\(label)'."
            case .hardwareUUIDUnavailable:
                return "Could not determine hardware UUID for keychain passphrase."
            }
        }
    }

    // MARK: - Private

    private func openOrCreate() throws -> SecKeychain {
        keychainLock.lock()
        defer { keychainLock.unlock() }

        var keychain: SecKeychain?
        let passphrase = try derivePassphrase()
        let passData = passphrase.data(using: .utf8) ?? Data()

        // Try to open existing
        let openStatus = SecKeychainOpen(path, &keychain)
        if openStatus == errSecSuccess, let keychain {
            var keychainStatus: SecKeychainStatus = 0
            let statusResult = SecKeychainGetStatus(keychain, &keychainStatus)
            if statusResult == errSecSuccess {
                let unlockStatus: OSStatus = passData.withUnsafeBytes { buffer in
                    SecKeychainUnlock(keychain, UInt32(buffer.count), buffer.baseAddress, true)
                }
                if unlockStatus == errSecSuccess {
                    return keychain
                }
            }
        }

        // Create new keychain
        let createStatus: OSStatus = passData.withUnsafeBytes { buffer in
            SecKeychainCreate(path, UInt32(buffer.count), buffer.baseAddress, false, nil, &keychain)
        }
        guard createStatus == errSecSuccess, let keychain else {
            throw KeychainError.operationFailed(createStatus, "create")
        }

        return keychain
    }

    private func findItem(in keychain: SecKeychain, label: String) throws -> SecKeychainItem? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecMatchSearchList as String: [keychain],
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.operationFailed(status, "find")
        }

        return (result as! SecKeychainItem)
    }

    private func deleteItem(in keychain: SecKeychain, label: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecMatchSearchList as String: [keychain],
            kSecAttrLabel as String: label
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound {
            throw KeychainError.notFoundLabel(label)
        }
        guard status == errSecSuccess else {
            throw KeychainError.operationFailed(status, "delete")
        }
    }

    private func protocolAttribute(for port: Int) -> CFString {
        switch port {
        case 993: return kSecAttrProtocolIMAPS
        case 143: return kSecAttrProtocolIMAP
        default: return kSecAttrProtocolIMAPS
        }
    }

    /// Derives keychain passphrase from hardware UUID + salt.
    private func derivePassphrase() throws -> String {
        guard let uuid = hardwareUUID() else {
            throw KeychainError.hardwareUUIDUnavailable
        }
        let input = "post-keychain:\(uuid)"
        let data = Data(input.utf8)
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buffer in
            CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func hardwareUUID() -> String? {
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard platformExpert != 0 else { return nil }
        defer { IOObjectRelease(platformExpert) }

        let uuidCF = IORegistryEntryCreateCFProperty(
            platformExpert,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        )
        return uuidCF?.takeRetainedValue() as? String
    }
}
#endif
