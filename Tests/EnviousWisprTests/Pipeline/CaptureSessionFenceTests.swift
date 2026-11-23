import Testing
import EnviousWisprAudio

@testable import EnviousWisprPipeline

/// Keeps the simulator's stop-ID equality controls. The production
/// preparation handoff is exercised by `AudioCaptureManagerStopFenceTests`.
@MainActor
@Suite("Capture session fence (#1854 Phase 1)")
struct CaptureSessionFenceTests {

  @Test("a stale stop from a PREVIOUS armed session is refused")
  func staleStopFromOlderSessionIsRefused() async throws {
    let capture = FakeAudioCapture()

    // Session 1 arms, then a successor arms. The counter is now 2.
    try await capture.startEnginePhase(startDeadline: MicrophoneStartBudget.deadline(from: .now))
    _ = try await capture.beginCapturePhase(recoveryPayload: nil)
    let firstSessionID = capture.currentCaptureSessionID
    try await capture.startEnginePhase(startDeadline: MicrophoneStartBudget.deadline(from: .now))
    _ = try await capture.beginCapturePhase(recoveryPayload: nil)

    #expect(capture.currentCaptureSessionID != firstSessionID)
    #expect(capture.isCapturing)

    // Session 1's cleanup arrives late, carrying its own id.
    _ = await capture.stopCapture(sessionID: firstSessionID)

    // THE FENCE WORKS HERE. This is the half production already closes, and it
    // is why the fake had to learn it: a fix credited with closing this window
    // would be taking credit for a guard that already exists.
    #expect(capture.stopCaptureRefusedCallCount == 1)
    #expect(capture.isCapturing, "the newer capture must survive a stale stop")
  }

  @Test("a prepared-but-never-armed cleanup still gets through")
  func unarmedCleanupIsPermitted() async throws {
    let capture = FakeAudioCapture()

    // Prepared, never armed: the counter is still 0.
    try await capture.startEnginePhase(startDeadline: MicrophoneStartBudget.deadline(from: .now))
    #expect(capture.currentCaptureSessionID == 0)

    // Its cleanup MUST be permitted or the engine leaks — not by a special case
    // for `0`, but because the counter is also `0`, so the equality holds. The
    // fix cannot simply refuse id 0: attempt 1 in #1854 refused `.notStarted`
    // and stranded a live engine.
    _ = await capture.stopCapture(sessionID: 0)

    #expect(
      capture.stopCaptureRefusedCallCount == 0,
      "refusing an unarmed cleanup leaks the engine — the round-1 failure mode")
  }

  @Test("a stale ZERO id is refused once the counter has moved on")
  func staleZeroIDIsRefusedAfterArming() async throws {
    let capture = FakeAudioCapture()

    // A session arms, so the counter is no longer 0.
    try await capture.startEnginePhase(startDeadline: MicrophoneStartBudget.deadline(from: .now))
    _ = try await capture.beginCapturePhase(recoveryPayload: nil)
    #expect(capture.currentCaptureSessionID != 0)

    // A leftover unarmed-cleanup carrying `0` arrives late. Production's guard
    // is strict equality, so this is REFUSED — `0` is not a skeleton key.
    _ = await capture.stopCapture(sessionID: 0)

    // This test exists because the first draft of the fence wrote
    // `|| sessionID == 0` and would have torn down the live capture here. A fake
    // that is more permissive than production makes a Phase 2 race test report a
    // failure that cannot occur, which is worse than no fake fidelity at all.
    #expect(capture.stopCaptureRefusedCallCount == 1)
    #expect(capture.isCapturing, "a stale zero-id stop must not stop a live capture")
  }
}
