import Foundation
import OSLog
import Security

/// Manages customer API key storage for OpenAI and Gemini polish providers.
///
/// Debug builds keep the historical file-based store at `~/.enviouswispr-keys/`
/// so local rebuilds do not trigger Keychain ACL prompts. Release builds use
/// Apple Keychain generic-password items and lazily migrate the two customer
/// API-key files from the legacy directory.
public struct KeychainManager: Sendable {
  public static let openAIKeyID = "openai-api-key"
  public static let geminiKeyID = "gemini-api-key"

  private static let productionService = "com.enviouswispr.app.api-keys"
  private static let supportedReleaseKeys: Set<String> = [openAIKeyID, geminiKeyID]
  private static let logger = Logger(subsystem: "com.enviouswispr.app", category: "Keychain")

  private let backend: KeyStorageBackend
  private let legacyStore: any LegacyKeyFileStorage
  private let keychainStore: any KeychainItemStorage

  public init() {
    let legacyStore = FileLegacyKeyStore()
    if Self.usesLegacyFilesForDefaultRuntime {
      self.init(
        backend: .legacyFiles,
        legacyStore: legacyStore,
        keychainStore: SecurityKeychainItemStore()
      )
    } else {
      self.init(
        backend: .keychain(service: Self.productionService),
        legacyStore: legacyStore,
        keychainStore: SecurityKeychainItemStore()
      )
    }
  }

  init(
    backend: KeyStorageBackend,
    legacyStore: any LegacyKeyFileStorage = FileLegacyKeyStore(),
    keychainStore: any KeychainItemStorage = SecurityKeychainItemStore()
  ) {
    self.backend = backend
    self.legacyStore = legacyStore
    self.keychainStore = keychainStore
  }

  public func store(key: String, value: String) throws {
    switch backend {
    case .legacyFiles:
      try legacyStore.store(key: key, value: value)
    case .keychain(let service):
      try ensureReleaseKeySupported(key)
      let previousValue = try existingKeychainValue(service: service, key: key)
      try keychainStore.store(service: service, account: key, value: value)
      do {
        try legacyStore.delete(key: key)
        KeychainCleanupDiagnostics.recordSuccess(keyID: key)
      } catch let cleanupError {
        do {
          try restoreKeychainValue(previousValue, service: service, key: key)
        } catch let restoreError {
          Self.logger.error(
            "Keychain rollback failed after legacy-file cleanup error account=\(key, privacy: .public) cleanup=\(String(describing: cleanupError), privacy: .public) rollback=\(String(describing: restoreError), privacy: .public)"
          )
          throw KeyStoreError.rollbackFailed(
            cleanup: cleanupError, rollback: restoreError)
        }
        // Rollback succeeded; surface the original cleanup failure so the
        // caller knows the legacy file is still on disk. Keychain is restored
        // to its previous state.
        throw cleanupError
      }
    }
  }

  public func retrieve(key: String) throws -> String {
    switch backend {
    case .legacyFiles:
      return try legacyStore.retrieve(key: key)
    case .keychain(let service):
      try ensureReleaseKeySupported(key)
      do {
        let value = try keychainStore.retrieve(service: service, account: key)
        deleteLegacyFileOrLog(key: key)
        return value
      } catch KeyStoreError.retrieveFailed(let status) where status == errSecItemNotFound {
        return try retrieveLegacyAndMigrate(key: key, service: service)
      } catch {
        throw error
      }
    }
  }

  public func delete(key: String) throws {
    switch backend {
    case .legacyFiles:
      try legacyStore.delete(key: key)
    case .keychain(let service):
      try ensureReleaseKeySupported(key)
      try legacyStore.delete(key: key)
      KeychainCleanupDiagnostics.recordSuccess(keyID: key)
      try keychainStore.delete(service: service, account: key)
    }
  }

  private func retrieveLegacyAndMigrate(key: String, service: String) throws -> String {
    let legacyValue = try legacyStore.retrieve(key: key)

    do {
      try keychainStore.store(service: service, account: key, value: legacyValue)
    } catch {
      // Plan §3 step 6: return the legacy value so LLM polish keeps working
      // this session; the legacy file stays in place so the next retrieve
      // retries migration. The failure MUST be visible — otherwise release
      // UAT cannot detect a Keychain write that silently never lands.
      Self.logger.error(
        "Keychain migration write failed; returning legacy value and preserving legacy file for retry account=\(key, privacy: .public) error=\(String(describing: error), privacy: .public)"
      )
      return legacyValue
    }

    deleteLegacyFileOrLog(key: key)
    return legacyValue
  }

