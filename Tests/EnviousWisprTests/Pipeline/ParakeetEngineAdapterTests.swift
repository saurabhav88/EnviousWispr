@preconcurrency import AVFoundation
import EnviousWisprASR
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - ParakeetEngineAdapterTests (epic #827, PR-4 §11.4)
//
// Unit coverage for `ParakeetEngineAdapter` — the production `ASREngineAdapter`
// Parakeet conformer. Drives a configurable `StubParakeetASRManager`; the PR-1 §B.2.2
// MUST / MUST NOT clauses get adversarial coverage.

@MainActor
@Suite struct ParakeetEngineAdapterTests {

  // MARK: Identity (PR-5 Rung 1)

  @Test("engineIdentity: Parakeet declares .parakeet backend")
  func engineIdentityBackend() {
    let adapter = ParakeetEngineAdapter(asrManager: StubParakeetASRManager())
    #expect(adapter.engineIdentity.backendType == .parakeet)
    #expect(adapter.engineIdentity.rawValue == "parakeet")
  }

  @Test("engineIdentity: Parakeet displayName == Parakeet v3")
  func engineIdentityDisplayName() {
    let adapter = ParakeetEngineAdapter(asrManager: StubParakeetASRManager())
    #expect(adapter.engineIdentity.displayName == "Parakeet v3")
  }

  // MARK: Capabilities + readiness

  @Test("capabilities: Parakeet streams, detects no language, decodes conditioned batch")
  func capabilities() {
    let adapter = ParakeetEngineAdapter(asrManager: StubParakeetASRManager())
    #expect(adapter.capabilities.supportsStreaming)
    #expect(!adapter.capabilities.supportsLanguageDetection)
    // #950 — Parakeet decodes the kernel-conditioned (VAD-trimmed) batch buffer,
    // so the tail-trim diagnostic applies to it.
    #expect(adapter.capabilities.decodesConditionedBatchSamples)
  }

  @Test("readiness reflects the ASR manager's load state")
  func readiness() {
    let manager = StubParakeetASRManager()
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    #expect(adapter.readiness == .notReady)
    manager.isModelLoaded = true
    #expect(adapter.readiness == .ready)
  }

  // MARK: warmUp

  @Test("warmUp() loads the model when not loaded")
  func warmUpLoads() async throws {
    let manager = StubParakeetASRManager()
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    try await adapter.warmUp()
    #expect(manager.loadModelCount == 1)
  }

  @Test("warmUp() is idempotent — a no-op when already loaded")
  func warmUpIdempotent() async throws {
    let manager = StubParakeetASRManager()
    manager.isModelLoaded = true
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    try await adapter.warmUp()
    #expect(manager.loadModelCount == 0)
  }

  // MARK: Stale-helper transport recovery (#1525 PR I-B)

  @Test("warmUp() retries once and succeeds after XPCASRTransportError.serviceUnreachable")
  func warmUpRetriesOnServiceUnreachable() async throws {
    let manager = StubParakeetASRManager()
    manager.loadModelError = XPCASRTransportError.serviceUnreachable
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    try await adapter.warmUp()
    #expect(manager.loadModelCount == 2)
    #expect(manager.isModelLoaded)
  }

  /// #1525 PR I-B narrowing-regression: `XPCASRTransportError`'s 6 new
  /// codec/transport cases are NOT "the XPC service is unreachable" — a bare
  /// `catch is XPCASRTransportError` would have retried a reload for, say,
  /// `.requestDecodingFailed`, masking a real codec bug.
  @Test(
    "warmUp() does NOT retry on the new XPCASRTransportError cases — they propagate",
    arguments: [
      XPCASRTransportError.requestEncodingFailed("x"),
      .invalidSamplePayload("x"),
      .requestDecodingFailed("x"),
      .modelNotLoaded,
      .responseEncodingFailed("x"),
      .responseDecodingFailed("x"),
    ]
  )
  func warmUpDoesNotRetryOnNewTransportCases(error: XPCASRTransportError) async throws {
    let manager = StubParakeetASRManager()
    manager.loadModelError = error
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    await #expect(throws: XPCASRTransportError.self) {
      try await adapter.warmUp()
    }
    #expect(manager.loadModelCount == 1)
  }

  // MARK: Streaming finalize + batch rescue (§3.2a)

  @Test("finalize: streaming success returns the streaming transcript")
  func streamingSuccess() async throws {
    let manager = StubParakeetASRManager()
    manager.finalizeStreamingResult = makeResult("streamed text")
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    try await adapter.beginSession(SessionID(), options: .default, streaming: true)
    let outcome = await adapter.finalize(batchSamples: nil)
    guard case .transcript(let result) = outcome else {
      Issue.record("expected .transcript, got \(outcome)")
      return
    }
    #expect(result.text == "streamed text")
    #expect(manager.transcribeCount == 0, "no batch rescue when streaming succeeds")
  }

  @Test("finalize: streaming empty + speech evidence runs the batch rescue over retained PCM")
  func streamingEmptyTriggersBatchRescue() async throws {
    let manager = StubParakeetASRManager()
    manager.finalizeStreamingResult = makeResult("")  // streaming returns empty
    manager.transcribeResult = makeResult("rescued text")
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: true)
    feed(adapter, samples: [0.1, 0.2, 0.3], session: sid)
    feed(adapter, samples: [0.4, 0.5], session: sid)
    let outcome = await adapter.finalize(batchSamples: nil)
    guard case .transcript(let result) = outcome else {
      Issue.record("expected .transcript, got \(outcome)")
      return
    }
    #expect(result.text == "rescued text")
    #expect(manager.transcribeCount == 1, "the batch rescue ran")
    #expect(
      manager.lastTranscribeSamples == [0.1, 0.2, 0.3, 0.4, 0.5],
      "the batch rescue decoded the retained session PCM")
  }

  @Test("finalize: streaming-finalize throwing falls back to the batch rescue")
  func streamingThrowTriggersBatchRescue() async throws {
    let manager = StubParakeetASRManager()
    manager.finalizeStreamingThrows = true
    manager.transcribeResult = makeResult("rescued after throw")
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: true)
    feed(adapter, samples: [0.7], session: sid)
    let outcome = await adapter.finalize(batchSamples: nil)
    guard case .transcript(let result) = outcome else {
      Issue.record("expected .transcript, got \(outcome)")
      return
    }
    #expect(result.text == "rescued after throw")
  }

  @Test("finalize: streaming + batch both empty returns .empty(hadSpeechEvidence: true)")
  func bothEmpty() async throws {
    let manager = StubParakeetASRManager()
    manager.finalizeStreamingResult = makeResult("")
    manager.transcribeResult = makeResult("")
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: true)
    feed(adapter, samples: [0.1], session: sid)
    let outcome = await adapter.finalize(batchSamples: nil)
    guard case .empty(let hadSpeechEvidence) = outcome else {
      Issue.record("expected .empty, got \(outcome)")
      return
    }
    #expect(hadSpeechEvidence, "past the kernel's VAD gate, an empty decode is a real ASR failure")
  }

  @Test("beginSession(streaming: false) opens no live stream — batch decode after stop")
  func batchModeSkipsStreaming() async throws {
    let manager = StubParakeetASRManager()
    manager.transcribeResult = makeResult("batch decoded")
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    let sid = SessionID()
    // The user disabled live transcription — the kernel passes streaming: false.
    try await adapter.beginSession(sid, options: .default, streaming: false)
    feed(adapter, samples: [0.1, 0.2], session: sid)
    #expect(manager.startStreamingCount == 0, "streaming disabled — no live stream opened")
    let outcome = await adapter.finalize(batchSamples: nil)
    guard case .transcript(let result) = outcome else {
      Issue.record("expected .transcript, got \(outcome)")
      return
    }
    #expect(result.text == "batch decoded")
    #expect(manager.finalizeStreamingCount == 0, "no streaming finalize when streaming was off")
    #expect(manager.transcribeCount == 1, "the batch rescue decoded the retained PCM")
    #expect(
      manager.lastTranscribeSamples == [0.1, 0.2],
      "the batch decode ran over the retained session PCM")
  }

  // MARK: Retained-PCM lifecycle

  @Test("retained PCM is cleared on finalize()")
  func pcmClearedOnFinalize() async throws {
    let manager = StubParakeetASRManager()
    manager.finalizeStreamingResult = makeResult("")
    manager.transcribeResult = makeResult("x")
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: true)
    feed(adapter, samples: [0.1, 0.2], session: sid)
    _ = await adapter.finalize(batchSamples: nil)
    // A fresh session must not see the prior session's PCM. Streaming empty +
    // a no-op batch over zero retained samples => .empty.
    manager.transcribeCount = 0
    manager.lastTranscribeSamples = []
    try await adapter.beginSession(SessionID(), options: .default, streaming: true)
    let outcome = await adapter.finalize(batchSamples: nil)
    guard case .empty = outcome else {
      Issue.record("expected .empty over cleared PCM, got \(outcome)")
      return
    }
    #expect(manager.transcribeCount == 0, "no retained PCM => no batch decode")
  }

  @Test("retained PCM is cleared on cancel()")
  func pcmClearedOnCancel() async throws {
    let manager = StubParakeetASRManager()
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: true)
    feed(adapter, samples: [0.1, 0.2], session: sid)
    await adapter.cancel()
    manager.transcribeResult = makeResult("")
    manager.finalizeStreamingResult = makeResult("")
    // After cancel, finalize() must short-circuit to .cancelled regardless.
    let outcome = await adapter.finalize(batchSamples: nil)
    guard case .cancelled = outcome else {
      Issue.record("expected .cancelled, got \(outcome)")
      return
    }
  }

  // MARK: #959 — cheap cancel() vs heavy recoverFromWedge() seam split

  @Test("#959 cancel() preserves a loaded model — no service-kill, readiness stays .ready")
  func cancelPreservesLoadedModel() async throws {
    let manager = StubParakeetASRManager()
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    try await adapter.warmUp()
    #expect(adapter.readiness == .ready)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: true)
    await adapter.cancel()
    #expect(
      manager.cancelInFlightLoadCount == 0,
      "ordinary discard must NOT call cancelInFlightLoad — the bug was tearing down a healthy engine"
    )
    #expect(manager.isModelLoaded, "resident model stays loaded after a cheap discard")
    #expect(adapter.readiness == .ready, "readiness must remain .ready after a discard (#959)")
  }

  @Test("#959 recoverFromWedge() tears the engine down — cancelInFlightLoad fires exactly once")
  func recoverFromWedgeTearsDownEngine() async throws {
    let manager = StubParakeetASRManager()
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    try await adapter.warmUp()
    await adapter.recoverFromWedge()
    #expect(
      manager.cancelInFlightLoadCount == 1,
      "wedge recovery is the ONLY path that invokes the #445 service-kill")
  }

  @Test("#959 cancel() still cancels an active streaming session (cheap-discard duties intact)")
  func cancelStillCancelsStreaming() async throws {
    let manager = StubParakeetASRManager()
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: true)
    await adapter.cancel()
    #expect(manager.cancelStreamingCount == 1, "cancel() must still tear down streaming")
    #expect(manager.cancelInFlightLoadCount == 0, "but must NOT kill the model load")
  }

  @Test("#959 cancel() during an IN-FLIGHT cold load releases it so the kernel unblocks (Codex P1)")
  func cancelDuringInFlightLoadReleasesIt() async throws {
    let manager = StubParakeetASRManager()
    manager.gateLoadModel = true
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    let warmTask = Task { @MainActor in try? await adapter.warmUp() }
    // Wait until warmUp() has entered loadModel() (parked on the gate) — now a
    // load is genuinely in flight (`isLoadInFlight == true`).
    while manager.loadModelCount == 0 { await Task.yield() }
    await adapter.cancel()
    #expect(
      manager.cancelInFlightLoadCount == 1,
      "cancel during an in-flight cold load must release it so the kernel's warmUp await unblocks")
    manager.releaseLoadGate()
    _ = await warmTask.value
  }

  @Test("finalize drains in-flight streaming feeds before finalizeStreaming")
  func finalizeDrainsStreamingFeeds() async throws {
    let manager = StubParakeetASRManager()
    manager.slowFeed = true  // feedAudio tasks are still in flight at finalize
    manager.finalizeStreamingResult = makeResult("streamed text")
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: true)
    feed(adapter, samples: [0.1], session: sid)
    feed(adapter, samples: [0.2], session: sid)
    _ = await adapter.finalize(batchSamples: nil)
    #expect(
      manager.feedAudioCount == 2,
      "finalize() waited for every dispatched feed — no tail buffer dropped")
  }

  @Test(
    "acceptAudio does not count a buffer whose feed throws (#867)",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/867",
      "feed-throw overcounts streamingBuffersFed")
  )
  func feedThrowDoesNotIncrementBuffersFed() async throws {
    let manager = StubParakeetASRManager()
    manager.feedAudioThrows = true  // every feed fails (transient ASR/XPC)
    manager.finalizeStreamingResult = makeResult("streamed text")
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: true)
    feed(adapter, samples: [0.1], session: sid)
    feed(adapter, samples: [0.2], session: sid)
    _ = await adapter.finalize(batchSamples: nil)
    let diag = try #require(adapter.lastASRDiagnostics)
    #expect(diag.streamingBuffersDispatched == 2, "both buffers were dispatched")
    #expect(
      diag.streamingBuffersFed == 0,
      "neither buffer counts as fed because the feed threw, preserving the dropped-feed signal for empty-result triage (#867)"
    )
  }

  @Test("acceptAudio counts every buffer whose feed succeeds (#867 success bracket)")
  func successfulFeedsAreAllCounted() async throws {
    let manager = StubParakeetASRManager()
    // feedAudioThrows stays false — every feed succeeds.
    manager.finalizeStreamingResult = makeResult("streamed text")
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: true)
    feed(adapter, samples: [0.1], session: sid)
    feed(adapter, samples: [0.2], session: sid)
    _ = await adapter.finalize(batchSamples: nil)
    let diag = try #require(adapter.lastASRDiagnostics)
    #expect(diag.streamingBuffersDispatched == 2)
    #expect(
      diag.streamingBuffersFed == 2,
      "the normal path still counts every successfully-fed buffer (no regression)")
  }

  // MARK: Stale-async session guards (Codex r2)

  @Test("a feed queued before a cancel is not fed into the terminated session")
  func staleFeedGuardOnCancel() async throws {
    let manager = StubParakeetASRManager()
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: true)
    feed(adapter, samples: [0.1], session: sid)  // dispatches a feed task
    // Capture the in-flight feed task BEFORE cancel (cancel clears the array).
    // cancel()'s synchronous prefix sets isTerminal/streamingActive before it
    // suspends, so the queued feed task runs after and sees the terminated
    // session. Await the captured handle deterministically — it guards on the
    // session check and returns without feeding (bounded; no fixed yield).
    let pendingFeeds = adapter.feedTasksForUnitTests
    await adapter.cancel()
    for task in pendingFeeds { await task.value }
    #expect(manager.feedAudioCount == 0, "the queued feed saw the terminated session and skipped")
  }

  @Test("a stale finalize does not clobber a session that began during its await")
  func staleFinalizeGuard() async throws {
    let manager = StubParakeetASRManager()
    manager.slowFinalizeStreaming = true
    manager.finalizeStreamingResult = makeResult("session A text")
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    let sidA = SessionID()
    try await adapter.beginSession(sidA, options: .default, streaming: true)
    feed(adapter, samples: [0.1], session: sidA)
    // finalize() for session A suspends inside the slow finalizeStreaming.
    async let outcomeA = adapter.finalize(batchSamples: nil)
    // Signal-wait until finalize actually entered finalizeStreaming, rather
    // than racing a fixed yield budget (#875).
    await manager.waitForFinalizeStreamingCount(1)
    // Session B begins while A's finalize is still suspended.
    try await adapter.beginSession(SessionID(), options: .default, streaming: true)
    _ = await outcomeA
    #expect(
      adapter.lastResult == nil,
      "the stale finalize skipped its post-await mutations — session B's state is intact")
  }

  // MARK: MUST / MUST NOT clauses (PR-1 §B.2.2)

  @Test("acceptAudio after a terminal session is a no-op")
  func acceptAudioAfterTerminalIsNoOp() async throws {
    let manager = StubParakeetASRManager()
    manager.finalizeStreamingResult = makeResult("done")
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: true)
    _ = await adapter.finalize(batchSamples: nil)
    let before = manager.feedAudioCount
    feed(adapter, samples: [0.9], session: sid)  // post-terminal — must be ignored
    #expect(manager.feedAudioCount == before, "no audio fed after a terminal session")
  }

  @Test("finalize() after cancel() returns .cancelled (never partial text)")
  func finalizeAfterCancel() async throws {
    let manager = StubParakeetASRManager()
    manager.finalizeStreamingResult = makeResult("would-be text")
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    try await adapter.beginSession(SessionID(), options: .default, streaming: true)
    await adapter.cancel()
    let outcome = await adapter.finalize(batchSamples: nil)
    guard case .cancelled = outcome else {
      Issue.record("expected .cancelled, got \(outcome)")
      return
    }
  }

  @Test("cancel() is idempotent")
  func cancelIdempotent() async throws {
    let manager = StubParakeetASRManager()
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    try await adapter.beginSession(SessionID(), options: .default, streaming: true)
    await adapter.cancel()
    await adapter.cancel()
    await adapter.cancel()
    // Three cancels behave as one — the adapter stays terminal-cancelled.
    let outcome = await adapter.finalize(batchSamples: nil)
    guard case .cancelled = outcome else {
      Issue.record("expected .cancelled, got \(outcome)")
      return
    }
  }

  @Test("beginSession cancels a pending model-unload timer from a prior session")
  func beginSessionCancelsIdleTimer() async throws {
    let manager = StubParakeetASRManager()
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    // A prior session armed a delayed unload.
    adapter.applyUnloadPolicy(.fiveMinutes)
    try await adapter.beginSession(SessionID(), options: .default, streaming: true)
    #expect(
      manager.cancelIdleTimerCount == 1,
      "beginSession cancels the idle timer so no unload fires mid-session")
  }

  @Test("applyUnloadPolicy forwards the policy to the ASR manager")
  func applyUnloadPolicy() {
    let manager = StubParakeetASRManager()
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    adapter.applyUnloadPolicy(.fiveMinutes)
    #expect(manager.lastUnloadPolicy == .fiveMinutes)
  }

  @Test("Parakeet leaves ASR service interruption ownership to ASREventRouter")
  func engineInterruptedCallbackOwnership() async throws {
    let manager = StubParakeetASRManager()
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    var fired = false
    adapter.onEngineInterrupted = { fired = true }
    // Fixer item #7 made ASREventRouter the sole owner of onServiceInterrupted;
    // the adapter-local hook remains optional and is not wired from this callback.
    #expect(manager.onServiceInterrupted == nil)
    #expect(!fired)
  }

  // MARK: #1707 — recoverFromASRInterruption

  @Test("recoverFromASRInterruption(): confirms readiness when the reload succeeds")
  func recoverFromASRInterruptionSucceeds() async {
    let manager = StubParakeetASRManager()
    let adapter = ParakeetEngineAdapter(
      asrManager: manager, asrInterruptionRecoveryDeadlineSec: 2.0)
    let outcome = await adapter.recoverFromASRInterruption()
    #expect(outcome == .readyForBatchDecode)
    #expect(manager.loadModelCount == 1, "recovery reuses warmUp()'s real load path, not a stub")
  }

  @Test("recoverFromASRInterruption(): returns .failed when the reload throws")
  func recoverFromASRInterruptionFailsOnThrow() async {
    struct SimulatedReloadFailure: Error {}
    let manager = StubParakeetASRManager()
    manager.loadModelError = SimulatedReloadFailure()
    let adapter = ParakeetEngineAdapter(
      asrManager: manager, asrInterruptionRecoveryDeadlineSec: 2.0)
    let outcome = await adapter.recoverFromASRInterruption()
    #expect(outcome == .failed)
  }

  @Test(
    "recoverFromASRInterruption(): deadline expiry returns .failed and ACTIVELY cancels the stale load"
  )
  func recoverFromASRInterruptionTimesOutAndSupersedes() async {
    // #1707 — the grounded-review r3/r4 fix: a bare abandoned `withDeadline`
    // would leave `cancelInFlightLoadCount == 0` (the load just keeps running
    // in the background); the ordered executor's synchronous `onTimeout`
    // must actively call `cancelInFlightLoad()` before this returns.
    let manager = StubParakeetASRManager()
    manager.gateLoadModel = true  // never released — forces the deadline to win
    let adapter = ParakeetEngineAdapter(
      asrManager: manager, asrInterruptionRecoveryDeadlineSec: 0.05)
    let outcome = await adapter.recoverFromASRInterruption()
    #expect(outcome == .failed)
    #expect(
      manager.cancelInFlightLoadCount == 1,
      "timeout must actively supersede the stale load, not just abandon it")
  }

  @Test("recoverFromASRInterruption(): succeeds when the reload completes just before the deadline")
  func recoverFromASRInterruptionSlowButSuccessful() async {
    let manager = StubParakeetASRManager()
    manager.gateLoadModel = true
    let adapter = ParakeetEngineAdapter(
      asrManager: manager, asrInterruptionRecoveryDeadlineSec: 2.0)
    let task = Task { await adapter.recoverFromASRInterruption() }
    while manager.loadModelCount == 0 { await Task.yield() }
    manager.releaseLoadGate()
    let outcome = await task.value
    #expect(outcome == .readyForBatchDecode)
    #expect(
      manager.cancelInFlightLoadCount == 0,
      "a successful reload must never trigger the timeout's active-cancel path")
  }

  @Test(
    "recoverFromASRInterruption(): a new session starting mid-attempt supersedes it — returns .cancelled"
  )
  func recoverFromASRInterruptionSupersededByNewSession() async {
    // #1707 — the attempt-scoped token's whole purpose: a stale recovery must
    // never report readiness for a session it no longer belongs to.
    let manager = StubParakeetASRManager()
    manager.gateLoadModel = true
    let adapter = ParakeetEngineAdapter(
      asrManager: manager, asrInterruptionRecoveryDeadlineSec: 2.0)
    let task = Task { await adapter.recoverFromASRInterruption() }
    while manager.loadModelCount == 0 { await Task.yield() }
    try? await adapter.beginSession(SessionID(), options: .default, streaming: false)
    manager.releaseLoadGate()
    let outcome = await task.value
    #expect(outcome == .cancelled)
  }

  @Test(
    "recoverFromASRInterruption(): a timed-out attempt's late-unwinding warmUp() does not clobber a legitimate successor warmUp() still in flight"
  )
  func recoverFromASRInterruptionStaleCleanupDoesNotClobberSuccessor() async {
    // Codex code-diff review r1 (P2): cancellation is cooperative — the
    // abandoned `warmUp()` behind a timed-out recovery attempt does not stop
    // just because its Task was `.cancel()`ed; it can unwind LATE, and its
    // `defer` would (without the `warmUpGeneration` fix) unconditionally
    // clear `loadProgressTickReporter`/`isLoadInFlight` out from under a
    // genuinely newer `warmUp()` call — e.g. the NEXT dictation's own
    // pre-recording warm-up starting immediately after the timeout.
    let manager = StubParakeetASRManager()
    manager.gateLoadModel = true
    let adapter = ParakeetEngineAdapter(
      asrManager: manager, asrInterruptionRecoveryDeadlineSec: 0.05)

    // Attempt #1 (stale): times out, but its own `warmUp()` Task stays parked
    // on the gate — the deadline firing does not unstick it.
    let recoveryOutcome = await adapter.recoverFromASRInterruption()
    #expect(recoveryOutcome == .failed)
    #expect(manager.loadModelCount == 1)

    // Attempt #2 (legitimate successor): genuinely in flight, its own
    // `loadProgressTickReporter` now installed.
    let task2 = Task { try? await adapter.warmUp() }
    while manager.loadModelCount < 2 { await Task.yield() }
    #expect(
      manager.loadProgressTickReporter != nil, "attempt #2 must have installed its own reporter")

    // Release ONLY attempt #1's (oldest, stale) gate — its `warmUp()` finally
    // unwinds and its `defer` runs while attempt #2 is STILL parked.
    manager.releaseLoadGate()
    for _ in 0..<20 { await Task.yield() }  // let attempt #1's Task actually unwind

    #expect(
      manager.loadProgressTickReporter != nil,
      "attempt #1's stale defer must not clear the reporter attempt #2 (still in flight) owns")

    manager.releaseLoadGate()  // release attempt #2, clean up
    _ = await task2.value
    #expect(
      manager.loadProgressTickReporter == nil,
      "attempt #2's OWN defer correctly clears it once IT concludes")
  }

  @Test(
    "recoverFromASRInterruption(): retires stale streamingActive so finalize does not try the streaming path first"
  )
  func recoverFromASRInterruptionRetiresStreamingState() async throws {
    // Premise 3: the crash handlers force `asrManager.isStreaming` false, but
    // this adapter's OWN `streamingActive` survives untouched — left
    // uncorrected, `finalize()` would try `finalizeStreamingWithRescue()`
    // first against a manager that no longer thinks it's streaming.
    let manager = StubParakeetASRManager()
    manager.finalizeStreamingResult = makeResult("streamed text")
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: true)
    feed(adapter, samples: [0.1, 0.2, 0.3], session: sid)

    _ = await adapter.recoverFromASRInterruption()

    let outcome = await adapter.finalize(batchSamples: nil)
    #expect(
      manager.finalizeStreamingCount == 0,
      "recovery must retire streamingActive so finalize takes the batch path")
    #expect(manager.transcribeCount == 1, "finalize must decode via the batch path instead")
    if case .transcript(let result) = outcome {
      #expect(result.text == manager.transcribeResult.text)
    } else {
      Issue.record("expected .transcript via batch decode, got \(outcome)")
    }
  }

  // MARK: #1707 Phase 2 — post-capture decode retry

  @Test("retryDecode() decodes the given samples and commits lastResult on success")
  func retryDecodeSucceeds() async throws {
    let manager = StubParakeetASRManager()
    manager.transcribeResult = makeResult("retried text")
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: false)

    let outcome = await adapter.retryDecode(inputSamples: [0.1, 0.2, 0.3])
    guard case .transcript(let result) = outcome else {
      Issue.record("expected .transcript, got \(outcome)")
      return
    }
    #expect(result.text == "retried text")
    #expect(adapter.lastResult?.text == "retried text")
    #expect(manager.transcribeCount == 1)
    #expect(manager.lastTranscribeSamples == [0.1, 0.2, 0.3])
  }

  @Test(
    "an adapter's own internal streaming-then-batch-rescue fallback and an explicit Phase-2 retryDecode are two distinct decode calls, never one shared budget"
  )
  func internalRescueAndPhase2RetryAreDistinctDecodeCalls() async throws {
    let manager = StubParakeetASRManager()
    // Streaming returns empty -> the internal batch-rescue fallback engages.
    manager.finalizeStreamingResult = ASRResult(
      text: "", language: "en", duration: 1, processingTime: 0, backendType: .parakeet)
    // The internal rescue's own batch decode also fails for real, exactly the
    // condition that makes the KERNEL spend its one Phase-2 retry.
    manager.transcribeThrows = true
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: true)
    feed(adapter, samples: [0.1], session: sid)

    let outcome = await adapter.finalize(batchSamples: nil)
    guard case .failed = outcome else {
      Issue.record("expected the internal rescue to also fail, got \(outcome)")
      return
    }
    #expect(
      manager.transcribeCount == 1,
      "the internal streaming-then-batch-rescue fallback is ONE decode call")

    // The kernel now spends its one Phase-2 retry — a second, independent
    // decode call, not a continuation of the internal rescue's own budget.
    manager.transcribeThrows = false
    manager.transcribeResult = makeResult("phase 2 retry text")
    let retryOutcome = await adapter.retryDecode(inputSamples: [0.4, 0.5])
    guard case .transcript(let retryResult) = retryOutcome else {
      Issue.record("expected the Phase-2 retry to recover a transcript, got \(retryOutcome)")
      return
    }
    #expect(retryResult.text == "phase 2 retry text")
    #expect(
      manager.transcribeCount == 2,
      "the internal fallback and the explicit Phase-2 retry are two distinct decode calls")
  }

  @Test(
    "retryDecode's readiness-gated repair re-checks staleness before spending the decode — a session change during the repair returns .cancelled and never decodes"
  )
  func retryDecodePostRepairStalenessRecheck() async throws {
    let manager = StubParakeetASRManager()
    manager.isModelLoaded = true
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    let sidA = SessionID()
    try await adapter.beginSession(sidA, options: .default, streaming: false)

    // Simulate the XPC helper dying mid-transcribe: readiness drops below
    // .ready, so retryDecode's repair-before-retry gate engages warmUp().
    manager.isModelLoaded = false
    manager.gateLoadModel = true
    async let outcome = adapter.retryDecode(inputSamples: [0.1, 0.2])
    // Wait until the repair warmUp() has genuinely entered loadModel().
    while manager.loadModelCount == 0 { await Task.yield() }

    // A new session begins while the repair is still in flight.
    try await adapter.beginSession(SessionID(), options: .default, streaming: false)
    manager.releaseLoadGate()

    guard case .cancelled = await outcome else {
      Issue.record("expected .cancelled from the post-repair staleness recheck")
      return
    }
    #expect(
      manager.transcribeCount == 0,
      "the decode attempt must never be spent once the repair discovers staleness")
  }

  @Test(
    "bumpRetryGeneration() — mirroring the kernel's own onTimeout closure — supersedes an in-flight retry so its eventual late completion is discarded, idempotently"
  )
  func bumpRetryGenerationSupersedesInFlightRetry() async throws {
    let manager = StubParakeetASRManager()
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: false)

    // Force retryDecode down its readiness-repair path so it parks on the
    // gated loadModel() — a deterministic stand-in for "the kernel's
    // withOrderedDeadline decided this retry took too long."
    manager.isModelLoaded = false
    manager.gateLoadModel = true
    manager.transcribeResult = makeResult("should be discarded")
    async let outcome = adapter.retryDecode(inputSamples: [0.1])
    while manager.loadModelCount == 0 { await Task.yield() }

    // Mirrors the kernel's onTimeout closure: bump the retry generation
    // (called twice — idempotent, never throws) BEFORE the parked repair
    // resolves.
    adapter.bumpRetryGeneration()
    adapter.bumpRetryGeneration()
    manager.releaseLoadGate()

    guard case .cancelled = await outcome else {
      Issue.record("expected the superseded retry to resolve .cancelled, not commit its decode")
      return
    }
    #expect(adapter.lastResult == nil, "the discarded retry's result must never reach lastResult")
  }

  @Test(
    "#1707 Codex r7: a retry's warmUp() repair throwing AFTER it was superseded by a new session must not write its stale error into lastFailureError"
  )
  func supersededRetryWarmUpFailureDoesNotPolluteNewSessionError() async throws {
    struct SimulatedRepairFailure: Error {}
    let manager = StubParakeetASRManager()
    manager.isModelLoaded = true
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: false)

    // Readiness drops below .ready, so retryDecode's repair-before-retry gate
    // engages warmUp() -> loadModel(). Park it, then queue a failure for
    // when it's released.
    manager.isModelLoaded = false
    manager.gateLoadModel = true
    manager.loadModelError = SimulatedRepairFailure()
    async let outcome = adapter.retryDecode(inputSamples: [0.1, 0.2])
    while manager.loadModelCount == 0 { await Task.yield() }

    // A new session begins BEFORE the parked repair resolves — mirrors the
    // kernel's onTimeout/new-session paths that make this retry stale.
    try await adapter.beginSession(SessionID(), options: .default, streaming: false)
    manager.releaseLoadGate()

    guard case .failed = await outcome else {
      Issue.record("expected the stale repair failure to still report .failed")
      return
    }
    #expect(
      adapter.lastFailureError == nil,
      "a stale, superseded retry's repair failure must never write lastFailureError — it would corrupt the NEW session's own error attribution"
    )
  }

  // MARK: Helpers

  /// Feed one synthetic buffer stamped with `session` — the kernel always
  /// hands the adapter buffers stamped with the begun session, and the
  /// adapter's streaming-feed guard drops a mismatched stamp.
  private func feed(_ adapter: ParakeetEngineAdapter, samples: [Float], session: SessionID) {
    guard let buffer = FakeAudioCapture.makeBuffer(samples: samples) else {
      Issue.record("failed to synthesize a test buffer")
      return
    }
    adapter.acceptAudio(
      AudioBufferHandoff(
        buffer: buffer, frameCount: samples.count, sequence: 1, sessionID: session))
  }

  private func makeResult(_ text: String) -> ASRResult {
    ASRResult(
      text: text, language: "en", duration: 1, processingTime: 0.1, backendType: .parakeet)
  }
}

