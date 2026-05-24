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
      #expect(event(.noSpeech) == .noSpeech)
      #expect(event(.audioInterrupted) == .audioInterrupted)
      #expect(event(.asrInterrupted) == .asrInterrupted)
      #expect(event(.failed(.asrEmpty)) == .failed(.asrEmpty))
    }

    @Test("the discarded event carries the abort reason")
    func discardedCarriesReason() {
      #expect(
        KernelHeartPathTelemetryObserver.lifecycleEvent(
          for: .discarded, discardReason: .tooShort) == .discarded(.tooShort))
      #expect(
        KernelHeartPathTelemetryObserver.lifecycleEvent(
          for: .discarded, discardReason: .releasedBeforeRecording)
          == .discarded(.releasedBeforeRecording))
    }

    @Test("non-event states map to nil")
    func nonEventStatesMapToNil() {
      for state: RecordingSessionState in [.idle, .preparing, .warmingUp, .stopping, .finalizing] {
        #expect(
          KernelHeartPathTelemetryObserver.lifecycleEvent(for: state, discardReason: nil) == nil)
      }
    }

    // MARK: Raw-state observation wiring

    @Test("the observer emits lifecycle events as the kernel transitions")
    func emitsOnTransition() async {
      let recorder = EventRecorder()
      let kernel = makeKernel()
      let observer = makeObserver(kernel: kernel, recorder: recorder)
      observer.start()

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

      #expect(recorder.events == [.recordingCommitted, .transcriptionStarted, .pipelineCompleted])
    }

    @Test("a cancelled terminal emits even though it renders a hidden overlay")
    func cancelledTerminalEmits() async {
      let recorder = EventRecorder()
      let kernel = makeKernel()
      let observer = makeObserver(kernel: kernel, recorder: recorder)
      observer.start()

      kernel.testForceTransition(to: .preparing)
      await drain()
      kernel.testForceTransition(to: .cancelled)
      await drain()

      #expect(recorder.events == [.cancelled])
    }

    // MARK: onCaptureStalled fan-out

    @Test("a capture stall fans out to the observer's telemetry emitter")
    func captureStallFanout() async {
      // The kernel-side control flow (stall -> failed(captureStalled)) is covered
      // by the simulator's capture-stall scenario; this test pins the new PR-4
      // fan-out: the kernel's captureStallTelemetry seam reaches the observer.
      let stallRecorder = StallRecorder()
      let emitter = HeartPathTelemetryEmitter(
        backend: .parakeet,
        captureTelemetry: CaptureTelemetryState(),
        captureError: { error, _, _, _ in stallRecorder.note(error) },
        addBreadcrumb: { _, _, _ in })
      let engine = FakeEngine(behavior: .batchSuccess(text: "x"), clock: FakeClock())
      let capture = FakeAudioCapture()
      let observerHolder = ObserverHolder()
      let kernel = RecordingSessionKernel(
        adapter: engine,
        audioCapture: capture,
        vad: FakeVADSignalSource(),
        currentTick: { 0 },
        sleepTicks: { _ in },
        processText: { raw, _ in raw },
        store: { _ in },
        deliver: { _ in .pasted },
        minimumRecordingTicks: 0,  // PR-4.5 #4: test does not advance the clock; opt out of the gate
        captureStallTelemetry: { ctx in observerHolder.observer?.handleCaptureStall(ctx) })
      let observer = KernelHeartPathTelemetryObserver(
        kernel: kernel, audioCapture: capture, emitter: emitter, emitLifecycleEvent: { _ in })
      observerHolder.observer = observer
      observer.start()

      kernel.start(config: .testDefault())
      await drainUntil { kernel.state == .recording }

      capture.fireCaptureStalled()
      await drain()

      #expect(stallRecorder.count == 1, "the capture-stall context reached the observer's emitter")
    }

    // MARK: Helpers

    private func event(_ state: RecordingSessionState) -> KernelLifecycleEvent? {
      KernelHeartPathTelemetryObserver.lifecycleEvent(for: state, discardReason: nil)
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

    private func drainUntil(_ condition: @MainActor () -> Bool) async {
      for _ in 0..<2000 {
        if condition() { return }
        await Task.yield()
      }
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

  @MainActor
  private final class ObserverHolder {
    weak var observer: KernelHeartPathTelemetryObserver?
  }

#endif  // DEBUG
