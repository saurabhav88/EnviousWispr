@preconcurrency import AVFoundation
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

  @Test("mock preWarm returns cleanly when not configured to throw")
  @MainActor
  func preWarmSucceedsByDefault() async throws {
    let mock = PassthroughAudioCapture()
    try await mock.preWarm()
    #expect(mock.preWarmCallCount == 1)
  }
}

enum PreWarmFailedError: Error, Equatable {
  case simulated
}

// MARK: - Minimal AudioCaptureInterface conformer for the default-success check

@MainActor
final class PassthroughAudioCapture: AudioCaptureInterface {
  var isCapturing: Bool = false
  var audioLevel: Float = 0
  var capturedSamples: [Float] = []
  var currentAudioRoute: String = "unknown"
  var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)?
  var onEngineInterrupted: (() -> Void)?
  var onVADAutoStop: (() -> Void)?
  var onCaptureStalled: ((CaptureStallContext) -> Void)?
  var onCaptureSessionInterruption: ((CaptureSessionInterruptionContext) -> Void)?
  var onXPCServiceError: ((XPCErrorContext) -> Void)?
  var onXPCReplyFailed: ((XPCReplyFailureContext) -> Void)?
  var onRouteResolved: ((CaptureRouteDecision, _ sourceTypeChanged: Bool) -> Void)?
  var currentCaptureSessionID: UInt64 = 0
  var isActivelyCapturing: Bool = false
  var captureSourceType: String = "mock"
  var noiseSuppressionEnabled: Bool = false
  var selectedInputDeviceUID: String = ""
  var preferredInputDeviceIDOverride: String = ""
  var warmEnginePolicy: WarmEnginePolicy = .off

  private(set) var preWarmCallCount: Int = 0

  func startEnginePhase() async throws {}
  func beginCapturePhase() async throws -> AsyncStream<AVAudioPCMBuffer> {
    AsyncStream { $0.finish() }
  }
  func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer> {
    AsyncStream { $0.finish() }
  }
  func stopCapture() async -> CaptureResult { CaptureResult(samples: []) }
  func rebuildEngine() {}
  func buildEngine(noiseSuppression: Bool) {}
  func preWarm() async throws { preWarmCallCount += 1 }
  func abortPreWarm() {}
  func waitForFormatStabilization(maxWait: TimeInterval, pollInterval: TimeInterval) async -> Bool {
    true
  }
  func configureVAD(autoStop: Bool, silenceTimeout: Double, sensitivity: Float, energyGate: Bool) {}
  func getSamplesSnapshot(fromIndex: Int) async -> (samples: [Float], totalCount: Int) {
    ([], 0)
  }
  func getVADSegments() async -> [SpeechSegment] { [] }
}
