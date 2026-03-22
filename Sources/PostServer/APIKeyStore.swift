#if canImport(Security)
import Foundation
import Security

private let apiKeychainLock = NSLock()

public final class APIKeyStore: Sendable {
    public static let itemService = "Post API Keys"
    public static let itemDescription = "Post API Key"

    public init() {}

    public struct APIKeyRecord: Codable, Sendable {
        public let token: String
        public let allowedServerIDs: [String]
        public let scopes: [String]?  // nil = ["imap"] for backward compatibility
        public let createdAt: Date
        
        /// Effective scopes with backward-compatible default
        public var effectiveScopes: Set<String> {
            if let scopes = scopes, !scopes.isEmpty {
                return Set(scopes)
            }
            return ["imap"]  // Default: IMAP-only (safe)
        }
    }

    public enum APIKeyStoreError: Error, LocalizedError {
        case operationFailed(OSStatus, String)
        case invalidToken
        case notFound(String)

        public var errorDescription: String? {
            switch self {
            case .operationFailed(let status, let operation):
                return "Keychain \(operation) failed with status \(status)."
            case .invalidToken:
                return "Token must be a valid UUID."
            case .notFound(let token):
                return "No API key found for token '\(token)'."
            }
        }
    }

    public func createKey(allowedServerIDs: [String], scopes: [String]? = nil) throws -> APIKeyRecord {
        let normalized = Self.normalizeServerIDs(allowedServerIDs)
        let normalizedScopes = scopes.map { Self.normalizeScopes($0) }
        let record = APIKeyRecord(
            token: UUID().uuidString.lowercased(),
            allowedServerIDs: normalized,
            scopes: normalizedScopes,
            createdAt: Date()
        )
        try store(record)
        return record
    }

    public func allowedServerIDs(forToken token: String) throws -> [String]? {
        try loadRecord(forToken: token)?.allowedServerIDs
    }

    public func listKeys() throws -> [APIKeyRecord] {
        apiKeychainLock.lock()
        defer { apiKeychainLock.unlock() }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.itemService,
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
            throw APIKeyStoreError.operationFailed(status, "list")
        }

        var records: [APIKeyRecord] = []
        records.reserveCapacity(items.count)

        for attrs in items {
            guard let token = attrs[kSecAttrAccount as String] as? String,
                  let record = try? loadRecordUnlocked(forToken: token) else {
                continue
            }
            records.append(record)
        }

        return records.sorted { $0.createdAt > $1.createdAt }
    }

    public func delete(token: String) throws {
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard UUID(uuidString: normalizedToken) != nil else {
            throw APIKeyStoreError.invalidToken
        }

        apiKeychainLock.lock()
        defer { apiKeychainLock.unlock() }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.itemService,
            kSecAttrAccount as String: normalizedToken,
            kSecAttrDescription as String: Self.itemDescription
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound {
            throw APIKeyStoreError.notFound(normalizedToken)
        }
        guard status == errSecSuccess else {
            throw APIKeyStoreError.operationFailed(status, "delete")
        }
    }

    private func store(_ record: APIKeyRecord) throws {
        apiKeychainLock.lock()
        defer { apiKeychainLock.unlock() }

        let token = record.token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard UUID(uuidString: token) != nil else {
            throw APIKeyStoreError.invalidToken
        }

        var storedRecord = record
        storedRecord = APIKeyRecord(
            token: token,
            allowedServerIDs: Self.normalizeServerIDs(record.allowedServerIDs),
            scopes: record.scopes.map { Self.normalizeScopes($0) },
            createdAt: record.createdAt
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(storedRecord)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.itemService,
            kSecAttrAccount as String: token,
            kSecAttrDescription as String: Self.itemDescription
        ]
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addAttrs = query
            addAttrs[kSecValueData as String] = data
            let addStatus = SecItemAdd(addAttrs as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw APIKeyStoreError.operationFailed(addStatus, "add")
            }
            return
        }

        guard updateStatus == errSecSuccess else {
            throw APIKeyStoreError.operationFailed(updateStatus, "update")
        }
    }

    private func loadRecord(forToken token: String) throws -> APIKeyRecord? {
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard UUID(uuidString: normalizedToken) != nil else {
            throw APIKeyStoreError.invalidToken
        }

        apiKeychainLock.lock()
        defer { apiKeychainLock.unlock() }

        return try loadRecordUnlocked(forToken: normalizedToken)
    }

    private func loadRecordUnlocked(forToken normalizedToken: String) throws -> APIKeyRecord? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.itemService,
            kSecAttrAccount as String: normalizedToken,
            kSecAttrDescription as String: Self.itemDescription,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw APIKeyStoreError.operationFailed(status, "find")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(APIKeyRecord.self, from: data)
    }

    private static func normalizeServerIDs(_ ids: [String]) -> [String] {
        Array(
            Set(
                ids
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        )
        .sorted()
    }
    
    private static func normalizeScopes(_ scopes: [String]) -> [String] {
        let validScopes = Set(["imap", "smtp"])
        return Array(
            Set(
                scopes
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { validScopes.contains($0) }
            )
        )
        .sorted()
    }
}
#else
import Foundation

public final class APIKeyStore: Sendable {
    public init() {}

    public struct APIKeyRecord: Codable, Sendable {
        public let token: String
        public let allowedServerIDs: [String]
        public let scopes: [String]?
        public let createdAt: Date
        
        public var effectiveScopes: Set<String> {
            if let scopes = scopes, !scopes.isEmpty {
                return Set(scopes)
            }
            return ["imap"]
        }
    }

    public enum APIKeyStoreError: Error, LocalizedError {
        case unsupportedPlatform

        public var errorDescription: String? {
            switch self {
            case .unsupportedPlatform:
                return "API key management requires Security.framework."
            }
        }
    }

    public func createKey(allowedServerIDs: [String], scopes: [String]? = nil) throws -> APIKeyRecord {
        _ = allowedServerIDs
        _ = scopes
        throw APIKeyStoreError.unsupportedPlatform
    }

    public func allowedServerIDs(forToken token: String) throws -> [String]? {
        _ = token
        throw APIKeyStoreError.unsupportedPlatform
    }

    public func listKeys() throws -> [APIKeyRecord] {
        throw APIKeyStoreError.unsupportedPlatform
    }

    public func delete(token: String) throws {
        _ = token
        throw APIKeyStoreError.unsupportedPlatform
    }
}
#endif
