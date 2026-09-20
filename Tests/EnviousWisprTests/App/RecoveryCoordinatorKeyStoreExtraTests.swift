import EnviousWisprCore
import Foundation
import Security
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// #1873: the `recovery_key_store_failed` capture names the store and the
/// OSStatus (or, for any other error, its domain#code), never just "failed".
@Suite("RecoveryCoordinator key-store failure extra (#1873)", .tags(.observabilityContract))
struct RecoveryCoordinatorKeyStoreExtraTests {

  private func fileStore() -> RecoveryKeyStore {
    RecoveryKeyStore(
      backend: .file,
      fileDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent("ew-1873-\(UUID().uuidString)", isDirectory: true))
  }

  @Test("a storeFailed OSStatus rides as an integer status with the store's name")
  func storeFailedCarriesStatus() {
    let extra = RecoveryCoordinator.keyStoreFailureExtra(
      RecoveryKeyStoreError.storeFailed(errSecInteractionNotAllowed),
      backend: .parakeet, store: fileStore())
    #expect(extra["backend"] as? String == "parakeet")
    #expect(extra["recovery.key_store_backend"] as? String == "file")
    #expect(extra["recovery.key_store_status"] as? Int == Int(errSecInteractionNotAllowed))
    #expect(extra["recovery.key_store_status"] as? Int == -25308)
    #expect(extra["recovery.key_store_error"] == nil)
  }

  @Test("the keychain backend names itself")
  func keychainBackendName() {
    let store = RecoveryKeyStore(
      backend: .keychain(service: "test.service"),
      fileDirectory: FileManager.default.temporaryDirectory)
    let extra = RecoveryCoordinator.keyStoreFailureExtra(
      RecoveryKeyStoreError.storeFailed(errSecIO), backend: .whisperKit, store: store)
    #expect(extra["recovery.key_store_backend"] as? String == "keychain")
    #expect(extra["recovery.key_store_status"] as? Int == Int(errSecIO))
  }

  @Test("a real file-backend failure (directory path occupied by a plain file) reports errSecIO")
  func realFileBackendFailureReportsErrSecIO() throws {
    let collision = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-1873-collision-\(UUID().uuidString)")
    try Data("not a directory".utf8).write(to: collision)
    defer { try? FileManager.default.removeItem(at: collision) }
    let store = RecoveryKeyStore(backend: .file, fileDirectory: collision)
    var caught: (any Error)?
    do {
      try store.store(keyData: RecoveryKeyStore.makeKey(), for: "session-1")
    } catch {
      caught = error
    }
    let error = try #require(caught)
    #expect((error as? RecoveryKeyStoreError) == .storeFailed(errSecIO))
    let extra = RecoveryCoordinator.keyStoreFailureExtra(error, backend: .parakeet, store: store)
    #expect(extra["recovery.key_store_backend"] as? String == "file")
    #expect(extra["recovery.key_store_status"] as? Int == Int(errSecIO))
    #expect(extra["recovery.key_store_status"] as? Int == -36)
  }

  @Test("any other error lands as domain#code, never silent")
  func otherErrorCarriesDomainAndCode() {
    let cocoa = NSError(domain: NSCocoaErrorDomain, code: 513, userInfo: nil)
    let extra = RecoveryCoordinator.keyStoreFailureExtra(
      cocoa, backend: .parakeet, store: fileStore())
    #expect(extra["recovery.key_store_error"] as? String == "NSCocoaErrorDomain#513")
    #expect(extra["recovery.key_store_status"] == nil)
  }
}