  /// Best-effort legacy-file cleanup AFTER a successful Keychain write.
  /// Failure here is logged at ERROR level (not warning) because the user-
  /// visible polish path keeps working from the Keychain value, so without a
  /// loud signal a stale plaintext file can sit on disk indefinitely — the
  /// exact failure mode the migration was meant to prevent. The next retrieve
  /// retries cleanup; persistent failure is a UAT/support escalation.
  ///
  /// Surfacing this caller-visibly (banner in Settings, diagnostics flag) is
  /// tracked separately; see the follow-up referenced in the plan.
  private func deleteLegacyFileOrLog(key: String) {
    do {
      try legacyStore.delete(key: key)
      KeychainCleanupDiagnostics.recordSuccess(keyID: key)
    } catch {
      Self.logger.error(
        "Legacy plaintext API key file remained on disk after Keychain migration; user-visible polish is unaffected but the security goal is not met. Will retry on next retrieve. account=\(key, privacy: .public) error=\(String(describing: error), privacy: .public)"
      )
      KeychainCleanupDiagnostics.recordFailure(keyID: key, error: error)
    }
  }

  private func existingKeychainValue(service: String, key: String) throws -> String? {
    do {
      return try keychainStore.retrieve(service: service, account: key)
    } catch KeyStoreError.retrieveFailed(let status) where status == errSecItemNotFound {
      return nil
    } catch {
      throw error
    }
  }

  private func restoreKeychainValue(_ value: String?, service: String, key: String) throws {
    if let value {
      try keychainStore.store(service: service, account: key, value: value)
    } else {
      try keychainStore.delete(service: service, account: key)
    }
  }

  private func ensureReleaseKeySupported(_ key: String) throws {
    guard Self.supportedReleaseKeys.contains(key) else {
      throw KeyStoreError.unsupportedKey(key)
    }
  }

  /// Production-bundle allowlist for the Apple Keychain backend.
  /// Anything not in this set — DEBUG, the `.dev` bundle, unknown / mis-stamped
  /// release builds — falls back to the file backend. Failing closed avoids
  /// a UAT or beta build silently touching the production Keychain service.
  private static let productionKeychainBundleIDs: Set<String> = [
    "com.enviouswispr.app"
  ]

  private static var usesLegacyFilesForDefaultRuntime: Bool {
    #if DEBUG
      return true
    #else
      guard let bundleID = Bundle.main.bundleIdentifier else { return true }
      return !productionKeychainBundleIDs.contains(bundleID)
    #endif
  }
}

enum KeyStorageBackend: Sendable {
  case legacyFiles
  case keychain(service: String)
}

/// Persistent diagnostics for the legacy-plaintext-cleanup step of the API-key
/// migration. After a successful Keychain write, if the legacy plaintext file
/// cannot be deleted, the user-visible polish path keeps working from the new
/// Keychain value — but the security goal is not met. The unified-log error
/// line is easy to miss, so we also persist a marker per key that the AI Polish
/// settings view reads to surface a non-blocking warning. See #725.
///
/// Storage is `UserDefaults.standard` — small, simple, no new actors needed.
/// Keys are namespaced with the `kcCleanupFail.` prefix so they do not collide
/// with `SettingsManager` keys (which use unprefixed names).
public enum KeychainCleanupDiagnostics {
  private static let dateKeyPrefix = "kcCleanupFail.date."
  private static let summaryKeyPrefix = "kcCleanupFail.summary."

  /// Snapshot of a single cleanup-failure record.
  public struct FailureRecord: Sendable, Equatable {
    public let keyID: String
    public let date: Date
    public let summary: String

    public init(keyID: String, date: Date, summary: String) {
      self.keyID = keyID
      self.date = date
      self.summary = summary
    }
  }

  /// Returns the most recent unresolved cleanup failure across all supported
  /// API-key IDs, or nil if every key cleaned up successfully or was never
  /// migrated. The settings banner uses this as the single read.
  public static func latestFailure(
    defaults: UserDefaults = .standard,
    keyIDs: [String] = [KeychainManager.openAIKeyID, KeychainManager.geminiKeyID]
  ) -> FailureRecord? {
    var latest: FailureRecord?
    for keyID in keyIDs {
      guard let date = defaults.object(forKey: dateKeyPrefix + keyID) as? Date else { continue }
      let summary = defaults.string(forKey: summaryKeyPrefix + keyID) ?? "Unknown error"
      let record = FailureRecord(keyID: keyID, date: date, summary: summary)
      if let existing = latest, existing.date >= date { continue }
      latest = record
    }
    return latest
  }

  /// Records a cleanup failure for `keyID`. Truncates the error description
  /// to bound UserDefaults growth even for pathological error strings.
  static func recordFailure(
    keyID: String,
    error: any Error,
    now: Date = Date(),
    defaults: UserDefaults = .standard
  ) {
    let summary = String(String(describing: error).prefix(240))
    defaults.set(now, forKey: dateKeyPrefix + keyID)
    defaults.set(summary, forKey: summaryKeyPrefix + keyID)
  }