// MARK: - StubParakeetASRManager

/// Configurable `ASRManagerInterface` stub for `ParakeetEngineAdapterTests`.
@MainActor
final class StubParakeetASRManager: ASRManagerInterface {
  var activeBackendType: ASRBackendType = .parakeet
  var isModelLoaded = false
  var isStreaming = false
  var downloadProgress: Double = 0
  var downloadPhase = "idle"
  var downloadDetail = ""
  var onServiceInterrupted: (() -> Void)?
  var loadProgressTickReporter: (@MainActor @Sendable (Date?, String) -> Void)?

  // Configurable behavior
  var supportsStreaming = true
  var startStreamingThrows = false
  var finalizeStreamingThrows = false
  var finalizeStreamingResult = ASRResult(
    text: "default", language: "en", duration: 1, processingTime: 0, backendType: .parakeet)
  var transcribeResult = ASRResult(
    text: "default-batch", language: "en", duration: 1, processingTime: 0,
    backendType: .parakeet)
  var transcribeThrows = false
  /// When set, `feedAudio` throws — models a transient ASR/XPC feed failure that
  /// the per-buffer feed task swallows (#867).
  var feedAudioThrows = false
  /// When set, `feedAudio` yields many times before completing — models a
  /// streaming feed still in flight when `finalize()` is called.
  var slowFeed = false
  /// When set, `finalizeStreaming` yields many times before returning — models
  /// a finalize suspended in ASR while a new session begins.
  var slowFinalizeStreaming = false
  /// #959: when set, `loadModel()` parks until `releaseLoadGate()` so a test can
  /// drive `cancel()` while a cold load is genuinely in flight (`isLoadInFlight`).
  /// #1707: a QUEUE (not a single slot) — lets a test park two independent
  /// overlapping `loadModel()` calls (e.g. a timed-out recovery attempt and a
  /// legitimate successor `warmUp()`) and release them in a specific order,
  /// which single-slot semantics could not represent (the second call would
  /// silently orphan the first's continuation).
  var gateLoadModel = false
  private var loadGates: [CheckedContinuation<Void, Never>] = []

