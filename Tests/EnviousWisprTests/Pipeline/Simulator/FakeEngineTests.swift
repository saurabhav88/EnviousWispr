import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// `FakeEngine` behavior tests (epic #827, PR-2 plan §11.2 items A, adversarial).
/// Each of the eight modes and every MUST / MUST NOT clause in PR-1 §B.2.2 is
/// asserted — without these, PR-2 is unfalsifiable.
@MainActor
@Suite("FakeEngine")
struct FakeEngineTests {

  private func makeEngine(_ behavior: FakeEngineBehavior) -> (FakeEngine, FakeClock) {
    let clock = FakeClock()
    return (FakeEngine(behavior: behavior, clock: clock), clock)
  }

  // MARK: Per-behavior finalize outcomes

  @Test("batchSuccess finalizes to a non-empty transcript")
  func batchSuccessOutcome() async {
    let (engine, _) = makeEngine(.batchSuccess(text: "hello"))
    let outcome = await engine.finalize(batchSamples: nil)
    guard case .transcript(let result) = outcome else {
      Issue.record("expected .transcript, got \(outcome)")
      return
    }
    #expect(result.text == "hello")
  }

  @Test("streamingSuccess finalizes to the final transcript")
  func streamingSuccessOutcome() async {
    let (engine, _) = makeEngine(.streamingSuccess(partials: ["he"], final: "hello"))
    let outcome = await engine.finalize(batchSamples: nil)
    guard case .transcript(let result) = outcome else {
      Issue.record("expected .transcript, got \(outcome)")
      return
    }
    #expect(result.text == "hello")
  }

  @Test("crashOnFinalize surfaces as .failed(.engineCrashed), never a throw or hang")
  func crashOutcome() async {
    let (engine, _) = makeEngine(.crashOnFinalize)
    let outcome = await engine.finalize(batchSamples: nil)
    guard case .failed(.engineCrashed) = outcome else {
      Issue.record("expected .failed(.engineCrashed), got \(outcome)")
      return
    }
  }

  // MARK: Adversarial / boundary — empty routing (§11.2 adversarial)

  @Test("empty(hadSpeechEvidence: true) does NOT route like empty(false)")
  func emptyWithSpeechEvidenceIsDistinct() async {
    let (withEvidence, _) = makeEngine(.empty(hadSpeechEvidence: true))
    let (withoutEvidence, _) = makeEngine(.empty(hadSpeechEvidence: false))
    let a = await withEvidence.finalize(batchSamples: nil)
    let b = await withoutEvidence.finalize(batchSamples: nil)
    guard case .empty(let evidenceA) = a, case .empty(let evidenceB) = b else {
      Issue.record("expected .empty from both")
      return
    }
    #expect(evidenceA == true)
    #expect(evidenceB == false)
    #expect(evidenceA != evidenceB, "the two empty modes must route differently")
  }

  @Test("cancelled mode never yields text")
  func cancelledNeverYieldsText() async {
    let (engine, _) = makeEngine(.cancelled)
    let outcome = await engine.finalize(batchSamples: nil)
    guard case .cancelled = outcome else {
      Issue.record("expected .cancelled, got \(outcome)")
      return
    }
  }

  // MARK: MUST / MUST NOT clauses (PR-1 §B.2.2)

  @Test("cancel() is idempotent")
  func cancelIsIdempotent() async {
    let (engine, _) = makeEngine(.batchSuccess(text: "x"))
    await engine.cancel()
    await engine.cancel()
    await engine.cancel()
    #expect(engine.cancelCallCount == 3)
    // Idempotent EFFECT: still terminal-cancelled, finalize still .cancelled.
    let outcome = await engine.finalize(batchSamples: nil)
    guard case .cancelled = outcome else {
      Issue.record("expected .cancelled after repeated cancel")
      return
    }
  }

  @Test("finalize() after cancel() returns .cancelled, never partial text")
  func finalizeAfterCancelIsCancelled() async {
    let (engine, _) = makeEngine(.batchSuccess(text: "should not appear"))
    await engine.cancel()
    let outcome = await engine.finalize(batchSamples: nil)
    guard case .cancelled = outcome else {
      Issue.record("expected .cancelled, got \(outcome)")
      return
    }
  }