  /// Records that cleanup succeeded for `keyID` — clears any prior failure
  /// marker so the banner does not stick after a successful retry. Idempotent.
  static func recordSuccess(
    keyID: String,
    defaults: UserDefaults = .standard
  ) {
    defaults.removeObject(forKey: dateKeyPrefix + keyID)
    defaults.removeObject(forKey: summaryKeyPrefix + keyID)
  }
}

protocol LegacyKeyFileStorage: Sendable {
  func store(key: String, value: String) throws
  func retrieve(key: String) throws -> String
  func delete(key: String) throws
}

protocol KeychainItemStorage: Sendable {
  func store(service: String, account: String, value: String) throws
  func retrieve(service: String, account: String) throws -> String
  func delete(service: String, account: String) throws
}

struct FileLegacyKeyStore: LegacyKeyFileStorage {
  private let storageDirectory: URL

  init(
    storageDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".enviouswispr-keys", isDirectory: true)
  ) {
    self.storageDirectory = storageDirectory
  }

  func store(key: String, value: String) throws {
    guard let data = value.data(using: .utf8) else {
      throw KeyStoreError.storeFailed(-1)
    }

    try ensureDirectoryExists()

    let url = fileURL(for: key)
    let tmpURL = storageDirectory.appendingPathComponent(".\(key).tmp")
    let fm = FileManager.default
    do {
      let fd = Foundation.open(tmpURL.path, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
      guard fd >= 0 else { throw KeyStoreError.storeFailed(-1) }
      let fh = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      fh.write(data)
      try fh.close()
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

  func retrieve(key: String) throws -> String {
    try ensureDirectoryExists()

    let url = fileURL(for: key)
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else {
      throw KeyStoreError.retrieveFailed(-1)
    }

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

  private func fileURL(for key: String) -> URL {
    storageDirectory.appendingPathComponent(key)
  }

  private func ensureDirectoryExists() throws {
    let fm = FileManager.default
    do {
      if !fm.fileExists(atPath: storageDirectory.path) {
        try fm.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
      }
      try fm.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: storageDirectory.path
      )
    } catch {
      throw KeyStoreError.storeFailed(-1)
    }
  }
}

struct SecurityKeychainItemStore: KeychainItemStorage {
  func store(service: String, account: String, value: String) throws {
    guard let data = value.data(using: .utf8) else {
      throw KeyStoreError.storeFailed(-1)
    }

    let query = baseQuery(service: service, account: account)
    let updateAttributes = [kSecValueData as String: data] as CFDictionary
    let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes)
    switch updateStatus {
    case errSecSuccess:
      return
    case errSecItemNotFound:
      var addQuery = query
      addQuery[kSecValueData as String] = data
      let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
      guard addStatus == errSecSuccess else {
        throw KeyStoreError.storeFailed(addStatus)
      }
    default:
      throw KeyStoreError.storeFailed(updateStatus)
    }
  }

  func retrieve(service: String, account: String) throws -> String {
    var query = baseQuery(service: service, account: account)
    query[kSecReturnData as String] = kCFBooleanTrue
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess else {
      throw KeyStoreError.retrieveFailed(status)
    }
    guard let data = result as? Data,
      let value = String(data: data, encoding: .utf8)
    else {
      throw KeyStoreError.retrieveFailed(-1)
    }
    return value
  }

  func delete(service: String, account: String) throws {
    let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeyStoreError.deleteFailed(status)
    }
  }

  private func baseQuery(service: String, account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
    ]
  }
}

enum KeyStoreError: LocalizedError, Sendable {
  case storeFailed(OSStatus)
  case retrieveFailed(OSStatus)
  case deleteFailed(OSStatus)
  case unsupportedKey(String)
  /// Both the legacy-cleanup AND the Keychain rollback failed during `store`.
  /// State is indeterminate; surface compound context so support / UAT can
  /// reconcile by hand. `cleanup` is the original failure that triggered the
  /// rollback; `rollback` is the secondary failure from the restore attempt.
  case rollbackFailed(cleanup: Error, rollback: Error)

  var errorDescription: String? {
    switch self {
    case .storeFailed(let s): return "Key store failed: \(s)"
    case .retrieveFailed(let s): return "Key retrieve failed: \(s)"
    case .deleteFailed(let s): return "Key delete failed: \(s)"
    case .unsupportedKey(let key): return "Unsupported key store item: \(key)"
    case .rollbackFailed(let cleanup, let rollback):
      return
        "Key store rollback failed: cleanup=\(cleanup.localizedDescription) rollback=\(rollback.localizedDescription)"
    }
  }
}
