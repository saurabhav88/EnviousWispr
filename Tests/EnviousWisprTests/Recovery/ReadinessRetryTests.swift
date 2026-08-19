@preconcurrency import AVFoundation
import EnviousWisprAudio
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprASR
@testable import EnviousWisprLLM
@testable import EnviousWisprServices
@testable import EnviousWisprStorage

/// #2207. `ActiveEngineOperation.load` used to mean "the load call returned".
/// `ASRManager.loadModel()` RECORDS readiness rather than requiring it, so a load
/// could return while the engine was not ready — and recovery, believing it,
/// transcribed, failed, and DELETED a recording it had successfully saved.
///
/// These suites protect the fix's two halves: the door now refuses a false
/// success, and recovery gives that specific failure exactly ONE retry rather
/// than destroying the take.

// MARK: - The engine door

/// Isolated postcondition behaviour on the production factory. `.driftGuard`:
/// a failure here means we changed our own contract, not that a user lost audio.
@Suite("Active engine load postcondition (#2207)", .tags(.driftGuard))
@MainActor
struct ActiveEngineLoadPostconditionTests {

  /// A backend the parakeet branch never touches; `.live` requires one.
  private static func unusedBackend() -> WhisperKitBackend {
    WhisperKitBackend(admittedModelFolder: { nil })
  }

  /// Constructed through `.live(...)`, never the memberwise initializer — a
  /// hand-built `load` closure that throws the expected error would prove only
  /// that a closure can throw.
  @Test("a load that returns while the engine is not ready throws instead of reporting success")
  func activeEngineLoadThrowsWhenReadinessDoesNotFollow() async throws {
    let manager = RecoverySpoolReplayerTests.FakeBatchASR()
    manager.readyAfterLoad = false

    let op = ActiveEngineOperation.live(
      asrManager: manager, whisperKitBackend: Self.unusedBackend())

    await #expect(throws: ASREngineNotReadyAfterLoadError.self) {
      try await op.load()
    }
    #expect(manager.isModelLoaded == false, "the projection the postcondition read")
  }

  /// THE ORDERING CONTROL, and without it the test above is not binding: a cold
  /// engine starts not-ready, so a guard placed BEFORE the load would refuse
  /// every healthy first load while the negative test still passed.
  @Test("the check runs AFTER the load, so an ordinary cold start still succeeds")
  func activeEngineLoadChecksAfterLoadNotBeforeIt() async throws {
    let manager = RecoverySpoolReplayerTests.FakeBatchASR()
    manager.readyAfterLoad = true  // begins false; the loader makes it true
    #expect(manager.isModelLoaded == false, "cold: a pre-load guard would refuse here")

    let op = ActiveEngineOperation.live(
      asrManager: manager, whisperKitBackend: Self.unusedBackend())

    try await op.load()
    #expect(manager.isModelLoaded, "the loader made it ready and the postcondition agreed")
  }
}

// MARK: - Telemetry vocabulary

@Suite("Readiness retry telemetry contract (#2207)", .tags(.observabilityContract))
struct ReadinessRetryTelemetryContractTests {

  @Test("every disposition has the exact wire spelling the dashboards will query")
  func dispositionsCarryTheirWireSpelling() {
    #expect(RecoveryRetryDisposition.granted.rawValue == "granted")
    #expect(RecoveryRetryDisposition.exhausted.rawValue == "exhausted")
    #expect(RecoveryRetryDisposition.persistenceFailed.rawValue == "persistence_failed")
  }

  @Test("the new failure class is distinct from the deterministic load refusal")
  func failureClassIsDistinctFromNotReady() {
    #expect(RecoveryFailureClass.loadReturnedNotReady.rawValue == "load_returned_not_ready")
    #expect(RecoveryFailureClass.loadReturnedNotReady != RecoveryFailureClass.notReady)
  }

