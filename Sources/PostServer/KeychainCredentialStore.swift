#if canImport(Security)
import Foundation
import Security

/// Manages IMAP credentials in a dedicated keychain file.
///
/// Uses `kSecClassInternetPassword` entries with native attributes
/// (server, port, account, protocol). The keychain file is unlocked
/// with a passphrase derived from the machine's hardware UUID.
public final class KeychainCredentialStore: Sendable {
    /// Default keychain file path next to config
    public static let defaultPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".post.keychain-db")

    private let path: String

    public init(path: URL = KeychainCredentialStore.defaultPath) {
        self.path = path.path
    }

    // MARK: - Public API

    /// Stores or updates IMAP credentials for a server.
    public func store(host: String, port: Int, username: String, password: String) throws {
        let keychain = try openOrCreate()
        defer { SecKeychainLock(keychain) }

        // Try to update existing
        if let existing = try? findItem(in: keychain, host: host, port: port, username: username) {
            let update: [String: Any] = [
                kSecValueData as String: password.data(using: .utf8)!
            ]
            let status = SecItemUpdate(
                [kSecMatchItemList as String: [existing]] as CFDictionary,
                update as CFDictionary
            )
            guard status == errSecSuccess else {
                throw KeychainError.operationFailed(status, "update")
            }
            return
        }

        // Create new
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecUseKeychain as String: keychain,
            kSecAttrServer as String: host,
            kSecAttrPort as String: port,
            kSecAttrAccount as String: username,
            kSecAttrProtocol as String: kSecAttrProtocolIMAPS,
            kSecAttrLabel as String: "\(username) (\(host))",
            kSecValueData as String: password.data(using: .utf8)!
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.operationFailed(status, "add")
        }
    }

    /// Retrieves the password for an IMAP server.
    public func password(host: String, port: Int, username: String) throws -> String? {
        let keychain = try openOrCreate()
        defer { SecKeychainLock(keychain) }

        guard let item = try? findItem(in: keychain, host: host, port: port, username: username) else {
            return nil
        }

        var passwordLength: UInt32 = 0
        var passwordData: UnsafeMutableRawPointer?
        let status = SecKeychainItemCopyContent(item, nil, nil, &passwordLength, &passwordData)
        guard status == errSecSuccess, let data = passwordData else {
            return nil
        }
        defer { SecKeychainItemFreeContent(nil, data) }

        return String(bytes: Data(bytes: data, count: Int(passwordLength)), encoding: .utf8)
    }

    /// Deletes the credential for an IMAP server.
    public func delete(host: String, port: Int, username: String) throws {
        let keychain = try openOrCreate()
        defer { SecKeychainLock(keychain) }

        guard let item = try? findItem(in: keychain, host: host, port: port, username: username) else {
            throw KeychainError.notFound(host: host, username: username)
        }

        let status = SecKeychainItemDelete(item)
        guard status == errSecSuccess else {
            throw KeychainError.operationFailed(status, "delete")
        }
    }

    /// Lists all stored credentials (without passwords).
    public func list() throws -> [StoredCredential] {
        let keychain = try openOrCreate()
        defer { SecKeychainLock(keychain) }

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
            let port = attrs[kSecAttrPort as String] as? Int ?? 993
            return StoredCredential(host: host, port: port, username: username)
        }
    }

    /// Returns whether the keychain file exists.
    public var exists: Bool {
        FileManager.default.fileExists(atPath: path)
    }

    // MARK: - Types

    public struct StoredCredential: Sendable {
        public let host: String
        public let port: Int
        public let username: String
    }

    public enum KeychainError: Error, LocalizedError {
        case operationFailed(OSStatus, String)
        case notFound(host: String, username: String)
        case hardwareUUIDUnavailable

        public var errorDescription: String? {
            switch self {
            case .operationFailed(let status, let operation):
                return "Keychain \(operation) failed with status \(status)."
            case .notFound(let host, let username):
                return "No credential found for \(username)@\(host)."
            case .hardwareUUIDUnavailable:
                return "Could not determine hardware UUID for keychain passphrase."
            }
        }
    }

    // MARK: - Private

    private func openOrCreate() throws -> SecKeychain {
        var keychain: SecKeychain?

        // Try to open existing
        let openStatus = SecKeychainOpen(path, &keychain)
        if openStatus == errSecSuccess, let keychain {
            // Check if it's actually valid by trying to get status
            var keychainStatus: SecKeychainStatus = 0
            let statusResult = SecKeychainGetStatus(keychain, &keychainStatus)
            if statusResult == errSecSuccess {
                // Exists, unlock it
                let passphrase = try derivePassphrase()
                let unlockStatus = SecKeychainUnlock(keychain, UInt32(passphrase.count), passphrase, true)
                if unlockStatus == errSecSuccess {
                    return keychain
                }
            }
        }

        // Create new keychain
        let passphrase = try derivePassphrase()
        let createStatus = SecKeychainCreate(path, UInt32(passphrase.count), passphrase, false, nil, &keychain)
        guard createStatus == errSecSuccess, let keychain else {
            throw KeychainError.operationFailed(createStatus, "create")
        }

        // Don't add to default search list (keep it private)
        return keychain
    }

    private func findItem(in keychain: SecKeychain, host: String, port: Int, username: String) throws -> SecKeychainItem? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecMatchSearchList as String: [keychain],
            kSecAttrServer as String: host,
            kSecAttrPort as String: port,
            kSecAttrAccount as String: username,
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

    /// Derives keychain passphrase from hardware UUID + salt.
    private func derivePassphrase() throws -> String {
        guard let uuid = hardwareUUID() else {
            throw KeychainError.hardwareUUIDUnavailable
        }
        // SHA256 of UUID + salt
        let input = "post-keychain:\(uuid)"
        let data = Data(input.utf8)
        // Use CommonCrypto-free approach via insecure hash
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

// CommonCrypto bridge
import CommonCrypto
#endif
