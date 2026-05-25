import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - KernelHeartPathTelemetryObserverTests (epic #827, PR-4 §11.4)
//
// Unit coverage for `KernelHeartPathTelemetryObserver` — the lifecycle-event
// map, the raw-state observation wiring (every terminal emits despite mapping
// to a `.hidden` overlay), and the `onCaptureStalled` fan-out.
//
// `#if DEBUG`-gated: the observation tests drive the kernel through
// `testForceTransition`, a `#if DEBUG`-only hook. `build-check` never compiles
// the test target in release, but the gate keeps a release-config test build
// honest (PR #838 / `gotchas-release.md`).

#if DEBUG

  @MainActor
  @Suite struct KernelHeartPathTelemetryObserverTests {

    // MARK: lifecycleEvent map — pure

    @Test("every terminal state maps to a lifecycle event, including .hidden-overlay terminals")
    func everyTerminalMapsToAnEvent() {
      // completed / cancelled / discarded / noSpeech all render a `.hidden`
      // overlay — a UI-keyed observer would miss them. The observer keys on raw
      // state, so each still produces an event.
      #expect(event(.completed) == .pipelineCompleted)
      #expect(event(.cancelled) == .cancelled)
      #expect(event(.noSpeech) == .noSpeech(.vadGate))
      #expect(event(.audioInterrupted) == .audioInterrupted)
      // Default priorState `.idle` → wasRecording == false (the non-recording
      // path); the routing test below covers the `.recording` → true case
      // and the `.transcribing` → false case.
      #expect(event(.asrInterrupted) == .asrInterrupted(wasRecording: false))
      #expect(event(.failed(.asrEmpty)) == .failed(.asrEmpty))
      // PR-4b.2 r10 — observer routes the two rich-emitter-owned failures into
      // the sink. The sink will skip these (negative coverage in
      // `KernelLifecycleTelemetrySinkTests`), but the observer MUST still
      // map them so the case is reachable rather than silently dropped.
      #expect(event(.failed(.captureStalled)) == .failed(.captureStalled))
      #expect(event(.failed(.noAudioCaptured)) == .failed(.noAudioCaptured))
    }

    @Test("the discarded event carries the abort reason")
    func discardedCarriesReason() {
      #expect(event(.discarded, discardReason: .tooShort) == .discarded(.tooShort))
      #expect(
        event(.discarded, discardReason: .releasedBeforeRecording)
          == .discarded(.releasedBeforeRecording))
    }

    @Test(".asrInterrupted carries was_recording derived from priorState (matrix #3)")
    func asrInterruptedCarriesWasRecording() {
      #expect(
        event(.asrInterrupted, priorState: .recording) == .asrInterrupted(wasRecording: true))
      #expect(
        event(.asrInterrupted, priorState: .transcribing)
          == .asrInterrupted(wasRecording: false))
    }

    @Test("the noSpeech event carries the source (r7)")
    func noSpeechCarriesSource() {
      #expect(event(.noSpeech, lastNoSpeechSource: .vadGate) == .noSpeech(.vadGate))
      #expect(
        event(.noSpeech, lastNoSpeechSource: .asrEmptyNoSpeech)
          == .noSpeech(.asrEmptyNoSpeech))
    }

    @Test("warmingUp emits .modelLoading only when a model load actually started (r6/r7)")
    func warmingUpGatedByDidLoadModel() {
      // r7 OQ-3 resolution — observer reads kernel-stamped flag, not adapter
      // readiness post-transition.
      #expect(event(.warmingUp, didLoadModelThisSession: true) == .modelLoading)
      #expect(event(.warmingUp, didLoadModelThisSession: false) == nil)
    }

    @Test("stopping always maps to .recordingStopped (r6)")
    func stoppingMapsToRecordingStopped() {
      #expect(event(.stopping) == .recordingStopped)
    }

    @Test("finalizing emits .asrCompleted only when entered from .transcribing (r6)")
    func finalizingGatedByPriorState() {
      // Old TP:922 fired inside the transcript branch. The kernel reaches
      // `.finalizing` ONLY from `.transcribing` via `runFinalizing(asrText:)`
      // — the no-speech / asrEmpty arms jump straight to terminal — so
      // `priorState == .transcribing` is the structural "ASR returned text"
      // signal. Codex review #11 caught that the previous implementation
      // gated on `kernel.deliveredTranscript`, which is set INSIDE
      // `runFinalizing` AFTER the transition; reading it at mapping time
      // would always be nil.
      #expect(event(.finalizing, priorState: .transcribing) == .asrCompleted)
      // Defensive contra-condition: a `.finalizing` arrival from any other
      // prior state is structurally impossible (the FSM doesn't allow it),
      // but if it somehow happened the breadcrumb must NOT fire.
      #expect(event(.finalizing, priorState: .recording) == nil)
      #expect(event(.finalizing, priorState: .preparing) == nil)
    }

    @Test("non-event states map to nil under default conditions")
    func nonEventStatesMapToNil() {
      // `.warmingUp` / `.stopping` / `.finalizing` now have conditional event
      // mappings (covered above); under default conditions warmingUp +
      // finalizing still return nil. Only `.idle` and `.preparing` are
      // unconditionally nil.
      for state: RecordingSessionState in [.idle, .preparing] {
        #expect(event(state) == nil)
      }
      #expect(event(.warmingUp) == nil)
      #expect(event(.finalizing) == nil)
    }

    // MARK: Raw-state observation wiring

    @Test("the observer emits lifecycle events as the kernel transitions")
    func emitsOnTransition() async {
      let recorder = EventRecorder()
      let kernel = makeKernel()
      let observer = makeObserver(kernel: kernel, recorder: recorder)
      observer.observeKernelState()

      // Force a legal happy-path sequence — the observer keys on raw `state`.
      kernel.testForceTransition(to: .preparing)
      await drain()
      kernel.testForceTransition(to: .recording)
      await drain()
      kernel.testForceTransition(to: .stopping)
      await drain()
      kernel.testForceTransition(to: .transcribing)
      await drain()
      kernel.testForceTransition(to: .finalizing)
      await drain()
      kernel.testForceTransition(to: .completed)
      await drain()

      // PR-4b.2 r6 — `.stopping` emits `.recordingStopped`; `.finalizing`
      // emits `.asrCompleted` when entered from `.transcribing` (the
      // structural transcript-branch signal — Codex review #11). The test's
      // forced path visits `.transcribing → .finalizing`, so the breadcrumb
      // fires here. `.warmingUp` wasn't visited (no model-load branch
      // entered).
      #expect(
        recorder.events == [
          .recordingCommitted(isStreaming: false), .recordingStopped, .transcriptionStarted,
          .asrCompleted,
          .pipelineCompleted,
        ])
    }

    @Test("a cancelled terminal emits even though it renders a hidden overlay")
    func cancelledTerminalEmits() async {
      let recorder = EventRecorder()
      let kernel = makeKernel()
      let observer = makeObserver(kernel: kernel, recorder: recorder)
      observer.observeKernelState()

      kernel.testForceTransition(to: .preparing)
      await drain()
      kernel.testForceTransition(to: .cancelled)
      await drain()

      #expect(recorder.events == [.cancelled])
    }

    // MARK: onCaptureStalled fan-out

    @Test("a capture stall handled by the observer reaches its telemetry emitter")
    func captureStallFanout() async {
      // PR-4b.1: the kernel no longer subscribes to `audioCapture.onCaptureStalled`,
      // so the previous end-to-end path (capture callback → kernel
      // `captureStallTelemetry` seam → observer) is unsubscribed. PR-4b.4 wires
      // the driver to fan out a stall to BOTH `observer.handleCaptureStall(_:)`
      // AND `kernel.externalCaptureStalled(_:)` from a single App router
      // subscription. This test now pins the observer-emitter half of that
      // fan-out: a direct `handleCaptureStall` invocation reaches the emitter.
      // The kernel-side control flow (stall → failed(captureStalled)) is
      // covered by the simulator's capture-stall scenario via the new
      // `externalCaptureStalled` entry.
      let stallRecorder = StallRecorder()
      let emitter = HeartPathTelemetryEmitter(
        backend: .parakeet,
        captureTelemetry: CaptureTelemetryState(),
        captureError: { error, _, _, _ in stallRecorder.note(error) },
        addBreadcrumb: { _, _, _ in })
      let capture = FakeAudioCapture()
      let kernel = makeKernel()
      let observer = KernelHeartPathTelemetryObserver(
        kernel: kernel, audioCapture: capture, emitter: emitter, emitLifecycleEvent: { _ in })

      observer.handleCaptureStall(capture.makeStallContext())
      await drain()

      #expect(stallRecorder.count == 1, "the capture-stall context reached the observer's emitter")
    }

    // MARK: Helpers

    private func event(
      _ state: RecordingSessionState,
      priorState: RecordingSessionState = .idle,
      discardReason: DiscardReason? = nil,
      didLoadModelThisSession: Bool = false,
      lastNoSpeechSource: NoSpeechSource? = nil,
      isStreamingSession: Bool = false
    ) -> KernelLifecycleEvent? {
      KernelHeartPathTelemetryObserver.lifecycleEvent(
        for: state,
        priorState: priorState,
        discardReason: discardReason,
        didLoadModelThisSession: didLoadModelThisSession,
        lastNoSpeechSource: lastNoSpeechSource,
        isStreamingSession: isStreamingSession)
    }

    private func makeKernel() -> RecordingSessionKernel {
      RecordingSessionKernel(
        adapter: FakeEngine(behavior: .batchSuccess(text: "x"), clock: FakeClock()),
        audioCapture: FakeAudioCapture(),
        vad: FakeVADSignalSource(),
        currentTick: { 0 },
        sleepTicks: { _ in },
        processText: { raw, _ in raw },
        store: { _ in },
        deliver: { _ in .pasted },
        minimumRecordingTicks: 0)  // PR-4.5 #4: clock never advances; opt out of the gate
    }

    private func makeObserver(
      kernel: RecordingSessionKernel, recorder: EventRecorder
    ) -> KernelHeartPathTelemetryObserver {
      KernelHeartPathTelemetryObserver(
        kernel: kernel,
        audioCapture: FakeAudioCapture(),
        emitLifecycleEvent: { recorder.events.append($0) })
    }

    private func drain() async {
      for _ in 0..<100 { await Task.yield() }
    }
  }

  @MainActor
  private final class EventRecorder {
    var events: [KernelLifecycleEvent] = []
  }

  @MainActor
  private final class StallRecorder {
    private(set) var count = 0
    func note(_ error: any Error) { count += 1 }
  }

#endif  // DEBUG
