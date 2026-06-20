import EnviousWisprCore
import EnviousWisprStorage
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// The host-side `RecoveryCoordinator` (#1063 PR1): arms a recording's encrypted
/// spool with a DURABLY-stored key before returning an enabled payload, deletes
/// the spool + key on a durable save, and purges every orphan on launch. All
/// paths fail open. Temp-dir-backed stores keep the tests isolated.
@MainActor
@Suite("Recovery coordinator (#1063)")
struct RecoveryCoordinatorTests {

  private static func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-recovery-coord-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private static func freshSettings(crashRecoveryEnabled: Bool) -> SettingsManager {
    let name = "ew.recovery.coord.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    let settings = SettingsManager(defaults: defaults)
    settings.crashRecoveryEnabled = crashRecoveryEnabled
    return settings
  }

  private struct Harness {
    let coordinator: RecoveryCoordinator
    let keyStore: RecoveryKeyStore
    let spoolStore: RecoverySpoolStore
  }

  private static func makeHarness() -> Harness {
    let keyStore = RecoveryKeyStore(backend: .file, fileDirectory: tempDir())
    let spoolDir = tempDir()
    let coordinator = RecoveryCoordinator(
      keyStore: keyStore,
      makeSpoolStore: { RecoverySpoolStore(directory: spoolDir) })
    return Harness(
      coordinator: coordinator, keyStore: keyStore,
      spoolStore: RecoverySpoolStore(directory: spoolDir))
  }

  @Test("recovery off ⇒ no directive")
  func disabledReturnsNil() async {
    let h = Self.makeHarness()
    let result = await h.coordinator.makeDirective(
      settings: Self.freshSettings(crashRecoveryEnabled: false),
      backendType: .parakeet, supportsLanguageDetection: false)
    #expect(result == nil)
  }

  @Test("recovery on ⇒ directive whose key is durably stored BEFORE it returns")
  func armsAndStoresKeyBeforeReturning() async throws {
    let h = Self.makeHarness()
    let result = await h.coordinator.makeDirective(
      settings: Self.freshSettings(crashRecoveryEnabled: true),
      backendType: .whisperKit, supportsLanguageDetection: true)
    let armed = try #require(result)

    let directive = try JSONDecoder().decode(RecoverySpoolDirective.self, from: armed.payload)
    #expect(directive.enabled)
    #expect(directive.recoverySessionID == armed.recoverySessionID)
    #expect(directive.keyData != nil)
    #expect(directive.settingsSnapshot.backendType == .whisperKit)
    #expect(directive.settingsSnapshot.backendSupportsLanguageDetection)

    // R2: the key is already retrievable the instant the payload is returned —
    // there is no crash window where the spool exists with no recoverable key.
    let storedKey = try h.keyStore.retrieve(for: armed.recoverySessionID)
    #expect(storedKey == directive.keyData)
  }

  @Test("durable save deletes that session's spool + key")
  func durableSaveDeletes() async throws {
    let h = Self.makeHarness()
    let id = "session-\(UUID().uuidString)"
    try Data([1, 2, 3]).write(to: h.spoolStore.spoolURL(for: id))
    try h.keyStore.store(keyData: RecoveryKeyStore.makeKey(), for: id)

    await h.coordinator.handleDurableSave(recoverySessionID: id).value

    #expect(!FileManager.default.fileExists(atPath: h.spoolStore.spoolURL(for: id).path))
    #expect(throws: RecoveryKeyStoreError.notFound) { try h.keyStore.retrieve(for: id) }
  }

  @Test("launch purge removes every orphan spool + key")
  func purgeRemovesAllOrphans() async throws {
    let h = Self.makeHarness()
    let ids = ["a-\(UUID().uuidString)", "b-\(UUID().uuidString)"]
    for id in ids {
      try Data([9]).write(to: h.spoolStore.spoolURL(for: id))
      try h.keyStore.store(keyData: RecoveryKeyStore.makeKey(), for: id)
    }

    await h.coordinator.purgeOrphansOnLaunch().value

    #expect(try h.spoolStore.listSpoolSessionIDs().isEmpty)
    for id in ids {
      #expect(throws: RecoveryKeyStoreError.notFound) { try h.keyStore.retrieve(for: id) }
    }
  }

  @Test("launch purge also sweeps an orphan key that has no spool")
  func purgeRemovesOrphanKeyWithoutSpool() async throws {
    let h = Self.makeHarness()
    // A key armed for a recording that aborted before the helper wrote a frame:
    // a key with NO spool. The spool-only pass can't see it (Codex code-diff P2).
    let id = "orphan-\(UUID().uuidString)"
    try h.keyStore.store(keyData: RecoveryKeyStore.makeKey(), for: id)
    #expect(try h.spoolStore.listSpoolSessionIDs().isEmpty)

    await h.coordinator.purgeOrphansOnLaunch().value

    #expect(throws: RecoveryKeyStoreError.notFound) { try h.keyStore.retrieve(for: id) }
  }

  // MARK: - In-session non-saved cleanup + purge protection (Codex code-diff r3)

