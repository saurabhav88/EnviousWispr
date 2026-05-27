@preconcurrency import AVFoundation
import EnviousWisprASR
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - ParakeetEngineAdapterLastResultLifecycleTests (epic #827, PR-5 Rung 2A)
//
// Mirrors `FakeEngineLastResultLifecycleTests` against the production
// Parakeet conformer using `StubParakeetASRManager` (declared at the bottom
// of `ParakeetEngineAdapterTests.swift`). The adversarial empty-finalize
// test exercises `finalizeBatch`'s `.empty(hadSpeechEvidence: true)` branch
// at `ParakeetEngineAdapter.swift:455-460`, the conformer's most
// regression-prone path.

@MainActor
@Suite struct ParakeetEngineAdapterLastResultLifecycleTests {

  @Test("lastResult is nil after beginSession()")
  func lastResultNilAfterBeginSession() async throws {
    let manager = StubParakeetASRManager()
    manager.finalizeStreamingResult = makeResult("first")
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: true)
    feed(adapter, samples: [0.1], session: sid)
    _ = await adapter.finalize(batchSamples: nil)
    #expect(adapter.lastResult != nil, "successful finalize set lastResult")
    // A fresh session must start with lastResult cleared.
    try await adapter.beginSession(SessionID(), options: .default, streaming: true)
    #expect(adapter.lastResult == nil)
  }

  @Test("lastResult is set after a successful .transcript finalize()")
  func lastResultSetAfterSuccessfulFinalize() async throws {
    let manager = StubParakeetASRManager()
    manager.finalizeStreamingResult = makeResult("streamed text")
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    try await adapter.beginSession(SessionID(), options: .default, streaming: true)
    let outcome = await adapter.finalize(batchSamples: nil)
    guard case .transcript = outcome else {
      Issue.record("expected .transcript, got \(outcome)")
      return
    }
    let result = try #require(adapter.lastResult)
    #expect(result.text == "streamed text")
    #expect(result.language == "en")
  }

  @Test("lastResult is nil after cancel()")
  func lastResultNilAfterCancel() async throws {
    let manager = StubParakeetASRManager()
    manager.finalizeStreamingResult = makeResult("done")
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: true)
    _ = await adapter.finalize(batchSamples: nil)
    #expect(adapter.lastResult != nil, "successful finalize set lastResult")
    await adapter.cancel()
    #expect(adapter.lastResult == nil, "cancel() must clear lastResult")
  }

  @Test("lastResult is NOT set on .empty / non-transcript finalize outcomes")
  func lastResultNotSetOnEmptyOrFailedFinalize() async throws {
    // Batch mode with an empty transcribe result drives finalizeBatch's
    // `.empty(hadSpeechEvidence: true)` branch (ParakeetEngineAdapter.swift:455-460).
    let manager = StubParakeetASRManager()
    manager.transcribeResult = makeResult("")  // empty -> .empty
    let adapter = ParakeetEngineAdapter(asrManager: manager)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: false)
    feed(adapter, samples: [0.1, 0.2], session: sid)
    let outcome = await adapter.finalize(batchSamples: nil)
    guard case .empty = outcome else {
      Issue.record("expected .empty, got \(outcome)")
      return
    }
    #expect(
      adapter.lastResult == nil,
      "an .empty finalize must not write lastResult (no stale-success)")
  }

  // MARK: Helpers

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
