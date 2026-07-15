import EnviousWisprCore
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
  /// #1177 (Telemetry Bible Phase 8): the LLM module's quiet-limb telemetry sink. The
  /// LLM module has no telemetry dependency, so the App composition root injects the
  /// `.live` sink here (this is the LLM module's already-ubiquitous dependency) and it
  /// is reached by Q3.3 (legacy-key cleanup, below) AND A6 (`LLMNetworkSession.preWarmModel`
  /// reads it off the `keychainManager` it already receives). `internal` — module-visible
  /// to `LLMNetworkSession`, injected via the public `init` param. Defaults to `.noop`,
  /// so the ~43 test sites + the connector default-args stay silent.
  let telemetrySink: LLMTelemetrySink

  public init(telemetrySink: LLMTelemetrySink = .noop) {
    let legacyStore = FileLegacyKeyStore()
    if Self.usesLegacyFilesForDefaultRuntime {
      self.init(
        backend: .legacyFiles,
        legacyStore: legacyStore,
        keychainStore: SecurityKeychainItemStore(),
        telemetrySink: telemetrySink
      )
    } else {
      self.init(
        backend: .keychain(service: Self.productionService),
        legacyStore: legacyStore,
        keychainStore: SecurityKeychainItemStore(),
        telemetrySink: telemetrySink
      )
    }
  }

  init(
    backend: KeyStorageBackend,
    legacyStore: any LegacyKeyFileStorage = FileLegacyKeyStore(),
    keychainStore: any KeychainItemStorage = SecurityKeychainItemStore(),
    telemetrySink: LLMTelemetrySink = .noop
  ) {
    self.backend = backend
    self.legacyStore = legacyStore
    self.keychainStore = keychainStore
    self.telemetrySink = telemetrySink
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
    } catch {
      Self.logger.error(
        "Legacy plaintext API key file remained on disk after Keychain migration; user-visible polish is unaffected but the security goal is not met. Will retry on next retrieve. account=\(key, privacy: .public) error=\(String(describing: error), privacy: .public)"
      )
      // #1177 (Telemetry Bible Phase 8): a security goal silently failed — the plaintext
      // key still sits on disk. The sink's `.live` emits a population event + a
      // fingerprinted Sentry handled error (per-account); fire-and-forget, never the key
      // material (only the account name). `.noop` everywhere except the App root.
      telemetrySink.legacyKeyCleanupFailed(error, key)
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
      // #1446: NO key is stored — the user's configuration state, not a defect.
      // `errSecItemNotFound` is `KeyStoreError`'s shared vocabulary for absence
      // (`SecurityKeychainItemStore` already reports it), so callers can tell
      // "never saved a key" apart from "saved a key we then failed to read".
      // Every OTHER exit below stays `-1`: the file exists but its bytes would
      // not read back, which IS a defect.
      throw KeyStoreError.retrieveFailed(errSecItemNotFound)
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
  private static let logger = Logger(
    subsystem: "com.enviouswispr.app", category: "Keychain")

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
      addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
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
    // Issue #845: best-effort cleanup of any v2.0.2 / v2.0.3 orphan that
    // lives in the legacy file-based macOS keychain. The query omits
    // kSecUseDataProtectionKeychain so it targets the legacy backend. We
    // swallow non-not-found errors here because the primary (DP) delete
    // already succeeded; throwing now would surface a confusing error for
    // an orphan the production code never reads. errSecItemNotFound is the
    // common case (no orphan) and is success.
    let legacyQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
    ]
    let legacyStatus = SecItemDelete(legacyQuery as CFDictionary)
    if legacyStatus != errSecSuccess && legacyStatus != errSecItemNotFound {
      Self.logger.error(
        "Legacy-keychain orphan cleanup failed account=\(account, privacy: .public) status=\(legacyStatus, privacy: .public)"
      )
    }
  }

  private func baseQuery(service: String, account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
      kSecUseDataProtectionKeychain as String: kCFBooleanTrue as Any,
    ]
  }
}

package enum KeyStoreError: LocalizedError, Sendable {
  case storeFailed(OSStatus)
  case retrieveFailed(OSStatus)
  case deleteFailed(OSStatus)
  case unsupportedKey(String)
  /// Both the legacy-cleanup AND the Keychain rollback failed during `store`.
  /// State is indeterminate; surface compound context so support / UAT can
  /// reconcile by hand. `cleanup` is the original failure that triggered the
  /// rollback; `rollback` is the secondary failure from the restore attempt.
  case rollbackFailed(cleanup: Error, rollback: Error)

  package var errorDescription: String? {
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

extension KeyStoreError: StableSentryErrorIdentity {
  /// #1525 PR F. Pins each case's exact measured current wire identity
  /// (`docs/audits/2026-07-14-1525-pr-f-preflight.md` §1) — never re-derive
  /// from ordinal reasoning. Only `.deleteFailed` (`#2`) is proven to reach
  /// Sentry today (legacy-key-cleanup path); the other 4 are pinned
  /// defensively so a future capture site inherits a stable identity
  /// instead of an ordinal that can silently shift. NEVER change any of
  /// these strings once shipped.
  package var sentryFingerprintDescriptor: String {
    switch self {
    case .storeFailed: return "EnviousWisprLLM.KeyStoreError#0"
    case .retrieveFailed: return "EnviousWisprLLM.KeyStoreError#1"
    case .deleteFailed: return "EnviousWisprLLM.KeyStoreError#2"
    case .unsupportedKey: return "EnviousWisprLLM.KeyStoreError#3"
    case .rollbackFailed: return "EnviousWisprLLM.KeyStoreError#4"
    }
  }

  package var sentrySemanticID: String {
    switch self {
    case .storeFailed: return "keystore.store_failed"
    case .retrieveFailed: return "keystore.retrieve_failed"
    case .deleteFailed: return "keystore.delete_failed"
    case .unsupportedKey: return "keystore.unsupported_key"
    case .rollbackFailed: return "keystore.rollback_failed"
    }
  }
}
