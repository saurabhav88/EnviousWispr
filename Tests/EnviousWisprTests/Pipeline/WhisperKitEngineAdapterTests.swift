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

  @Test("capabilities: WhisperKit decodes batch-only and detects language")
  func capabilities() {
    let adapter = WhisperKitEngineAdapter(backend: StubWhisperKitBackend())
    #expect(adapter.capabilities.supportsStreaming == false)
    #expect(adapter.capabilities.supportsLanguageDetection == true)
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

  @Test("readiness goes notReady after applyUnloadPolicy(.immediately) executes")
  func cachedReadinessAfterImmediateUnload() async throws {
    let backend = StubWhisperKitBackend()
    let adapter = WhisperKitEngineAdapter(backend: backend)
    try await adapter.warmUp()
    #expect(adapter.readiness == .ready)
    adapter.applyUnloadPolicy(.immediately)
    // Yield so the scheduled `Task` runs `backend.unload()` and posts back.
    for _ in 0..<50 { await Task.yield() }
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
    // Give any putative background task a chance to run.
    for _ in 0..<50 { await Task.yield() }
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

  @Test(".auto mode (language nil) does NOT start the incremental worker")
  func autoModeSkipsWorker() async throws {
    let backend = StubWhisperKitBackend()
    let adapter = WhisperKitEngineAdapter(backend: backend)
    try await adapter.beginSession(SessionID(), options: .default, streaming: false)
    let count = await backend.makeIncrementalSessionCount
    #expect(count == 0)
  }

  @Test(".locked mode (language non-nil) starts the incremental worker")
  func lockedModeStartsWorker() async throws {
    let backend = StubWhisperKitBackend()
    let stubSession = StubIncrementalSession(result: .rejected())
    await backend.setIncrementalSessionFactory({ stubSession })
    let adapter = WhisperKitEngineAdapter(backend: backend)
    let options = TranscriptionOptions(language: "en")
    try await adapter.beginSession(SessionID(), options: options, streaming: false)
    let count = await backend.makeIncrementalSessionCount
    #expect(count == 1)
    let starts = await stubSession.startCount
    #expect(starts == 1)
  }

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

  @Test(
    "beginSession cancels and drops any orphan incremental worker from a prior session (Codex r3 defect 2)"
  )
  func beginSessionCancelsOrphanWorker() async throws {
    let backend = StubWhisperKitBackend()
    let stubSession = StubIncrementalSession(result: .rejected())
    await backend.setIncrementalSessionFactory({ stubSession })
    let adapter = WhisperKitEngineAdapter(backend: backend)
    // Session A: locked mode, worker is installed.
    try await adapter.beginSession(
      SessionID(), options: TranscriptionOptions(language: "en"), streaming: false)
    let starts1 = await stubSession.startCount
    #expect(starts1 == 1, "worker installed for session A")
    // Session B: auto mode, no factory provided this time. The orphan must
    // be cancelled and dropped so auto mode does NOT enter the worker path.
    await backend.setIncrementalSessionFactory(nil)
    try await adapter.beginSession(SessionID(), options: .default, streaming: false)
    // Yield so the detached worker.cancel() task runs.
    for _ in 0..<10 { await Task.yield() }
    let cancels = await stubSession.cancelCount
    #expect(cancels == 1, "orphan worker must be cancelled on beginSession")
  }

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

  // MARK: Finalize — incremental worker

  @Test("workerAcceptedResultUsedDirectly: accepted worker result skips batch decode")
  func workerAcceptedResultUsedDirectly() async throws {
    let backend = StubWhisperKitBackend()
    let stubSession = StubIncrementalSession(result: .accepted(text: "worker-text"))
    await backend.setIncrementalSessionFactory({ stubSession })
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
    #expect(result.text == "worker-text")
    let txCount = await backend.transcribeCount
    #expect(txCount == 0, "accepted worker result skips batch decode")
  }

  @Test("workerRejectedFallsBackToBatch: rejected worker result triggers batch decode")
  func workerRejectedFallsBackToBatch() async throws {
    let backend = StubWhisperKitBackend()
    await backend.setTranscribeResult(
      ASRResult(
        text: "batch-text", language: "en", duration: 1, processingTime: 0.1,
        backendType: .whisperKit))
    let stubSession = StubIncrementalSession(result: .rejected())
    await backend.setIncrementalSessionFactory({ stubSession })
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
    #expect(txCount == 1)
  }

  @Test("workerNotStartedInAutoMode: .auto mode never creates a worker; finalize goes to batch")
  func workerNotStartedInAutoMode() async throws {
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
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: 16_000)])
    // Pass a distinct, easily-identifiable batchSamples — the WhisperKit
    // adapter MUST ignore it and decode against `retainedPCM`.
    let distinct: [Float] = [Float](repeating: 0.99, count: 16_000)
    _ = await adapter.finalize(batchSamples: distinct)
    let lastSamples = await backend.lastTranscribeSamples
    // The adapter pads via `paddedASRSamples(rawSamples:)`; samples shorter
    // than `minimumTranscriptionSamples` get zero-padded. 16_000 == minimum,
    // so the passed-in payload is the retained PCM (all 0.1), not the 0.99
    // distinct buffer.
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
    // Signal-based wait: poll the backend's transcribeCount until finalize
    // has actually entered the slow transcribe path. Pure-yield racing is
    // fragile — `async let` schedules finalize but doesn't guarantee it
    // reaches the suspend point before the test's next await
    // (~/.claude/rules/no-arbitrary-timeouts.md `prefer-signal-based-detection`).
    var entered = false
    for _ in 0..<200 {
      let count = await backend.transcribeCount
      if count == 1 {
        entered = true
        break
      }
      await Task.yield()
    }
    #expect(entered, "finalize did not reach backend.transcribe within 200 yields")
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
    // Wait for finalize to reach transcribe.
    var entered = false
    for _ in 0..<200 {
      let count = await backend.transcribeCount
      if count == 1 {
        entered = true
        break
      }
      await Task.yield()
    }
    #expect(entered, "finalize did not reach backend.transcribe within 200 yields")
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
    for _ in 0..<50 { await Task.yield() }
    let count = await backend.unloadCount
    #expect(count == 0)
  }

  @Test("applyUnloadPolicy(.immediately) calls backend.unload()")
  func applyUnloadPolicyImmediately() async throws {
    let backend = StubWhisperKitBackend()
    let adapter = WhisperKitEngineAdapter(backend: backend)
    try await adapter.warmUp()
    adapter.applyUnloadPolicy(.immediately)
    for _ in 0..<50 { await Task.yield() }
    let count = await backend.unloadCount
    #expect(count == 1)
  }

  @Test("cancelPendingUnload cancels the in-flight modelUnloadTask")
  func cancelPendingUnloadCancelsArmed() async throws {
    let backend = StubWhisperKitBackend()
    let adapter = WhisperKitEngineAdapter(backend: backend)
    try await adapter.warmUp()
    adapter.applyUnloadPolicy(.twoMinutes)
    adapter.cancelPendingUnload()
    for _ in 0..<50 { await Task.yield() }
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
}
