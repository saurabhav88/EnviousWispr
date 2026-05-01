@preconcurrency import AVFoundation
import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprServices
import EnviousWisprStorage
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// V2 fault-injection — Lane C invariant C2 (issue #291).
///
/// Asserts that cancellation is a silent unwind on `TranscriptionPipeline`:
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
  }

  private static func withCaptureSpy(_ body: (CaptureSpy) async -> Void) async {
    let spy = CaptureSpy()
    let prior = SentryBreadcrumb.captureErrorDelegate
    SentryBreadcrumb.captureErrorDelegate = { _, category, stage, _ in
      spy.record(.init(category: category, stage: stage))
    }
    defer { SentryBreadcrumb.captureErrorDelegate = prior }
    await body(spy)
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
    let pipeline = TranscriptionPipeline(
      audioCapture: audioCapture,
      asrManager: asrManager,
      transcriptStore: TranscriptStore()
    )

    let config = DictationSessionConfig.testDefault(
      autoPasteToActiveApp: false,
      vadSensitivity: 0.5,
      languageMode: .auto,
      llmProvider: .openAI,
      llmModel: "gpt-test"
    )

    await Self.withCaptureSpy { spy in
      await pipeline.startRecording(config: config)

      let reachedRecording = await pollUntil(timeout: .seconds(1)) {
        pipeline.state == .recording
      }
      #expect(reachedRecording, "must reach .recording before cancellation")

      await pipeline.cancelRecording()

      #expect(pipeline.state == .idle, "cancelRecording must return to .idle")
      #expect(asrManager.transcribeCallCount == 0, "ASR must not be called on cancelled session")

      // The whole point: cancellation must NOT route through error telemetry.
      // Any captured call during start→cancel→idle is a regression.
      #expect(
        spy.calls.isEmpty,
        "cancellation must emit zero Sentry error breadcrumbs (got: \(spy.calls.map(\.stage)))")
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