  /// #1525 PR G. Pinned at introduction; changing either string re-groups every
  /// historical Sentry issue for this error.
  @Test("the new error carries its pinned Sentry identity")
  func newErrorCarriesItsPinnedIdentity() {
    let error = ASREngineNotReadyAfterLoadError()
    #expect(
      error.sentryFingerprintDescriptor == "EnviousWisprASR.ASREngineNotReadyAfterLoadError#1")
    #expect(error.sentrySemanticID == "asr.engine_not_ready_after_load")
  }

  /// Codex diff review found the OTHER entry point never cleared it, so a
  /// successful pipeline run rendered the previous ASR run's red error beside
  /// its result. Both entry points are driven here; asserting only `run` would
  /// have passed against the defect.
  @Test("both benchmark entry points clear a stale failure")
  @MainActor
  func bothBenchmarkEntryPointsClearLastFailure() async {
    let manager = RecoverySpoolReplayerTests.FakeBatchASR()
    manager.readyAfterLoad = false
    let engine = ActiveEngineOperation.live(
      asrManager: manager, whisperKitBackend: WhisperKitBackend(admittedModelFolder: { nil }))
    let suite = BenchmarkSuite(engineMutationScope: .alwaysAllowedForTesting)

    await suite.run(using: manager, activeEngine: engine)
    #expect(suite.lastFailure != nil, "a load that returns unready must SAY so")

    // Now let the engine come good and drive the OTHER entry point.
    manager.readyAfterLoad = true
    await suite.runPipelineBenchmark(using: manager, activeEngine: engine)
    #expect(
      suite.lastFailure == nil,
      "a successful run must not leave the previous run's error on screen")
  }

  /// Codex diff review: without this the Diagnostics row renders Foundation's
  /// generated type-and-domain string at the user.
  @Test("the new error reads as plain English, not a type name")
  func newErrorHasAUserFacingDescription() {
    let described = ASREngineNotReadyAfterLoadError().localizedDescription
    #expect(described == "The engine finished loading but was not ready to use.")
    #expect(!described.contains("ASREngineNotReadyAfterLoad"), "never show the type name")
    #expect(!described.contains("EnviousWispr"), "never show the module name")
  }

  /// The classifier must not route this through the supersede arm — that maps to
  /// `.cancelled`, which recovery treats as terminal and DELETES the recording.
  @Test("classification routes the new error away from the cancelled arm")
  func classificationDoesNotFallIntoCancelled() {
    let classified = recoveryFailureClass(for: ASREngineNotReadyAfterLoadError())
    #expect(classified == .loadReturnedNotReady)
    #expect(classified != .cancelled, "cancelled is terminal — this is the #2132 trap")
  }
}

// MARK: - The recovery outcome

// Telemetry capture rides `TelemetryService.testEventHook`, which is DEBUG-only.
// An unwrapped reference compiles in Debug and breaks the RELEASE build ~20
// minutes later with zero failure marks, so the whole suite is gated.
#if DEBUG

  /// Wires the REAL replayer, store and spool cipher. Only the ASR engine and the
  /// retry marker's file operations are injected — everything the assertions read
  /// is production code.
  @MainActor
  enum Fixture {
    struct Bundle {
      let replayer: RecoverySpoolReplayer
      let asr: RecoverySpoolReplayerTests.FakeBatchASR
      let store: RecoverySpoolStore
      let spoolDir: URL
      let id: String
      var spoolExists: Bool {
        FileManager.default.fileExists(atPath: store.spoolURL(for: id).path)
      }
    }

    static func tempDir() -> URL {
      let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ew-readiness-\(UUID().uuidString)", isDirectory: true)
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      return dir
    }

    /// Commit fails; cleanup succeeds. Row C.
    static func failingCommit() -> RecoverySpoolStore.ReadinessRetryFileOps {
      var ops = RecoverySpoolStore.ReadinessRetryFileOps.live
      ops.commit = { _, _ in throw RecoverySpoolStoreError.readinessRetryMarkerWriteFailed(28) }
      return ops
    }

    /// Commit fails AND the ensuing cleanup fails, counting both. Row H — the two
    /// counters are what distinguish it from row C.
    static func failingCommitAndCleanup(counter: Counter)
      -> RecoverySpoolStore.ReadinessRetryFileOps
    {
      var ops = RecoverySpoolStore.ReadinessRetryFileOps.live
      ops.commit = { _, _ in throw RecoverySpoolStoreError.readinessRetryMarkerWriteFailed(28) }
      ops.cleanupTemp = { _ in
        counter.recordAttempt()
        counter.recordFailure()
        throw CocoaError(.fileWriteNoPermission)
      }
      return ops
    }

    static func make(
      ops: RecoverySpoolStore.ReadinessRetryFileOps = .live
    ) throws -> Bundle {
      let spoolDir = tempDir()
      let keyStore = RecoveryKeyStore(backend: .file, fileDirectory: tempDir())
      let transcriptStore = TranscriptStore(directory: tempDir())
      let transcriptCoordinator = TranscriptCoordinator(store: transcriptStore)
      let asr = RecoverySpoolReplayerTests.FakeBatchASR()
      let replayer = RecoverySpoolReplayer(
        activeEngine: ActiveEngineOperation(
          isLoaded: { asr.isModelLoaded },
          load: { try await asr.loadModel() },
          transcribe: { samples, options in
            try await asr.transcribe(audioSamples: samples, options: options)
          },
          hardCancel: {}),
        keyStore: keyStore,
        makeSpoolStore: {
          var store = RecoverySpoolStore(directory: spoolDir)
          store.readinessRetryFileOps = ops
          return store
        },
        transcriptStore: transcriptStore,
        transcriptCoordinator: transcriptCoordinator,
        keychainManager: KeychainManager(),
        outputClassifierHolder: OutputClassifierHolder(),
        now: { Date() },
        currentVocabulary: { (.empty, .empty) })
      var store = RecoverySpoolStore(directory: spoolDir)
      store.readinessRetryFileOps = ops
      let id = "readiness-\(UUID().uuidString)"
      let bundle = Bundle(
        replayer: replayer, asr: asr, store: store, spoolDir: spoolDir, id: id)
      try seed(bundle, keyStore: keyStore)
      return bundle
    }

    private static func seed(_ b: Bundle, keyStore: RecoveryKeyStore) throws {
      let keyData = Data(repeating: 7, count: RecoveryConstants.aesKeyByteCount)
      try keyStore.store(keyData: keyData, for: b.id)
      let writer = RecoverySpoolWriter(
        recoverySessionID: b.id, spoolURL: b.store.spoolURL(for: b.id),
        cipher: RecoverySpoolCipher(mode: .aesGcm256, keyData: keyData),
        settings: RecordingSettingsSnapshot(
          backendType: .parakeet, backendSupportsLanguageDetection: false,
          languageMode: .auto, wordCorrectionEnabled: false, fillerRemovalEnabled: false,
          emojiFormatterEnabled: false, spokenPunctuationEnabled: false,
          customWordsVersion: nil, llmProvider: "none", llmModel: "",
          polishPromptVersion: nil),
        appVersion: "1.0.0", createdAt: Date(timeIntervalSince1970: 0))
      writer.start()
      writer.append([0.1, 0.2, 0.3])
      let done = DispatchSemaphore(value: 0)
      writer.finalize(reason: .cleanFinalized) { done.signal() }
      done.wait()
    }

    static func capturingTelemetry(
      _ body: () async throws -> Void
    ) async rethrows -> RecoverySpoolReplayerTests.TelemetryBox {
      let box = RecoverySpoolReplayerTests.TelemetryBox()
      TelemetryService.shared.testEventHook = { @Sendable e in box.add(e) }
      defer { TelemetryService.shared.testEventHook = nil }
      try await body()
      return box
    }
  }


