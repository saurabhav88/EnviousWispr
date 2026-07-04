@preconcurrency import AVFoundation
import EnviousWisprASR
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - WhisperKitEngineAdapterTests (epic #827, PR-5 Rung 3 §11.2)
//
// Unit coverage for `WhisperKitEngineAdapter` — the production
// `ASREngineAdapter` WhisperKit conformer. Drives a configurable
// `StubWhisperKitBackend` (actor stub conforming to the local
// `WhisperKitBackendDriving` seam) so no real WhisperKit model loads. The
// PR-1 §B.2.2 MUST / MUST NOT clauses get adversarial coverage, and the
// coordinate-space lesson (epic §0.5) is locked by `batchSamplesIgnored`.

@MainActor
@Suite struct WhisperKitEngineAdapterTests {

  // MARK: Identity (PR-5 Rung 1)

  @Test("engineIdentity: WhisperKit declares .whisperKit backend")
  func engineIdentityBackend() {
    let adapter = WhisperKitEngineAdapter(backend: StubWhisperKitBackend())
    #expect(adapter.engineIdentity.backendType == .whisperKit)
    #expect(adapter.engineIdentity.rawValue == "whisperKit")
  }

  @Test("engineIdentity: WhisperKit displayName == WhisperKit")
  func engineIdentityDisplayName() {
    let adapter = WhisperKitEngineAdapter(backend: StubWhisperKitBackend())
    #expect(adapter.engineIdentity.displayName == "WhisperKit")
  }

  // MARK: Capabilities + readiness

  @Test("capabilities: WhisperKit streams (PR-2), detects language, ignores conditioned batch")
  func capabilities() {
    let adapter = WhisperKitEngineAdapter(backend: StubWhisperKitBackend())
    // #1308 (Step 2, PR-2): WhisperKit now advertises streaming so the kernel's
    // `useStreamingASR && supportsStreaming` gate can route the Live-transcription
    // toggle through it (the adapter still degrades to batch for auto language).
    #expect(adapter.capabilities.supportsStreaming == true)
    #expect(adapter.capabilities.supportsLanguageDetection == true)
    // #950 — WhisperKit ignores `batchSamples` and decodes the raw capture, so
    // the VAD trim does not touch its ASR input; tail-trim diagnostic excluded.
    #expect(adapter.capabilities.decodesConditionedBatchSamples == false)
  }

  @Test("readiness transitions: init → notReady; warmUp → ready; cancel keeps notReady")
  func cachedReadinessTransitions() async throws {
    let backend = StubWhisperKitBackend()
    let adapter = WhisperKitEngineAdapter(backend: backend)
    #expect(adapter.readiness == .notReady)
    try await adapter.warmUp()
    #expect(adapter.readiness == .ready)
    await adapter.cancel()
    // Backend was set ready by `prepare()`; cancel only refreshes the cached
    // value from the live backend, so `.ready` is retained when the backend
    // says so. Adversarial path is `applyUnloadPolicy(.immediately)` below.
    #expect(adapter.readiness == .ready)
  }

  // MARK: #959 — heavy recoverFromWedge() (best-effort, deadline-bounded)

  @Test("#959 recoverFromWedge() tears the engine down to .notReady for a fresh reload")
  func recoverFromWedgeForcesNotReady() async throws {
    let backend = StubWhisperKitBackend()
    let adapter = WhisperKitEngineAdapter(backend: backend)
    try await adapter.warmUp()
    #expect(adapter.readiness == .ready)
    await adapter.recoverFromWedge()
    #expect(adapter.readiness == .notReady, "wedge recovery unloads the in-process backend")
    #expect(await backend.unloadCount == 1)
  }

  @Test("#959 recoverFromWedge() returns within its deadline even if unload() hangs")
  func recoverFromWedgeIsDeadlineBounded() async throws {
    let backend = StubWhisperKitBackend()
    await backend.setHangUnload(true)
    // Inject a fast fail-open deadline; a wedged in-process unload must NOT hang
    // the kernel's recovery path.
    let adapter = WhisperKitEngineAdapter(backend: backend, wedgeRecoveryUnloadDeadlineSec: 0.05)
    try await adapter.warmUp()
    #expect(adapter.readiness == .ready)
    await adapter.recoverFromWedge()  // must return despite the hung unload
    #expect(adapter.readiness == .notReady)
  }

  @Test("readiness goes notReady after applyUnloadPolicy(.immediately) executes")
  func cachedReadinessAfterImmediateUnload() async throws {
    let backend = StubWhisperKitBackend()
    let adapter = WhisperKitEngineAdapter(backend: backend)
    try await adapter.warmUp()
    #expect(adapter.readiness == .ready)
    adapter.applyUnloadPolicy(.immediately)
    // Await the armed unload task to completion (deterministic, bounded) —
    // a fixed `Task.yield()` budget is not enough under release-config CI.
    await adapter.modelUnloadTaskForUnitTests?.value
    #expect(adapter.readiness == .notReady)
    let unloadCount = await backend.unloadCount
    #expect(unloadCount == 1)
  }

  @Test("readiness goes notReady when warmUp throws (failed prepare)")
  func cachedReadinessAfterFailedPrepare() async {
    let backend = StubWhisperKitBackend()
    await backend.setPrepareThrows(StubBackendError.prepareFailed)
    let adapter = WhisperKitEngineAdapter(backend: backend)
    do {
      try await adapter.warmUp()
      Issue.record("expected throw")
    } catch {
      // expected
    }
    #expect(adapter.readiness == .notReady)
  }

  // MARK: warmUp

  @Test("warmUp() loads when the backend is not ready")
  func warmUpLoads() async throws {
    let backend = StubWhisperKitBackend()
    let adapter = WhisperKitEngineAdapter(backend: backend)
    try await adapter.warmUp()
    let count = await backend.prepareCount
    #expect(count == 1)
  }

  @Test("warmUp() is a no-op when the backend is already ready")
  func warmUpIdempotent() async throws {
    let backend = StubWhisperKitBackend()
    await backend.setIsReady(true)
    let adapter = WhisperKitEngineAdapter(backend: backend)
    try await adapter.warmUp()
    let count = await backend.prepareCount
    #expect(count == 0)
  }

  @Test(
    "warmUpFromCache() does NOT call prepareIfCached (avoids load-race with prepare(), Codex r5)"
  )
  func warmUpFromCacheDoesNotTriggerLoad() async throws {
    let backend = StubWhisperKitBackend()
    await backend.setPrepareIfCachedResult(true)
    let adapter = WhisperKitEngineAdapter(backend: backend)
    try await adapter.warmUpFromCache()
    // warmUpFromCache awaits its own work and (by design, Codex r5) spawns no
    // background load task, so the counts are final the instant it returns —
    // assert synchronously instead of yield-polling for a task that never
    // exists (#875).
    let pifCount = await backend.prepareIfCachedCount
    let prepareCount = await backend.prepareCount
    #expect(pifCount == 0, "warmUpFromCache must NOT call prepareIfCached")
    #expect(prepareCount == 0, "warmUpFromCache must NOT call prepare")
  }

  @Test("warmUpFromCache() refreshes cachedReadiness from the backend state")
  func warmUpFromCacheRefreshesCachedReadiness() async throws {
    let backend = StubWhisperKitBackend()
    let adapter = WhisperKitEngineAdapter(backend: backend)
    // Backend is not ready → cachedReadiness stays .notReady.
    try await adapter.warmUpFromCache()
    #expect(adapter.readiness == .notReady)
    // Backend flips ready (simulating a prior `warmUp()` that completed) →
    // the next warmUpFromCache call observes and reports .ready.
    await backend.setIsReady(true)
    try await adapter.warmUpFromCache()
    #expect(adapter.readiness == .ready)
  }

  @Test("warmUpFromCache() never throws (limb-style)")
  func warmUpFromCacheNeverThrows() async throws {
    let backend = StubWhisperKitBackend()
    let adapter = WhisperKitEngineAdapter(backend: backend)
    try await adapter.warmUpFromCache()  // must not throw
  }

  @Test("loadProgress returns nil (WhisperKit has no model-load signal)")
  func loadProgressIsNil() {
    let adapter = WhisperKitEngineAdapter(backend: StubWhisperKitBackend())
    #expect(adapter.loadProgress == nil)
  }

  @Test("lastObservedPhase falls back to protocol default \"warmup\"")
  func lastObservedPhaseDefault() {
    let adapter = WhisperKitEngineAdapter(backend: StubWhisperKitBackend())
    #expect(adapter.lastObservedPhase == "warmup")
  }

  // MARK: Session lifecycle

  // #1307: worker-start behavior is now frozen to zero — see
  // `noPathStartsWorker` in the "Finalize — single clean batch" section, which
  // pins the whole (language × streaming) grid to no worker starts.

  @Test(
    "beginSession clears lastResult, lastASRDiagnostics, lastFailureError, lastLanguageDetection, PCM, segments"
  )
  func beginSessionClearsState() async throws {
    let backend = StubWhisperKitBackend()
    let adapter = WhisperKitEngineAdapter(backend: backend)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: false)
    feed(adapter, samples: [0.1, 0.2], session: sid)
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: 1600)])
    // Begin a fresh session — must clear everything.
    try await adapter.beginSession(SessionID(), options: .default, streaming: false)
    #expect(adapter.lastResult == nil)
    #expect(adapter.lastASRDiagnostics == nil)
    #expect(adapter.lastFailureError == nil)
    #expect(adapter.lastLanguageDetection == nil)
  }

  // MARK: acceptAudio

  @Test("acceptAudio after a terminal session is a no-op")
  func acceptAudioAfterTerminalIsNoOp() async throws {
    let backend = StubWhisperKitBackend()
    await backend.setObserveLIDResult(.unavailable)
    let adapter = WhisperKitEngineAdapter(backend: backend)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: false)
    feed(adapter, samples: [0.1], session: sid)
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: 1600)])
    _ = await adapter.finalize(batchSamples: nil)
    let beforeRetainedCount = adapter.retainedPCMForTests.count
    feed(adapter, samples: [0.9, 0.9, 0.9], session: sid)
    #expect(adapter.retainedPCMForTests.count == beforeRetainedCount)
  }

  @Test(
    "acceptAudio drops late buffers stamped with a prior session (Codex code-diff r3 defect 3, PR-1 §B.3 invariant 7)"
  )
  func acceptAudioDropsStaleSessionBuffers() async throws {
    let backend = StubWhisperKitBackend()
    let adapter = WhisperKitEngineAdapter(backend: backend)
    let sidA = SessionID()
    try await adapter.beginSession(sidA, options: .default, streaming: false)
    feed(adapter, samples: [0.1, 0.1], session: sidA)
    let sidB = SessionID()
    try await adapter.beginSession(sidB, options: .default, streaming: false)
    // Buffer stamped with the old (sidA) session arrives after the new
    // beginSession — must be dropped, NOT appended to B's retainedPCM.
    feed(adapter, samples: [0.9, 0.9, 0.9], session: sidA)
    #expect(
      adapter.retainedPCMForTests.isEmpty,
      "stale buffer was appended to fresh session's retainedPCM")
  }

  // #1307 removed the orphan-worker-cancel path (no worker is ever installed),
  // so the former `beginSessionCancelsOrphanWorker` test no longer applies.

  @Test("acceptAudio is bounded by retainedPCMCap")
  func acceptAudioCappedAtMaxRecording() async throws {
    let backend = StubWhisperKitBackend()
    let adapter = WhisperKitEngineAdapter(backend: backend)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: false)
    let cap = Int(TimingConstants.maxRecordingDuration * AudioConstants.sampleRate)
    // Two oversize buffers — the second must be truncated to the cap.
    let big = [Float](repeating: 0.1, count: cap - 100)
    feed(adapter, samples: big, session: sid)
    feed(adapter, samples: [Float](repeating: 0.2, count: 1_000), session: sid)
    #expect(adapter.retainedPCMForTests.count == cap)
  }

  // MARK: observeSpeechSegments

  @Test("observeSpeechSegments stores segments; cleared on beginSession and cancel")
  func observeSpeechSegmentsLifecycle() async throws {
    let backend = StubWhisperKitBackend()
    let adapter = WhisperKitEngineAdapter(backend: backend)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: false)
    let segments = [SpeechSegment(startSample: 0, endSample: 16_000)]
    adapter.observeSpeechSegments(segments)
    #expect(adapter.observedSpeechSegmentsForTests.count == 1)
    await adapter.cancel()
    #expect(adapter.observedSpeechSegmentsForTests.isEmpty)
  }

  // MARK: Finalize — core paths

  @Test(
    "finalize with empty observeSpeechSegments runs ASR — adapter trusts kernel-side no-speech gate (Codex r2 defect 1)"
  )
  func finalizeEmptySegmentsRunsASRTrustingKernelGate() async throws {
    let backend = StubWhisperKitBackend()
    await backend.setTranscribeResult(
      ASRResult(
        text: "recovered", language: "en", duration: 1, processingTime: 0.1,
        backendType: .whisperKit))
    let adapter = WhisperKitEngineAdapter(backend: backend)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: false)
    feed(adapter, samples: speechSamples(count: 16_000), session: sid)
    // Kernel calls `observeSpeechSegments([])` in both
    // VAD-confirmed-no-speech AND VAD-unavailable cases — adapter cannot
    // disambiguate, so it trusts the kernel's own `.confirmedNoSpeech` gate
    // (which would have early-returned before reaching `finalize`) and
    // ALWAYS runs ASR. Empty segments simply means "no clipTimestamps".
    adapter.observeSpeechSegments([])
    let outcome = await adapter.finalize(batchSamples: nil)
    guard case .transcript(let result) = outcome else {
      Issue.record("expected .transcript (no adapter-side no-speech gate), got \(outcome)")
      return
    }
    #expect(result.text == "recovered")
    let txCount = await backend.transcribeCount
    #expect(txCount == 1, "ASR runs even with empty segments — kernel owns the gate")
  }

  @Test(
    "finalize WITHOUT observeSpeechSegments runs ASR — adapter trusts kernel-side no-speech gate"
  )
  func finalizeNoSegmentSignalRunsASR() async throws {
    let backend = StubWhisperKitBackend()
    await backend.setTranscribeResult(
      ASRResult(
        text: "recovered", language: "en", duration: 1, processingTime: 0.1,
        backendType: .whisperKit))
    let adapter = WhisperKitEngineAdapter(backend: backend)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: false)
    feed(adapter, samples: speechSamples(count: 16_000), session: sid)
    // Deliberately skip observeSpeechSegments — same semantic as empty
    // segments in the kernel-driven model.
    let outcome = await adapter.finalize(batchSamples: nil)
    guard case .transcript(let result) = outcome else {
      Issue.record("expected .transcript, got \(outcome)")
      return
    }
    #expect(result.text == "recovered")
  }

  @Test("finalize with segments + non-empty decode returns .transcript and sets lastResult")
  func finalizeSuccessSetsLastResult() async throws {
    let backend = StubWhisperKitBackend()
    await backend.setTranscribeResult(
      ASRResult(
        text: "hello world", language: "en", duration: 1, processingTime: 0.1,
        backendType: .whisperKit))
    let adapter = WhisperKitEngineAdapter(backend: backend)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: false)
    feed(adapter, samples: speechSamples(count: 16_000), session: sid)
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: 16_000)])
    let outcome = await adapter.finalize(batchSamples: nil)
    guard case .transcript(let result) = outcome else {
      Issue.record("expected .transcript, got \(outcome)")
      return
    }
    #expect(result.text == "hello world")
    #expect(adapter.lastResult != nil)
  }

  @Test("finalize with segments + empty decode returns .empty(hadSpeechEvidence: true)")
  func finalizeEmptyDecodeReturnsEmptyTrue() async throws {
    let backend = StubWhisperKitBackend()
    await backend.setTranscribeResult(
      ASRResult(
        text: "  ", language: "en", duration: 1, processingTime: 0.1,
        backendType: .whisperKit))
    let adapter = WhisperKitEngineAdapter(backend: backend)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: false)
    feed(adapter, samples: speechSamples(count: 16_000), session: sid)
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: 16_000)])
    let outcome = await adapter.finalize(batchSamples: nil)
    guard case .empty(let hadSpeechEvidence) = outcome else {
      Issue.record("expected .empty, got \(outcome)")
      return
    }
    #expect(hadSpeechEvidence == true)
  }

  @Test(
    "asrEmptyWithSpeechEvidenceExposesDiagnostics: lastASRDiagnostics survives finalize (council F4 / OQ-6)"
  )
  func asrEmptyWithSpeechEvidenceExposesDiagnostics() async throws {
    let backend = StubWhisperKitBackend()
    await backend.setTranscribeResult(
      ASRResult(
        text: "", language: "en", duration: 1, processingTime: 0.1,
        backendType: .whisperKit))
    let adapter = WhisperKitEngineAdapter(backend: backend)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: false)
    let samples = speechSamples(count: 16_000)
    feed(adapter, samples: samples, session: sid)
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: 16_000)])
    let outcome = await adapter.finalize(batchSamples: nil)
    guard case .empty(let hadSpeechEvidence) = outcome, hadSpeechEvidence else {
      Issue.record("expected .empty(hadSpeechEvidence: true), got \(outcome)")
      return
    }
    let diagnostics = try #require(adapter.lastASRDiagnostics)
    #expect(diagnostics.rawSampleCount == samples.count)
  }

  @Test("finalize after cancel() returns .cancelled (never partial text)")
  func finalizeAfterCancelReturnsCancelled() async throws {
    let backend = StubWhisperKitBackend()
    let adapter = WhisperKitEngineAdapter(backend: backend)
    try await adapter.beginSession(SessionID(), options: .default, streaming: false)
    await adapter.cancel()
    let outcome = await adapter.finalize(batchSamples: nil)
    guard case .cancelled = outcome else {
      Issue.record("expected .cancelled, got \(outcome)")
      return
    }
  }

  @Test("finalize: backend throws CancellationError returns .cancelled")
  func finalizeBackendCancellationReturnsCancelled() async throws {
    let backend = StubWhisperKitBackend()
    await backend.setTranscribeThrows(CancellationError())
    let adapter = WhisperKitEngineAdapter(backend: backend)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: false)
    feed(adapter, samples: speechSamples(count: 16_000), session: sid)
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: 16_000)])
    let outcome = await adapter.finalize(batchSamples: nil)
    guard case .cancelled = outcome else {
      Issue.record("expected .cancelled, got \(outcome)")
      return
    }
  }

  @Test(
    "finalize: backend throws non-cancel error returns .failed(.decodeFailed) and sets lastFailureError"
  )
  func finalizeBackendErrorReturnsFailed() async throws {
    let backend = StubWhisperKitBackend()
    await backend.setTranscribeThrows(StubBackendError.decodeFailed)
    let adapter = WhisperKitEngineAdapter(backend: backend)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: false)
    feed(adapter, samples: speechSamples(count: 16_000), session: sid)
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: 16_000)])
    let outcome = await adapter.finalize(batchSamples: nil)
    guard case .failed(let kind) = outcome, case .decodeFailed = kind else {
      Issue.record("expected .failed(.decodeFailed), got \(outcome)")
      return
    }
    #expect(adapter.lastFailureError != nil)
  }

  // MARK: Finalize — LID

  @Test("lidDetectedSetsLanguage: LID non-abstain sets decodeOptions.language before transcribe")
  func lidDetectedSetsLanguage() async throws {
    let backend = StubWhisperKitBackend()
    await backend.setObserveLIDResult(
      .observations([
        RawLIDObservation(argmaxLang: "es", logProb: -0.05),
        RawLIDObservation(argmaxLang: "es", logProb: -0.05),
      ]))
    let adapter = WhisperKitEngineAdapter(backend: backend)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: false)
    feed(adapter, samples: speechSamples(count: 16_000 * 3), session: sid)
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: 16_000 * 3)])
    _ = await adapter.finalize(batchSamples: nil)
    let opts = await backend.lastTranscribeOptions
    // LID confidence might still abstain depending on classifier thresholds;
    // assert the lastLanguageDetection is set regardless and the language
    // pinned to decodeOptions is non-nil iff LID accepted.
    let lid = try #require(adapter.lastLanguageDetection)
    if !lid.abstained, let lang = lid.lang {
      #expect(opts.language == lang)
    } else {
      #expect(opts.language == nil)
    }
  }

  @Test("lidAbstainedKeepsNilLanguage: abstaining LID nulls decodeOptions.language")
  func lidAbstainedKeepsNilLanguage() async throws {
    let backend = StubWhisperKitBackend()
    await backend.setObserveLIDResult(.error(reason: "all_windows_failed"))
    let adapter = WhisperKitEngineAdapter(backend: backend)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: false)
    feed(adapter, samples: speechSamples(count: 16_000), session: sid)
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: 16_000)])
    _ = await adapter.finalize(batchSamples: nil)
    let opts = await backend.lastTranscribeOptions
    #expect(opts.language == nil)
  }

  @Test(
    "lastLanguageDetectionLifecycle: nil at init / beginSession; set after finalize; nil after cancel"
  )
  func lastLanguageDetectionLifecycle() async throws {
    let backend = StubWhisperKitBackend()
    let adapter = WhisperKitEngineAdapter(backend: backend)
    #expect(adapter.lastLanguageDetection == nil)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: false)
    #expect(adapter.lastLanguageDetection == nil)
    feed(adapter, samples: speechSamples(count: 16_000), session: sid)
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: 16_000)])
    _ = await adapter.finalize(batchSamples: nil)
    #expect(adapter.lastLanguageDetection != nil)
    await adapter.cancel()
    #expect(adapter.lastLanguageDetection == nil)
  }

  // MARK: Finalize — single clean batch (#1307: no incremental worker)

  /// Old-worker-not-started freeze (plan §11): no path in `beginSession`
  /// constructs the incremental worker. Parametrized over both language modes
  /// AND both `streaming` flags so the whole (language × streaming) grid is
  /// pinned to zero worker starts — automating the "grep proves zero call
  /// sites" check at local test time. Step 3 adds the type-deletion freeze.
  @Test(
    "no path starts the incremental worker (#1307 freeze)",
    arguments: [
      (TranscriptionOptions(language: "en"), false),
      (TranscriptionOptions(language: "en"), true),
      (TranscriptionOptions.default, false),
      (TranscriptionOptions.default, true),
    ])
  func noPathStartsWorker(options: TranscriptionOptions, streaming: Bool) async throws {
    let backend = StubWhisperKitBackend()
    // A factory is available — the freeze proves the adapter never CALLS it,
    // not merely that none was provided.
    let stubSession = StubIncrementalSession(result: .accepted(text: "worker-text"))
    await backend.setIncrementalSessionFactory({ stubSession })
    let adapter = WhisperKitEngineAdapter(backend: backend)
    try await adapter.beginSession(SessionID(), options: options, streaming: streaming)
    let mks = await backend.makeIncrementalSessionCount
    #expect(
      mks == 0,
      "no worker vended for (language: \(options.language ?? "auto"), streaming: \(streaming))")
    let starts = await stubSession.startCount
    #expect(starts == 0, "worker never started")
  }

  @Test("lockedModeGoesStraightToBatch: .locked finalize runs one clean batch decode")
  func lockedModeGoesStraightToBatch() async throws {
    let backend = StubWhisperKitBackend()
    await backend.setTranscribeResult(
      ASRResult(
        text: "batch-text", language: "en", duration: 1, processingTime: 0.1,
        backendType: .whisperKit))
    let adapter = WhisperKitEngineAdapter(backend: backend)
    let sid = SessionID()
    let options = TranscriptionOptions(language: "en")
    try await adapter.beginSession(sid, options: options, streaming: false)
    feed(adapter, samples: speechSamples(count: 16_000), session: sid)
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: 16_000)])
    let outcome = await adapter.finalize(batchSamples: nil)
    guard case .transcript(let result) = outcome else {
      Issue.record("expected .transcript, got \(outcome)")
      return
    }
    #expect(result.text == "batch-text")
    let txCount = await backend.transcribeCount
    #expect(txCount == 1, "exactly one batch decode, no worker")
    let mks = await backend.makeIncrementalSessionCount
    #expect(mks == 0)
  }

  @Test("autoModeGoesStraightToBatch: .auto finalize runs one clean batch decode")
  func autoModeGoesStraightToBatch() async throws {
    let backend = StubWhisperKitBackend()
    await backend.setTranscribeResult(
      ASRResult(
        text: "auto-batch", language: "en", duration: 1, processingTime: 0.1,
        backendType: .whisperKit))
    let adapter = WhisperKitEngineAdapter(backend: backend)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: false)
    feed(adapter, samples: speechSamples(count: 16_000), session: sid)
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: 16_000)])
    let outcome = await adapter.finalize(batchSamples: nil)
    guard case .transcript = outcome else {
      Issue.record("expected .transcript, got \(outcome)")
      return
    }
    let mks = await backend.makeIncrementalSessionCount
    #expect(mks == 0)
    let txCount = await backend.transcribeCount
    #expect(txCount == 1)
  }

  // MARK: Streaming routing matrix (#1308, PR-2)

  @Test("streaming ON + locked language: starts the streaming session; its flush is authoritative")
  func streamingLockedUsesSession() async throws {
    let backend = StubWhisperKitBackend()
    let stubSession = StubIncrementalSession(result: .accepted(text: "streamed-text"))
    await backend.setStreamingSessionFactory({ stubSession })
    let adapter = WhisperKitEngineAdapter(backend: backend)
    let sid = SessionID()
    try await adapter.beginSession(
      sid, options: TranscriptionOptions(language: "en"), streaming: true)
    let started = await stubSession.startCount
    #expect(started == 1, "streaming session started for streaming ON + locked")
    feed(adapter, samples: speechSamples(count: 16_000), session: sid)
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: 16_000)])
    let outcome = await adapter.finalize(batchSamples: nil)
    guard case .transcript(let result) = outcome else {
      Issue.record("expected .transcript, got \(outcome)")
      return
    }
    #expect(result.text == "streamed-text", "streaming flush text is authoritative")
    #expect(result.language == "en")
    let mss = await backend.makeStreamingSessionCount
    #expect(mss == 1)
    let txCount = await backend.transcribeCount
    #expect(txCount == 0, "no batch decode when streaming flush succeeds")
    // Codex r4 P2: streaming success must still set the locked language-detection
    // state so downstream polish keeps per-language custom vocabulary.
    #expect(adapter.lastLanguageDetection?.lang == "en")
    #expect(adapter.lastLanguageDetection?.tier == .locked)
    #expect(adapter.lastLanguageDetection?.abstained == false)
    // #1309 effective-path telemetry: streaming delivered the transcript.
    let diag = adapter.lastASRDiagnostics
    #expect(diag?.streamingEffective == true)
    #expect(diag?.streamingDegradeReason == "none")
    #expect(diag?.streamingFinalPath == "streaming_flush")
    #expect(diag?.incrementalDecodeCount == 1)
    #expect(diag?.stopWhileDecodeInFlight == false)
    #expect(diag?.streamingMaxUnconfirmedWindowSec == 25.0)
  }

  @Test("streaming ON + auto language: degrades to clean batch, no streaming session")
  func streamingAutoDegradesToBatch() async throws {
    let backend = StubWhisperKitBackend()
    let stubSession = StubIncrementalSession(result: .accepted(text: "should-not-run"))
    await backend.setStreamingSessionFactory({ stubSession })
    await backend.setTranscribeResult(
      ASRResult(
        text: "auto-batch", language: "en", duration: 1, processingTime: 0.1,
        backendType: .whisperKit))
    let adapter = WhisperKitEngineAdapter(backend: backend)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: true)
    let mss = await backend.makeStreamingSessionCount
    #expect(mss == 0, "auto language never vends a streaming session")
    feed(adapter, samples: speechSamples(count: 16_000), session: sid)
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: 16_000)])
    let outcome = await adapter.finalize(batchSamples: nil)
    guard case .transcript(let result) = outcome else {
      Issue.record("expected .transcript, got \(outcome)")
      return
    }
    #expect(result.text == "auto-batch")
    let txCount = await backend.transcribeCount
    #expect(txCount == 1, "auto + streaming ON runs clean batch")
    // #1309: requested-but-degraded — the auto-language case (the issue's
    // named test scenario: requested=true, effective=false, reason=auto_language).
    let diag = adapter.lastASRDiagnostics
    #expect(diag?.streamingEffective == false)
    #expect(diag?.streamingDegradeReason == "auto_language")
    #expect(diag?.streamingFinalPath == "clean_batch")
  }

  @Test("streaming ON + locked but model not ready (nil vend): fail-open to clean batch")
  func streamingModelNotReadyFailsOpen() async throws {
    let backend = StubWhisperKitBackend()
    // No streamingSessionFactory set → makeStreamingSession returns nil.
    await backend.setTranscribeResult(
      ASRResult(
        text: "fallback-batch", language: "en", duration: 1, processingTime: 0.1,
        backendType: .whisperKit))
    let adapter = WhisperKitEngineAdapter(backend: backend)
    let sid = SessionID()
    try await adapter.beginSession(
      sid, options: TranscriptionOptions(language: "en"), streaming: true)
    feed(adapter, samples: speechSamples(count: 16_000), session: sid)
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: 16_000)])
    let outcome = await adapter.finalize(batchSamples: nil)
    guard case .transcript(let result) = outcome else {
      Issue.record("expected .transcript, got \(outcome)")
      return
    }
    #expect(result.text == "fallback-batch", "nil streaming vend → clean batch fallback")
    let txCount = await backend.transcribeCount
    #expect(txCount == 1)
    // #1309: model-not-ready degrade.
    let diag = adapter.lastASRDiagnostics
    #expect(diag?.streamingEffective == false)
    #expect(diag?.streamingDegradeReason == "model_not_ready")
    #expect(diag?.streamingFinalPath == "clean_batch")
  }

  @Test("streaming ON + locked but flush returns empty: fail-open to clean batch")
  func streamingEmptyFlushFailsOpen() async throws {
    let backend = StubWhisperKitBackend()
    let stubSession = StubIncrementalSession(
      result: .rejected(stopWhileDecodeInFlight: true))
    await backend.setStreamingSessionFactory({ stubSession })
    await backend.setTranscribeResult(
      ASRResult(
        text: "rescue-batch", language: "en", duration: 1, processingTime: 0.1,
        backendType: .whisperKit))
    let adapter = WhisperKitEngineAdapter(backend: backend)
    let sid = SessionID()
    try await adapter.beginSession(
      sid, options: TranscriptionOptions(language: "en"), streaming: true)
    feed(adapter, samples: speechSamples(count: 16_000), session: sid)
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: 16_000)])
    let outcome = await adapter.finalize(batchSamples: nil)
    guard case .transcript(let result) = outcome else {
      Issue.record("expected .transcript, got \(outcome)")
      return
    }
    #expect(result.text == "rescue-batch", "empty streaming flush → clean batch fallback")
    let mss = await backend.makeStreamingSessionCount
    #expect(mss == 1, "streaming session was started")
    let txCount = await backend.transcribeCount
    #expect(txCount == 1, "batch fallback ran after empty flush")
    // #1309: flush produced nothing → fallback_batch with flush_empty, and the
    // stop-mid-decode signal survives into the fallback's diagnostics
    // (Codex r1 P2 — it matters most exactly when the flush broke).
    let diag = adapter.lastASRDiagnostics
    #expect(diag?.streamingEffective == false)
    #expect(diag?.streamingDegradeReason == "flush_empty")
    #expect(diag?.streamingFinalPath == "fallback_batch")
    #expect(diag?.stopWhileDecodeInFlight == true)
    // Codex r2: the flush's counters survive the fallback too.
    #expect(diag?.incrementalDecodeCount == 0)
    #expect(diag?.incrementalTailDecodeMs == 0)
    #expect(diag?.streamingMaxUnconfirmedWindowSec == 25.0)
  }

  @Test("streaming OFF + locked: no streaming session, clean batch")
  func streamingOffUsesBatch() async throws {
    let backend = StubWhisperKitBackend()
    let stubSession = StubIncrementalSession(result: .accepted(text: "should-not-run"))
    await backend.setStreamingSessionFactory({ stubSession })
    await backend.setTranscribeResult(
      ASRResult(
        text: "off-batch", language: "en", duration: 1, processingTime: 0.1,
        backendType: .whisperKit))
    let adapter = WhisperKitEngineAdapter(backend: backend)
    let sid = SessionID()
    try await adapter.beginSession(
      sid, options: TranscriptionOptions(language: "en"), streaming: false)
    let mss = await backend.makeStreamingSessionCount
    #expect(mss == 0, "toggle off never vends a streaming session")
    feed(adapter, samples: speechSamples(count: 16_000), session: sid)
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: 16_000)])
    let outcome = await adapter.finalize(batchSamples: nil)
    guard case .transcript(let result) = outcome else {
      Issue.record("expected .transcript, got \(outcome)")
      return
    }
    #expect(result.text == "off-batch")
    // #1309: not requested → disabled / clean_batch.
    let diag = adapter.lastASRDiagnostics
    #expect(diag?.streamingEffective == false)
    #expect(diag?.streamingDegradeReason == "disabled")
    #expect(diag?.streamingFinalPath == "clean_batch")
  }

  // MARK: Finalize — coordinate space (council F1 / OQ-1)

  @Test(
    "batchSamplesIgnored: adapter passes its own retainedPCM-derived samples, not batchSamples (council F1 / OQ-1)"
  )
  func batchSamplesIgnored() async throws {
    let backend = StubWhisperKitBackend()
    await backend.setTranscribeResult(
      ASRResult(
        text: "decoded", language: "en", duration: 1, processingTime: 0.1,
        backendType: .whisperKit))
    let adapter = WhisperKitEngineAdapter(backend: backend)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: false)
    let retained: [Float] = (0..<16_000).map { _ in 0.1 }
    feed(adapter, samples: retained, session: sid)
    // The 1-arg test overload sets the authoritative capture buffer to the
    // fed retained PCM (all 0.1).
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: 16_000)])
    // Pass a distinct, easily-identifiable batchSamples — the WhisperKit
    // adapter MUST ignore `finalize`'s batchSamples and decode the
    // observe-provided capture buffer instead (#827).
    let distinct: [Float] = [Float](repeating: 0.99, count: 16_000)
    _ = await adapter.finalize(batchSamples: distinct)
    let lastSamples = await backend.lastTranscribeSamples
    // The adapter pads via `paddedASRSamples(rawSamples:)`; samples shorter
    // than `minimumTranscriptionSamples` get zero-padded. 16_000 == minimum,
    // so the passed-in payload is the capture buffer (all 0.1), not the 0.99
    // distinct `batchSamples`.
    #expect(lastSamples.first == Float(0.1))
    #expect(lastSamples.contains(where: { $0 == Float(0.99) }) == false)
  }

  @Test(
    "clipTimestampsDerivedFromObservedSegments: decodeOptions.speechSegments threaded from observe")
  func clipTimestampsDerivedFromObservedSegments() async throws {
    let backend = StubWhisperKitBackend()
    await backend.setTranscribeResult(
      ASRResult(
        text: "ok", language: "en", duration: 1, processingTime: 0.1,
        backendType: .whisperKit))
    let adapter = WhisperKitEngineAdapter(backend: backend)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: false)
    feed(adapter, samples: speechSamples(count: 16_000), session: sid)
    let segments = [
      SpeechSegment(startSample: 0, endSample: 8_000),
      SpeechSegment(startSample: 12_000, endSample: 16_000),
    ]
    adapter.observeSpeechSegments(segments)
    _ = await adapter.finalize(batchSamples: nil)
    let opts = await backend.lastTranscribeOptions
    #expect(opts.speechSegments.count == 2)
    #expect(opts.speechSegments[0].startSample == 0)
    #expect(opts.speechSegments[0].endSample == 8_000)
    #expect(opts.speechSegments[1].startSample == 12_000)
    #expect(opts.speechSegments[1].endSample == 16_000)
  }

  // MARK: Adversarial / stale guards

  @Test("cancelPendingUnload is idempotent — multiple calls do not crash")
  func cancelPendingUnloadIdempotent() {
    let adapter = WhisperKitEngineAdapter(backend: StubWhisperKitBackend())
    adapter.cancelPendingUnload()
    adapter.cancelPendingUnload()
    adapter.cancelPendingUnload()
    // No crash, no observable effect — passes if it returns.
  }

  @Test(
    "staleFeedDropped: a buffer fed after cancel + new beginSession does not appear in the fresh session's PCM"
  )
  func staleFeedDropped() async throws {
    let backend = StubWhisperKitBackend()
    let adapter = WhisperKitEngineAdapter(backend: backend)
    let sidA = SessionID()
    try await adapter.beginSession(sidA, options: .default, streaming: false)
    feed(adapter, samples: [0.1, 0.1], session: sidA)
    await adapter.cancel()
    let sidB = SessionID()
    try await adapter.beginSession(sidB, options: .default, streaming: false)
    feed(adapter, samples: [0.2, 0.2], session: sidB)
    let pcm = adapter.retainedPCMForTests
    #expect(pcm == [Float(0.2), Float(0.2)])
  }

  @Test("staleFinalize: a stale finalize during a fresh session does not clobber lastResult")
  func staleFinalizeGuard() async throws {
    let backend = StubWhisperKitBackend()
    await backend.setSlowTranscribe(true)
    await backend.setTranscribeResult(
      ASRResult(
        text: "stale-text", language: "en", duration: 1, processingTime: 0.1,
        backendType: .whisperKit))
    let adapter = WhisperKitEngineAdapter(backend: backend)
    let sidA = SessionID()
    try await adapter.beginSession(sidA, options: .default, streaming: false)
    feed(adapter, samples: speechSamples(count: 16_000), session: sidA)
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: 16_000)])
    async let outcomeA = adapter.finalize(batchSamples: nil)
    // Signal-wait until finalize actually entered the slow transcribe path,
    // rather than racing a fixed yield budget — `async let` schedules finalize
    // but doesn't guarantee it reached the suspend point (#875;
    // no-arbitrary-timeouts.md `prefer-signal-based-detection`).
    await backend.waitForTranscribeCount(1)
    // Session B begins while A's finalize is still suspended in transcribe.
    try await adapter.beginSession(SessionID(), options: .default, streaming: false)
    _ = await outcomeA
    #expect(
      adapter.lastResult == nil,
      "stale finalize must skip post-await mutations; session B's lastResult stays clean")
  }

  @Test(
    "staleFinalize must NOT clear session B's PCM/segments (Codex code-diff defect 3)"
  )
  func staleFinalizeMustNotClearFreshSessionState() async throws {
    let backend = StubWhisperKitBackend()
    await backend.setSlowTranscribe(true)
    await backend.setTranscribeResult(
      ASRResult(
        text: "stale-text", language: "en", duration: 1, processingTime: 0.1,
        backendType: .whisperKit))
    let adapter = WhisperKitEngineAdapter(backend: backend)
    let sidA = SessionID()
    try await adapter.beginSession(sidA, options: .default, streaming: false)
    feed(adapter, samples: speechSamples(count: 16_000), session: sidA)
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: 16_000)])
    async let outcomeA = adapter.finalize(batchSamples: nil)
    // Signal-wait until finalize entered transcribe (#875).
    await backend.waitForTranscribeCount(1)
    // Session B begins, feeds fresh audio + segments.
    let sidB = SessionID()
    try await adapter.beginSession(sidB, options: .default, streaming: false)
    let freshSamples: [Float] = [Float](repeating: 0.42, count: 16_000)
    feed(adapter, samples: freshSamples, session: sidB)
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: 8_000)])
    // The stale finalize resolves while session B is mid-flight.
    _ = await outcomeA
    // Session B's PCM and segments must remain intact — the stale guard must
    // only return, not mutate fresh state.
    #expect(
      adapter.retainedPCMForTests == freshSamples, "session B's PCM was cleared by stale finalize")
    #expect(
      adapter.observedSpeechSegmentsForTests.count == 1,
      "session B's observed segments were cleared by stale finalize")
    #expect(
      adapter.observedSpeechSegmentsForTests.first?.endSample == 8_000,
      "session B's segment payload was mutated by stale finalize")
  }

  // MARK: Cleanup

  @Test("applyUnloadPolicy(.never) schedules no unload task")
  func applyUnloadPolicyNever() async throws {
    let backend = StubWhisperKitBackend()
    let adapter = WhisperKitEngineAdapter(backend: backend)
    try await adapter.warmUp()
    adapter.applyUnloadPolicy(.never)
    // `.never` arms no task — the inspector is nil synchronously after the
    // call, so no unload can fire. Assert directly instead of yield-polling
    // for an absence (#875).
    #expect(adapter.modelUnloadTaskForUnitTests == nil, ".never schedules no unload task")
    let count = await backend.unloadCount
    #expect(count == 0)
  }

  @Test("applyUnloadPolicy(.immediately) calls backend.unload()")
  func applyUnloadPolicyImmediately() async throws {
    let backend = StubWhisperKitBackend()
    let adapter = WhisperKitEngineAdapter(backend: backend)
    try await adapter.warmUp()
    adapter.applyUnloadPolicy(.immediately)
    // Await the armed unload task deterministically (release-config CI does
    // not complete it within a fixed `Task.yield()` budget — #874 red main).
    await adapter.modelUnloadTaskForUnitTests?.value
    let count = await backend.unloadCount
    #expect(count == 1)
  }

  @Test("cancelPendingUnload cancels the in-flight modelUnloadTask")
  func cancelPendingUnloadCancelsArmed() async throws {
    let backend = StubWhisperKitBackend()
    let adapter = WhisperKitEngineAdapter(backend: backend)
    try await adapter.warmUp()
    adapter.applyUnloadPolicy(.twoMinutes)
    // Capture the armed task, cancel it, then await the captured handle: its
    // sleep throws on cancellation and the task returns without unloading, so
    // the await is bounded (no fixed yield). Assert the inspector cleared and
    // no unload fired (#875).
    let armed = adapter.modelUnloadTaskForUnitTests
    adapter.cancelPendingUnload()
    await armed?.value
    #expect(
      adapter.modelUnloadTaskForUnitTests == nil, "cancelPendingUnload clears the armed task")
    let count = await backend.unloadCount
    #expect(count == 0, "armed timer was cancelled before its deadline; no unload fired")
  }

  // MARK: Engine interruption hook

  @Test("WhisperKit leaves onEngineInterrupted to the App router (settable but not auto-fired)")
  func engineInterruptedCallbackOwnership() async throws {
    let adapter = WhisperKitEngineAdapter(backend: StubWhisperKitBackend())
    var fired = false
    adapter.onEngineInterrupted = { fired = true }
    #expect(fired == false)
    // No mid-recording crash signal exists for WhisperKit today; the App
    // layer's `handleASRServiceInterruption` (Rung 5) wires the callback.
  }

  // MARK: Codex r7 matrix gap closure

  @Test(
    "finalize without an active session returns .empty(false) and never decodes (Codex r7 S0)"
  )
  func finalizeWithoutSessionShortCircuits() async {
    let backend = StubWhisperKitBackend()
    let adapter = WhisperKitEngineAdapter(backend: backend)
    let outcome = await adapter.finalize(batchSamples: nil)
    guard case .empty(let hadSpeechEvidence) = outcome, hadSpeechEvidence == false else {
      Issue.record("expected .empty(false), got \(outcome)")
      return
    }
    let txCount = await backend.transcribeCount
    let observeCount = await backend.observeLIDCount
    #expect(txCount == 0, "no transcribe runs without an active session")
    #expect(observeCount == 0, "no LID runs without an active session")
  }

  @Test(
    "finalize after a successful terminal finalize returns .empty(false) — no re-decode (Codex r7 S4)"
  )
  func finalizeAfterTerminalShortCircuits() async throws {
    let backend = StubWhisperKitBackend()
    await backend.setTranscribeResult(
      ASRResult(
        text: "first", language: "en", duration: 1, processingTime: 0.1,
        backendType: .whisperKit))
    let adapter = WhisperKitEngineAdapter(backend: backend)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: false)
    feed(adapter, samples: speechSamples(count: 16_000), session: sid)
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: 16_000)])
    _ = await adapter.finalize(batchSamples: nil)
    let txCountAfterFirst = await backend.transcribeCount
    // Second finalize on the same terminal session must short-circuit.
    let outcome = await adapter.finalize(batchSamples: nil)
    guard case .empty(let hadSpeechEvidence) = outcome, hadSpeechEvidence == false else {
      Issue.record("expected .empty(false) on re-finalize, got \(outcome)")
      return
    }
    let txCountAfterSecond = await backend.transcribeCount
    #expect(
      txCountAfterFirst == txCountAfterSecond,
      "second finalize must NOT call transcribe again")
  }

  @Test(
    "observeSpeechSegments is dropped after cancel and after a terminal finalize (Codex r7 S3/S4)"
  )
  func observeSpeechSegmentsDroppedAfterTerminal() async throws {
    let backend = StubWhisperKitBackend()
    await backend.setTranscribeResult(
      ASRResult(
        text: "done", language: "en", duration: 1, processingTime: 0.1,
        backendType: .whisperKit))
    let adapter = WhisperKitEngineAdapter(backend: backend)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: false)
    feed(adapter, samples: speechSamples(count: 16_000), session: sid)
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: 16_000)])
    _ = await adapter.finalize(batchSamples: nil)
    // After terminal finalize, late observe must NOT repopulate.
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: 99_999)])
    #expect(
      adapter.observedSpeechSegmentsForTests.isEmpty,
      "post-terminal observeSpeechSegments must be a no-op")
  }

  @Test(
    "observeSpeechSegments is dropped after cancel (Codex r7 S3)"
  )
  func observeSpeechSegmentsDroppedAfterCancel() async throws {
    let backend = StubWhisperKitBackend()
    let adapter = WhisperKitEngineAdapter(backend: backend)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: false)
    await adapter.cancel()
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: 99_999)])
    #expect(
      adapter.observedSpeechSegmentsForTests.isEmpty,
      "post-cancel observeSpeechSegments must be a no-op")
  }

  @Test(
    "observeSpeechSegments without a live session is dropped (Codex r7 S0)"
  )
  func observeSpeechSegmentsWithoutSessionIsDropped() {
    let adapter = WhisperKitEngineAdapter(backend: StubWhisperKitBackend())
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: 16_000)])
    #expect(
      adapter.observedSpeechSegmentsForTests.isEmpty,
      "observeSpeechSegments without a live session must be a no-op")
  }

  // MARK: PR-5 Rung 5 UAT #827 — batch decode uses the authoritative capture buffer

  @Test(
    "observeSpeechSegments stores segments unshifted in the capture coordinate"
  )
  func observeSpeechSegmentsStoresUnshifted() async throws {
    let backend = StubWhisperKitBackend()
    let adapter = WhisperKitEngineAdapter(backend: backend)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: false)
    // Segments index into `rawCaptureSamples` (the kernel's captureResult.samples),
    // NOT the adapter's retainedPCM shadow buffer — so they are stored verbatim,
    // no pre-roll shift (#827 reverses the prior shift).
    adapter.observeSpeechSegments(
      [SpeechSegment(startSample: 100, endSample: 15_000)],
      rawCaptureSamples: [Float](repeating: 0.1, count: 16_000)
    )
    let stored = adapter.observedSpeechSegmentsForTests
    #expect(stored.first?.startSample == 100, "segments stored unshifted")
    #expect(stored.first?.endSample == 15_000)
  }

  @Test(
    "batch decode uses rawCaptureSamples even when it is LONGER than retainedPCM (#827 nil-samples regression)"
  )
  func batchDecodeUsesCaptureBufferNotShadowPCM() async throws {
    // Reproduces the alternating "Audio samples are nil" shape: the adapter's
    // async-fed `retainedPCM` is SHORTER than the kernel's authoritative
    // `captureResult.samples`, and a VAD segment runs to the full capture
    // length. The fix decodes the capture buffer (segment in range), not the
    // shorter shadow buffer (which would overrun → nil).
    let backend = StubWhisperKitBackend()
    await backend.setTranscribeResult(
      ASRResult(
        text: "decoded", language: "en", duration: 1, processingTime: 0.1,
        backendType: .whisperKit))
    let adapter = WhisperKitEngineAdapter(backend: backend)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: false)
    // Shadow buffer (retainedPCM): 16_000 samples of 0.1, fed async.
    feed(adapter, samples: [Float](repeating: 0.1, count: 16_000), session: sid)
    // Authoritative capture buffer: LONGER (24_000) and a distinct value, with
    // a segment running to its full length.
    let capture = [Float](repeating: 0.5, count: 24_000)
    adapter.observeSpeechSegments(
      [SpeechSegment(startSample: 0, endSample: 24_000)], rawCaptureSamples: capture)
    let outcome = await adapter.finalize(batchSamples: nil)
    guard case .transcript = outcome else {
      Issue.record("expected .transcript (no nil-samples failure), got \(outcome)")
      return
    }
    let lastSamples = await backend.lastTranscribeSamples
    #expect(
      lastSamples.count == 24_000,
      "decode must use the 24_000-sample capture buffer, not the 16_000 shadow PCM")
    #expect(
      lastSamples.first == Float(0.5), "decoded the capture buffer (0.5), not retainedPCM (0.1)")
  }

  @Test(
    "applyUnloadPolicy refuses to arm during an active session (Codex r7 S1)"
  )
  func applyUnloadPolicyRefusedDuringActiveSession() async throws {
    let backend = StubWhisperKitBackend()
    let adapter = WhisperKitEngineAdapter(backend: backend)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: false)
    adapter.applyUnloadPolicy(.immediately)
    // applyUnloadPolicy refuses to arm during an active session — the
    // inspector is nil synchronously after the call, so no unload task exists
    // to fire. Assert directly instead of yield-polling for an absence (#875).
    #expect(
      adapter.modelUnloadTaskForUnitTests == nil,
      "no unload task may be armed during an active session")
    let count = await backend.unloadCount
    #expect(count == 0, "unload must NOT fire while a session is active")
  }

  @Test(
    "applyUnloadPolicy armed under session A does NOT unload after beginSession(B) (Codex r7 S5)"
  )
  func applyUnloadPolicyArmedUnderADoesNotFireUnderB() async throws {
    let backend = StubWhisperKitBackend()
    let adapter = WhisperKitEngineAdapter(backend: backend)
    // Drive A through to terminal (so applyUnloadPolicy may arm).
    let sidA = SessionID()
    try await adapter.beginSession(sidA, options: .default, streaming: false)
    await backend.setTranscribeResult(
      ASRResult(
        text: "done", language: "en", duration: 1, processingTime: 0.1,
        backendType: .whisperKit))
    feed(adapter, samples: speechSamples(count: 16_000), session: sidA)
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: 16_000)])
    _ = await adapter.finalize(batchSamples: nil)
    // Now apply policy in the terminal A state — armed unload task starts.
    adapter.applyUnloadPolicy(.immediately)
    // Capture A's armed task with a synchronous read (no MainActor yield), so
    // beginSession(B)'s synchronous prefix still cancels + clears it before it
    // can run. Begin B, then await the captured handle: cancellation + the
    // session-keying re-check make it return without unloading — bounded (#875).
    let armedUnderA = adapter.modelUnloadTaskForUnitTests
    try await adapter.beginSession(SessionID(), options: .default, streaming: false)
    await armedUnderA?.value
    #expect(
      adapter.modelUnloadTaskForUnitTests == nil,
      "beginSession(B) cancels and clears A's armed unload task")
    let count = await backend.unloadCount
    #expect(count == 0, "unload from A's armed task must NOT fire under B")
  }

  // MARK: Production-unwired sanity

  @Test("WhisperKitEngineAdapter exists at Sources/EnviousWisprPipeline/")
  func productionFileExists() throws {
    let path = "Sources/EnviousWisprPipeline/WhisperKitEngineAdapter.swift"
    let url = repoRoot().appending(path: path)
    #expect(FileManager.default.fileExists(atPath: url.path))
  }

  // MARK: Helpers

  /// Feed one synthetic buffer stamped with `session` — the kernel always
  /// hands the adapter buffers stamped with the begun session.
  private func feed(_ adapter: WhisperKitEngineAdapter, samples: [Float], session: SessionID) {
    guard let buffer = FakeAudioCapture.makeBuffer(samples: samples) else {
      Issue.record("failed to synthesize a test buffer")
      return
    }
    adapter.acceptAudio(
      AudioBufferHandoff(
        buffer: buffer, frameCount: samples.count, sequence: 1, sessionID: session))
  }

  /// 16 kHz mono Float32 samples with small non-zero amplitude (so VAD-derived
  /// LID padded samples never collapse to silence padding).
  private func speechSamples(count: Int) -> [Float] {
    (0..<count).map { _ in 0.1 }
  }

  private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}

// MARK: - Test-only inspectors on the adapter

extension WhisperKitEngineAdapter {
  var retainedPCMForTests: [Float] { retainedPCMForUnitTests }
  var observedSpeechSegmentsForTests: [SpeechSegment] { observedSpeechSegmentsForUnitTests }

  /// Test-only convenience that calls the production
  /// `observeSpeechSegments(_:rawCaptureSamples:)` with `rawCaptureSamples` set
  /// to the adapter's current retained PCM — so lifecycle/storage tests that
  /// fed audio via `acceptAudio` decode that same audio without supplying a
  /// separate capture buffer. Tests that exercise the #827 fix (segments
  /// indexing a capture buffer longer than retained PCM) use the two-arg
  /// signature directly. Production callers (the kernel) always pass
  /// `captureResult.samples`.
  func observeSpeechSegments(_ segments: [SpeechSegment]) {
    observeSpeechSegments(segments, rawCaptureSamples: retainedPCMForUnitTests)
  }
}
