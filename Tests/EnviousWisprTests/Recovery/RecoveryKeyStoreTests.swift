import Foundation
import Security
import Testing

@testable import EnviousWisprServices

/// The per-session key store (#1063 PR0). The file backend (what unsigned
/// `swift test` and the dev bundle use) is always exercised; the data-protection
/// keychain backend is gated behind an entitlement probe and skips honestly on
/// an unsigned binary (`keychain-security.md` — DP keychain returns
/// errSecMissingEntitlement -34018 without the signed entitlement). The signed
/// wire is proven on release Live UAT.
@Suite("Recovery key store (#1063)")
struct RecoveryKeyStoreTests {

  private func makeFileStore() -> RecoveryKeyStore {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ewrec-keys-\(UUID().uuidString)", isDirectory: true)
    return RecoveryKeyStore(backend: .file, fileDirectory: dir)
  }

  @Test("a generated key is 256 bits")
  func generatedKeyIs256Bits() {
    #expect(RecoveryKeyStore.makeKey().count == 32)
  }

  @Test("file backend: store, retrieve, then destroy a session key")
  func fileBackendLifecycle() throws {
    let store = makeFileStore()
    let key = RecoveryKeyStore.makeKey()
    let sessionID = UUID().uuidString

    try store.store(keyData: key, for: sessionID)
    #expect(try store.retrieve(for: sessionID) == key)

    try store.delete(for: sessionID)
    #expect(throws: RecoveryKeyStoreError.notFound) {
      _ = try store.retrieve(for: sessionID)
    }
    // Destroy is idempotent.
    try store.delete(for: sessionID)
  }

  @Test("file backend: storing twice overwrites, never duplicates")
  func fileBackendOverwrites() throws {
    let store = makeFileStore()
    let sessionID = UUID().uuidString
    try store.store(keyData: RecoveryKeyStore.makeKey(), for: sessionID)
    let second = RecoveryKeyStore.makeKey()
    try store.store(keyData: second, for: sessionID)
    #expect(try store.retrieve(for: sessionID) == second)
  }

  @Test("retrieving an unknown session key throws notFound")
  func fileBackendUnknownKey() {
    let store = makeFileStore()
    #expect(throws: RecoveryKeyStoreError.notFound) {
      _ = try store.retrieve(for: UUID().uuidString)
    }
  }

  // MARK: Data-protection keychain (entitlement-gated)

  /// One-time probe: can this (signed) binary use the DP keychain at all?
  private static let hasDataProtectionKeychainEntitlement: Bool = {
    let service = "ew.recovery.probe.\(UUID().uuidString)"
    let add: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: "probe",
      kSecValueData as String: Data([1]),
      kSecUseDataProtectionKeychain as String: kCFBooleanTrue as Any,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let status = SecItemAdd(add as CFDictionary, nil)
    guard status == errSecSuccess else { return false }
    SecItemDelete(
      [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: "probe",
        kSecUseDataProtectionKeychain as String: kCFBooleanTrue as Any,
      ] as CFDictionary)
    return true
  }()

  @Test(
    "DP keychain: store, retrieve, destroy on a signed build",
    .enabled(if: RecoveryKeyStoreTests.hasDataProtectionKeychainEntitlement))
  func keychainBackendLifecycle() throws {
    let service = "com.enviouswispr.app.recovery-keys.test.\(UUID().uuidString)"
    let store = RecoveryKeyStore(
      backend: .keychain(service: service),
      fileDirectory: FileManager.default.temporaryDirectory)
    let sessionID = UUID().uuidString
    let key = RecoveryKeyStore.makeKey()
    defer { try? store.delete(for: sessionID) }

    try store.store(keyData: key, for: sessionID)
    #expect(try store.retrieve(for: sessionID) == key)
    try store.delete(for: sessionID)
    #expect(throws: RecoveryKeyStoreError.notFound) {
      _ = try store.retrieve(for: sessionID)
    }
  }
}