/// `.productOutcome`: when one of these fails, a dictation the user recorded is
/// gone. `.serialized` because the telemetry hook is process-global.
@Suite("Readiness retry recovery outcomes (#2207)", .serialized, .tags(.productOutcome))
@MainActor
struct ReadinessRetryRecoveryTests {

  /// ROW A. The first refusal keeps the recording and gives the attempt back.
  /// Red here means a recording that was never decoded is being destroyed again.
  @Test("the first refusal keeps the recording and spends one retry")
  func firstEngineUnavailableRefusalGetsOneRetry() async throws {
    let h = try Fixture.make()
    h.asr.loadError = ASREngineNotReadyAfterLoadError()

    var outcome: RecoveryReplayOutcome?
    let box = await Fixture.capturingTelemetry {
      outcome = await h.replayer.replay(recoverySessionID: h.id, isAborted: { false })
    }

    #expect(outcome == .deferred, "the engine never looked at the audio")
    #expect(h.store.hasReadinessRetryMarker(for: h.id), "the retry is now RECORDED, not implied")
    #expect(!h.store.hasAttemptMarker(for: h.id), "cleared, so a later pass may retry")
    #expect(h.spoolExists, "THE POINT: the recording is still on disk")
    #expect(h.asr.transcribeCallCount == 0, "the load never succeeded, so nothing was decoded")

    let e = try #require(box.recoveryEvents().first)
    #expect(e.stringProps["outcome"] == "deferred")
    #expect(e.stringProps["failure_class"] == "load_returned_not_ready")
    #expect(e.stringProps["retry_disposition"] == "granted")
    // The audio reconstructed perfectly; only the engine was missing. Absent
    // `audio_decrypted` reads as "nothing came out of the spool" — the inverse.
    #expect(e.boolProps["audio_decrypted"] == true)
    #expect(e.boolProps["camp_b_candidate"] == true)
  }

