import EnviousWisprAudio
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// Issue #289 — verify the `AudioCaptureInterface.preWarm` contract now
/// propagates errors. Full pipeline-level integration tests for the
/// `handle(event:)` / `handleCaptureStall` recovery paths are gapped for
/// follow-up (requires mocks for `ASRManagerInterface` + `WhisperKitBackend`
/// that don't yet exist in this repo). The core behavior is validated by
/// deliberate-failure UAT in the PR (inject `PreWarmFailedError.simulated`
/// and observe recovery to `.error`).
@Suite("PreWarm throws contract")
struct PreWarmThrowsTests {

  /// Drives the REAL `RecordingSessionKernel.preWarm()` over a throwing capture
  /// and asserts the kernel rethrows, so `RecordingStarter` can surface
  /// "Microphone unavailable" to the user. The old `preWarmPropagatesError` only
  /// proved a stub configured to throw threw — it never touched the kernel, so
  /// deleting the kernel's rethrow (`RecordingSessionKernel.swift:648`) left it
  /// green.
  @Test(
    "the kernel rethrows a preWarm failure from the audio capture",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/289",
      "preWarm error must propagate so the start path can surface it"
    )
  )
  @MainActor
  func kernelRethrowsPreWarmError() async {
    let clock = FakeClock()
    let engine = FakeEngine(behavior: .batchSuccess(text: "default"), clock: clock)
    let capture = FakeAudioCapture()
    capture.preWarmError = PreWarmFailedError.simulated
    let vad = FakeVADSignalSource()
    let paste = FakePasteTarget()
    let session = KernelRecordingSession(
      engine: engine, capture: capture, vad: vad, clock: clock, paste: paste)
    await #expect(throws: PreWarmFailedError.self) {
      try await session.testKernel.preWarm()
    }
    #expect(capture.preWarmCallCount == 1)  // the kernel actually reached capture.preWarm()
  }

  /// The success-path twin of `kernelRethrowsPreWarmError`: drives the REAL
  /// `RecordingSessionKernel.preWarm()` over a capture that succeeds and asserts
  /// the kernel reaches `capture.preWarm()` and returns without throwing. The old
  /// `preWarmSucceedsByDefault` only called a local mock's `preWarm()` and checked
  /// the mock's own counter — it ran zero production code, so any kernel mutation
  /// (never calling preWarm on the happy path, or always throwing) left it green.
  @Test("the kernel completes preWarm cleanly when the audio capture succeeds")
  @MainActor
  func kernelCompletesPreWarmOnSuccess() async throws {
    let clock = FakeClock()
    let engine = FakeEngine(behavior: .batchSuccess(text: "default"), clock: clock)
    let capture = FakeAudioCapture()  // preWarmError == nil → success path
    let vad = FakeVADSignalSource()
    let paste = FakePasteTarget()
    let session = KernelRecordingSession(
      engine: engine, capture: capture, vad: vad, clock: clock, paste: paste)
    try await session.testKernel.preWarm()  // real kernel; must not throw
    #expect(capture.preWarmCallCount == 1)  // the kernel actually reached capture.preWarm()
  }
}

enum PreWarmFailedError: Error, Equatable {
  case simulated
}
