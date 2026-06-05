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
  var gateLoadModel = false
  private var loadGate: CheckedContinuation<Void, Never>?

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

  func loadModel() async throws {
    loadModelCount += 1
    if gateLoadModel {
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in loadGate = c }
    }
    isModelLoaded = true
  }

  func releaseLoadGate() {
    loadGate?.resume()
    loadGate = nil
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