  /// ROW B — THE BOUND. Without it a permanently unready engine defers forever
  /// and spools accumulate with nothing ever cleaning them up.
  @Test("a second refusal is terminal, so a broken engine cannot defer forever")
  func repeatedEngineUnavailableRefusalTerminates() async throws {
    let h = try Fixture.make()
    h.asr.loadError = ASREngineNotReadyAfterLoadError()
    try h.store.writeReadinessRetryMarker(for: h.id)  // the retry is already spent

    var outcome: RecoveryReplayOutcome?
    let box = await Fixture.capturingTelemetry {
      outcome = await h.replayer.replay(recoverySessionID: h.id, isAborted: { false })
    }

    #expect(outcome == .failed(.unrecoverable), "one retry, then we stop")
    let e = try #require(box.recoveryEvents().first)
    #expect(e.stringProps["outcome"] == "failed")
    #expect(e.stringProps["retry_disposition"] == "exhausted")
    #expect(e.stringProps["failure_class"] == "load_returned_not_ready")
  }

  /// THE TRAP, specified so it cannot be satisfied trivially. Two independent
  /// spools, two errors injected through the REAL load closure, one real replay
  /// each. An earlier draft of this row was satisfiable by two mocked outcomes
  /// and proved nothing about the live catch.
  @Test("the two load-site refusals do not share an outcome")
  func theTwoLoadSiteRefusalsDoNotShareAnOutcome() async throws {
    let transient = try Fixture.make()
    transient.asr.loadError = ASREngineNotReadyAfterLoadError()
    let deterministic = try Fixture.make()
    deterministic.asr.loadError = ASRError.notReady

    var transientOutcome: RecoveryReplayOutcome?
    var deterministicOutcome: RecoveryReplayOutcome?
    let box = await Fixture.capturingTelemetry {
      transientOutcome = await transient.replayer.replay(
        recoverySessionID: transient.id, isAborted: { false })
      deterministicOutcome = await deterministic.replayer.replay(
        recoverySessionID: deterministic.id, isAborted: { false })
    }

    #expect(transientOutcome == .deferred, "the load RETURNED and readiness was false")
    #expect(
      deterministicOutcome == .failed(.unrecoverable),
      "no model is admitted; retrying repeats this failure every launch forever")
    #expect(transient.spoolExists, "kept")
    #expect(transient.asr.transcribeCallCount == 0)
    #expect(deterministic.asr.transcribeCallCount == 0)

