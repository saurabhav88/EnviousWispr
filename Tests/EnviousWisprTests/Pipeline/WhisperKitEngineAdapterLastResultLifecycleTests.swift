@preconcurrency import AVFoundation
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprPipeline

// MARK: - WhisperKitEngineAdapterLastResultLifecycleTests (epic #827, PR-5 Rung 3 §11.2)
//
// Mirrors `ParakeetEngineAdapterLastResultLifecycleTests` against the
// WhisperKit conformer using `StubWhisperKitBackend` (declared at the bottom
// of `StubWhisperKitBackend.swift`). The adversarial empty-finalize test
// exercises the .empty(hadSpeechEvidence: true) branch — the conformer's
// most regression-prone path.

@MainActor
@Suite struct WhisperKitEngineAdapterLastResultLifecycleTests {

  @Test("lastResult is nil after beginSession()")
  func lastResultNilAfterBeginSession() async throws {
    let backend = StubWhisperKitBackend()
    await backend.setTranscribeResult(
      ASRResult(
        text: "first", language: "en", duration: 1, processingTime: 0.1,
        backendType: .whisperKit))
    let adapter = WhisperKitEngineAdapter(
      backend: backend, engineMutationScope: .alwaysAllowedForTesting)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: false)
    feed(adapter, samples: speechSamples(count: 16_000), session: sid)
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: 16_000)])
    _ = await adapter.finalize(batchSamples: nil)
    #expect(adapter.lastResult != nil, "successful finalize set lastResult")
    try await adapter.beginSession(SessionID(), options: .default, streaming: false)
    #expect(adapter.lastResult == nil)
  }

  @Test("lastResult is set after a successful .transcript finalize()")
  func lastResultSetAfterSuccessfulFinalize() async throws {
    let backend = StubWhisperKitBackend()
    await backend.setTranscribeResult(
      ASRResult(
        text: "polished", language: "en", duration: 1, processingTime: 0.1,
        backendType: .whisperKit))
    let adapter = WhisperKitEngineAdapter(
      backend: backend, engineMutationScope: .alwaysAllowedForTesting)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: false)
    feed(adapter, samples: speechSamples(count: 16_000), session: sid)
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: 16_000)])
    let outcome = await adapter.finalize(batchSamples: nil)
    guard case .transcript = outcome else {
      Issue.record("expected .transcript, got \(outcome)")
      return
    }
    let result = try #require(adapter.lastResult)
    #expect(result.text == "polished")
  }

  @Test("lastResult is nil after cancel()")
  func lastResultNilAfterCancel() async throws {
    let backend = StubWhisperKitBackend()
    await backend.setTranscribeResult(
      ASRResult(
        text: "done", language: "en", duration: 1, processingTime: 0.1,
        backendType: .whisperKit))
    let adapter = WhisperKitEngineAdapter(
      backend: backend, engineMutationScope: .alwaysAllowedForTesting)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: false)
    feed(adapter, samples: speechSamples(count: 16_000), session: sid)
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: 16_000)])
    _ = await adapter.finalize(batchSamples: nil)
    #expect(adapter.lastResult != nil)
    await adapter.cancel()
    #expect(adapter.lastResult == nil, "cancel() must clear lastResult")
  }

  @Test("lastResult is NOT set on .empty / non-transcript finalize outcomes")
  func lastResultNotSetOnEmptyFinalize() async throws {
    let backend = StubWhisperKitBackend()
    await backend.setTranscribeResult(
      ASRResult(
        text: "", language: "en", duration: 1, processingTime: 0.1,
        backendType: .whisperKit))
    let adapter = WhisperKitEngineAdapter(
      backend: backend, engineMutationScope: .alwaysAllowedForTesting)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: false)
    feed(adapter, samples: speechSamples(count: 16_000), session: sid)
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: 16_000)])
    let outcome = await adapter.finalize(batchSamples: nil)
    guard case .empty = outcome else {
      Issue.record("expected .empty, got \(outcome)")
      return
    }
    #expect(
      adapter.lastResult == nil,
      ".empty finalize must not write lastResult (no stale-success)")
  }

  @Test("lastResult is NOT set on .failed finalize outcomes")
  func lastResultNotSetOnFailedFinalize() async throws {
    let backend = StubWhisperKitBackend()
    await backend.setTranscribeThrows(StubBackendError.decodeFailed)
    let adapter = WhisperKitEngineAdapter(
      backend: backend, engineMutationScope: .alwaysAllowedForTesting)
    let sid = SessionID()
    try await adapter.beginSession(sid, options: .default, streaming: false)
    feed(adapter, samples: speechSamples(count: 16_000), session: sid)
    adapter.observeSpeechSegments([SpeechSegment(startSample: 0, endSample: 16_000)])
    let outcome = await adapter.finalize(batchSamples: nil)
    guard case .failed = outcome else {
      Issue.record("expected .failed, got \(outcome)")
      return
    }
    #expect(adapter.lastResult == nil)
  }

  @Test("lastResult is NOT set on .cancelled finalize outcomes")
  func lastResultNotSetOnCancelledFinalize() async throws {
    let backend = StubWhisperKitBackend()
    let adapter = WhisperKitEngineAdapter(
      backend: backend, engineMutationScope: .alwaysAllowedForTesting)
    try await adapter.beginSession(SessionID(), options: .default, streaming: false)
    await adapter.cancel()
    _ = await adapter.finalize(batchSamples: nil)
    #expect(adapter.lastResult == nil)
  }

  // MARK: Helpers

  private func feed(_ adapter: WhisperKitEngineAdapter, samples: [Float], session: SessionID) {
    guard let buffer = FakeAudioCapture.makeBuffer(samples: samples) else {
      Issue.record("failed to synthesize a test buffer")
      return
    }
    adapter.acceptAudio(
      AudioBufferHandoff(
        buffer: buffer, frameCount: samples.count, sequence: 1, sessionID: session))
  }

  private func speechSamples(count: Int) -> [Float] {
    (0..<count).map { _ in 0.1 }
  }
}
