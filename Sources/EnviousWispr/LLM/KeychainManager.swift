import Foundation

/// Manages API key storage and retrieval using secure file-based storage.
///
/// Keys are stored in `~/.enviouswispr-keys/` with restrictive POSIX permissions:
/// - Directory: 0700 (owner-only access)
/// - Files: 0600 (owner read/write only)
///
/// This approach is used instead of the macOS Keychain because:
/// - The Data Protection Keychain (`kSecUseDataProtectionKeychain`) requires entitlements
///   that are unavailable to non-sandboxed, ad-hoc-signed apps built with SPM CLI tools
///   (fails with errSecMissingEntitlement / -34018).
/// - The legacy Keychain's partition list / cdhash-based ACLs cause password prompts on
///   every rebuild because each build produces a new cdhash.
/// - File-based storage with strict permissions is standard practice for non-sandboxed
///   macOS developer tools and provides adequate protection for API keys.
struct KeychainManager: Sendable {
    static let openAIKeyID = "openai-api-key"
    static let geminiKeyID = "gemini-api-key"

    // MARK: - Secure File Storage

    /// Directory where key files are stored.
    private var storageDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".enviouswispr-keys", isDirectory: true)
    }

    /// URL for a specific key file.
    private func fileURL(for key: String) -> URL {
        storageDirectory.appendingPathComponent(key)
    }

    /// Ensure the storage directory exists with restrictive permissions.
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
                throw KeyStoreError.storeFailed(-1)
            }
        }
    }

    /// Store a value securely to a file.
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
            throw KeyStoreError.storeFailed(-1)
        }
    }

    /// Retrieve a value from a file.
    func retrieve(key: String) throws -> String {
        let url = fileURL(for: key)

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw KeyStoreError.retrieveFailed(-1)
        }

        do {
            let data = try Data(contentsOf: url)
            guard let value = String(data: data, encoding: .utf8) else {
                throw KeyStoreError.retrieveFailed(-1)
            }
            return value
        } catch is KeyStoreError {
            throw KeyStoreError.retrieveFailed(-1)
        } catch {
            throw KeyStoreError.retrieveFailed(-1)
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
            throw KeyStoreError.deleteFailed(-1)
        }
    }
}

enum KeyStoreError: LocalizedError, Sendable {
    case storeFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .storeFailed(let s): return "Key store failed: \(s)"
        case .retrieveFailed(let s): return "Key retrieve failed: \(s)"
        case .deleteFailed(let s): return "Key delete failed: \(s)"
        }
    }
}
