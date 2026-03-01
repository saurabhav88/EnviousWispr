import Foundation
@preconcurrency import Security

/// Manages API key storage and retrieval.
/// - DEBUG: File-based storage in ~/.enviouswispr-keys/ (avoids passcode prompts during development).
/// - RELEASE: macOS Keychain via SecItem* APIs with kSecAttrAccessibleWhenUnlockedThisDeviceOnly.
struct KeychainManager: Sendable {
    static let openAIKeyID = "openai-api-key"
    static let geminiKeyID = "gemini-api-key"

#if DEBUG
    // MARK: - File-based storage (DEBUG only)

    /// Directory where key files are stored.
    private var storageDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".enviouswispr-keys", isDirectory: true)
    }

    /// URL for a specific key file.
    private func fileURL(for key: String) -> URL {
        storageDirectory.appendingPathComponent(key)
    }

    /// Ensure the storage directory exists, creating it if necessary.
    private func ensureDirectoryExists() throws {
        let fm = FileManager.default
        let dir = storageDirectory
        if !fm.fileExists(atPath: dir.path) {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try fm.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: dir.path
                )
            } catch {
                throw KeychainError.storeFailed(-1)
            }
        }
    }

    /// Store a value to a file.
    func store(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else { return }

        try ensureDirectoryExists()

        let url = fileURL(for: key)
        do {
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            throw KeychainError.storeFailed(-1)
        }
    }

    /// Retrieve a value from a file.
    func retrieve(key: String) throws -> String {
        let url = fileURL(for: key)

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw KeychainError.retrieveFailed(-1)
        }

        do {
            let data = try Data(contentsOf: url)
            guard let value = String(data: data, encoding: .utf8) else {
                throw KeychainError.retrieveFailed(-1)
            }
            return value
        } catch is KeychainError {
            throw KeychainError.retrieveFailed(-1)
        } catch {
            throw KeychainError.retrieveFailed(-1)
        }
    }

    /// Delete a key file.
    func delete(key: String) throws {
        let url = fileURL(for: key)
        let fm = FileManager.default

        guard fm.fileExists(atPath: url.path) else {
            return
        }

        do {
            try fm.removeItem(at: url)
        } catch {
            throw KeychainError.deleteFailed(-1)
        }
    }

#else
    // MARK: - macOS Keychain (RELEASE)

    private let service = "com.enviouswispr.api-keys"

    /// Build the base query dictionary for a given key.
    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    /// Store a value in the Keychain. Updates if the key already exists.
    func store(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else { return }

        var query = baseQuery(for: key)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let addStatus = SecItemAdd(query as CFDictionary, nil)

        if addStatus == errSecDuplicateItem {
            let updateAttributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ]
            let updateStatus = SecItemUpdate(
                baseQuery(for: key) as CFDictionary,
                updateAttributes as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw KeychainError.storeFailed(updateStatus)
            }
        } else if addStatus != errSecSuccess {
            throw KeychainError.storeFailed(addStatus)
        }
    }

    /// Retrieve a value from the Keychain.
    func retrieve(key: String) throws -> String {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.retrieveFailed(status)
        }
        return value
    }

    /// Delete a value from the Keychain.
    func delete(key: String) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
#endif
}

enum KeychainError: LocalizedError, Sendable {
    case storeFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .storeFailed(let s): return "Keychain store failed: \(s)"
        case .retrieveFailed(let s): return "Keychain retrieve failed: \(s)"
        case .deleteFailed(let s): return "Keychain delete failed: \(s)"
        }
    }
}
