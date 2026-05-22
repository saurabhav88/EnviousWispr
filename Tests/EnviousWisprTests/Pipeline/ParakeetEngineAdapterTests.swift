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

  // MARK: Capabilities + readiness

  @Test("capabilities: Parakeet streams, detects no language")
  func capabilities() {
    let adapter = ParakeetEngineAdapter(asrManager: StubParakeetASRManager())
    #expect(adapter.capabilities.supportsStreaming)
    #expect(!adapter.capabilities.supportsLanguageDetection)
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
    try await adapter.beginSession(SessionID(), options: .default)
    let outcome = await adapter.finalize()
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
    try await adapter.beginSession(SessionID(), options: .default)
    feed(adapter, samples: [0.1, 0.2, 0.3])
    feed(adapter, samples: [0.4, 0.5])
    let outcome = await adapter.finalize()
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
    try await adapter.beginSession(SessionID(), options: .default)
    feed(adapter, samples: [0.7])
    let outcome = await adapter.finalize()
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
    try await adapter.beginSession(SessionID(), options: .default)
    feed(adapter, samples: [0.1])
    let outcome = await adapter.finalize()
    guard case .empty(let hadSpeechEvidence) = outcome else {
      Issue.record("expected .empty, got \(outcome)")
      return
    }
    #expect(hadSpeechEvidence, "past the kernel's VAD gate, an empty decode is a real ASR failure")
  }

  // MARK: Retained-PCM lifecycle

  @Test("retained PCM is cleared on finalize()")
  func pcmClearedOnFinalize() async throws {
    let manager = StubParakeetASRManager()
    manager.finalizeStreamingResult = makeResult("")
    manager.transcribeResult = makeResult("x")
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    try await adapter.beginSession(SessionID(), options: .default)
    feed(adapter, samples: [0.1, 0.2])
    _ = await adapter.finalize()
    // A fresh session must not see the prior session's PCM. Streaming empty +
    // a no-op batch over zero retained samples => .empty.
    manager.transcribeCount = 0
    manager.lastTranscribeSamples = []
    try await adapter.beginSession(SessionID(), options: .default)
    let outcome = await adapter.finalize()
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
    try await adapter.beginSession(SessionID(), options: .default)
    feed(adapter, samples: [0.1, 0.2])
    await adapter.cancel()
    manager.transcribeResult = makeResult("")
    manager.finalizeStreamingResult = makeResult("")
    // After cancel, finalize() must short-circuit to .cancelled regardless.
    let outcome = await adapter.finalize()
    guard case .cancelled = outcome else {
      Issue.record("expected .cancelled, got \(outcome)")
      return
    }
  }

  @Test("finalize drains in-flight streaming feeds before finalizeStreaming")
  func finalizeDrainsStreamingFeeds() async throws {
    let manager = StubParakeetASRManager()
    manager.slowFeed = true  // feedAudio tasks are still in flight at finalize
    manager.finalizeStreamingResult = makeResult("streamed text")
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    try await adapter.beginSession(SessionID(), options: .default)
    feed(adapter, samples: [0.1])
    feed(adapter, samples: [0.2])
    _ = await adapter.finalize()
    #expect(
      manager.feedAudioCount == 2,
      "finalize() waited for every dispatched feed — no tail buffer dropped")
  }

  // MARK: MUST / MUST NOT clauses (PR-1 §B.2.2)

  @Test("acceptAudio after a terminal session is a no-op")
  func acceptAudioAfterTerminalIsNoOp() async throws {
    let manager = StubParakeetASRManager()
    manager.finalizeStreamingResult = makeResult("done")
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    try await adapter.beginSession(SessionID(), options: .default)
    _ = await adapter.finalize()
    let before = manager.feedAudioCount
    feed(adapter, samples: [0.9])  // post-terminal — must be ignored
    #expect(manager.feedAudioCount == before, "no audio fed after a terminal session")
  }

  @Test("finalize() after cancel() returns .cancelled (never partial text)")
  func finalizeAfterCancel() async throws {
    let manager = StubParakeetASRManager()
    manager.finalizeStreamingResult = makeResult("would-be text")
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    try await adapter.beginSession(SessionID(), options: .default)
    await adapter.cancel()
    let outcome = await adapter.finalize()
    guard case .cancelled = outcome else {
      Issue.record("expected .cancelled, got \(outcome)")
      return
    }
  }

  @Test("cancel() is idempotent")
  func cancelIdempotent() async throws {
    let manager = StubParakeetASRManager()
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    try await adapter.beginSession(SessionID(), options: .default)
    await adapter.cancel()
    await adapter.cancel()
    await adapter.cancel()
    // Three cancels behave as one — the adapter stays terminal-cancelled.
    let outcome = await adapter.finalize()
    guard case .cancelled = outcome else {
      Issue.record("expected .cancelled, got \(outcome)")
      return
    }
  }

  @Test("applyUnloadPolicy forwards the policy to the ASR manager")
  func applyUnloadPolicy() {
    let manager = StubParakeetASRManager()
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    adapter.applyUnloadPolicy(.fiveMinutes)
    #expect(manager.lastUnloadPolicy == .fiveMinutes)
  }

  @Test("a mid-recording ASR-service crash drives onEngineInterrupted")
  func engineInterruptedBridge() async throws {
    let manager = StubParakeetASRManager()
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    var fired = false
    adapter.onEngineInterrupted = { fired = true }
    manager.onServiceInterrupted?()
    #expect(fired, "ASRManagerInterface.onServiceInterrupted bridges to onEngineInterrupted")
  }

  // MARK: Helpers

  private func feed(_ adapter: ParakeetEngineAdapter, samples: [Float]) {
    guard let buffer = FakeAudioCapture.makeBuffer(samples: samples) else {
      Issue.record("failed to synthesize a test buffer")
      return
    }
    adapter.acceptAudio(
      AudioBufferHandoff(
        buffer: buffer, frameCount: samples.count, sequence: 1, sessionID: SessionID()))
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
  /// When set, `feedAudio` yields many times before completing — models a
  /// streaming feed still in flight when `finalize()` is called.
  var slowFeed = false

  // Observed counters
  var loadModelCount = 0
  var startStreamingCount = 0
  var feedAudioCount = 0
  var finalizeStreamingCount = 0
  var cancelStreamingCount = 0
  var transcribeCount = 0
  var cancelInFlightLoadCount = 0
  var lastUnloadPolicy: ModelUnloadPolicy?
  var lastTranscribeSamples: [Float] = []

  func loadModel() async throws {
    loadModelCount += 1
    isModelLoaded = true
  }
  func loadModelSilently() async {}
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
    feedAudioCount += 1
  }

  func finalizeStreaming() async throws -> ASRResult {
    finalizeStreamingCount += 1
    if finalizeStreamingThrows { throw FakeASRError.decode }
    return finalizeStreamingResult
  }

  func cancelStreaming() async {
    cancelStreamingCount += 1
    isStreaming = false
  }
  func noteTranscriptionComplete(policy: ModelUnloadPolicy) { lastUnloadPolicy = policy }
  func cancelIdleTimer() {}
  func cancelInFlightLoad() { cancelInFlightLoadCount += 1 }

  enum FakeASRError: Error { case streamingSetup, decode }
}
