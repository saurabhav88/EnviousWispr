@preconcurrency import AVFoundation
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import EnviousWisprStorage
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprPipeline

/// V2 fault-injection — Lane C invariant C2 (issue #291).
///
/// Asserts that cancellation is a silent unwind on the old Parakeet pipeline:
/// driving the pipeline into `.recording` and then calling `cancelRecording()`
/// must not emit Sentry error breadcrumbs. Cancellation is a legitimate user
/// action, not a failure mode, and any error-class breadcrumb during unwind
/// would alert-spam the live triage Routine.
///
/// Surface: pipeline cancellation path. Injects a per-instance capture sink
/// into the pipeline (via `KernelDictationDriverFactory` inputs) instead of
/// installing the process-global `SentryBreadcrumb.captureErrorDelegate`. The
/// global is shared across all `@MainActor` tests: while this test is suspended
/// at an `await`, a sibling test's pipeline could fire `captureError` into the
/// global delegate this test had installed, recording a stray breadcrumb and
/// flaking the `spy.calls.isEmpty` assertion (#875, release-config one-per-run).
/// A per-instance sink keeps this pipeline off that global entirely.
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
    let spy = CaptureSpy()
    let vad = KernelDictationDriverFactory.makeSharedVADSignalSource(
      audioCapture: audioCapture)
    let pipeline = KernelDictationDriverFactory.makeForParakeet(
      inputs: .init(
        audioCapture: audioCapture,
        asrManager: asrManager,
        vadSignalSource: vad,
        transcriptStore: TranscriptStore(),
        keychainManager: KeychainManager(),
        captureTelemetry: CaptureTelemetryState(),
        pasteCompletionRegistry: PasteCompletionRegistry(),
        engineMutationScope: .alwaysAllowedForTesting,
        captureErrorSink: { _, category, stage, _, _ in
          spy.record(.init(category: category, stage: stage))
        }
      ))
    let stateWaiter = PipelineStateWaiter(pipeline)

    let config = DictationSessionConfig.testDefault(
      autoPasteToActiveApp: false,
      vadSensitivity: 0.5,
      languageMode: .auto,
      llmProvider: .openAI,
      llmModel: "gpt-test"
    )

    try await pipeline.handle(event: .toggleRecording(config))

    await stateWaiter.wait(for: .recording)
    #expect(pipeline.state == .recording, "must reach .recording before cancellation")

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

    // The injected sink fires synchronously on the main actor, so spy.calls is
    // final the instant cancelRecording returns — no drain wait needed.
    #expect(
      spy.calls.isEmpty,
      "cancel path must emit zero Sentry error breadcrumbs (got: \(spy.calls.map(\.stage)))")
  }
}