  @Test("a non-saved terminal deletes the armed session's spool + key in-session")
  func endedWithoutSaveDeletesArmed() async throws {
    let h = Self.makeHarness()
    // Arm a recording: makeDirective mints the id + durably stores the key.
    let armed = try #require(
      await h.coordinator.makeDirective(
        settings: Self.freshSettings(crashRecoveryEnabled: true),
        backendType: .parakeet, supportsLanguageDetection: false))
    // The helper would have written + finalized the spool; simulate it on disk.
    try Data([1, 2, 3]).write(to: h.spoolStore.spoolURL(for: armed.recoverySessionID))
    #expect((try? h.keyStore.retrieve(for: armed.recoverySessionID)) != nil)

    // App-alive non-saved ending (cancel / no-speech / error): delete NOW.
    await h.coordinator.handleRecordingEndedWithoutDurableSave()?.value

    #expect(
      !FileManager.default.fileExists(
        atPath: h.spoolStore.spoolURL(for: armed.recoverySessionID).path))
    #expect(throws: RecoveryKeyStoreError.notFound) {
      try h.keyStore.retrieve(for: armed.recoverySessionID)
    }
  }

  @Test("non-saved cleanup is a no-op when nothing is armed")
  func endedWithoutSaveNoopWhenNothingArmed() async {
    let h = Self.makeHarness()
    #expect(await h.coordinator.handleRecordingEndedWithoutDurableSave() == nil)
  }

  @Test("a durable save clears the armed id so a later non-saved cleanup is a no-op")
  func durableSaveClearsArmed() async throws {
    let h = Self.makeHarness()
    let armed = try #require(
      await h.coordinator.makeDirective(
        settings: Self.freshSettings(crashRecoveryEnabled: true),
        backendType: .parakeet, supportsLanguageDetection: false))
    await h.coordinator.handleDurableSave(recoverySessionID: armed.recoverySessionID).value
    // The save already deleted + cleared the armed id — nothing left to clean.
    #expect(await h.coordinator.handleRecordingEndedWithoutDurableSave() == nil)
  }

  @Test("a key-store failure leaves nothing armed (no phantom for the purge to guard)")
  func storeFailureLeavesNothingArmed() async throws {
    // A file key store whose directory can never be created: its parent is a
    // regular file, so `createDirectory` throws and every `store` fails. This
    // exercises makeDirective's fail-open guard — armedSessionID is set BEFORE
    // the store (to close the purge race, Codex r4 P2) and must be cleared again
    // when the store fails, or the purge would protect a session with no key and
    // a later non-saved cleanup would fire against nothing.
    let parentFile = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-key-parent-\(UUID().uuidString)")
    try Data([0]).write(to: parentFile)
    let unwritableDir = parentFile.appendingPathComponent("keys", isDirectory: true)
    let keyStore = RecoveryKeyStore(backend: .file, fileDirectory: unwritableDir)
    let spoolDir = Self.tempDir()
    let coordinator = RecoveryCoordinator(
      keyStore: keyStore, makeSpoolStore: { RecoverySpoolStore(directory: spoolDir) })

    let result = await coordinator.makeDirective(
      settings: Self.freshSettings(crashRecoveryEnabled: true),
      backendType: .parakeet, supportsLanguageDetection: false)
    #expect(result == nil, "a failed durable key store must disable recovery for the take")

    // Nothing armed: a non-saved cleanup is a no-op, and the purge guards no
    // phantom id. (handleRecordingEndedWithoutDurableSave returns nil ⇔ armed nil.)
    #expect(coordinator.handleRecordingEndedWithoutDurableSave() == nil)
  }

  @Test("launch purge PROTECTS the session armed for an in-flight recording")
  func purgeProtectsLiveArmedSession() async throws {
    let h = Self.makeHarness()
    // A recording armed concurrently with the launch purge.
    let armed = try #require(
      await h.coordinator.makeDirective(
        settings: Self.freshSettings(crashRecoveryEnabled: true),
        backendType: .parakeet, supportsLanguageDetection: false))
    try Data([1]).write(to: h.spoolStore.spoolURL(for: armed.recoverySessionID))
    // An orphan from a PRIOR run that must still be swept.
    let orphan = "orphan-\(UUID().uuidString)"
    try Data([2]).write(to: h.spoolStore.spoolURL(for: orphan))
    try h.keyStore.store(keyData: RecoveryKeyStore.makeKey(), for: orphan)

    await h.coordinator.purgeOrphansOnLaunch().value

    // Orphan swept …
    #expect(
      !FileManager.default.fileExists(atPath: h.spoolStore.spoolURL(for: orphan).path))
    #expect(throws: RecoveryKeyStoreError.notFound) { try h.keyStore.retrieve(for: orphan) }
    // … but the live armed session's spool + key SURVIVE (deleting its key would
    // make its spool unrecoverable after a crash — Codex code-diff r3 P2).
    #expect(
      FileManager.default.fileExists(
        atPath: h.spoolStore.spoolURL(for: armed.recoverySessionID).path))
    #expect((try? h.keyStore.retrieve(for: armed.recoverySessionID)) != nil)
  }
}
