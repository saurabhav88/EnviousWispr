import Foundation
import Testing

@testable import EnviousWisprLLM

/// Tests for the persistent diagnostics surface added in #725. Verifies the
/// namespace records failure/success markers correctly AND that
/// `KeychainManager` wires them on the cleanup paths so the AI Polish settings
/// banner reflects real on-disk state.
@Suite("KeychainCleanupDiagnostics", .serialized)
struct KeychainCleanupDiagnosticsTests {

  // MARK: - Direct namespace behavior

  @Test("recordFailure writes a marker readable via latestFailure")
  func recordFailureWritesMarker() {
    let suite = makeIsolatedSuite()
    defer { tearDown(suite) }

    let now = Date()
    KeychainCleanupDiagnostics.recordFailure(
      keyID: KeychainManager.openAIKeyID,
      error: TestError.cleanupFailed,
      now: now,
      defaults: suite
    )

    let latest = KeychainCleanupDiagnostics.latestFailure(
      defaults: suite,
      keyIDs: [KeychainManager.openAIKeyID, KeychainManager.geminiKeyID]
    )

    #expect(latest?.keyID == KeychainManager.openAIKeyID)
    #expect(latest?.date == now)
    #expect(latest?.summary.contains("cleanupFailed") == true)
  }

  @Test("recordSuccess clears the marker for that key")
  func recordSuccessClearsMarker() {
    let suite = makeIsolatedSuite()
    defer { tearDown(suite) }

    KeychainCleanupDiagnostics.recordFailure(
      keyID: KeychainManager.openAIKeyID,
      error: TestError.cleanupFailed,
      defaults: suite
    )

    KeychainCleanupDiagnostics.recordSuccess(
      keyID: KeychainManager.openAIKeyID,
      defaults: suite
    )

    let latest = KeychainCleanupDiagnostics.latestFailure(
      defaults: suite,
      keyIDs: [KeychainManager.openAIKeyID, KeychainManager.geminiKeyID]
    )
    #expect(latest == nil)
  }

  @Test("latestFailure returns the more recent record when both keys have failed")
  func latestFailureAcrossKeys() {
    let suite = makeIsolatedSuite()
    defer { tearDown(suite) }

    let older = Date(timeIntervalSinceReferenceDate: 100_000)
    let newer = Date(timeIntervalSinceReferenceDate: 200_000)

    KeychainCleanupDiagnostics.recordFailure(
      keyID: KeychainManager.openAIKeyID,
      error: TestError.cleanupFailed,
      now: older,
      defaults: suite
    )
    KeychainCleanupDiagnostics.recordFailure(
      keyID: KeychainManager.geminiKeyID,
      error: TestError.cleanupFailed,
      now: newer,
      defaults: suite
    )

    let latest = KeychainCleanupDiagnostics.latestFailure(
      defaults: suite,
      keyIDs: [KeychainManager.openAIKeyID, KeychainManager.geminiKeyID]
    )

    #expect(latest?.keyID == KeychainManager.geminiKeyID)
    #expect(latest?.date == newer)
  }

  @Test("clearing only one of two failures leaves the remaining one as latest")
  func clearingOneLeavesOther() {
    let suite = makeIsolatedSuite()
    defer { tearDown(suite) }

    KeychainCleanupDiagnostics.recordFailure(
      keyID: KeychainManager.openAIKeyID,
      error: TestError.cleanupFailed,
      defaults: suite
    )
    KeychainCleanupDiagnostics.recordFailure(
      keyID: KeychainManager.geminiKeyID,
      error: TestError.cleanupFailed,
      defaults: suite
    )

    KeychainCleanupDiagnostics.recordSuccess(
      keyID: KeychainManager.geminiKeyID,
      defaults: suite
    )

    let latest = KeychainCleanupDiagnostics.latestFailure(
      defaults: suite,
      keyIDs: [KeychainManager.openAIKeyID, KeychainManager.geminiKeyID]
    )
    #expect(latest?.keyID == KeychainManager.openAIKeyID)
  }

  // MARK: - KeychainManager wiring (uses .standard; save + restore)

  @Test("KeychainManager retrieve cleanup failure records diagnostics in standard defaults")
  func retrieveCleanupFailureRecordsDiagnostics() throws {
    let priorDate = UserDefaults.standard.object(
      forKey: "kcCleanupFail.date." + KeychainManager.openAIKeyID)
    let priorSummary = UserDefaults.standard.object(
      forKey: "kcCleanupFail.summary." + KeychainManager.openAIKeyID)
    defer {
      restoreDefault(
        key: "kcCleanupFail.date." + KeychainManager.openAIKeyID, value: priorDate)
      restoreDefault(
        key: "kcCleanupFail.summary." + KeychainManager.openAIKeyID, value: priorSummary)
    }

    UserDefaults.standard.removeObject(
      forKey: "kcCleanupFail.date." + KeychainManager.openAIKeyID)
    UserDefaults.standard.removeObject(
      forKey: "kcCleanupFail.summary." + KeychainManager.openAIKeyID)

    let legacyStore = FailingDeleteLegacyStore(value: "leaked-key-value")
    let keychainStore = CleanupDiagnosticsInMemoryKeychainStore()
    let manager = KeychainManager(
      backend: .keychain(service: "com.enviouswispr.tests.kc.\(UUID().uuidString)"),
      legacyStore: legacyStore,
      keychainStore: keychainStore
    )

    // Retrieve triggers retrieveLegacyAndMigrate: stores in keychain (success),
    // then calls deleteLegacyFileOrLog which fails (FailingDeleteLegacyStore
    // throws on delete). The retrieve still returns the value so polish keeps
    // working; the diagnostics flag should be set.
    let value = try manager.retrieve(key: KeychainManager.openAIKeyID)
    #expect(value == "leaked-key-value")

    let latest = KeychainCleanupDiagnostics.latestFailure()
    #expect(latest?.keyID == KeychainManager.openAIKeyID)
    #expect(latest?.summary.isEmpty == false)
  }

