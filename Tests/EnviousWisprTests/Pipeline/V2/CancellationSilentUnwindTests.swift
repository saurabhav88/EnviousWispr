@preconcurrency import AVFoundation
import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import EnviousWisprStorage
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// V2 fault-injection — Lane C invariant C2 (issue #291).
///
/// Asserts that cancellation is a silent unwind on the old Parakeet pipeline:
/// driving the pipeline into `.recording` and then calling `cancelRecording()`
/// must not emit Sentry error breadcrumbs. Cancellation is a legitimate user
/// action, not a failure mode, and any error-class breadcrumb during unwind
/// would alert-spam the live triage Routine.
///
/// Surface: pipeline cancellation path. Uses the same
/// `SentryBreadcrumb.captureErrorDelegate` spy pattern as
/// `HeartPathTelemetryWiringTests`.
@MainActor
@Suite("V2 Lane C — cancellation unwinds without Sentry error spam")
struct CancellationSilentUnwindTests {

  /// Sendable spy storage — Sentry delegate may fire from any thread.
  private final class CaptureSpy: @unchecked Sendable {
    struct Captured {
      let category: SentryBreadcrumb.ErrorCategory
      let stage: String
    }
    private let lock = NSLock()
    private var _calls: [Captured] = []
    var calls: [Captured] {
      lock.lock()
      defer { lock.unlock() }
      return _calls
    }
    func record(_ call: Captured) {
      lock.lock()
      defer { lock.unlock() }
      _calls.append(call)
    }
    /// Clear all recorded calls. Used to scope an assertion window to a
    /// specific phase (e.g. cancel-only, not the prior recording window).
    func clear() {
      lock.lock()
      defer { lock.unlock() }
      _calls.removeAll()
    }
  }

  private static func withCaptureSpy(_ body: (CaptureSpy) async throws -> Void) async rethrows {
    let spy = CaptureSpy()
    let prior = SentryBreadcrumb.captureErrorDelegate
    SentryBreadcrumb.captureErrorDelegate = { _, category, stage, _ in
      spy.record(.init(category: category, stage: stage))
    }
    defer { SentryBreadcrumb.captureErrorDelegate = prior }
    try await body(spy)
  }

  @Test("cancelRecording from .recording emits zero Sentry error breadcrumbs")
  func testCancellationSilentUnwind() async throws {
    let fixture = try SyntheticAudioFixture.make(
      fileName: "v2-c2-cancel-silent-unwind.wav",
      pattern: .toneBurst
    )
    let audioCapture = try FixtureAudioCapture(fixtureURL: fixture.url)
    let asrManager = MockASRManager(
      transcribeBehavior: .success(
        ASRResult(
          text: "should never be used",
          language: "en",
          duration: fixture.durationSeconds,
          processingTime: 0.01,
          backendType: .parakeet
        )
      )
    )
    let pipeline = KernelDictationDriverFactory.makeForParakeet(
      inputs: .init(
        audioCapture: audioCapture,
        asrManager: asrManager,
        transcriptStore: TranscriptStore(),
        keychainManager: KeychainManager(),
        captureTelemetry: CaptureTelemetryState(),
        pasteCompletionRegistry: PasteCompletionRegistry()
      ))

    let config = DictationSessionConfig.testDefault(
      autoPasteToActiveApp: false,
      vadSensitivity: 0.5,
      languageMode: .auto,
      llmProvider: .openAI,
      llmModel: "gpt-test"
    )

    try await Self.withCaptureSpy { spy in
      try await pipeline.handle(event: .toggleRecording(config))

      let reachedRecording = await pollUntil(timeout: .seconds(1)) {
        pipeline.state == .recording
      }
      #expect(reachedRecording, "must reach .recording before cancellation")

      // Scope the assertion to the cancel phase. PR-4b.4 (#827): the kernel
      // has its own no-buffer stall watchdog that may emit an
      // `audioCaptureStalled` breadcrumb during the recording window when
      // `FixtureAudioCapture`'s synthetic stream produces no live buffers.
      // That pre-cancel emission is a fixture-driven artifact, not the
      // unwind behavior under test. The product invariant ("cancellation is
      // a legitimate user action, not a failure") concerns whether the
      // cancel path itself routes through error telemetry — clear the spy
      // so only post-cancel emissions count toward the assertion.
      spy.clear()

      await pipeline.cancelRecording()

      #expect(pipeline.state == .idle, "cancelRecording must return to .idle")
      #expect(asrManager.transcribeCallCount == 0, "ASR must not be called on cancelled session")

      #expect(
        spy.calls.isEmpty,
        "cancel path must emit zero Sentry error breadcrumbs (got: \(spy.calls.map(\.stage)))")
    }
  }
}

@MainActor
private func pollUntil(
  timeout: Duration,
  interval: Duration = .milliseconds(10),
  condition: @escaping @MainActor () -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if condition() { return true }
    try? await Task.sleep(for: interval)
  }
  return condition()
}