    let classes = box.recoveryEvents().compactMap { $0.stringProps["failure_class"] }
    #expect(classes == ["load_returned_not_ready", "not_ready"], "one label each, never shared")
  }

  /// ROW C. The retry was earned and could not be recorded, so we must NOT clear
  /// the attempt marker — a retry the budget never recorded is the hole the
  /// bound exists to close.
  @Test("a retry that cannot be persisted leaves the attempt spent")
  func readinessRetryMarkerWriteFailureKeepsAttemptSpent() async throws {
    let h = try Fixture.make(ops: Fixture.failingCommit())
    h.asr.loadError = ASREngineNotReadyAfterLoadError()

    var outcome: RecoveryReplayOutcome?
    let box = await Fixture.capturingTelemetry {
      outcome = await h.replayer.replay(recoverySessionID: h.id, isAborted: { false })
    }

    #expect(outcome == .deferredPersistenceFailed)
    #expect(!h.store.hasReadinessRetryMarker(for: h.id), "nothing committed")
    #expect(h.store.hasAttemptMarker(for: h.id), "stands, so the next launch abandons")
    #expect(h.spoolExists, "still not deleted — that is the whole point")
    #expect(
      !RecoveryCoordinator.shouldDeleteAfterReplay(.deferredPersistenceFailed),
      "the coordinator is the sole destructor and must retain this outcome")

    let e = try #require(box.recoveryEvents().first)
    #expect(e.stringProps["reason"] == "marker_write_failed")
    #expect(e.stringProps["failure_class"] == "load_returned_not_ready")
    #expect(e.stringProps["retry_disposition"] == "persistence_failed")
    #expect(e.boolProps["audio_decrypted"] == true)
    #expect(e.boolProps["camp_b_candidate"] == true)
  }

  /// ROW A's ORDERING, continuing into ROW D. The retry marker must COMMIT before
  /// the attempt marker is cleared: a crash in that window has to abandon the
  /// spool rather than mint an uncounted retry. Observed through a production
  /// seam the subject itself fires — never inferred from timing.
  @Test("the retry marker commits before the attempt marker is cleared")
  func retryMarkerWritePrecedesAttemptMarkerClear() async throws {
    let h = try Fixture.make()
    h.asr.loadError = ASREngineNotReadyAfterLoadError()

    var bothPresentAtCommit = false
    h.replayer.onReadinessRetryMarkerCommitted = { [store = h.store, id = h.id] in
      bothPresentAtCommit =
        store.hasReadinessRetryMarker(for: id) && store.hasAttemptMarker(for: id)
    }

    _ = await h.replayer.replay(recoverySessionID: h.id, isAborted: { false })

    #expect(
      bothPresentAtCommit,
      "at the instant of commit BOTH markers exist; the reverse order would grant a retry nothing recorded")
  }

  /// ROW H, and it must be distinguishable from ROW C. Asserting only the routing
  /// would pass whether cleanup succeeded, failed, or was never attempted.
  @Test("a failed cleanup after a failed commit still holds the recording")
  func readinessRetryMarkerWriteAndCleanupFailureStaysDeferred() async throws {
    let cleanupAttempts = Counter()
    let h = try Fixture.make(ops: Fixture.failingCommitAndCleanup(counter: cleanupAttempts))
    h.asr.loadError = ASREngineNotReadyAfterLoadError()

    var outcome: RecoveryReplayOutcome?
    let box = await Fixture.capturingTelemetry {
      outcome = await h.replayer.replay(recoverySessionID: h.id, isAborted: { false })
    }

    // THE DISTINCTION from row C. Without these two the case is row C rewritten.
    #expect(cleanupAttempts.value == 1, "cleanup was ATTEMPTED exactly once")
    #expect(cleanupAttempts.failuresRaised == 1, "and the injected failure was CONSUMED")

    #expect(outcome == .deferredPersistenceFailed, "a failed cleanup changes nothing for the user")
    #expect(!h.store.hasReadinessRetryMarker(for: h.id))
    #expect(h.store.hasAttemptMarker(for: h.id))
    #expect(h.spoolExists)
    let e = try #require(box.recoveryEvents().first)
    #expect(e.stringProps["reason"] == "marker_write_failed")
    #expect(e.stringProps["retry_disposition"] == "persistence_failed")
  }

  /// The field must appear ONLY on the bounded readiness retry. Codex found it
  /// leaking onto the transcribe-site deferral, where no budget is consulted and
  /// no marker is written — which would have counted ordinary transcription
  /// deferrals as failed readiness retries and corrupted the very split the
  /// field exists to measure.
  @Test("an unrelated deferral carries no retry disposition")
  func transcribeSiteDeferralDoesNotClaimAReadinessRetry() async throws {
    let h = try Fixture.make()
    h.asr.transcribeError = ASRError.notReady  // the TRANSCRIBE site, not the load site

    var outcome: RecoveryReplayOutcome?
    let box = await Fixture.capturingTelemetry {
      outcome = await h.replayer.replay(recoverySessionID: h.id, isAborted: { false })
    }

    #expect(outcome == .deferred, "unchanged #2205 behaviour")
    let e = try #require(box.recoveryEvents().first)
    #expect(e.stringProps["failure_class"] == "not_ready")
    #expect(
      e.stringProps["retry_disposition"] == nil,
      "no readiness retry happened here, so claiming one falsifies the dashboard")
    #expect(!h.store.hasReadinessRetryMarker(for: h.id), "and no budget was spent")
  }

  /// Spool deletion must ATTEMPT every readiness-retry artifact, and keep
  /// attempting the others when one fails — the store's cleanup is best-effort
  /// by design, so this asserts attempts, never guarantees.
  @Test("deleting a spool clears its readiness-retry marker and interrupted temp")
  func spoolDeletionAttemptsEveryReadinessRetryArtifact() async throws {
    let h = try Fixture.make()
    try h.store.writeReadinessRetryMarker(for: h.id)
    let temp = h.spoolDir.appendingPathComponent(".\(h.id).readiness-retry.tmp")
    try Data([0x31]).write(to: temp)

    try h.store.delete(recoverySessionID: h.id)

    #expect(!h.store.hasReadinessRetryMarker(for: h.id), "no stale marker outlives its spool")
    #expect(
      !FileManager.default.fileExists(atPath: temp.path),
      "the interrupted-write temp goes too, or it is orphaned permanently")
  }
}

/// Counts cleanup attempts so row H can prove it differs from row C.
final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var attempts = 0
  private var failures = 0
  var value: Int { lock.withLock { attempts } }
  var failuresRaised: Int { lock.withLock { failures } }
  func recordAttempt() { lock.withLock { attempts += 1 } }
  func recordFailure() { lock.withLock { failures += 1 } }
}

#endif