  @Test("KeychainManager retrieve cleanup success clears prior diagnostics")
  func retrieveCleanupSuccessClearsDiagnostics() throws {
    let priorDate = UserDefaults.standard.object(
      forKey: "kcCleanupFail.date." + KeychainManager.openAIKeyID)
    let priorSummary = UserDefaults.standard.object(
      forKey: "kcCleanupFail.summary." + KeychainManager.openAIKeyID)
    defer {
      restoreDefault(
        key: "kcCleanupFail.date." + KeychainManager.openAIKeyID, value: priorDate)
      restoreDefault(
        key: "kcCleanupFail.summary." + KeychainManager.openAIKeyID, value: priorSummary)
    }

    // Pre-populate diagnostics as if a previous launch failed cleanup.
    KeychainCleanupDiagnostics.recordFailure(
      keyID: KeychainManager.openAIKeyID,
      error: TestError.cleanupFailed
    )
    #expect(KeychainCleanupDiagnostics.latestFailure() != nil)

    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let legacyStore = FileLegacyKeyStore(storageDirectory: dir)
    try legacyStore.store(key: KeychainManager.openAIKeyID, value: "secret-value")
    let keychainStore = CleanupDiagnosticsInMemoryKeychainStore()
    let manager = KeychainManager(
      backend: .keychain(service: "com.enviouswispr.tests.kc.\(UUID().uuidString)"),
      legacyStore: legacyStore,
      keychainStore: keychainStore
    )

    let value = try manager.retrieve(key: KeychainManager.openAIKeyID)
    #expect(value == "secret-value")

    // Migration ran: keychain stored + legacy deleted successfully → flag cleared.
    #expect(KeychainCleanupDiagnostics.latestFailure() == nil)
  }

  // MARK: - Helpers

  private enum TestError: Error { case cleanupFailed }

  private func makeIsolatedSuite() -> UserDefaults {
    let name = "kcCleanupTests.\(UUID().uuidString)"
    return UserDefaults(suiteName: name)!
  }

  private func tearDown(_ suite: UserDefaults) {
    for keyID in [KeychainManager.openAIKeyID, KeychainManager.geminiKeyID] {
      suite.removeObject(forKey: "kcCleanupFail.date." + keyID)
      suite.removeObject(forKey: "kcCleanupFail.summary." + keyID)
    }
  }

  private func restoreDefault(key: String, value: Any?) {
    if let value {
      UserDefaults.standard.set(value, forKey: key)
    } else {
      UserDefaults.standard.removeObject(forKey: key)
    }
  }
}

/// LegacyStore stub that returns a fixed value on retrieve but throws on delete,
/// emulating the post-migration cleanup-failure window described in #725.
private final class FailingDeleteLegacyStore: LegacyKeyFileStorage {
  private let value: String
  init(value: String) { self.value = value }
  func store(key: String, value: String) throws {}
  func retrieve(key: String) throws -> String { value }
  func delete(key: String) throws { throw DeleteError.simulated }

  enum DeleteError: Error { case simulated }
}

/// In-memory KeychainItemStorage stub, scoped to this test file so the test
/// does not depend on the real Apple Keychain. Mirrors the existing private
/// `InMemoryKeychainStore` in `KeychainManagerTests.swift`; kept here to avoid
/// raising that one to internal visibility just for #725.
private final class CleanupDiagnosticsInMemoryKeychainStore: KeychainItemStorage,
  @unchecked Sendable
{
  private var values: [String: String] = [:]
  private let lock = NSLock()

  func store(service: String, account: String, value: String) throws {
    lock.lock()
    defer { lock.unlock() }
    values["\(service):\(account)"] = value
  }

  func retrieve(service: String, account: String) throws -> String {
    lock.lock()
    defer { lock.unlock() }
    guard let value = values["\(service):\(account)"] else {
      throw KeyStoreError.retrieveFailed(errSecItemNotFound)
    }
    return value
  }

  func delete(service: String, account: String) throws {
    lock.lock()
    defer { lock.unlock() }
    values.removeValue(forKey: "\(service):\(account)")
  }
}

private func makeTempDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("kc-cleanup-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
