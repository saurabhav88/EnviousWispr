import Testing

@testable import EnviousWisprPipeline

/// #1854 Phase 1. Pins what the capture-session identity fence does and does
/// NOT protect, now that `FakeAudioCapture` models it faithfully.
///
/// The fence lives in `AudioCaptureManager.stopCapture(sessionID:)` and refuses
/// a stop whose id is not the live one. Its own comment states the limit this
/// issue exists to close:
///
/// > `0` stays valid: it is the id of a prepared-but-never-armed engine, whose
/// > cleanup must be allowed through or the engine leaks. This guard cannot
/// > identify that prepared interval; callers must separately gate it using
/// > lifecycle ownership.
///
/// Until now the fake ignored `sessionID` entirely, so every stale stop landed
/// and a test could not tell "production would have fenced this" from "this is
/// the hole". Both showed up as the capture stopping. These tests separate them.
@MainActor
@Suite("Capture session fence (#1854 Phase 1)")
struct CaptureSessionFenceTests {

  @Test("a stale stop from a PREVIOUS armed session is refused")
  func staleStopFromOlderSessionIsRefused() async throws {
    let capture = FakeAudioCapture()

    // Session 1 arms, then a successor arms. The counter is now 2.
    try await capture.startEnginePhase()
    _ = try await capture.beginCapturePhase(recoveryPayload: nil)
    let firstSessionID = capture.currentCaptureSessionID
    try await capture.startEnginePhase()
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

  @Test("a stale stop DURING the successor's prepared interval is NOT refused")
  func staleStopDuringPreparedIntervalIsNotRefused() async throws {
    let capture = FakeAudioCapture()

    // Predecessor arms. Counter is 1.
    try await capture.startEnginePhase()
    _ = try await capture.beginCapturePhase(recoveryPayload: nil)
    let ownedSessionID = capture.currentCaptureSessionID

    // The successor prepares the engine but has NOT armed yet — exactly the
    // interval cloud review reached independently on PR #1855. `startEnginePhase`
    // does not bump the counter, so it still reads the PREDECESSOR's id.
    try await capture.startEnginePhase()
    #expect(
      capture.currentCaptureSessionID == ownedSessionID,
      "preparing a successor must not bump the counter — that is the premise")

    // The predecessor's detached cleanup lands now, carrying the id it
    // snapshotted synchronously at terminal time (`RecordingSessionKernel`
    // :3797). That id still matches, so the fence has nothing to catch it with.
    _ = await capture.stopCapture(sessionID: ownedSessionID)

    // THE HOLE, pinned. Not refused, and the engine the successor just prepared
    // is now stopped. `AudioCaptureManager`'s own comment predicts exactly this:
    // the guard cannot identify the prepared interval, so the caller must gate
    // it by lifecycle ownership — which is Phase 2.
    #expect(
      capture.stopCaptureRefusedCallCount == 0,
      "the identity fence cannot see this interval — that is the defect")
    #expect(
      !capture.isCapturing,
      "the successor's prepared engine was stopped by its predecessor's cleanup")
  }

  @Test("a prepared-but-never-armed cleanup still gets through")
  func unarmedCleanupIsPermitted() async throws {
    let capture = FakeAudioCapture()

    // Prepared, never armed: the counter is still 0.
    try await capture.startEnginePhase()
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
    try await capture.startEnginePhase()
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
