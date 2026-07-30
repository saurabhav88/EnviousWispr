import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - Baseline: terminal recording-scope clearing (#1846)
//
// These two tests assert a defect that EXISTS on unmodified `origin/main`, so
// they are RED there and GREEN only after the generic terminal postamble lands
// (`RULE: red-test-during-a-fix-runs-against-baseline-first`). A green baseline
// would mean the test is wrong, not that the code is right.
//
// DELIBERATELY BASELINE-COMPATIBLE. This file is kept separate from the take-ID
// tests and references NO #1846 symbol — no `KernelTelemetryState.takeID`, no
// `updateTakeID`, no `dictation.take_id`. That is what lets it be copied into a
// worktree at `origin/main` and COMPILE there. If it failed to compile, the
// resulting red would prove nothing about the defect: a compile error is not a
// failing assertion, and treating one as the other is the same worthless signal
// as a green that never ran anything.
//
// Measured on `origin/main` before the fix: of the seven terminal lifecycle
// events, five arms had no arm-local `recording.active` clear
// (`.pipelineCompleted`, `.failed`, `.discarded`, `.noSpeech`, `.cancelled`) and
// two did (`.audioInterrupted`, `.asrInterrupted`).

#if DEBUG

  @MainActor
  @Suite("Terminal recording-scope clearing baseline (#1846)")
  struct KernelLifecycleRecordingScopeBaselineTests {

    /// Records only the seam under test. Intentionally minimal so nothing here
    /// can depend on a symbol added by #1846.
    @MainActor
    private final class RecordingStateRecorder {
      struct Call: Equatable {
        let active: Bool
        let backend: String?
        let isStreaming: Bool?
      }
      var calls: [Call] = []
      var inactiveCalls: [Call] { calls.filter { !$0.active } }
    }

    private func makeSink(
      recorder: RecordingStateRecorder,
      telemetryState: KernelTelemetryState = KernelTelemetryState()
    ) -> KernelLifecycleTelemetrySink {
      // Every argument here exists on `origin/main`. `updateTakeID` is
      // deliberately NOT passed — it is defaulted, so omitting it compiles
      // against both the baseline and the fixed tree.
      //
      // Do NOT "fix" that by adding it: naming the argument is exactly what would
      // break baseline compilation and destroy this file's only purpose. It is
      // safe because that seam's default is INERT (`{ _ in }`), which is the
      // reason the sink breaks convention there; production wires it in
      // `KernelDictationDriverFactory`. If anyone ever restores a real default on
      // that seam, this file starts mutating global Sentry state silently.
      //
      // `dictationInvoked` and `audioCaptureInterrupted` are ALSO not named, and
      // that is load-bearing rather than an oversight. Chunk 5 widened both seams
      // with a `takeID` parameter; naming either one would pin this file to the
      // post-Chunk-5 arity and it would stop compiling on `origin/main`. They are
      // safe UNNAMED because neither is reachable from these two tests, which is a
      // stronger guarantee than injecting a no-op: `dictationInvoked` fires only
      // from the `.recordingCommitted` arm, and `audioCaptureInterrupted` is
      // guarded on `telemetryState.interruptionCause != nil`. Neither test emits
      // that event or sets that cause.
      //
      // WARNING for whoever adds the third test here: if it emits
      // `.recordingCommitted` or sets `interruptionCause`, it WILL reach the real
      // PostHog SDK through those defaults. Inject them then, and accept that doing
      // so ends this file's `origin/main` compatibility.
      KernelLifecycleTelemetrySink(
        backend: .parakeet,
        audioCapture: FakeAudioCapture(),
        context: KernelSessionContext(),
        captureTelemetry: CaptureTelemetryState(),
        telemetryState: telemetryState,
        breadcrumb: { _, _, _ in },
        updateRecordingState: { active, backend, isStreaming in
          recorder.calls.append(
            RecordingStateRecorder.Call(
              active: active, backend: backend, isStreaming: isStreaming))
        },
        updateAudioRoute: { _ in },
        modelLoadWedged: { _, _ in },
        captureError: { _, _, _, _ in },
        deadMicRecovered: { _ in }
      )
    }

    // MARK: Test 1 — the `.failed` terminal

    /// RED on `origin/main`: the `.failed` arm emits its capture error and
    /// returns without ever clearing capture scope, so a later unrelated Sentry
    /// event inherits `recording.active=true`.
    @Test("the .failed terminal clears recording scope")
    func failedTerminalClearsRecordingScope() {
      let recorder = RecordingStateRecorder()
      let sink = makeSink(recorder: recorder)

      sink.emit(.failed(.asrEmpty))

      #expect(
        recorder.inactiveCalls.count == 1,
        """
        the .failed terminal must clear recording.active exactly once, but \
        \(recorder.inactiveCalls.count) inactive updates were emitted. On \
        unmodified origin/main this is 0 — the .failed arm has no clear of its \
        own and no generic terminal postamble runs after it.
        """)
    }

    // MARK: Test 2 — cancel arriving during `.stopping`

    /// RED on `origin/main` for the same reason, reached through the REAL route
    /// rather than by calling `.cancelled` directly: a cancel landing while the
    /// kernel is `.stopping` calls `finishTerminal(.cancelled)` and the resuming
    /// stop path returns early on `recordingOutcome != nil`, so the stop marker
    /// — the one place capture scope would otherwise be cleared — never runs.
    ///
    /// Driving the route matters. Emitting `.cancelled` straight into the sink
    /// would still be red, but it would not prove that this PATH reaches a
    /// terminal without passing the stop marker, which is the actual defect.
    @Test("a cancel during .stopping clears recording scope")
    func cancelDuringStoppingClearsRecordingScope() async throws {
      let clock = FakeClock()
      let wrapper = KernelRecordingSession(
        engine: FakeEngine(behavior: .batchSuccess(text: "hello"), clock: clock),
        capture: FakeAudioCapture(),
        vad: FakeVADSignalSource(),
        clock: clock,
        paste: FakePasteTarget())
      let kernel = wrapper.testKernel

      // Legal transitions to the stopping state, matching the existing FSM tests.
      kernel.testForceTransition(to: .arming)
      kernel.testForceTransition(to: .live)
      kernel.testForceTransition(to: .stopping)
      #expect(kernel.state == .stopping)

      kernel.cancel()

      // Route assertion — must already pass on origin/main. If this fails, the
      // test is wrong about the route and the scope assertion below is moot.
      #expect(
        kernel.recordingOutcome == .cancelled,
        "a cancel during .stopping must conclude .cancelled before the scope assertion means anything"
      )

      // Project the outcome through the existing terminal authority rather than
      // hand-picking an event, so the test cannot drift from what the observer
      // would really emit.
      let outcome = try #require(kernel.recordingOutcome)
      let event = try #require(
        KernelHeartPathTelemetryObserver.terminalEvent(for: outcome, isStreaming: false))

      let recorder = RecordingStateRecorder()
      let sink = makeSink(recorder: recorder)
      sink.emit(event)

      #expect(
        recorder.inactiveCalls.count == 1,
        """
        a cancel during .stopping must clear recording.active exactly once, but \
        \(recorder.inactiveCalls.count) inactive updates were emitted. On \
        unmodified origin/main this is 0 — the .cancelled arm has no clear and \
        this route never reaches the stop marker.
        """)
    }
  }

#endif
