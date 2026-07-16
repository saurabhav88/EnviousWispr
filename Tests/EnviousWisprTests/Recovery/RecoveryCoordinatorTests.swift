import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprStorage
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// The host-side `RecoveryCoordinator` (#1063 PR2 / #1464): arms a recording's
/// encrypted spool with a DURABLY-stored key, and is the SOLE spool/key destructor
/// — it applies two exhaustive predicates (`shouldDeleteOnLiveEnding` for a live
/// non-saved ending, `shouldDeleteAfterReplay` for a launch replay outcome), so the
/// replayer no longer deletes. On launch it scans + recovers orphans behind a
/// blocking gate (single-flight, dedup, generation-guarded discard, `defer`-cleared
/// gate) and posts a success notice. A fake replayer drives the scan/gate/
/// generation logic; temp-dir stores keep the tests isolated.
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

  /// Records each replay and returns a scripted outcome. Optionally runs a hook on
  /// each replay (e.g. to fire a Discard mid-flight) and reports whether the
  /// coordinator's `isAborted` closure read true at that point.
  private final class FakeReplayer: RecoverySpoolReplaying {
    var replayedIDs: [String] = []
    var isRecoveringDuringReplay: [Bool] = []
    var abortedSeen: [Bool] = []
    var outcomeByDefault: RecoveryReplayOutcome = .recovered
    var onReplay: ((String) -> Void)?
    /// When true, the FIRST replay suspends on a continuation until the test
    /// resumes it — so the test can run a second scan while one is genuinely
    /// in-flight (exercising single-flight).
    var suspendFirstReplay = false
    var gateContinuation: CheckedContinuation<Void, Never>?
    private let isRecoveringProbe: () -> Bool

    init(isRecoveringProbe: @escaping () -> Bool) {
      self.isRecoveringProbe = isRecoveringProbe
    }

    func replay(recoverySessionID id: String, isAborted: @MainActor () -> Bool) async
      -> RecoveryReplayOutcome
    {
      replayedIDs.append(id)
      isRecoveringDuringReplay.append(isRecoveringProbe())
      if suspendFirstReplay && replayedIDs.count == 1 {
        await withCheckedContinuation { gateContinuation = $0 }
      }
      onReplay?(id)
      let aborted = isAborted()
      abortedSeen.append(aborted)
      return aborted ? .aborted : outcomeByDefault
    }
  }

  private struct Harness {
    let coordinator: RecoveryCoordinator
    let keyStore: RecoveryKeyStore
    let spoolStore: RecoverySpoolStore
    let replayer: FakeReplayer
    let resetEngineCount: Box<Int>
  }

  /// `existing` and `dictationActive` are boxed so a test can mutate them after
  /// construction; the closures capture the boxes.
  private final class Box<T> {
    var value: T
    init(_ v: T) { value = v }
  }

  private static func makeHarness(
    existing: Set<String> = [],
    dictationActive: Bool = false
  ) -> Harness {
    let keyStore = RecoveryKeyStore(backend: .file, fileDirectory: tempDir())
    let spoolDir = tempDir()
    let existingBox = Box(existing)
    let activeBox = Box(dictationActive)
    let resetEngineCount = Box(0)
    // The probe needs the coordinator, set after construction.
    var coordinatorRef: RecoveryCoordinator?
    let replayer = FakeReplayer(isRecoveringProbe: { coordinatorRef?.isRecovering ?? false })
    let coordinator = RecoveryCoordinator(
      keyStore: keyStore,
      makeSpoolStore: { RecoverySpoolStore(directory: spoolDir) },
      replayer: replayer,
      existingRecoveryIDs: { existingBox.value },
      isDictationActive: { activeBox.value },
      resetEngine: { resetEngineCount.value += 1 })
    coordinatorRef = coordinator
    return Harness(
      coordinator: coordinator, keyStore: keyStore,
      spoolStore: RecoverySpoolStore(directory: spoolDir), replayer: replayer,
      resetEngineCount: resetEngineCount)
  }

  private static func writeSpool(_ store: RecoverySpoolStore, _ id: String) throws {
    try Data([1, 2, 3]).write(to: store.spoolURL(for: id))
  }

  // MARK: - Arm + durable save (PR1 behavior, unchanged)

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
    #expect(directive.settingsSnapshot.backendType == .whisperKit)
    let storedKey = try h.keyStore.retrieve(for: armed.recoverySessionID)
    #expect(storedKey == directive.keyData)
  }

  @Test("durable save deletes that session's spool + key")
  func durableSaveDeletes() async throws {
    let h = Self.makeHarness()
    let id = "session-\(UUID().uuidString)"
    try Self.writeSpool(h.spoolStore, id)
    try h.keyStore.store(keyData: RecoveryKeyStore.makeKey(), for: id)
    await h.coordinator.handleDurableSave(recoverySessionID: id).value
    #expect(!FileManager.default.fileExists(atPath: h.spoolStore.spoolURL(for: id).path))
    #expect(throws: RecoveryKeyStoreError.notFound) { try h.keyStore.retrieve(for: id) }
  }

  // MARK: - Non-saved terminal routing (#1464 live-ending predicate)

  @Test("a delete ending (discard/no-speech/user-cancel) deletes the spool + key")
  func discardTerminalDeletes() async throws {
    let h = Self.makeHarness()
    for ending in [RecordingRecoveryEnding.discarded, .noSpeech, .cancelled(.user)] {
      let id = "del-\(UUID().uuidString)"
      try Self.writeSpool(h.spoolStore, id)
      try h.keyStore.store(keyData: RecoveryKeyStore.makeKey(), for: id)
      await h.coordinator.handleRecordingEndedWithoutDurableSave(
        recoverySessionID: id, ending: ending)?.value
      #expect(
        !FileManager.default.fileExists(atPath: h.spoolStore.spoolURL(for: id).path),
        "\(ending) should delete the spool")
      #expect(throws: RecoveryKeyStoreError.notFound) { try h.keyStore.retrieve(for: id) }
    }
  }

  @Test("a retain ending (fault / system-cancel) RETAINS the spool + key")
  func failureTerminalRetains() async throws {
    let h = Self.makeHarness()
    let retainEndings: [RecordingRecoveryEnding] = [
      .failed, .audioInterrupted, .asrInterrupted, .noTransport, .cancelled(.systemOrFault),
    ]
    for ending in retainEndings {
      let id = "keep-\(UUID().uuidString)"
      try Self.writeSpool(h.spoolStore, id)
      try h.keyStore.store(keyData: RecoveryKeyStore.makeKey(), for: id)
      let task = h.coordinator.handleRecordingEndedWithoutDurableSave(
        recoverySessionID: id, ending: ending)
      #expect(task == nil, "\(ending) retains — no delete work")
      #expect(FileManager.default.fileExists(atPath: h.spoolStore.spoolURL(for: id).path))
      #expect((try? h.keyStore.retrieve(for: id)) != nil)
    }
  }

  @Test("non-saved cleanup is a no-op when id is nil")
  func endedWithoutSaveNoopWhenNil() async {
    let h = Self.makeHarness()
    #expect(
      h.coordinator.handleRecordingEndedWithoutDurableSave(
        recoverySessionID: nil, ending: .discarded) == nil)
  }

  // MARK: - #1464 delete/retain predicates (adversarial: every case in both classes)

  @Test("shouldDeleteOnLiveEnding: delete endings delete, retain endings retain")
  func liveEndingPredicate() {
    #expect(RecoveryCoordinator.shouldDeleteOnLiveEnding(.discarded))
    #expect(RecoveryCoordinator.shouldDeleteOnLiveEnding(.noSpeech))
    #expect(RecoveryCoordinator.shouldDeleteOnLiveEnding(.cancelled(.user)))
    #expect(!RecoveryCoordinator.shouldDeleteOnLiveEnding(.failed))
    #expect(!RecoveryCoordinator.shouldDeleteOnLiveEnding(.audioInterrupted))
    #expect(!RecoveryCoordinator.shouldDeleteOnLiveEnding(.asrInterrupted))
    #expect(!RecoveryCoordinator.shouldDeleteOnLiveEnding(.noTransport))
    #expect(!RecoveryCoordinator.shouldDeleteOnLiveEnding(.cancelled(.systemOrFault)))
  }

  @Test(
    "shouldDeleteAfterReplay: recovered/abandoned/unrecoverable delete; save/aborted/deferred retain"
  )
  func replayOutcomePredicate() {
    #expect(RecoveryCoordinator.shouldDeleteAfterReplay(.recovered))
    #expect(RecoveryCoordinator.shouldDeleteAfterReplay(.abandoned))
    #expect(RecoveryCoordinator.shouldDeleteAfterReplay(.failed(.unrecoverable)))
    #expect(!RecoveryCoordinator.shouldDeleteAfterReplay(.failed(.save(.other))))
    #expect(!RecoveryCoordinator.shouldDeleteAfterReplay(.failed(.saveMarkerClearFailed(.other))))
    #expect(!RecoveryCoordinator.shouldDeleteAfterReplay(.aborted))
    #expect(!RecoveryCoordinator.shouldDeleteAfterReplay(.deferred))
  }

  // MARK: - #1464 sole destructor: post-replay deletion + success notice + pre-start abort

  /// The key delete is detached; poll on the OBSERVABLE signal (key gone) with a
  /// bounded deadline — the same idiom the key-only-sweep tests below use. The loop
  /// condition IS the signal; the sleep is only the poll interval.
  private static func awaitKeyDeleted(_ keyStore: RecoveryKeyStore, id: String) async {
    for _ in 0..<200 where (try? keyStore.retrieve(for: id)) != nil {
      try? await Task.sleep(for: .milliseconds(5))  // settle: poll interval; loop cond is the signal
    }
  }

  @Test("the coordinator deletes the spool + key after a .recovered replay")
  func recoveredReplayDeletes() async throws {
    let h = Self.makeHarness()
    let id = "rec-\(UUID().uuidString)"
    try Self.writeSpool(h.spoolStore, id)
    try h.keyStore.store(keyData: RecoveryKeyStore.makeKey(), for: id)
    h.replayer.outcomeByDefault = .recovered
    await h.coordinator.scanAndRecover()
    await Self.awaitKeyDeleted(h.keyStore, id: id)
    #expect(!FileManager.default.fileExists(atPath: h.spoolStore.spoolURL(for: id).path))
    #expect(throws: RecoveryKeyStoreError.notFound) { try h.keyStore.retrieve(for: id) }
  }

  @Test("the coordinator deletes after an unrecoverable replay")
  func unrecoverableReplayDeletes() async throws {
    let h = Self.makeHarness()
    let id = "unrec-\(UUID().uuidString)"
    try Self.writeSpool(h.spoolStore, id)
    try h.keyStore.store(keyData: RecoveryKeyStore.makeKey(), for: id)
    h.replayer.outcomeByDefault = .failed(.unrecoverable)
    await h.coordinator.scanAndRecover()
    await Self.awaitKeyDeleted(h.keyStore, id: id)
    #expect(!FileManager.default.fileExists(atPath: h.spoolStore.spoolURL(for: id).path))
    #expect(throws: RecoveryKeyStoreError.notFound) { try h.keyStore.retrieve(for: id) }
  }

  @Test("the coordinator RETAINS the spool + key after a save-failure replay (§3.3)")
  func saveFailureReplayRetains() async throws {
    let h = Self.makeHarness()
    let id = "save-\(UUID().uuidString)"
    try Self.writeSpool(h.spoolStore, id)
    try h.keyStore.store(keyData: RecoveryKeyStore.makeKey(), for: id)
    h.replayer.outcomeByDefault = .failed(.save(.other))
    await h.coordinator.scanAndRecover()
    #expect(
      FileManager.default.fileExists(atPath: h.spoolStore.spoolURL(for: id).path),
      "a History-save failure retains the spool for next-launch retry")
    #expect((try? h.keyStore.retrieve(for: id)) != nil, "and retains the key")
  }

  @Test("onRecoverySucceeded fires once per .recovered orphan, never on failure")
  func successCallbackFires() async throws {
    let h = Self.makeHarness()
    var successCount = 0
    h.coordinator.onRecoverySucceeded = { successCount += 1 }
    try Self.writeSpool(h.spoolStore, "s-\(UUID().uuidString)")
    h.replayer.outcomeByDefault = .recovered
    await h.coordinator.scanAndRecover()
    #expect(successCount == 1, "recovered ⇒ one success notice")

    let h2 = Self.makeHarness()
    var failCount = 0
    h2.coordinator.onRecoverySucceeded = { failCount += 1 }
    try Self.writeSpool(h2.spoolStore, "f-\(UUID().uuidString)")
    h2.replayer.outcomeByDefault = .failed(.unrecoverable)
    await h2.coordinator.scanAndRecover()
    #expect(failCount == 0, "a failed recovery posts no success notice")
  }

  @Test("pre-start abort deletes the just-armed spool + key")
  func preStartAbortDeletes() async throws {
    let h = Self.makeHarness()
    let id = "abort-\(UUID().uuidString)"
    try Self.writeSpool(h.spoolStore, id)
    try h.keyStore.store(keyData: RecoveryKeyStore.makeKey(), for: id)
    await h.coordinator.handlePreStartAbort(recoverySessionID: id)?.value
    #expect(!FileManager.default.fileExists(atPath: h.spoolStore.spoolURL(for: id).path))
    #expect(throws: RecoveryKeyStoreError.notFound) { try h.keyStore.retrieve(for: id) }
  }

  @Test("pre-start abort is a no-op when id is nil")
  func preStartAbortNoopWhenNil() {
    let h = Self.makeHarness()
    #expect(h.coordinator.handlePreStartAbort(recoverySessionID: nil) == nil)
  }

  // MARK: - Launch scan + recover

  @Test("scan replays every recoverable orphan, gate ends cleared")
  func scanReplaysOrphans() async throws {
    let h = Self.makeHarness()
    let ids = ["a-\(UUID().uuidString)", "b-\(UUID().uuidString)"]
    for id in ids { try Self.writeSpool(h.spoolStore, id) }
    await h.coordinator.scanAndRecover()
    #expect(Set(h.replayer.replayedIDs) == Set(ids))
    #expect(h.replayer.isRecoveringDuringReplay.allSatisfy { $0 }, "gate held during each replay")
    #expect(!h.coordinator.isRecovering, "defer clears the gate on completion (R1)")
  }

  @Test("no orphans ⇒ no replay, gate never set")
  func scanNoOrphans() async {
    let h = Self.makeHarness()
    await h.coordinator.scanAndRecover()
    #expect(h.replayer.replayedIDs.isEmpty)
    #expect(!h.coordinator.isRecovering)
  }

  @Test("dedup: an orphan already in History is deleted WITHOUT re-transcribing")
  func scanDedupsAlreadySaved() async throws {
    let saved = "saved-\(UUID().uuidString)"
    let fresh = "fresh-\(UUID().uuidString)"
    let h = Self.makeHarness(existing: [saved])
    try Self.writeSpool(h.spoolStore, saved)
    try h.keyStore.store(keyData: RecoveryKeyStore.makeKey(), for: saved)
    try Self.writeSpool(h.spoolStore, fresh)
    await h.coordinator.scanAndRecover()
    #expect(h.replayer.replayedIDs == [fresh], "saved id deduped, not replayed")
    #expect(
      !FileManager.default.fileExists(atPath: h.spoolStore.spoolURL(for: saved).path),
      "deduped orphan deleted")
  }

  @Test("scan PROTECTS the live armed session (never replays it)")
  func scanProtectsArmed() async throws {
    let h = Self.makeHarness()
    let armed = try #require(
      await h.coordinator.makeDirective(
        settings: Self.freshSettings(crashRecoveryEnabled: true),
        backendType: .parakeet, supportsLanguageDetection: false))
    try Self.writeSpool(h.spoolStore, armed.recoverySessionID)
    let orphan = "orphan-\(UUID().uuidString)"
    try Self.writeSpool(h.spoolStore, orphan)
    await h.coordinator.scanAndRecover()
    #expect(h.replayer.replayedIDs == [orphan])
    #expect(
      FileManager.default.fileExists(
        atPath: h.spoolStore.spoolURL(for: armed.recoverySessionID).path),
      "armed live session's spool survives the scan")
  }

  @Test("contention guard: a live dictation defers recovery (no replay, gate stays off)")
  func scanDefersWhenDictationActive() async throws {
    let h = Self.makeHarness(dictationActive: true)
    try Self.writeSpool(h.spoolStore, "orphan-\(UUID().uuidString)")
    await h.coordinator.scanAndRecover()
    #expect(h.replayer.replayedIDs.isEmpty, "never run the shared engine during a live take")
    #expect(!h.coordinator.isRecovering)
  }

  @Test("gate ends cleared even when every orphan fails (defer backstop, R1)")
  func scanGateClearedOnAllFailures() async throws {
    let h = Self.makeHarness()
    h.replayer.outcomeByDefault = .failed(.unrecoverable)
    try Self.writeSpool(h.spoolStore, "orphan-\(UUID().uuidString)")
    await h.coordinator.scanAndRecover()
    #expect(!h.coordinator.isRecovering)
  }

  @Test("single-flight: a scan started while another is in-flight is rejected")
  func scanSingleFlight() async throws {
    let h = Self.makeHarness()
    let id = "orphan-\(UUID().uuidString)"
    try Self.writeSpool(h.spoolStore, id)
    h.replayer.suspendFirstReplay = true
    // Start the first scan; it suspends mid-replay (gate held), so it is genuinely
    // in-flight when the second scan runs.
    let first = Task { await h.coordinator.scanAndRecover() }
    while h.replayer.gateContinuation == nil { await Task.yield() }
    // A second scan now must be rejected by the single-flight guard.
    await h.coordinator.scanAndRecover()
    // Release the first scan and let it finish.
    h.replayer.gateContinuation?.resume()
    await first.value
    #expect(h.replayer.replayedIDs == [id], "orphan replayed exactly once")
  }

  // MARK: - Discard

  @Test("Discard mid-recovery bumps the generation, frees the gate, and deletes the orphan")
  func discardDuringRecovery() async throws {
    let h = Self.makeHarness()
    let id = "orphan-\(UUID().uuidString)"
    try Self.writeSpool(h.spoolStore, id)
    try h.keyStore.store(keyData: RecoveryKeyStore.makeKey(), for: id)
    // Simulate the user hitting Discard WHILE this orphan is mid-replay.
    h.replayer.onReplay = { [coordinator = h.coordinator] _ in
      coordinator.discardActiveRecovery()
    }
    await h.coordinator.scanAndRecover()
    // The replay saw the post-discard generation bump → reported aborted.
    #expect(h.replayer.abortedSeen == [true], "isAborted read true after Discard bumped generation")
    #expect(!h.coordinator.isRecovering, "gate cleared")
    #expect(h.resetEngineCount.value == 1, "Discard hard-reset the shared engine")
    #expect(
      !FileManager.default.fileExists(atPath: h.spoolStore.spoolURL(for: id).path),
      "Discard deleted the orphan the user was waiting on")
  }

  @Test("Discard resets the engine; the gate clears when the replay returns (founder fix + r6 P2)")
  func discardResetsEngineAndClearsGateWhenReplayReturns() async throws {
    let h = Self.makeHarness()
    let id = "inflight-\(UUID().uuidString)"
    try Self.writeSpool(h.spoolStore, id)
    try h.keyStore.store(keyData: RecoveryKeyStore.makeKey(), for: id)
    h.replayer.suspendFirstReplay = true
    // The replay is genuinely in flight (suspended) — modelling the shared engine
    // still busy (e.g. the in-process backend whose transcribe can't be killed).
    let first = Task { await h.coordinator.scanAndRecover() }
    while h.replayer.gateContinuation == nil { await Task.yield() }
    #expect(h.coordinator.isRecovering, "gate closed while the replay holds the engine")

    h.coordinator.discardActiveRecovery()

    // Discard hard-resets the engine immediately. The gate stays closed until the
    // replay returns — so a backend whose work the reset can't kill never contends
    // (r6 P2). (For the default out-of-process engine the reset kills the call, so
    // the replay returns almost at once and this window is ~instant in production.)
    #expect(h.resetEngineCount.value == 1, "Discard hard-reset the engine")
    #expect(h.coordinator.isRecovering, "gate stays closed until the engine is actually free")
    h.replayer.gateContinuation?.resume()
    await first.value
    #expect(!h.coordinator.isRecovering, "gate opens once the replay returns (engine free)")
  }

  @Test("scan sweeps a key-only orphan (a key whose spool was never written, P2)")
  func scanSweepsKeyOnlyOrphan() async throws {
    let h = Self.makeHarness()
    let id = "keyonly-\(UUID().uuidString)"
    try h.keyStore.store(keyData: RecoveryKeyStore.makeKey(), for: id)
    // No spool file for this id — the spool scan can't see it.
    await h.coordinator.scanAndRecover()
    // The sweep is detached; wait briefly for it to drain.
    for _ in 0..<200 where (try? h.keyStore.retrieve(for: id)) != nil {
      try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(throws: RecoveryKeyStoreError.notFound) { try h.keyStore.retrieve(for: id) }
    #expect(h.replayer.replayedIDs.isEmpty, "no spool ⇒ nothing to replay")
  }

  @Test("the key-only sweep PROTECTS the live armed session's key (P2 race-safety)")
  func keySweepProtectsArmedKey() async throws {
    let h = Self.makeHarness()
    // A live recording armed but no spool yet (the helper hasn't written a frame).
    let armed = try #require(
      await h.coordinator.makeDirective(
        settings: Self.freshSettings(crashRecoveryEnabled: true),
        backendType: .parakeet, supportsLanguageDetection: false))
    // A genuine key-only orphan from a prior run.
    let orphan = "orphan-\(UUID().uuidString)"
    try h.keyStore.store(keyData: RecoveryKeyStore.makeKey(), for: orphan)
    await h.coordinator.scanAndRecover()
    for _ in 0..<200 where (try? h.keyStore.retrieve(for: orphan)) != nil {
      try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(throws: RecoveryKeyStoreError.notFound) { try h.keyStore.retrieve(for: orphan) }
    #expect(
      (try? h.keyStore.retrieve(for: armed.recoverySessionID)) != nil,
      "the live armed recording's key must survive the sweep (else it's unrecoverable)")
  }

  @Test("key sweep protects a FAILURE spool that appeared AFTER the scan snapshot (r4 P2)")
  func keySweepProtectsLateFailureSpool() async throws {
    let h = Self.makeHarness()
    let recoverable = "orphan-\(UUID().uuidString)"
    try Self.writeSpool(h.spoolStore, recoverable)
    try h.keyStore.store(keyData: RecoveryKeyStore.makeKey(), for: recoverable)
    // A key-only orphan that the sweep WILL delete — its disappearance signals the
    // detached sweep has run, so the assertions below aren't racing it.
    let sentinel = "sentinel-\(UUID().uuidString)"
    try h.keyStore.store(keyData: RecoveryKeyStore.makeKey(), for: sentinel)
    // During the recoverable orphan's replay, simulate a NEW recording that armed
    // and ended at a FAILURE terminal — its spool + key appear AFTER the scan's
    // spool snapshot. The stale-snapshot sweep would delete its key; the fresh
    // re-list must protect it.
    let lateFailure = "late-failure-\(UUID().uuidString)"
    h.replayer.onReplay = { _ in
      try? Data([9]).write(to: h.spoolStore.spoolURL(for: lateFailure))
      try? h.keyStore.store(keyData: RecoveryKeyStore.makeKey(), for: lateFailure)
    }
    await h.coordinator.scanAndRecover()
    for _ in 0..<200 where (try? h.keyStore.retrieve(for: sentinel)) != nil {
      try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(throws: RecoveryKeyStoreError.notFound) { try h.keyStore.retrieve(for: sentinel) }
    #expect(
      (try? h.keyStore.retrieve(for: lateFailure)) != nil,
      "a failure spool retained after the scan snapshot keeps its key (else undecryptable)")
  }

  @Test("Discard is a no-op when nothing is recovering")
  func discardNoopWhenIdle() {
    let h = Self.makeHarness()
    h.coordinator.discardActiveRecovery()
    #expect(!h.coordinator.isRecovering)
  }

  @Test("a key-store failure leaves nothing armed")
  func storeFailureLeavesNothingArmed() async throws {
    let parentFile = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-key-parent-\(UUID().uuidString)")
    try Data([0]).write(to: parentFile)
    let unwritableDir = parentFile.appendingPathComponent("keys", isDirectory: true)
    let keyStore = RecoveryKeyStore(backend: .file, fileDirectory: unwritableDir)
    let spoolDir = Self.tempDir()
    let replayer = FakeReplayer(isRecoveringProbe: { false })
    let coordinator = RecoveryCoordinator(
      keyStore: keyStore,
      makeSpoolStore: { RecoverySpoolStore(directory: spoolDir) },
      replayer: replayer,
      existingRecoveryIDs: { [] },
      isDictationActive: { false })
    let result = await coordinator.makeDirective(
      settings: Self.freshSettings(crashRecoveryEnabled: true),
      backendType: .parakeet, supportsLanguageDetection: false)
    #expect(result == nil, "a failed durable key store disables recovery for the take")
    #expect(
      coordinator.handleRecordingEndedWithoutDurableSave(
        recoverySessionID: nil, ending: .discarded) == nil)
  }
}
