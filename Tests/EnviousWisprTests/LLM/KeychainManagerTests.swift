import Foundation
import Security
import Testing

@testable import EnviousWisprLLM

@Suite("KeychainManager", .serialized)
struct KeychainManagerTests {
  @Test("legacy file backend stores 0700 directory and 0600 files")
  func legacyFileBackendPermissions() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let manager = KeychainManager(
      backend: .legacyFiles,
      legacyStore: FileLegacyKeyStore(storageDirectory: dir),
      keychainStore: InMemoryKeychainStore()
    )

    try manager.store(key: KeychainManager.openAIKeyID, value: "debug-key")

    #expect(try manager.retrieve(key: KeychainManager.openAIKeyID) == "debug-key")
    let directoryPermissions = try posixPermissions(at: dir)
    let filePermissions = try posixPermissions(
      at: dir.appendingPathComponent(KeychainManager.openAIKeyID))
    #expect(directoryPermissions == 0o700)
    #expect(filePermissions == 0o600)

    try manager.delete(key: KeychainManager.openAIKeyID)
    #expect(
      !FileManager.default.fileExists(
        atPath: dir.appendingPathComponent(KeychainManager.openAIKeyID).path))
  }

  /// Probe the Data Protection keychain to decide whether tests that hit real
  /// `SecItem*` APIs can run. Bare `swift test` produces an unsigned test
  /// binary; macOS returns `errSecMissingEntitlement` (-34018) for DP-scoped
  /// queries without a signed entitlement. These tests are then conditionally
  /// disabled in CI and local `swift test`, and exercised only in signed
  /// release-config Live UAT against the shipped `.app`.
  ///
  /// Probe is intentionally lazy and cached for the suite lifetime to avoid
  /// repeatedly trying SecItemAdd during test discovery.
  static let hasDataProtectionKeychainEntitlement: Bool = {
    let probeService = "com.enviouswispr.tests.dp-probe.\(UUID().uuidString)"
    let addQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: probeService,
      kSecAttrAccount as String: "probe",
      kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
      kSecUseDataProtectionKeychain as String: kCFBooleanTrue as Any,
      kSecValueData as String: Data([0]),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    // Clean up the probe item regardless of outcome.
    let deleteQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: probeService,
      kSecAttrAccount as String: "probe",
      kSecUseDataProtectionKeychain as String: kCFBooleanTrue as Any,
    ]
    _ = SecItemDelete(deleteQuery as CFDictionary)
    return addStatus == errSecSuccess
  }()

  @Test(
    "Security Keychain store can round-trip with a unique test service",
    .enabled(
      if: KeychainManagerTests.hasDataProtectionKeychainEntitlement,
      "Data Protection keychain requires signed entitlement; verified in Live UAT against shipped .app"
    ))
  func securityKeychainRoundTrip() throws {
    let service = "com.enviouswispr.tests.api-keys.\(UUID().uuidString)"
    let store = SecurityKeychainItemStore()
    defer { try? store.delete(service: service, account: KeychainManager.openAIKeyID) }

    try store.store(
      service: service, account: KeychainManager.openAIKeyID, value: "fake-openai-key")

    #expect(
      try store.retrieve(service: service, account: KeychainManager.openAIKeyID)
        == "fake-openai-key")

    try store.delete(service: service, account: KeychainManager.openAIKeyID)
    #expect(throws: Error.self) {
      _ = try store.retrieve(service: service, account: KeychainManager.openAIKeyID)
    }
  }

  // MARK: - Issue #845 — Data Protection Keychain + explicit accessibility

  @Test(
    "DP-backend write is invisible to a legacy-scoped read",
    .enabled(
      if: KeychainManagerTests.hasDataProtectionKeychainEntitlement,
      "Data Protection keychain requires signed entitlement; verified in Live UAT against shipped .app"
    ),
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/845",
      "Data-protection keychain + explicit accessibility per TN3137"))
  func securityKeychainBackendIsolationWriteDPReadLegacyMisses() throws {
    let service = "com.enviouswispr.tests.api-keys.\(UUID().uuidString)"
    let store = SecurityKeychainItemStore()
    defer {
      try? store.delete(service: service, account: KeychainManager.openAIKeyID)
      // Belt-and-suspenders: also wipe any leftover legacy item from the raw query.
      _ = SecItemDelete(
        Self.legacyQuery(service: service, account: KeychainManager.openAIKeyID) as CFDictionary)
    }

    try store.store(
      service: service, account: KeychainManager.openAIKeyID, value: "dp-only-value")

    // Reading via SecurityKeychainItemStore (DP-scoped) must hit.
    #expect(
      try store.retrieve(service: service, account: KeychainManager.openAIKeyID)
        == "dp-only-value")

    // Reading via a raw legacy-scoped query MUST miss — the item is in DP, not legacy.
    var legacyReadQuery = Self.legacyQuery(
      service: service, account: KeychainManager.openAIKeyID)
    legacyReadQuery[kSecReturnData as String] = kCFBooleanTrue
    legacyReadQuery[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(legacyReadQuery as CFDictionary, &result)
    #expect(status == errSecItemNotFound)
  }

  @Test(
    "Legacy-backend item is invisible to a DP-scoped retrieve",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/845",
      "Data-protection keychain + explicit accessibility per TN3137"))
  func securityKeychainBackendIsolationWriteLegacyReadDPMisses() throws {
    let service = "com.enviouswispr.tests.api-keys.\(UUID().uuidString)"
    let store = SecurityKeychainItemStore()
    defer {
      try? store.delete(service: service, account: KeychainManager.openAIKeyID)
      _ = SecItemDelete(
        Self.legacyQuery(service: service, account: KeychainManager.openAIKeyID) as CFDictionary)
    }

    // Seed a legacy-backend item directly.
    guard let data = "legacy-only-value".data(using: .utf8) else {
      Issue.record("UTF-8 encoding failed")
      return
    }
    var legacyAddQuery = Self.legacyQuery(
      service: service, account: KeychainManager.openAIKeyID)
    legacyAddQuery[kSecValueData as String] = data
    let addStatus = SecItemAdd(legacyAddQuery as CFDictionary, nil)
    #expect(addStatus == errSecSuccess)

    // Production code (DP-scoped retrieve) MUST NOT see the legacy item.
    #expect(throws: KeyStoreError.self) {
      _ = try store.retrieve(service: service, account: KeychainManager.openAIKeyID)
    }
  }

  @Test(
    "Stored item has explicit kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly",
    .enabled(
      if: KeychainManagerTests.hasDataProtectionKeychainEntitlement,
      "Data Protection keychain requires signed entitlement; verified in Live UAT against shipped .app"
    ),
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/845",
      "Data-protection keychain + explicit accessibility per TN3137"))
  func securityKeychainStoredItemHasExplicitAccessibility() throws {
    let service = "com.enviouswispr.tests.api-keys.\(UUID().uuidString)"
    let store = SecurityKeychainItemStore()
    defer { try? store.delete(service: service, account: KeychainManager.openAIKeyID) }

    try store.store(
      service: service, account: KeychainManager.openAIKeyID, value: "access-attr-test")

    // Re-read via the DP-scoped query and ask for the attributes dictionary.
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: KeychainManager.openAIKeyID,
      kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
      kSecUseDataProtectionKeychain as String: kCFBooleanTrue as Any,
      kSecReturnAttributes as String: kCFBooleanTrue as Any,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    #expect(status == errSecSuccess)

    let attrs = try #require(result as? [String: Any])
    let accessible = try #require(attrs[kSecAttrAccessible as String] as? String)
    #expect(accessible == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String))
    _ = query  // silence unused warning on local var rebinding form
  }

  @Test(
    "Delete wipes both DP item and any legacy-backend orphan",
    .enabled(
      if: KeychainManagerTests.hasDataProtectionKeychainEntitlement,
      "Data Protection keychain requires signed entitlement; verified in Live UAT against shipped .app"
    ),
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/845",
      "Data-protection keychain + explicit accessibility per TN3137"))
  func securityKeychainDeleteCleansLegacyOrphan() throws {
    let service = "com.enviouswispr.tests.api-keys.\(UUID().uuidString)"
    let store = SecurityKeychainItemStore()
    defer {
      try? store.delete(service: service, account: KeychainManager.openAIKeyID)
      _ = SecItemDelete(
        Self.legacyQuery(service: service, account: KeychainManager.openAIKeyID) as CFDictionary)
    }

    // Seed both backends: a legacy orphan (simulating v2.0.2 / v2.0.3 leftover)
    // and a DP item (simulating the user's re-pasted key on the fixed build).
    guard let legacyData = "legacy-orphan".data(using: .utf8) else {
      Issue.record("UTF-8 encoding failed")
      return
    }
    var legacyAddQuery = Self.legacyQuery(
      service: service, account: KeychainManager.openAIKeyID)
    legacyAddQuery[kSecValueData as String] = legacyData
    #expect(SecItemAdd(legacyAddQuery as CFDictionary, nil) == errSecSuccess)

    try store.store(
      service: service, account: KeychainManager.openAIKeyID, value: "dp-current")

    // User-initiated clear MUST wipe both backends.
    try store.delete(service: service, account: KeychainManager.openAIKeyID)

    // DP backend empty.
    #expect(throws: KeyStoreError.self) {
      _ = try store.retrieve(service: service, account: KeychainManager.openAIKeyID)
    }

    // Legacy backend ALSO empty — the N5 cleanup ran.
    var legacyReadQuery = Self.legacyQuery(
      service: service, account: KeychainManager.openAIKeyID)
    legacyReadQuery[kSecReturnData as String] = kCFBooleanTrue
    legacyReadQuery[kSecMatchLimit as String] = kSecMatchLimitOne
    var legacyResult: CFTypeRef?
    let legacyReadStatus = SecItemCopyMatching(legacyReadQuery as CFDictionary, &legacyResult)
    #expect(legacyReadStatus == errSecItemNotFound)
  }

  @Test(
    "Delete on missing item is success across both backends",
    .enabled(
      if: KeychainManagerTests.hasDataProtectionKeychainEntitlement,
      "Data Protection keychain requires signed entitlement; verified in Live UAT against shipped .app"
    ),
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/845",
      "Data-protection keychain + explicit accessibility per TN3137"))
  func securityKeychainDeleteIsIdempotentWhenNothingExists() throws {
    let service = "com.enviouswispr.tests.api-keys.\(UUID().uuidString)"
    let store = SecurityKeychainItemStore()

    // No items in either backend. delete() must succeed (errSecItemNotFound on
    // both is treated as success).
    try store.delete(service: service, account: KeychainManager.openAIKeyID)
  }

  /// Builds a legacy-backend SecItem query (omits kSecUseDataProtectionKeychain
  /// so the call targets the legacy file-based macOS keychain, matching what
  /// EW v2.0.2 / v2.0.3 wrote before #845 adopted the DP backend).
  private static func legacyQuery(service: String, account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
    ]
  }

  // MARK: - Pre-#845 tests follow

  @Test("release retrieve migrates legacy file when Keychain item is missing")
  func releaseRetrieveMigratesLegacyFile() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let legacyStore = FileLegacyKeyStore(storageDirectory: dir)
    let keychainStore = InMemoryKeychainStore()
    let manager = releaseStyleManager(legacyStore: legacyStore, keychainStore: keychainStore)

    try legacyStore.store(key: KeychainManager.openAIKeyID, value: "legacy-value")

    #expect(try manager.retrieve(key: KeychainManager.openAIKeyID) == "legacy-value")
    #expect(
      try keychainStore.retrieve(service: testService, account: KeychainManager.openAIKeyID)
        == "legacy-value")
    #expect(
      !FileManager.default.fileExists(
        atPath: dir.appendingPathComponent(KeychainManager.openAIKeyID).path))
  }

  @Test("release retrieve prefers Keychain and removes stale legacy file")
  func releaseRetrieveKeychainWinsOverStaleLegacyFile() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let legacyStore = FileLegacyKeyStore(storageDirectory: dir)
    let keychainStore = InMemoryKeychainStore()
    let manager = releaseStyleManager(legacyStore: legacyStore, keychainStore: keychainStore)

    try legacyStore.store(key: KeychainManager.openAIKeyID, value: "stale-file-value")
    try keychainStore.store(
      service: testService, account: KeychainManager.openAIKeyID, value: "keychain-value")

    #expect(try manager.retrieve(key: KeychainManager.openAIKeyID) == "keychain-value")
    #expect(
      !FileManager.default.fileExists(
        atPath: dir.appendingPathComponent(KeychainManager.openAIKeyID).path))
  }

  @Test("release retrieve surfaces non-missing Keychain failures")
  func releaseRetrieveDoesNotFallBackForNonMissingKeychainFailure() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let legacyStore = FileLegacyKeyStore(storageDirectory: dir)
    let keychainStore = InMemoryKeychainStore(retrieveStatus: errSecAuthFailed)
    let manager = releaseStyleManager(legacyStore: legacyStore, keychainStore: keychainStore)

    try legacyStore.store(key: KeychainManager.openAIKeyID, value: "legacy-value")

    #expect(throws: KeyStoreError.self) {
      _ = try manager.retrieve(key: KeychainManager.openAIKeyID)
    }
    #expect(
      FileManager.default.fileExists(
        atPath: dir.appendingPathComponent(KeychainManager.openAIKeyID).path))
  }

  @Test("release store writes Keychain and removes stale legacy file")
  func releaseStoreDeletesStaleLegacyFile() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let legacyStore = FileLegacyKeyStore(storageDirectory: dir)
    let keychainStore = InMemoryKeychainStore()
    let manager = releaseStyleManager(legacyStore: legacyStore, keychainStore: keychainStore)

    try legacyStore.store(key: KeychainManager.geminiKeyID, value: "old-gemini")
    try manager.store(key: KeychainManager.geminiKeyID, value: "new-gemini")

    #expect(
      try keychainStore.retrieve(service: testService, account: KeychainManager.geminiKeyID)
        == "new-gemini")
    #expect(
      !FileManager.default.fileExists(
        atPath: dir.appendingPathComponent(KeychainManager.geminiKeyID).path))
  }

  @Test("release store surfaces previous Keychain read failures before writing")
  func releaseStoreDoesNotMaskPreviousKeychainReadFailure() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let legacyStore = FileLegacyKeyStore(storageDirectory: dir)
    let keychainStore = InMemoryKeychainStore(retrieveStatus: errSecAuthFailed)
    let manager = releaseStyleManager(legacyStore: legacyStore, keychainStore: keychainStore)

    #expect(throws: KeyStoreError.self) {
      try manager.store(key: KeychainManager.geminiKeyID, value: "new-gemini")
    }
    #expect(
      keychainStore.storedValue(service: testService, account: KeychainManager.geminiKeyID) == nil)
  }

  @Test("migration write failure returns legacy value and preserves legacy file")
  func migrationWriteFailureFallsBackToLegacyForCurrentSession() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let legacyStore = FileLegacyKeyStore(storageDirectory: dir)
    let keychainStore = InMemoryKeychainStore(storeStatus: errSecAuthFailed)
    let manager = releaseStyleManager(legacyStore: legacyStore, keychainStore: keychainStore)

    try legacyStore.store(key: KeychainManager.openAIKeyID, value: "legacy-still-works")

    #expect(try manager.retrieve(key: KeychainManager.openAIKeyID) == "legacy-still-works")
    #expect(
      FileManager.default.fileExists(
        atPath: dir.appendingPathComponent(KeychainManager.openAIKeyID).path))
  }

  @Test("release store rolls back new Keychain item when legacy cleanup fails")
  func releaseStoreRollsBackNewKeychainItemWhenLegacyCleanupFails() throws {
    let keychainStore = InMemoryKeychainStore()
    let manager = releaseStyleManager(
      legacyStore: FailingDeleteLegacyStore(),
      keychainStore: keychainStore
    )

    do {
      try manager.store(key: KeychainManager.openAIKeyID, value: "new-key")
      Issue.record("Expected store to throw")
    } catch let error as KeyStoreError {
      switch error {
      case .deleteFailed:
        break  // expected — the original legacy-cleanup error surfaces unchanged
      case .rollbackFailed:
        Issue.record("Cleanup-only failure surfaced as rollbackFailed: \(error)")
      default:
        Issue.record("Expected KeyStoreError.deleteFailed, got \(error)")
      }
    } catch {
      Issue.record("Expected KeyStoreError, got \(error)")
    }
    #expect(throws: Error.self) {
      _ = try keychainStore.retrieve(service: testService, account: KeychainManager.openAIKeyID)
    }
  }

  @Test("release store restores previous Keychain item when legacy cleanup fails")
  func releaseStoreRestoresPreviousKeychainItemWhenLegacyCleanupFails() throws {
    let keychainStore = InMemoryKeychainStore()
    let manager = releaseStyleManager(
      legacyStore: FailingDeleteLegacyStore(),
      keychainStore: keychainStore
    )
    try keychainStore.store(
      service: testService, account: KeychainManager.openAIKeyID, value: "old-key")

    do {
      try manager.store(key: KeychainManager.openAIKeyID, value: "new-key")
      Issue.record("Expected store to throw")
    } catch let error as KeyStoreError {
      switch error {
      case .deleteFailed:
        break  // expected — the original legacy-cleanup error surfaces unchanged
      case .rollbackFailed:
        Issue.record("Cleanup-only failure surfaced as rollbackFailed: \(error)")
      default:
        Issue.record("Expected KeyStoreError.deleteFailed, got \(error)")
      }
    } catch {
      Issue.record("Expected KeyStoreError, got \(error)")
    }
    #expect(
      try keychainStore.retrieve(service: testService, account: KeychainManager.openAIKeyID)
        == "old-key")
  }

  @Test("release store surfaces rollbackFailed when both legacy cleanup and Keychain rollback fail")
  func releaseStoreSurfacesCompoundRollbackFailure() throws {
    let keychainStore = InMemoryKeychainStore(deleteStatus: errSecAuthFailed)
    let manager = releaseStyleManager(
      legacyStore: FailingDeleteLegacyStore(),
      keychainStore: keychainStore
    )

    do {
      try manager.store(key: KeychainManager.openAIKeyID, value: "new-key")
      Issue.record("Expected store to throw")
    } catch let error as KeyStoreError {
      guard case .rollbackFailed = error else {
        Issue.record("Expected rollbackFailed, got \(error)")
        return
      }
    } catch {
      Issue.record("Expected KeyStoreError.rollbackFailed, got \(error)")
    }
  }

  @Test("release delete removes legacy file and Keychain item")
  func releaseDeleteRemovesBothStores() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let legacyStore = FileLegacyKeyStore(storageDirectory: dir)
    let keychainStore = InMemoryKeychainStore()
    let manager = releaseStyleManager(legacyStore: legacyStore, keychainStore: keychainStore)

    try legacyStore.store(key: KeychainManager.openAIKeyID, value: "legacy")
    try keychainStore.store(
      service: testService, account: KeychainManager.openAIKeyID, value: "keychain")

    try manager.delete(key: KeychainManager.openAIKeyID)

    #expect(
      !FileManager.default.fileExists(
        atPath: dir.appendingPathComponent(KeychainManager.openAIKeyID).path))
    #expect(throws: Error.self) {
      _ = try keychainStore.retrieve(service: testService, account: KeychainManager.openAIKeyID)
    }
  }

  @Test("release delete stops before Keychain deletion when legacy deletion fails")
  func releaseDeleteDoesNotSilentlyResurrectWhenLegacyDeletionFails() throws {
    let legacyStore = FailingDeleteLegacyStore()
    let keychainStore = InMemoryKeychainStore()
    let manager = releaseStyleManager(legacyStore: legacyStore, keychainStore: keychainStore)

    try keychainStore.store(
      service: testService, account: KeychainManager.openAIKeyID, value: "keychain")

    #expect(throws: Error.self) {
      try manager.delete(key: KeychainManager.openAIKeyID)
    }
    #expect(
      try keychainStore.retrieve(service: testService, account: KeychainManager.openAIKeyID)
        == "keychain")
  }

  @Test("release flows do not touch unrelated legacy files")
  func releaseFlowsPreserveUnrelatedLegacyFiles() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let unrelated = dir.appendingPathComponent("business-workspace-admin-sa.json")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try "not-an-ew-customer-key".write(to: unrelated, atomically: true, encoding: .utf8)

    let manager = releaseStyleManager(
      legacyStore: FileLegacyKeyStore(storageDirectory: dir),
      keychainStore: InMemoryKeychainStore()
    )

    try manager.store(key: KeychainManager.openAIKeyID, value: "openai")
    _ = try manager.retrieve(key: KeychainManager.openAIKeyID)
    try manager.delete(key: KeychainManager.openAIKeyID)

    #expect(FileManager.default.fileExists(atPath: unrelated.path))
    #expect(throws: Error.self) {
      try manager.delete(key: "business-workspace-admin-sa.json")
    }
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
  }

  private var testService: String { "com.enviouswispr.tests.api-keys" }

  private func releaseStyleManager(
    legacyStore: any LegacyKeyFileStorage,
    keychainStore: any KeychainItemStorage
  ) -> KeychainManager {
    KeychainManager(
      backend: .keychain(service: testService),
      legacyStore: legacyStore,
      keychainStore: keychainStore
    )
  }

  private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-keychain-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func posixPermissions(at url: URL) throws -> Int {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
  }
}

