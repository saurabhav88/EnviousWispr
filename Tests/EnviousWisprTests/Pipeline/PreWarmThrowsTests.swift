@preconcurrency import AVFoundation
import EnviousWisprAudio
import EnviousWisprCore
import Foundation
import Testing

/// Issue #289 — verify the `AudioCaptureInterface.preWarm` contract now
/// propagates errors. Full pipeline-level integration tests for the
/// `handle(event:)` / `handleCaptureStall` recovery paths are gapped for
/// follow-up (requires mocks for `ASRManagerInterface` + `WhisperKitBackend`
/// that don't yet exist in this repo). The core behavior is validated by
/// deliberate-failure UAT in the PR (inject `PreWarmFailedError.simulated`
/// and observe recovery to `.error`).
@Suite("PreWarm throws contract")
struct PreWarmThrowsTests {

  @Test("conforming mock can throw on preWarm, callers observe error")
  @MainActor
  func preWarmPropagatesError() async {
    let mock = ThrowingAudioCapture()
    await #expect(throws: PreWarmFailedError.self) {
      try await mock.preWarm()
    }
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

// MARK: - Minimal AudioCaptureInterface conformers for protocol-contract tests

@MainActor
final class ThrowingAudioCapture: AudioCaptureInterface {
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
  func preWarm() async throws {
    throw PreWarmFailedError.simulated
  }
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
