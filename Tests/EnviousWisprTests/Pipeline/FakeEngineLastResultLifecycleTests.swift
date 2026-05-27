@preconcurrency import AVFoundation
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - FakeEngineLastResultLifecycleTests (epic #827, PR-5 Rung 2A)
//
// Enforces the §4 contract on the test simulator: `lastResult` is `nil`
// after `beginSession()`, set after a successful `finalize()`, `nil` after
// `cancel()`, and NOT set on `.empty(...)` / `.failed(...)` finalize
// outcomes (no stale-success). The adversarial empty-finalize case is the
// one a future Rung 3 conformer is most likely to get wrong.

@MainActor
@Suite struct FakeEngineLastResultLifecycleTests {

  @Test("lastResult is nil after beginSession()")
  func lastResultNilAfterBeginSession() async throws {
    let engine = FakeEngine(behavior: .batchSuccess(text: "x"), clock: FakeClock())
    // Pre-seed a stale value as if a prior session had run.
    engine.lastResult = ASRResult(
      text: "stale", language: "en", duration: 0.5, processingTime: 0.1,
      backendType: .parakeet)
    try await engine.beginSession(SessionID(), options: .default, streaming: false)
    #expect(engine.lastResult == nil)
  }

  @Test("lastResult is set after a successful .transcript finalize()")
  func lastResultSetAfterSuccessfulFinalize() async throws {
    let engine = FakeEngine(behavior: .batchSuccess(text: "hello world"), clock: FakeClock())
    try await engine.beginSession(SessionID(), options: .default, streaming: false)
    let outcome = await engine.finalize(batchSamples: nil)
    guard case .transcript = outcome else {
      Issue.record("expected .transcript, got \(outcome)")
      return
    }
    let result = try #require(engine.lastResult)
    #expect(result.text == "hello world")
  }

  @Test("lastResult is nil after cancel()")
  func lastResultNilAfterCancel() async throws {
    let engine = FakeEngine(behavior: .batchSuccess(text: "x"), clock: FakeClock())
    try await engine.beginSession(SessionID(), options: .default, streaming: false)
    _ = await engine.finalize(batchSamples: nil)
    #expect(engine.lastResult != nil, "successful finalize set lastResult")
    await engine.cancel()
    #expect(engine.lastResult == nil, "cancel() must clear lastResult")
  }

  @Test("lastResult is NOT set on .empty / non-transcript finalize outcomes")
  func lastResultNotSetOnEmptyOrFailedFinalize() async throws {
    let engine = FakeEngine(
      behavior: .empty(hadSpeechEvidence: true), clock: FakeClock())
    try await engine.beginSession(SessionID(), options: .default, streaming: false)
    let outcome = await engine.finalize(batchSamples: nil)
    guard case .empty = outcome else {
      Issue.record("expected .empty, got \(outcome)")
      return
    }
    #expect(
      engine.lastResult == nil,
      "an .empty finalize must not write lastResult (no stale-success)")
  }
}