private final class InMemoryKeychainStore: KeychainItemStorage, @unchecked Sendable {
  private let lock = NSLock()
  private var items: [String: String] = [:]
  private let storeStatus: OSStatus?
  private let retrieveStatus: OSStatus?
  private let deleteStatus: OSStatus?

  init(
    storeStatus: OSStatus? = nil,
    retrieveStatus: OSStatus? = nil,
    deleteStatus: OSStatus? = nil
  ) {
    self.storeStatus = storeStatus
    self.retrieveStatus = retrieveStatus
    self.deleteStatus = deleteStatus
  }

  func store(service: String, account: String, value: String) throws {
    if let storeStatus {
      throw KeyStoreError.storeFailed(storeStatus)
    }
    lock.withLock {
      items[key(service: service, account: account)] = value
    }
  }

  func retrieve(service: String, account: String) throws -> String {
    if let retrieveStatus {
      throw KeyStoreError.retrieveFailed(retrieveStatus)
    }
    return try lock.withLock {
      guard let value = items[key(service: service, account: account)] else {
        throw KeyStoreError.retrieveFailed(errSecItemNotFound)
      }
      return value
    }
  }

  func delete(service: String, account: String) throws {
    if let deleteStatus {
      throw KeyStoreError.deleteFailed(deleteStatus)
    }
    _ = lock.withLock {
      items.removeValue(forKey: key(service: service, account: account))
    }
  }

  func storedValue(service: String, account: String) -> String? {
    lock.withLock {
      items[key(service: service, account: account)]
    }
  }

  private func key(service: String, account: String) -> String {
    "\(service)::\(account)"
  }
}

private struct FailingDeleteLegacyStore: LegacyKeyFileStorage {
  func store(key: String, value: String) throws {}

  func retrieve(key: String) throws -> String {
    "legacy"
  }

  func delete(key: String) throws {
    throw KeyStoreError.deleteFailed(-1)
  }
}
