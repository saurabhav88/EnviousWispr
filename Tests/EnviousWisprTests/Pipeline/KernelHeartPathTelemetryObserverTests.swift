import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprASR
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

    // MARK: terminalEvent map — pure (ending category → lifecycle event)

    @Test("every recording outcome maps to its lifecycle event, including .hidden-overlay endings")
    func everyOutcomeMapsToAnEvent() {
      // completed / cancelled / discarded / noSpeech all render a `.hidden`
      // overlay — a UI-keyed observer would miss them. The observer keys on the
      // concluded `RecordingOutcome`, so each still produces an event (#1548 D1).
      #expect(terminalEvent(.completed) == .pipelineCompleted)
      #expect(terminalEvent(.cancelled) == .cancelled)
      #expect(terminalEvent(.noSpeech(.vadGate)) == .noSpeech(.vadGate))
      // #1174 A3 — absent cause defaults defensively to `.engineLost` (capture).
      #expect(terminalEvent(.audioInterrupted(nil)) == .audioInterrupted(cause: .engineLost))
      // The stamped cause threads through unchanged (here a verified device loss).
      #expect(
        terminalEvent(.audioInterrupted(.deviceRemoved))
          == .audioInterrupted(cause: .deviceRemoved))
      // The `wasRecording` flag rides on the outcome now (set by the kernel from
      // `.live` vs `.delivering(.transcribing)`); the observer preserves it.
      #expect(
        terminalEvent(.asrInterrupted(wasRecording: true)) == .asrInterrupted(wasRecording: true))
      #expect(
        terminalEvent(.asrInterrupted(wasRecording: false)) == .asrInterrupted(wasRecording: false))
      #expect(terminalEvent(.failed(.asrEmpty)) == .failed(.asrEmpty))
      // PR-4b.2 r10 — observer routes the two rich-emitter-owned failures into
      // the sink. The sink will skip these (negative coverage in
      // `KernelLifecycleTelemetrySinkTests`), but the observer MUST still
      // map them so the case is reachable rather than silently dropped.
      #expect(terminalEvent(.failed(.captureStalled)) == .failed(.captureStalled))
      #expect(terminalEvent(.failed(.noAudioCaptured)) == .failed(.noAudioCaptured))
      // #1548 D1: the no-transport ending projects onto the existing
      // `.failed(.noAudioCaptured)` telemetry (locked projection — no new identity).
      #expect(terminalEvent(.noTransport) == .failed(.noAudioCaptured))
    }

    @Test("the discarded event carries the abort reason")
    func discardedCarriesReason() {
      #expect(terminalEvent(.discarded(.tooShort)) == .discarded(.tooShort))
      #expect(
        terminalEvent(.discarded(.releasedBeforeRecording))
          == .discarded(.releasedBeforeRecording))
    }

    @Test(".asrInterrupted preserves the was_recording flag the outcome carries (matrix #3)")
    func asrInterruptedPreservesWasRecording() {
      // The kernel derives the flag from `.live` (true) vs `.delivering(.transcribing)`
      // (false) and `isLegalConclusion` rejects a mismatched flag; the OBSERVER's
      // only job is a lossless pass-through, which is what this pins. The
      // where-the-flag-comes-from coverage lives in the kernel external-entry tests.
      #expect(
        terminalEvent(.asrInterrupted(wasRecording: true)) == .asrInterrupted(wasRecording: true))
      #expect(
        terminalEvent(.asrInterrupted(wasRecording: false)) == .asrInterrupted(wasRecording: false))
    }

    @Test("the noSpeech event carries the source (r7)")
    func noSpeechCarriesSource() {
      #expect(terminalEvent(.noSpeech(.vadGate)) == .noSpeech(.vadGate))
      #expect(terminalEvent(.noSpeech(.asrEmptyNoSpeech)) == .noSpeech(.asrEmptyNoSpeech))
    }

    // MARK: deltaEvents map — pure (in-flight tuple delta → lifecycle events)

    @Test("model loading fires only on a false→true load flag while arming (r6/r7)")
    func modelLoadingGateUsesTupleDelta() {
      // r7 OQ-3 resolution — the observer reads the kernel-stamped flag, not
      // adapter readiness. The old `.warmingUp` state folded into `.arming`
      // (#1548 D1); the gate is now a `didLoadModelThisSession` delta while
      // Arming.
      #expect(
        deltaEvents(prevState: .arming, state: .arming, didLoadModel: true) == [.modelLoading])
      #expect(deltaEvents(prevState: .arming, state: .arming).isEmpty)
      // Not while arming → no model-loading breadcrumb.
      #expect(deltaEvents(prevState: .idle, state: .live, didLoadModel: true).isEmpty)
      // One coalesced fire can carry BOTH session-startup and model-loading
      // (idle→arming then didLoadModel=true before the re-arm ran).
      #expect(
        deltaEvents(prevState: .idle, state: .arming, didLoadModel: true)
          == [.pipelineStartingUp, .modelLoading])
    }

    @Test("asrCompleted fires only on transcribing→finalizing while delivering (r6)")
    func asrCompletedGateUsesTupleDelta() {
      // Old TP:922 fired inside the transcript branch. The kernel advances
      // `deliveringPhase` .transcribing → .finalizing(_) ONLY after ASR returned
      // non-empty text — the no-speech / asrEmpty arms conclude straight to an
      // outcome — so that phase advance is the structural "ASR returned text"
      // signal (a phase change with NO FSM transition, #1548 D1).
      #expect(
        deltaEvents(
          prevState: .delivering, state: .delivering,
          prevPhase: .transcribing, phase: .finalizing(.transcribing)) == [.asrCompleted])
      // The .finalizing(.transcribing) → .finalizing(.polishing) advance is NOT
      // the ASR-completed signal — it must stay silent.
      #expect(
        deltaEvents(
          prevState: .delivering, state: .delivering,
          prevPhase: .finalizing(.transcribing), phase: .finalizing(.polishing)
        ).isEmpty)
    }

    @Test("stopping no longer emits .recordingStopped in the observer")
    func stoppingDoesNotEmitRecordingStoppedFromObserver() {
      // Fixer item #4 moved recording-stopped emission to the kernel callback
      // carrying stopCapture()'s exact sample count; the observer path is empty.
      #expect(deltaEvents(prevState: .live, state: .stopping).isEmpty)
    }

    @Test("a non-triggering delta emits nothing")
    func nonEventDeltaIsEmpty() {
      // The resting delta and a same-state / same-phase re-fire produce no event.
      #expect(deltaEvents(prevState: .idle, state: .idle).isEmpty)
      #expect(
        deltaEvents(
          prevState: .delivering, state: .delivering, prevPhase: .transcribing, phase: .transcribing
        )
        .isEmpty)
    }

    @Test("a session start (idle→arming) emits the startup breadcrumb")
    func pipelineStartingUpOnArm() {
      // PR-5 Rung 5 Pass 2 #1: the head of every session emits
      // `.pipelineStartingUp` (parity with OLD `WhisperKitPipeline.swift:438`).
      #expect(deltaEvents(prevState: .idle, state: .arming) == [.pipelineStartingUp])
    }

    // MARK: Raw-state observation wiring

    @Test("the observer emits lifecycle events as the kernel transitions")
    func emitsOnTransition() async {
      let recorder = EventRecorder()
      let kernel = makeKernel()
      let observer = makeObserver(kernel: kernel, recorder: recorder)
      observer.observeKernelState()

      // Force a legal happy-path sequence — the observer keys on the raw
      // lifecycle tuple (#1548 D1). The transcribe→finalize boundary is a
      // `deliveringPhase` advance with no FSM transition.
      kernel.testForceTransition(to: .arming)
      await drain()
      kernel.testForceTransition(to: .live)
      await drain()
      kernel.testForceTransition(to: .stopping)
      await drain()
      kernel.testForceTransition(to: .delivering)
      await drain()
      kernel.testSetDeliveringPhase(.finalizing(.transcribing))
      await drain()
      kernel.testForceConclude(.completed)
      await drain()

      // `.stopping` no longer emits via the observer. The kernel-parity-hardening
      // PR moved the recording-stopped breadcrumb to a direct kernel callback
      // (`recordingStoppedTelemetry` in the constructor) that receives the
      // exact `sampleCount` returned by `stopCapture()`, replacing the prior
      // observer-path emission that read the inaccurate `capturedSamples.count`
      // property snapshot. The breadcrumb still fires in production; the
      // observer is no longer the emission path for it.
      //
      // `.finalizing` emits `.asrCompleted` when entered from `.transcribing`
      // (PR-4b.2 r6 — the structural transcript-branch signal, Codex review #11).
      // The test's forced path visits `.transcribing → .finalizing`, so the
      // breadcrumb fires here. `.warmingUp` wasn't visited (no model-load
      // branch entered).
      // PR-5 Rung 5 Pass 2 #1: `.preparing` now emits `.pipelineStartingUp`
      // at the head of the sequence (startup breadcrumb parity).
      #expect(
        recorder.events == [
          .pipelineStartingUp,
          .recordingCommitted(isStreaming: false), .transcriptionStarted,
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

      kernel.testForceTransition(to: .arming)
      await drain()
      kernel.testForceConclude(.cancelled)
      await drain()

      // PR-5 Rung 5 Pass 2 #1: the idle→arming start emits `.pipelineStartingUp`
      // before the cancelled conclusion.
      #expect(recorder.events == [.pipelineStartingUp, .cancelled])
    }

    @Test("one coalesced observation emits every applicable event in order (#1548 D1, Dec 3)")
    func coalescedStateAndPhaseChangeEmitsBothEvents() async {
      let recorder = EventRecorder()
      let kernel = makeKernel()

      // Stage the observer's previous tuple at `.stopping`.
      kernel.testForceState(.stopping)

      let observer = makeObserver(kernel: kernel, recorder: recorder)
      observer.observeKernelState()

      // Do NOT drain between these two tracked mutations: the first schedules
      // the observation task, the second lands before it runs, so ONE fire sees
      // both deltas. A first-by-priority handler would drop `.asrCompleted`.
      kernel.testForceState(.delivering)
      kernel.testSetDeliveringPhase(.finalizing(.transcribing))
      await drain()

      #expect(recorder.events == [.transcriptionStarted, .asrCompleted])
    }

    // MARK: onCaptureStalled fan-out

    @Test("a capture stall handled by the observer reaches its telemetry emitter")
    func captureStallFanout() async {
      // PR-4b.1: the kernel no longer subscribes to `audioCapture.onCaptureStalled`,
      // so the previous end-to-end path (capture callback → kernel telemetry
      // seam → observer) is gone. PR-4b.4 wires
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

    /// The pure ending-category → lifecycle-event map (#1548 D1).
    private func terminalEvent(
      _ outcome: RecordingOutcome,
      isStreaming: Bool = false
    ) -> KernelLifecycleEvent? {
      KernelHeartPathTelemetryObserver.terminalEvent(for: outcome, isStreaming: isStreaming)
    }

    /// The pure in-flight tuple-delta → lifecycle-events map (#1548 D1). Every
    /// argument defaults to a no-op so each test names only the axes it drives.
    private func deltaEvents(
      prevState: RecordingSessionState,
      state: RecordingSessionState,
      prevOutcome: RecordingOutcome? = nil,
      outcome: RecordingOutcome? = nil,
      prevDidLoadModel: Bool = false,
      didLoadModel: Bool = false,
      prevPhase: DeliveringPhase = .transcribing,
      phase: DeliveringPhase = .transcribing,
      isStreaming: Bool = false
    ) -> [KernelLifecycleEvent] {
      KernelHeartPathTelemetryObserver.deltaEvents(
        prevState: prevState,
        state: state,
        prevOutcome: prevOutcome,
        outcome: outcome,
        prevDidLoadModel: prevDidLoadModel,
        didLoadModel: didLoadModel,
        prevPhase: prevPhase,
        phase: phase,
        isStreaming: isStreaming)
    }

    private func makeKernel() -> RecordingSessionKernel {
      RecordingSessionKernel(
        adapter: FakeEngine(behavior: .batchSuccess(text: "x"), clock: FakeClock()),
        audioCapture: FakeAudioCapture(),
        vad: FakeVADSignalSource(),
        currentTick: { 0 },
        sleepTicks: { _ in },
        processText: { raw, _ in raw },
        store: { _, _ in },
        deliver: { _ in .pasted },
        engineMutationScope: .alwaysAllowedForTesting,
        minimumRecordingTicks: 0)  // PR-4.5 #4: clock never advances; opt out of the gate
    }

    private func makeObserver(
      kernel: RecordingSessionKernel, recorder: EventRecorder
    ) -> KernelHeartPathTelemetryObserver {
      KernelHeartPathTelemetryObserver(
        kernel: kernel,
        audioCapture: FakeAudioCapture(),
        emitter: HeartPathTelemetryEmitter(
          backend: .parakeet, captureTelemetry: CaptureTelemetryState()),
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
