import EnviousWisprCore
import Foundation
import Testing

/// `FakeAudioCapture` behavior tests (epic #827, PR-2 plan §11.2 item B).
/// Includes the `stopCapture()`-on-cancel-and-on-wedge teardown assertion
/// (§3.3 / Gemini finding 5) — a left-hot microphone is a heart-path break, so
/// capture teardown is verified, not assumed.
@MainActor
@Suite("FakeAudioCapture")
struct FakeAudioCaptureTests {

  @Test("deliverBuffer feeds the capture stream and fires onBufferCaptured")
  func deliverBufferFeedsStreamAndCallback() async throws {
    let capture = FakeAudioCapture()
    let callbackCount = Counter()
    capture.onBufferCaptured = { _ in callbackCount.bump() }
    let stream = try await capture.beginCapturePhase()

    let collected = CollectedCount()
    let consumer = Task { @MainActor in
      for await _ in stream { collected.value += 1 }
    }
    await Task.yield()
    capture.deliverBuffer()
    capture.deliverBuffer()
    _ = await capture.stopCapture()
    await consumer.value

    #expect(callbackCount.value == 2, "onBufferCaptured fires once per delivered buffer")
    #expect(collected.value == 2, "each buffer reaches the AsyncStream consumer")
    #expect(capture.deliveredBufferCount == 2)
  }

  @Test("stopCapture is invoked on teardown — the no-hot-mic assertion")
  func stopCaptureTeardownAssertion() async throws {
    let capture = FakeAudioCapture()
    #expect(capture.stopCaptureCallCount == 0)
    _ = try await capture.beginCapturePhase()
    #expect(capture.isCapturing == true)
    _ = await capture.stopCapture()
    #expect(capture.stopCaptureCallCount == 1)
    #expect(capture.isCapturing == false, "capture must not be left hot after stop")
  }

  @Test("permission denied makes startEnginePhase throw")
  func permissionDeniedThrows() async {
    let capture = FakeAudioCapture()
    capture.permissionDenied = true
    await #expect(throws: FakeCaptureError.self) {
      try await capture.startEnginePhase()
    }
  }

  @Test("capture-start failure makes beginCapturePhase throw")
  func captureStartFailureThrows() async {
    let capture = FakeAudioCapture()
    capture.failCaptureStart = true
    await #expect(throws: FakeCaptureError.self) {
      _ = try await capture.beginCapturePhase()
    }
  }

  @Test("stopCapture reports accumulated samples and VAD segments")
  func stopCaptureReportsCaptureResult() async throws {
    let capture = FakeAudioCapture()
    _ = try await capture.beginCapturePhase()
    capture.deliverBuffer(frameCount: 100)
    capture.addSpeechSegment(startSample: 0, endSample: 80)
    let result = await capture.stopCapture()
    #expect(result.samples.count == 100)
    #expect(result.vadSegments.count == 1)
  }

  @Test("engine interruption fires onEngineInterrupted")
  func interruptionFiresCallback() {
    let capture = FakeAudioCapture()
    var interrupted = false
    capture.onEngineInterrupted = { _ in interrupted = true }
    capture.raiseEngineInterruption()
    #expect(interrupted == true)
  }

  @Test("XPC-only telemetry callbacks stay nil on a direct source")
  func xpcCallbacksStayNil() {
    let capture = FakeAudioCapture()
    #expect(capture.onXPCServiceError == nil)
    #expect(capture.onXPCReplyFailed == nil)
    #expect(capture.onCaptureSessionInterruption == nil)
    #expect(capture.onRouteResolved == nil)
  }

  @MainActor
  final class CollectedCount {
    var value = 0
  }

  /// A reference counter a `@Sendable` capture callback can bump. The fake
  /// drives the callback synchronously on the MainActor, so the unchecked
  /// `Sendable` conformance is sound for this test.
  final class Counter: @unchecked Sendable {
    private(set) var value = 0
    func bump() { value += 1 }
  }
}