  @Test("acceptAudio after a terminal session is a no-op")
  func acceptAudioAfterTerminalIsNoOp() async throws {
    let (engine, _) = makeEngine(.batchSuccess(text: "x"))
    let pcm = try #require(FakeAudioCapture.makeBuffer(samples: [0.1]))
    let buffer = AudioBufferHandoff(
      buffer: pcm, frameCount: 1, sequence: 1, sessionID: SessionID())
    engine.acceptAudio(buffer)
    #expect(engine.acceptedBufferCount == 1)
    await engine.cancel()
    engine.acceptAudio(buffer)
    engine.acceptAudio(buffer)
    #expect(engine.acceptedBufferCount == 1, "no buffer counted after terminal")
    #expect(engine.acceptAudioAfterTerminalCount == 2)
  }

  @Test("warmUp() is idempotent and safe when already ready")
  func warmUpIsIdempotent() async throws {
    let (engine, _) = makeEngine(.batchSuccess(text: "x"))
    try await engine.warmUp()
    #expect(engine.readiness == .ready)
    try await engine.warmUp()
    try await engine.warmUp()
    #expect(engine.readiness == .ready)
    #expect(engine.warmUpCallCount == 3)
  }

  // MARK: slowLoad — clock-driven warm-up

  @Test("slowLoad becomes ready only after the configured ticks")
  func slowLoadWaitsForClock() async throws {
    let clock = FakeClock()
    let engine = FakeEngine(behavior: .slowLoad(ticksToReady: 3), clock: clock)
    let warmUp = Task { @MainActor in try await engine.warmUp() }
    await Task.yield()
    #expect(engine.readiness == .warming)
    clock.advance(by: 2)
    await Task.yield()
    #expect(engine.readiness == .warming, "not ready before the deadline")
    clock.advance(by: 1)
    try await warmUp.value
    #expect(engine.readiness == .ready)
  }

  // MARK: Wedge semantics — nil vs non-nil silent stream (§3.3, Codex revision 6)

  @Test("loadProgressAbsent yields a nil loadProgress stream")
  func loadProgressAbsentIsNil() {
    let clock = FakeClock()
    let absent = FakeEngine(
      behavior: .batchSuccess(text: "x"), clock: clock, loadProgressAbsent: true)
    let present = FakeEngine(behavior: .batchSuccess(text: "x"), clock: clock)
    #expect(absent.loadProgress == nil, "absent knob means no wedge signal at all")
    #expect(present.loadProgress != nil)
  }

  @Test("wedgeOnLoad keeps a NON-nil stream that simply goes silent")
  func wedgeOnLoadHasNonNilSilentStream() {
    let clock = FakeClock()
    let engine = FakeEngine(behavior: .wedgeOnLoad, clock: clock)
    #expect(
      engine.loadProgress != nil,
      "a wedge mode exposes the stream and emits no ticks — that silence is the wedge signal")
  }

  @Test("cancel() before a wedgeOnLoad warmUp() does not hang")
  func cancelBeforeWedgeOnLoadDoesNotHang() async {
    let clock = FakeClock()
    let engine = FakeEngine(behavior: .wedgeOnLoad, clock: clock)
    // cancel-before-warmUp ordering: there is no future cancel() to resume a
    // parked continuation, so warmUp() must throw immediately, not park.
    await engine.cancel()
    await #expect(throws: ASREngineError.self) {
      try await engine.warmUp()
    }
  }

  @Test("wedgeOnFinalize: cancel() releases the wedged finalize as .cancelled")
  func wedgeOnFinalizeReleasedByCancel() async {
    let clock = FakeClock()
    let engine = FakeEngine(behavior: .wedgeOnFinalize, clock: clock)
    let finalizeTask = Task { @MainActor in await engine.finalize(batchSamples: nil) }
    await Task.yield()
    await engine.cancel()
    let outcome = await finalizeTask.value
    guard case .cancelled = outcome else {
      Issue.record("expected .cancelled after cancel released the wedge, got \(outcome)")
      return
    }
  }

  @Test("applyUnloadPolicy records the policy")
  func applyUnloadPolicyRecorded() {
    let (engine, _) = makeEngine(.batchSuccess(text: "x"))
    engine.applyUnloadPolicy(.immediately)
    #expect(engine.lastUnloadPolicy == .immediately)
  }
}
