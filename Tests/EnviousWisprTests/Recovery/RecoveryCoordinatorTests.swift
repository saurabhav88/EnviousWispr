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
    /// #1707 Phase 3 — per-id scripted outcome, taking precedence over
    /// `outcomeByDefault` when present (for multi-item scans where different
    /// orphans need different outcomes).
    var outcomeByID: [String: RecoveryReplayOutcome] = [:]
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
      return aborted ? .aborted : (outcomeByID[id] ?? outcomeByDefault)
    }
  }

  private struct Harness {
    let coordinator: RecoveryCoordinator
    let keyStore: RecoveryKeyStore
    let spoolStore: RecoverySpoolStore
    let replayer: FakeReplayer
    let resetEngineCount: Box<Int>
    /// Exposed so a test can flip live-dictation-active state AFTER
    /// construction (e.g. from a concurrently-spawned Task simulating a live
    /// press that mints its own session mid-scan).
    let dictationActiveBox: Box<Bool>
  }

  /// `existing` and `dictationActive` are boxed so a test can mutate them after
  /// construction; the closures capture the boxes.
  private final class Box<T> {
    var value: T
    init(_ v: T) { value = v }
  }

  private static func makeHarness(
    existing: Set<String> = [],
    dictationActive: Bool = false,
    recoveryEngineClaim: RecoveryEngineClaim = .alwaysAllowedForTesting
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
      recoveryEngineClaim: recoveryEngineClaim,
      resetEngine: { resetEngineCount.value += 1 })
    coordinatorRef = coordinator
    return Harness(
      coordinator: coordinator, keyStore: keyStore,
      spoolStore: RecoverySpoolStore(directory: spoolDir), replayer: replayer,
      resetEngineCount: resetEngineCount, dictationActiveBox: activeBox)
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
    // #1707 Phase 2: an exhausted Phase-2 retry deletes its spool (the
    // decode genuinely never produced anything); a pre-capture / never-
    // retried `.failed` (plain, no retry consulted) still retains — the
    // negative half of this same adversarial pair.
    #expect(RecoveryCoordinator.shouldDeleteOnLiveEnding(.asrRetryExhausted))
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

  // MARK: - #1707 Phase 3: nextLaunchOnlyRecoveryIDs

  @Test(
    ".deferredMarkerClearFailed and .failed(.saveMarkerClearFailed) both suppress same-launch rescan"
  )
  func markerClearFailureOutcomesSuppressSameLaunchRescan() async throws {
    let h = Self.makeHarness()
    let deferredID = "deferred-markerfail-\(UUID().uuidString)"
    let saveID = "save-markerfail-\(UUID().uuidString)"
    try Self.writeSpool(h.spoolStore, deferredID)
    try Self.writeSpool(h.spoolStore, saveID)
    h.replayer.outcomeByID[deferredID] = .deferredMarkerClearFailed
    h.replayer.outcomeByID[saveID] = .failed(.saveMarkerClearFailed(.other))
    await h.coordinator.scanAndRecover()
    #expect(Set(h.replayer.replayedIDs) == Set([deferredID, saveID]))
    // Both outcomes RETAIN — neither spool is deleted.
    #expect(FileManager.default.fileExists(atPath: h.spoolStore.spoolURL(for: deferredID).path))
    #expect(FileManager.default.fileExists(atPath: h.spoolStore.spoolURL(for: saveID).path))
    // A same-launch rescan (the SAME coordinator instance) must not re-attempt
    // either id — they are next-launch-only.
    h.replayer.replayedIDs = []
    await h.coordinator.scanAndRecover()
    #expect(h.replayer.replayedIDs.isEmpty, "both ids suppressed on this instance's rescan")
  }

  @Test("nextLaunchOnlyRecoveryIDs is never cleared within one coordinator instance's lifetime")
  func nextLaunchOnlyIDsNeverClearedOnSameInstance() async throws {
    let h = Self.makeHarness()
    let id = "persist-\(UUID().uuidString)"
    try Self.writeSpool(h.spoolStore, id)
    h.replayer.outcomeByID[id] = .deferredMarkerClearFailed
    await h.coordinator.scanAndRecover()
    #expect(h.replayer.replayedIDs == [id])
    // Repeated rescans on the SAME instance never re-attempt it.
    for _ in 0..<3 {
      h.replayer.replayedIDs = []
      await h.coordinator.scanAndRecover()
      #expect(h.replayer.replayedIDs.isEmpty)
    }
  }

  @Test(
    "a live recording's own retained failure is excluded from THIS SAME session's wake-up rescan"
  )
  func retainedLiveFailureExcludedFromSameSessionRescan() async throws {
    // GitHub cloud review, PR #1732: `onDictationEndedForRecovery` fires right
    // after a live recording ends. For a RETAIN ending, the engine may still be
    // in the exact broken state that produced the failure — a same-launch
    // rescan must not immediately re-attempt (and potentially delete) the very
    // spool this ending just retained.
    let h = Self.makeHarness()
    let id = "live-fail-\(UUID().uuidString)"
    try Self.writeSpool(h.spoolStore, id)
    // `.failed` is a RETAIN-kind ending (`shouldDeleteOnLiveEnding` returns
    // false) — mirrors the live driver calling this on a genuine failure.
    h.coordinator.handleRecordingEndedWithoutDurableSave(recoverySessionID: id, ending: .failed)
    #expect(
      FileManager.default.fileExists(atPath: h.spoolStore.spoolURL(for: id).path),
      "a retain ending never deletes")
    // If the engine were still broken, a replay attempt here would fail again.
    h.replayer.outcomeByID[id] = .failed(.unrecoverable)
    // The SAME session's own wake-up call — must not touch `id` this pass.
    h.coordinator.requestRecoveryRecheck()
    for _ in 0..<20 {
      try? await Task.sleep(for: .milliseconds(5))  // settle: bounded drain to let any spurious replay run
    }
    #expect(
      h.replayer.replayedIDs.isEmpty,
      "the just-retained id must not be re-attempted by this same session's own rescan")
    #expect(
      FileManager.default.fileExists(atPath: h.spoolStore.spoolURL(for: id).path),
      "still on disk — not destroyed by a same-launch replay of the just-retained spool")
  }

  @Test("a FRESH coordinator instance (a genuine new launch) starts with an empty suppression set")
  func freshInstanceStartsEmpty() async throws {
    let h = Self.makeHarness()
    let id = "newlaunch-\(UUID().uuidString)"
    try Self.writeSpool(h.spoolStore, id)
    h.replayer.outcomeByID[id] = .deferredMarkerClearFailed
    await h.coordinator.scanAndRecover()
    #expect(h.replayer.replayedIDs == [id])
    // A genuinely NEW launch constructs a fresh coordinator (and fresh
    // replayer) — the suppression set is per-instance, not persisted.
    let h2 = Self.makeHarness()
    try Self.writeSpool(h2.spoolStore, id)
    h2.replayer.outcomeByDefault = .recovered
    await h2.coordinator.scanAndRecover()
    #expect(
      h2.replayer.replayedIDs == [id], "a fresh instance re-attempts a previously-suppressed id")
  }

  // MARK: - #1707 Phase 3 §3.1: live-dictation-preempts-recovery-between-items

  @Test(
    "a pending live-start signal observed mid-scan yields the engine BETWEEN items — item 2 is never attempted"
  )
  func pendingLiveStartYieldsBetweenItems() async throws {
    let h = Self.makeHarness()
    let first = "first-\(UUID().uuidString)"
    let second = "second-\(UUID().uuidString)"
    try Self.writeSpool(h.spoolStore, first)
    try Self.writeSpool(h.spoolStore, second)
    // Simulate `RecordingStarter`'s refusal path firing WHILE item 1 replays.
    h.replayer.onReplay = { [coordinator = h.coordinator] id in
      if id == first { coordinator.pendingLiveStartSignal = true }
    }
    await h.coordinator.scanAndRecover()
    #expect(h.replayer.replayedIDs == [first], "item 2 never attempted — the scan yielded first")
    #expect(!h.coordinator.isRecovering, "the gate is clear after yielding")
    #expect(
      FileManager.default.fileExists(atPath: h.spoolStore.spoolURL(for: second).path),
      "the un-attempted second orphan stays on disk for the next trigger")
  }

  @Test(
    "a live-start signal observed during the LAST item's replay still yields — a concurrent wake-up does not immediately reclaim the engine"
  )
  func pendingLiveStartYieldsAfterFinalItem() async throws {
    // GitHub cloud review, PR #1732: the top-of-loop guard only catches a
    // live-start signal if there is a NEXT item to check it before. A signal
    // arriving during the LAST item's replay had no such checkpoint, so if an
    // UNRELATED wake-up cause also fires during that same window (setting
    // `pendingRescan`, coalesced since a scan is already in progress),
    // `drainPendingRescan()` would immediately run another pass — whose own
    // per-pass reset clears the signal and reclaims the engine right after
    // refusing the user's press, before their retry gets a chance.
    let h = Self.makeHarness()
    let first = "first-\(UUID().uuidString)"
    let second = "second-\(UUID().uuidString)"
    try Self.writeSpool(h.spoolStore, first)
    try Self.writeSpool(h.spoolStore, second)
    // `second` is RETAINED (not deleted) so it would still be on disk for an
    // improper immediate re-pass to (incorrectly) rediscover and re-attempt.
    h.replayer.outcomeByID[second] = .failed(.save(.other))
    h.replayer.onReplay = { [coordinator = h.coordinator] id in
      if id == second {
        coordinator.pendingLiveStartSignal = true
        // Simulate an unrelated wake-up cause firing in the same window.
        coordinator.requestRecoveryRecheck()
      }
    }
    await h.coordinator.scanAndRecover()
    #expect(
      h.replayer.replayedIDs == [first, second],
      "each real orphan attempted exactly once — no improper immediate re-pass")
    #expect(!h.coordinator.isRecovering, "the gate is clear after yielding")
    #expect(
      FileManager.default.fileExists(atPath: h.spoolStore.spoolURL(for: second).path),
      "the retained second orphan stays on disk for the next real trigger")
  }

  @Test(
    "a fresh record-press queued exactly at the item boundary gets a genuine scheduling turn before the next item re-claims the engine (GitHub cloud review, PR #1732)"
  )
  func freshPressAtItemBoundaryGetsScheduledBeforeNextClaim() async throws {
    // Between one item's `defer` (isRecovering -> false) and the next item's
    // own claim, nothing suspended in the OLD code — so a record-press Task
    // queued exactly then never got an actual scheduling turn to observe
    // `isRecovering == false` (Swift's MainActor only switches tasks at a
    // real suspension point). The fix adds `await Task.yield()` at the top
    // of each iteration so such a press gets its turn first. Modeled here as
    // a Task spawned during item 1's replay that flips `isDictationActive`
    // — simulating a live press that mints its own session — with NO
    // internal yield of its own, so it is immediately ready to run the
    // moment the coordinator's own Task next suspends.
    let h = Self.makeHarness()
    let first = "first-\(UUID().uuidString)"
    let second = "second-\(UUID().uuidString)"
    try Self.writeSpool(h.spoolStore, first)
    try Self.writeSpool(h.spoolStore, second)
    h.replayer.onReplay = { [dictationActiveBox = h.dictationActiveBox] id in
      if id == first {
        Task { @MainActor in
          dictationActiveBox.value = true
        }
      }
    }
    await h.coordinator.scanAndRecover()
    #expect(
      h.replayer.replayedIDs == [first],
      "item 2 must never be attempted — the queued press's Task got a real turn at the yield and minted its own session before item 2's claim"
    )
    #expect(!h.coordinator.isRecovering, "the gate is clear after deferring")
    #expect(
      FileManager.default.fileExists(atPath: h.spoolStore.spoolURL(for: second).path),
      "the un-attempted second orphan stays on disk for the next trigger")
  }

  @Test("pendingLiveStartSignal is cleared entering the next fresh scan pass")
  func pendingLiveStartClearedOnNextPass() async throws {
    let h = Self.makeHarness()
    let first = "first-\(UUID().uuidString)"
    let second = "second-\(UUID().uuidString)"
    try Self.writeSpool(h.spoolStore, first)
    try Self.writeSpool(h.spoolStore, second)
    // A RETAINED (not deleted) outcome for `first`, so it is still on disk
    // for pass 2 — isolating the assertion to the signal-clearing behavior,
    // not to whether a successfully-recovered item gets deleted.
    h.replayer.outcomeByID[first] = .failed(.save(.other))
    h.replayer.onReplay = { [coordinator = h.coordinator] id in
      if id == first { coordinator.pendingLiveStartSignal = true }
    }
    await h.coordinator.scanAndRecover()
    #expect(h.replayer.replayedIDs == [first])
    // A later wake-up (e.g. the live dictation ending) triggers a fresh pass.
    // The stale signal from the PRIOR pass must not spuriously yield this one.
    h.replayer.onReplay = nil
    h.replayer.replayedIDs = []
    await h.coordinator.scanAndRecover()
    #expect(
      Set(h.replayer.replayedIDs) == Set([first, second]),
      "a fresh pass re-attempts both remaining orphans — the prior signal is cleared, not stale")
  }

  // MARK: - #1707 Phase 3 §3.2: EngineRecoveryGate integration

  @Test("a mutation claim held on the gate defers the ENTIRE scan — no item is attempted")
  func gateDeniedRecoveryDefersWholeScan() async throws {
    let gate = EngineRecoveryGate()
    let h = Self.makeHarness(
      recoveryEngineClaim: .live(
        tryBegin: { gate.tryBeginRecovery() }, end: { gate.endRecovery() }))
    #expect(gate.tryBeginMutation(), "an unrelated engine mutation holds the gate")
    try Self.writeSpool(h.spoolStore, "orphan-\(UUID().uuidString)")
    await h.coordinator.scanAndRecover()
    #expect(
      h.replayer.replayedIDs.isEmpty, "the gate denied the claim before any item was attempted")
    #expect(!h.coordinator.isRecovering)
  }

  @Test("once the held mutation releases, requestRecoveryRecheck() lets the deferred scan succeed")
  func gateReleaseThenRequestRecheckSucceeds() async throws {
    let gate = EngineRecoveryGate()
    let h = Self.makeHarness(
      recoveryEngineClaim: .live(
        tryBegin: { gate.tryBeginRecovery() }, end: { gate.endRecovery() }))
    #expect(gate.tryBeginMutation())
    let id = "orphan-\(UUID().uuidString)"
    try Self.writeSpool(h.spoolStore, id)
    await h.coordinator.scanAndRecover()
    #expect(h.replayer.replayedIDs.isEmpty, "denied while the mutation is held")
    // The mutation releases — recovery was owed a retry (§3.2's `recoveryRetryOwed`).
    #expect(gate.endMutation() == true)
    h.coordinator.requestRecoveryRecheck()
    // `requestRecoveryRecheck()` spawns its drain asynchronously — poll the
    // real signal (`replayedIDs` becoming non-empty), backing off between
    // checks rather than waiting a fixed duration.
    for _ in 0..<200 where h.replayer.replayedIDs.isEmpty {
      try? await Task.sleep(for: .milliseconds(5))  // settle: bounded poll backoff, not a fixed wait
    }
    #expect(h.replayer.replayedIDs == [id], "the deferred scan succeeded once the gate opened")
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
      isDictationActive: { false },
      recoveryEngineClaim: .alwaysAllowedForTesting)
    let result = await coordinator.makeDirective(
      settings: Self.freshSettings(crashRecoveryEnabled: true),
      backendType: .parakeet, supportsLanguageDetection: false)
    #expect(result == nil, "a failed durable key store disables recovery for the take")
    #expect(
      coordinator.handleRecordingEndedWithoutDurableSave(
        recoverySessionID: nil, ending: .discarded) == nil)
  }
  // MARK: - #1755 chunk 4 — deletion-failure breadcrumb matrix

  /// The exact breadcrumb shape the deletion-failure seam records.
  struct Crumb: Equatable {
    let stage: String
    let message: String
    let data: [String: String]
  }

  private final class CrumbLog {
    var crumbs: [Crumb] = []
  }

  /// Lock-protected fired-or-waiting one-shot: whichever of signal()/wait()
  /// runs first, the waiter resumes exactly once. Race-safe by construction.
  private final class OneShotSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiter: CheckedContinuation<Void, Never>?
    func signal() {
      let resumable: CheckedContinuation<Void, Never>? = lock.withLock {
        if fired { return nil }
        fired = true
        let w = waiter
        waiter = nil
        return w
      }
      resumable?.resume()
    }
    func wait() async {
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        let resumeNow: Bool = lock.withLock {
          if fired { return true }
          waiter = c
          return false
        }
        if resumeNow { c.resume() }
      }
    }
  }

  /// Lock-safe counter for the key-delete seam, which runs OFF the MainActor
  /// inside the detached destruction task. Awaiting that task proves the
  /// increment completed — no scheduling hops.
  private final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
  }

  // Best-effort deletion stays best-effort (no retries, no escapes); the ONLY
  // new behavior is one failure breadcrumb per failed component per
  // destruction call, with exact shape and a fixed source label.
  @Test(
    "live-ending destruction: 2×2 spool/key failure matrix emits exactly one breadcrumb per failed component",
    arguments: [false, true], [false, true])
  func deletionFailureMatrix(spoolFails: Bool, keyFails: Bool) async throws {
    let harness = Self.makeHarness()
    let coordinator = harness.coordinator
    let log = CrumbLog()
    let spoolAttempts = Box(0)
    let keyAttempts = AtomicCounter()
    struct InjectedDeleteFailure: Error {}
    coordinator.destructionSpoolDeleteForTesting = { _ in
      spoolAttempts.value += 1
      if spoolFails { throw InjectedDeleteFailure() }
    }
    coordinator.destructionKeyDeleteForTesting = { _ in
      keyAttempts.increment()
      if keyFails { throw InjectedDeleteFailure() }
    }
    coordinator.deletionFailureBreadcrumbForTesting = { stage, message, data in
      log.crumbs.append(Crumb(stage: stage, message: message, data: data))
    }

    // Drive the REAL live-ending destruction route with a delete-class ending.
    let task = coordinator.handleRecordingEndedWithoutDurableSave(
      recoverySessionID: "matrix-\(spoolFails)-\(keyFails)", ending: .discarded)
    let unwrapped = try #require(task, "a delete-class ending must return the detached work")
    // Awaiting the destruction task IS the completion proof: the key attempt
    // increments inline and the key-failure breadcrumb's MainActor emission is
    // awaited inside the task before it finishes.
    await unwrapped.value

    #expect(spoolAttempts.value == 1, "spool attempt exactly once")
    #expect(keyAttempts.value == 1, "key attempt exactly once, even after spool failure")
    let expectedCount = (spoolFails ? 1 : 0) + (keyFails ? 1 : 0)
    #expect(log.crumbs.count == expectedCount, "exactly one breadcrumb per failed component")
    if spoolFails {
      #expect(
        log.crumbs.contains(
          Crumb(
            stage: "recovery", message: "deletion_failed",
            data: ["component": "spool", "source": "live_ending"])),
        "exact spool failure breadcrumb")
    }
    if keyFails {
      #expect(
        log.crumbs.contains(
          Crumb(
            stage: "recovery", message: "deletion_failed",
            data: ["component": "key", "source": "live_ending"])),
        "exact key failure breadcrumb")
    }
    if spoolFails && keyFails {
      #expect(
        Set(log.crumbs.map { $0.data["component"] ?? "" }) == ["spool", "key"],
        "both-fail cell: one spool + one key, no duplicate")
    }
  }

  @Test("key-failure breadcrumb survives external coordinator ownership release")
  func keyFailureBreadcrumbSurvivesOwnershipRelease() async throws {
    // Finding r2-1/r3-1: prove the detached delete's STRONG capture delivers
    // the breadcrumb after every external reference is gone. Deterministic
    // protocol: gate the injected key delete AFTER it signals entry, await the
    // entry signal, nil every external strong reference, assert the weak
    // observer stays alive (the task owns the coordinator), release the gate
    // so the delete throws, await the task, assert the exact crumb.
    let log = CrumbLog()
    struct InjectedDeleteFailure: Error {}
    var harness: Harness? = Self.makeHarness()
    var coordinator: RecoveryCoordinator? = harness?.coordinator
    weak var observed = coordinator
    // Race-safe one-shot entry signal, created BEFORE destruction starts —
    // fired-or-waiting semantics make the ordering safe whichever thread wins
    // (r4 ordering).
    let entry = OneShotSignal()
    let gate = DispatchSemaphore(value: 0)
    coordinator?.destructionSpoolDeleteForTesting = { _ in }
    coordinator?.destructionKeyDeleteForTesting = { _ in
      entry.signal()
      gate.wait()  // released by the test after ownership is dropped — a signal, not a clock
      throw InjectedDeleteFailure()
    }
    coordinator?.deletionFailureBreadcrumbForTesting = { stage, message, data in
      log.crumbs.append(Crumb(stage: stage, message: message, data: data))
    }
    let task = try #require(coordinator).handleRecordingEndedWithoutDurableSave(
      recoverySessionID: "lifetime", ending: .discarded)
    let unwrapped = try #require(task)
    await entry.wait()  // entry — resumes immediately if it already fired
    harness = nil
    coordinator = nil
    #expect(observed != nil, "the detached task must own the coordinator while running")
    gate.signal()
    await unwrapped.value
    #expect(
      log.crumbs == [
        Crumb(
          stage: "recovery", message: "deletion_failed",
          data: ["component": "key", "source": "live_ending"])
      ],
      "the strong capture must deliver the breadcrumb after ownership release")
  }

}