  // Observed counters
  var loadModelCount = 0
  var startStreamingCount = 0
  var feedAudioCount = 0
  var finalizeStreamingCount = 0
  var cancelStreamingCount = 0
  var transcribeCount = 0
  var cancelInFlightLoadCount = 0
  var cancelIdleTimerCount = 0
  var lastUnloadPolicy: ModelUnloadPolicy?
  var lastTranscribeSamples: [Float] = []

  // Signal-based waiter for `finalizeStreamingCount` — `finalize` suspends
  // inside the slow finalizeStreaming, so the test awaits
  // `waitForFinalizeStreamingCount(1)` to know it entered, instead of
  // yield-polling (#875).
  private var finalizeStreamingWaiters = CountWaiters("finalizeStreamingCount")

  /// #1525 PR I-B: when set, `loadModel()` throws it on the NEXT call only,
  /// then clears itself — lets a test exercise `loadModelWithTransportRecovery`'s
  /// one-shot retry (a retry that SUCCEEDS second time) without looping forever.
  var loadModelError: (any Error)?

  func loadModel() async throws {
    loadModelCount += 1
    if gateLoadModel {
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in loadGates.append(c) }
    }
    // Checked AFTER the gate parks/releases so a test can script a load that
    // throws once resumed (#1707 Codex r7), not only an immediate throw.
    if let error = loadModelError {
      loadModelError = nil
      throw error
    }
    isModelLoaded = true
  }

  /// Releases the OLDEST still-parked `loadModel()` call (FIFO) — with one
  /// gated call in flight this is exactly the original single-slot behavior;
  /// with two, it lets a test control release order explicitly.
  func releaseLoadGate() {
    guard !loadGates.isEmpty else { return }
    loadGates.removeFirst().resume()
  }
  func unloadModel() async {}
  func setInitialBackendType(_ type: ASRBackendType) { activeBackendType = type }
  func switchBackend(to type: ASRBackendType) async { activeBackendType = type }

  var activeBackendSupportsStreaming: Bool { get async { supportsStreaming } }

  func transcribe(audioSamples: [Float], options: TranscriptionOptions) async throws -> ASRResult {
    transcribeCount += 1
    lastTranscribeSamples = audioSamples
    if transcribeThrows { throw FakeASRError.decode }
    return transcribeResult
  }

  func startStreaming(options: TranscriptionOptions) async throws {
    startStreamingCount += 1
    if startStreamingThrows { throw FakeASRError.streamingSetup }
    isStreaming = true
  }

  func feedAudio(_ buffer: AVAudioPCMBuffer) async throws {
    if slowFeed {
      for _ in 0..<100 { await Task.yield() }
    }
    if feedAudioThrows { throw FakeASRError.feed }
    feedAudioCount += 1
  }

  func finalizeStreaming() async throws -> ASRResult {
    finalizeStreamingCount += 1
    finalizeStreamingWaiters.notify(reached: finalizeStreamingCount)
    if slowFinalizeStreaming {
      for _ in 0..<200 { await Task.yield() }
    }
    if finalizeStreamingThrows { throw FakeASRError.decode }
    return finalizeStreamingResult
  }

  /// Await until `finalizeStreamingCount >= target`. Resolves immediately if
  /// already reached; always resolves within `timeout`.
  func waitForFinalizeStreamingCount(_ target: Int, timeout: Duration = .seconds(5)) async {
    if finalizeStreamingCount >= target { return }
    let id = UUID()
    let timeoutTask = Task { [weak self] in
      try? await Task.sleep(for: timeout)
      self?.resumeFinalizeStreamingWaiter(id)
    }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      finalizeStreamingWaiters.install(id: id, target: target, continuation)
    }
    timeoutTask.cancel()
  }

  private func resumeFinalizeStreamingWaiter(_ id: UUID) {
    finalizeStreamingWaiters.resume(id: id)
  }

  func cancelStreaming() async {
    cancelStreamingCount += 1
    isStreaming = false
  }
  func noteTranscriptionComplete(policy: ModelUnloadPolicy) { lastUnloadPolicy = policy }
  func cancelIdleTimer() { cancelIdleTimerCount += 1 }
  func cancelInFlightLoad() { cancelInFlightLoadCount += 1 }

  enum FakeASRError: Error { case streamingSetup, decode, feed }
}
