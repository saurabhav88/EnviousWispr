import Foundation
import EnviousWisprCore

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
public struct KeychainManager: Sendable {
    public static let openAIKeyID = "openai-api-key"
    public static let geminiKeyID = "gemini-api-key"

    public init() {}

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
    /// Always enforces 0700 — even if the directory was loosened by a backup restore.
    private func ensureDirectoryExists() throws {
        let fm = FileManager.default
        let dir = storageDirectory
        do {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            try fm.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: dir.path
            )
        } catch {
            throw KeyStoreError.storeFailed(-1)
        }
    }

    /// Store a value securely to a file.
    /// Writes to a temp file at 0600 first, then renames — avoids a TOCTOU window
    /// where the file is briefly world-readable.
    public func store(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else { return }

        try ensureDirectoryExists()

        let url = fileURL(for: key)
        let tmpURL = storageDirectory.appendingPathComponent(".\(key).tmp")
        let fm = FileManager.default
        do {
            // Create temp file at 0600 from the start — no world-readable window
            let fd = Foundation.open(tmpURL.path, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
            guard fd >= 0 else { throw KeyStoreError.storeFailed(-1) }
            let fh = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            fh.write(data)
            try fh.close()
            // Replace target atomically (overwrite if exists)
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmpURL)
            } else {
                try fm.moveItem(at: tmpURL, to: url)
            }
        } catch {
            try? fm.removeItem(at: tmpURL)
            throw KeyStoreError.storeFailed(-1)
        }
    }

    /// Retrieve a value from a file.
    /// Re-enforces directory and file permissions on every read.
    public func retrieve(key: String) throws -> String {
        try ensureDirectoryExists()

        let url = fileURL(for: key)
        let fm = FileManager.default

        guard fm.fileExists(atPath: url.path) else {
            throw KeyStoreError.retrieveFailed(-1)
        }

        // Re-enforce file permissions on read
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

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
    public func delete(key: String) throws {
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

public enum KeyStoreError: LocalizedError, Sendable {
    case storeFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .storeFailed(let s): return "Key store failed: \(s)"
        case .retrieveFailed(let s): return "Key retrieve failed: \(s)"
        case .deleteFailed(let s): return "Key delete failed: \(s)"
        }
    }
}
