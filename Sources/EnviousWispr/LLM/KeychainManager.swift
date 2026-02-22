// TEMPORARY: File-based storage for dev convenience. Revert to Keychain before release.

import Foundation

/// Manages API key storage and retrieval via files in ~/.enviouswispr-keys/.
/// Original implementation used macOS Keychain (SecItem* APIs). This file-based
/// version avoids passcode prompts during development.
struct KeychainManager: Sendable {
    static let openAIKeyID = "openai-api-key"
    static let geminiKeyID = "gemini-api-key"

    private let service = "com.enviouswispr.api-keys"

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
                // Restrict permissions to owner only (0700)
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
            // Restrict file permissions to owner read/write only (0600)
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
            // Match Keychain behavior: not-found is not an error
            return
        }

        do {
            try fm.removeItem(at: url)
        } catch {
            throw KeychainError.deleteFailed(-1)
        }
    }
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
