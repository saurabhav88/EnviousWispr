import AppKit
import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - KernelDictationDriverTests (epic #827, PR-4 §11.4)
//
// Unit coverage for `KernelDictationDriver` — the state / overlay maps, the
// PipelineEvent dispatch, the external-error surface, and the no-op contracts.

@MainActor
@Suite struct KernelDictationDriverTests {

  // MARK: RecordingSessionState -> PipelineState map (pure, total)

  @Test(
    "the state map is total: every in-flight state is active, every outcome maps to its surface")
  func stateMapIsTotal() {
    func mappedState(_ s: RecordingSessionState, phase: DeliveringPhase = .transcribing)
      -> PipelineState
    {
      KernelDictationDriver.pipelineState(
        for: s, outcome: nil, deliveringPhase: phase, externalError: nil)
    }
    func mappedOutcome(_ o: RecordingOutcome) -> PipelineState {
      KernelDictationDriver.pipelineState(for: .idle, outcome: o, externalError: nil)
    }
    // In-flight states (#1548 D1) — every active state must report `isActive` so
    // the backend-switch guard (`PipelineSettingsSync`, §3.13) sees the kernel
    // session as active.
    for s: RecordingSessionState in [.arming, .live, .stopping, .delivering] {
      #expect(mappedState(s).isActive, "\(s) must map to an active PipelineState")
    }
    #expect(mappedState(.idle) == .idle)
    #expect(mappedState(.live) == .recording)
    #expect(mappedState(.delivering, phase: .transcribing) == .transcribing)
    #expect(mappedState(.delivering, phase: .finalizing(.transcribing)) == .polishing)
    // Concluded outcomes — the ending category moved onto `recordingOutcome`,
    // the state has returned to `.idle`. Idle-class endings collapse to idle
    // (silent — no error surface).
    #expect(mappedOutcome(.completed) == .complete)
    #expect(mappedOutcome(.cancelled) == .idle)
    #expect(mappedOutcome(.discarded(.tooShort)) == .idle)
    #expect(mappedOutcome(.noSpeech(.vadGate)) == .idle)
    // Error-surface endings.
    for o: RecordingOutcome in [
      .failed(.asrEmpty), .audioInterrupted(nil), .asrInterrupted(wasRecording: true),
      .noTransport,
    ] {
      if case .error = mappedOutcome(o) {
      } else {
        Issue.record("\(o) should map to .error")
      }
    }
  }

  @Test("an external error overrides the mapped state")
  func externalErrorOverridesState() {
    #expect(
      KernelDictationDriver.pipelineState(for: .idle, outcome: nil, externalError: "boom")
        == .error("boom"))
    #expect(
      KernelDictationDriver.pipelineState(for: .live, outcome: nil, externalError: "boom")
        == .error("boom"))
  }

  @Test("failureMessage mirrors the shipped strings for the equivalent failures")
  func failureMessages() {
    #expect(KernelDictationDriver.failureMessage(.asrEmpty) == "Couldn't catch that -- try again")
    #expect(KernelDictationDriver.failureMessage(.noAudioCaptured) == "No audio captured")
    #expect(
      KernelDictationDriver.failureMessage(.emptyAfterProcessing)
        == "No speech detected. Your clipboard is unchanged. Try again.")
  }

  @Test("failureMessage embeds error detail for the three TP-parity reasons (Div 4)")
  func failureMessagesWithDetail() {
    // Parity with the old Parakeet pipeline at TP:440-445 / TP:577-588 / TP:1045-1051:
    // include `error.localizedDescription` when present.
    #expect(
      KernelDictationDriver.failureMessage(.modelLoadFailed, detail: "out of memory")
        == "Model load failed: out of memory")
    #expect(
      KernelDictationDriver.failureMessage(.captureStartFailed, detail: "device busy")
        == "Recording failed: device busy")
    #expect(
      KernelDictationDriver.failureMessage(.asrFailed, detail: "stream closed")
        == "Transcription failed: stream closed")
    // No detail → byte-parity with the bare strings.
    #expect(KernelDictationDriver.failureMessage(.modelLoadFailed) == "Model load failed.")
    #expect(KernelDictationDriver.failureMessage(.captureStartFailed) == "Recording failed.")
    #expect(KernelDictationDriver.failureMessage(.asrFailed) == "Transcription failed.")
    // Other reasons ignore the detail (out-of-scope for parity).
    #expect(
      KernelDictationDriver.failureMessage(.asrEmpty, detail: "irrelevant")
        == "Couldn't catch that -- try again")
  }

  // MARK: handle(event:) -> kernel triggers

  @Test("handle(.toggleRecording) from idle starts a kernel session")
  func toggleRecordingStarts() async throws {
    let h = makeDriver()
    try await startDriverToLive(h)
    #expect(h.kernel.state == .live)
    #expect(h.driver.state == .recording)
  }

  @Test("recordingElapsedSeconds passes through the kernel's value")
  func recordingElapsedSecondsPassesThrough() async throws {
    let h = makeDriver()
    #expect(h.driver.recordingElapsedSeconds == nil, "idle → nil, matching the kernel directly")

    try await startDriverToLive(h)

    #expect(h.driver.recordingElapsedSeconds != nil)
    #expect(h.driver.recordingElapsedSeconds == h.kernel.recordingElapsedSeconds)
  }

  @Test("handle(.toggleRecording) while recording requests a stop")
  func toggleRecordingWhileActiveStops() async throws {
    let h = makeDriver()
    try await startDriverToLive(h)
    try await h.driver.handle(event: .toggleRecording(.testDefault()))
    await drainUntil { h.kernel.recordingOutcome != nil }
    #expect(h.kernel.recordingOutcome != nil, "the second toggle drove the session to a terminal")
  }

  // MARK: External-error surface

  @Test("setExternalError surfaces .error on state and overlay")
  func setExternalErrorSurfaces() {
    let h = makeDriver()
    h.driver.setExternalError("device unplugged")
    #expect(h.driver.state == .error("device unplugged"))
    #expect(h.driver.overlayIntent == .error(message: "device unplugged"))
  }

  @Test("a new start clears the external error")
  func startClearsExternalError() async throws {
    let h = makeDriver()
    h.driver.setExternalError("device unplugged")
    try await startDriverToLive(h)
    #expect(h.driver.state != .error("device unplugged"))
  }

  // MARK: currentTranscript / lastPolishError side-channel

  @Test("currentTranscript and lastPolishError read the finalization side-channel")
  func sideChannelReads() {
    let h = makeDriver()
    #expect(h.driver.currentTranscript == nil)
    h.outcome.transcript = Transcript(text: "hello world")
    h.outcome.polishError = "polish timed out"
    #expect(h.driver.currentTranscript?.text == "hello world")
    #expect(h.driver.lastPolishError == "polish timed out")
  }

  @Test("reset() clears currentTranscript (sync entry — parity with TP:1081-1102)")
  func syncResetClearsTranscript() {
    let h = makeDriver()
    h.outcome.transcript = Transcript(text: "old session")
    #expect(h.driver.currentTranscript?.text == "old session")
    h.driver.reset()
    #expect(h.driver.currentTranscript == nil)
  }

  @Test("handle(.reset) clears currentTranscript (event entry — parity with TP:1081-1102)")
  func eventResetClearsTranscript() async throws {
    let h = makeDriver()
    h.outcome.transcript = Transcript(text: "old session")
    #expect(h.driver.currentTranscript?.text == "old session")
    try await h.driver.handle(event: .reset)
    #expect(h.driver.currentTranscript == nil)
  }

  #if DEBUG
    @Test("overlayIntent surfaces failure detail (Div 4 — overlay parity)")
    func overlayIntentEnrichedDetail() {
      let h = makeDriver()
      h.kernel.testSetModelLoadError(
        NSError(
          domain: "test", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "vram exhausted"]))
      // Conclude on .failed(.modelLoadFailed) — the ending category is an
      // outcome now, not an FSM state (#1548 D1).
      #expect(h.kernel.testForceTransition(to: .arming))
      h.kernel.testForceConclude(.failed(.modelLoadFailed))
      // Both the lifecycle-coordinator state read AND the visible overlay
      // must carry the enriched detail; an unenriched overlay was the bug
      // Codex flagged on the initial Div 4 patch.
      #expect(h.driver.state == .error("Model load failed: vram exhausted"))
      #expect(
        h.driver.overlayIntent == .error(message: "Model load failed: vram exhausted"))
    }

    @Test(
      "terminal-state cleanup clears paste targets (Div 8 — parity with TP:998-1000)"
    )
    func terminalClearsContextTargets() async {
      let h = makeDriver()
      // Populate the targets without going through the start path (which
      // would also set them and overwrite). NSRunningApplication.current is
      // a process-stable handle; AXUIElement bridges from any AnyObject.
      h.driver.contextForTesting.targetApp = NSRunningApplication.current
      h.driver.contextForTesting.config = DictationSessionConfig.testDefault()
      #expect(h.driver.contextForTesting.targetApp != nil)
      #expect(h.driver.contextForTesting.config != nil)
      // Conclude the kernel — `idle → arming` then a `.cancelled` conclusion
      // returns the FSM to `.idle` with the ending on `recordingOutcome`
      // (#1548 D1), which the observer sees.
      #expect(h.kernel.testForceTransition(to: .arming))
      h.kernel.testForceConclude(.cancelled)
      // The observer hops to @MainActor via Task; drain until the cleanup
      // observes the terminal.
      await drainUntil { h.driver.contextForTesting.targetApp == nil }
      #expect(h.driver.contextForTesting.targetApp == nil)
      #expect(h.driver.contextForTesting.config == nil)
    }

    @Test(
      "terminal-state cleanup stamps bundle id into snapshot before nulling targetApp (Codex r2 on Div 8)"
    )
    func terminalCleanupStampsBundleIDIntoSnapshot() async throws {
      let h = makeDriver()
      // Pre-seed the kernel's recording snapshot the way `freezeRecordingSnapshot`
      // would at recording start — except `targetAppBundleID` is still nil
      // (the kernel never has direct access to `context.targetApp`). The
      // sentinel value is what the stamp must REPLACE; if the stamp logic
      // were missing, the sentinel would survive and the test would catch
      // that even when `bundleIdentifier` returns nil under `swift test`
      // (Codex r2 follow-up on Div 8 — guard against a vacuous nil==nil pass).
      let sentinel = "test.sentinel.unstamped"
      h.kernel.testSetRecordingSnapshot(
        KernelRecordingSnapshotTelemetry(
          backend: "parakeet", audioRoute: "test", wasStreaming: false,
          startTime: Date(), durationMs: 0, targetAppBundleID: sentinel))
      let currentApp = NSRunningApplication.current
      h.driver.contextForTesting.targetApp = currentApp
      #expect(h.kernel.testGetRecordingSnapshot()?.targetAppBundleID == sentinel)
      // Force a terminal — the driver's observer-driven cleanup must stamp
      // the bundle id (or nil if the test process has none) into the
      // snapshot BEFORE nulling context.targetApp.
      #expect(h.kernel.testForceTransition(to: .arming))
      h.kernel.testForceConclude(.cancelled)
      await drainUntil { h.driver.contextForTesting.targetApp == nil }
      #expect(h.driver.contextForTesting.targetApp == nil)
      // Regardless of whether `bundleIdentifier` returned nil or a real
      // value under `swift test`, the sentinel must NOT survive — that's
      // proof the stamp ran. AND the stamped value must equal the bundle
      // id we read off the running application.
      let stamped = h.kernel.testGetRecordingSnapshot()?.targetAppBundleID
      #expect(stamped != sentinel, "stamp must have replaced the sentinel")
      #expect(stamped == currentApp.bundleIdentifier)
    }

    @Test(
      "reset() preserves the transcript when the kernel is in the finalizing safe-point"
    )
    func resetDuringFinalizingPreservesTranscript() {
      let h = makeDriver()
      // Walk to .finalizing — the safe-point window where the in-flight
      // session may still legitimately reach `.completed` and history +
      // completion telemetry must see the saved transcript.
      #expect(h.kernel.testForceTransition(to: .arming))
      #expect(h.kernel.testForceTransition(to: .live))
      #expect(h.kernel.testForceTransition(to: .stopping))
      #expect(h.kernel.testForceTransition(to: .delivering))
      h.kernel.testSetDeliveringPhase(.finalizing(.transcribing))
      h.outcome.transcript = Transcript(text: "in-flight save")
      h.driver.reset()
      #expect(h.driver.currentTranscript?.text == "in-flight save")
    }

    @Test(
      "reset() clears the stale polish error once the kernel is idle (#859)",
      .bug(
        "https://github.com/saurabhav88/EnviousWispr/issues/859", "stale polishError survives reset"
      )
    )
    func resetWhenIdleClearsStalePolishError() {
      let h = makeDriver()
      // A prior session's polish failure left a message on the public surface.
      h.outcome.polishError = "AI polish failed"
      #expect(h.driver.lastPolishError == "AI polish failed")
      h.driver.reset()  // kernel is at idle (resting)
      #expect(
        h.driver.lastPolishError == nil,
        "reset() at idle must clear the stale polish-error surface")
    }

    @Test("handle(.reset) clears the stale polish error once the kernel is idle (#859)")
    func handleResetWhenIdleClearsStalePolishError() async throws {
      let h = makeDriver()
      h.outcome.polishError = "AI polish failed"
      try await h.driver.handle(event: .reset)  // kernel is at idle (resting)
      #expect(
        h.driver.lastPolishError == nil,
        "handle(.reset) at idle must mirror reset() and clear the polish-error surface")
    }

    @Test(
      "reset() preserves the polish error when the kernel is in the finalizing safe-point (#859)"
    )
    func resetDuringFinalizingPreservesPolishError() {
      let h = makeDriver()
      // Mirror the transcript safe-point contract: a reset arriving during the
      // finalizing window must not erase the in-flight outcome before
      // `.completed` is observed for completion telemetry.
      #expect(h.kernel.testForceTransition(to: .arming))
      #expect(h.kernel.testForceTransition(to: .live))
      #expect(h.kernel.testForceTransition(to: .stopping))
      #expect(h.kernel.testForceTransition(to: .delivering))
      h.kernel.testSetDeliveringPhase(.finalizing(.transcribing))
      h.outcome.polishError = "in-flight polish error"
      h.driver.reset()
      #expect(h.driver.lastPolishError == "in-flight polish error")
    }

    // MARK: #930 — overlay phase labels

    @Test(
      "the finalizing sub-status flip pushes a fresh overlay intent (Transcribing -> Polishing)"
    )
    func finalizingSubStatusFlipPushesOverlay() async {
      let h = makeDriver()
      var pushed: [OverlayIntent] = []
      h.driver.onOverlayIntentChange = { pushed.append($0) }
      // Walk to the finalizing safe-point (sub-status defaults to .transcribing).
      #expect(h.kernel.testForceTransition(to: .arming))
      #expect(h.kernel.testForceTransition(to: .live))
      #expect(h.kernel.testForceTransition(to: .stopping))
      #expect(h.kernel.testForceTransition(to: .delivering))
      h.kernel.testSetDeliveringPhase(.finalizing(.transcribing))
      // The polish step's onWillProcess equivalent — flip to .polishing.
      h.kernel.testSetFinalizingSubStatus(.polishing)
      await drainUntil { pushed.last == .processing(label: "Polishing...") }
      #expect(
        pushed.last == .processing(label: "Polishing..."),
        "a .polishing sub-status while .finalizing must push the Polishing overlay")
    }

    @Test(
      "a sub-status flip while NOT finalizing pushes nothing (display-only, guarded)"
    )
    func subStatusFlipOutsideFinalizingDoesNotPush() async {
      let h = makeDriver()
      var pushed: [OverlayIntent] = []
      h.driver.onOverlayIntentChange = { pushed.append($0) }
      // Kernel is at .idle — a sub-status mutation must not reach the overlay.
      h.kernel.testSetFinalizingSubStatus(.polishing)
      // Give any scheduled @MainActor hop a chance to land, then assert silence.
      for _ in 0..<50 { await Task.yield() }
      #expect(pushed.isEmpty, "no overlay push may fire while the kernel is not finalizing")
    }

    @Test(
      "the sub-status observation survives the inter-session reset (two finalizing sessions)"
    )
    func subStatusObservationSurvivesInterSessionReset() async {
      let h = makeDriver()
      var pushed: [OverlayIntent] = []
      h.driver.onOverlayIntentChange = { pushed.append($0) }
      // Session 1 → finalizing → polishing.
      #expect(h.kernel.testForceTransition(to: .arming))
      #expect(h.kernel.testForceTransition(to: .live))
      #expect(h.kernel.testForceTransition(to: .stopping))
      #expect(h.kernel.testForceTransition(to: .delivering))
      h.kernel.testSetDeliveringPhase(.finalizing(.transcribing))
      h.kernel.testSetFinalizingSubStatus(.polishing)
      await drainUntil { pushed.last == .processing(label: "Polishing...") }
      let afterSession1 = pushed.count
      #expect(afterSession1 >= 1)
      // End session 1 and reproduce the kill window: the delivering phase
      // resets to .transcribing while the kernel is NOT delivering (concluded +
      // reset). If the re-arm sat behind the delivering guard, the observation
      // would die here. `reset()` clears the outcome barrier so session 2 can
      // start clean (#1548 D1 inter-session reset).
      h.kernel.testForceConclude(.completed)
      h.kernel.reset()
      h.kernel.testSetDeliveringPhase(.transcribing)
      for _ in 0..<50 { await Task.yield() }
      // Session 2 → finalizing → polishing again. The push MUST fire a second
      // time, proving the observation re-armed across the reset.
      #expect(h.kernel.testForceTransition(to: .arming))
      #expect(h.kernel.testForceTransition(to: .live))
      #expect(h.kernel.testForceTransition(to: .stopping))
      #expect(h.kernel.testForceTransition(to: .delivering))
      h.kernel.testSetDeliveringPhase(.finalizing(.transcribing))
      h.kernel.testSetFinalizingSubStatus(.polishing)
      await drainUntil {
        pushed.count > afterSession1 && pushed.last == .processing(label: "Polishing...")
      }
      #expect(
        pushed.last == .processing(label: "Polishing..."),
        "session 2's polish flip must still push — the observer survived the reset")
    }

    @Test(
      "a WARM press stays hidden during Arming, then shows the recording pill once audio lands"
    )
    func warmPreparingProjectsToRecordingPill() async throws {
      let h = makeDriver()
      // Warm the engine so `adapter.readiness == .ready` (a genuine cold load
      // would surface the caching pill instead).
      try await h.adapter.warmUp()
      #expect(h.adapter.readiness == .ready)
      // #1548 D1 (founder 2026-07-14): the pill does NOT show early on a warm
      // press. Arming stays HIDDEN — we do not claim "recording" until transport
      // is proven. The first buffer lands within ~100 ms on the built-in mic
      // (imperceptible), so there is no phantom "Preparing..." flash and no
      // premature pill. Showing it early would defeat the whole transport gate.
      try await h.driver.handle(event: .toggleRecording(.testDefault()))
      await drainUntil { h.kernel.state == .arming }
      #expect(h.kernel.state == .arming)
      #expect(h.driver.overlayIntent == .hidden)
      // The recording pill appears the instant the first buffer commits Live.
      for _ in 0..<2000 where h.kernel.state != .live {
        h.capture.deliverBuffer()
        await Task.yield()
      }
      #expect(h.kernel.state == .live)
      #expect(h.driver.overlayIntent == .recording(audioLevel: 0))
    }

    @Test("a COLD arming surfaces the cold-boot pill, not the bare wall (#879)")
    func coldPreparingShowsCachingPill() {
      let h = makeDriver()
      // Fresh adapter is `.notReady` — a real cold model load is running. #1548
      // D1 folded the old `.preparing` + `.warmingUp` cold states into `.arming`;
      // the cold-vs-warm pill choice is driven by adapter readiness, not by a
      // distinct warming-up state (this test absorbed the old
      // `warmingUpShowsCachingPill`, which is now identical to it).
      #expect(h.adapter.readiness == .notReady)
      #expect(h.kernel.testForceTransition(to: .arming))
      // #879: the bare "Preparing dictation…" wall is unreachable on a cold
      // path; the honest cold-boot pill (engine-named) replaces it.
      #expect(h.driver.overlayIntent == .cachingModel(engineLabel: "Parakeet v3"))
    }
  #endif

  // MARK: #879 — ensureEngineWarm shared helper

  @Test("ensureEngineWarm drives a not-ready engine to ready via a single warmUp")
  func ensureEngineWarmDrivesNotReadyToReady() async {
    let h = makeDriver()
    #expect(h.adapter.readiness == .notReady)
    #expect(h.adapter.warmUpCallCount == 0)
    await h.driver.ensureEngineWarm(reason: .coldPress)
    #expect(h.adapter.readiness == .ready)
    // The helper drives the normal load exactly once — no prewarm/dummy step.
    #expect(h.adapter.warmUpCallCount == 1)
  }

  @Test("ensureEngineWarm is a no-op when the engine is already ready")
  func ensureEngineWarmNoOpWhenReady() async throws {
    let h = makeDriver()
    try await h.adapter.warmUp()
    #expect(h.adapter.readiness == .ready)
    #expect(h.adapter.warmUpCallCount == 1)
    // Already ready → the helper must not touch the adapter again (no second
    // load, no drift). Live readiness is the sole gate.
    await h.driver.ensureEngineWarm(reason: .launch)
    #expect(h.adapter.warmUpCallCount == 1)
  }

  @Test("ensureEngineWarm reports .ready when the warm-up succeeds")
  func ensureEngineWarmReportsReady() async {
    let h = makeDriver()
    let outcome = await h.driver.ensureEngineWarm(reason: .onboarding)
    guard case .ready = outcome else {
      Issue.record("expected .ready, got \(outcome)")
      return
    }
    #expect(h.adapter.readiness == .ready)
  }

  @Test(
    "ensureEngineWarm reports .failed(error) when warm-up throws — never throws into the caller")
  func ensureEngineWarmReportsFailedOnThrow() async {
    // `.wedgeOnLoad` + a prior cancel makes `warmUp()` throw immediately
    // (`ASREngineError.wedged`). The helper must catch it and surface `.failed`
    // so onboarding can drive its "download failed → Retry" UX — and the
    // heart-path press never sees the throw.
    let h = makeDriver(behavior: .wedgeOnLoad)
    await h.adapter.cancel()
    let outcome = await h.driver.ensureEngineWarm(reason: .onboarding)
    guard case .failed = outcome else {
      Issue.record("expected .failed, got \(outcome)")
      return
    }
    #expect(h.adapter.readiness != .ready)
  }

  // MARK: #1388 — terminal classification (user Cancel vs guard verdict vs failure)

  @Test("#1388: the cancellation error maps to .cancelled — never .failed")
  func warmupCancellationErrorMapsToCancelled() async {
    let h = makeDriver(behavior: .failLoad(ASRLoadCancelledError()))
    let outcome = await h.driver.ensureEngineWarm(reason: .onboarding)
    guard case .cancelled = outcome else {
      Issue.record("a user Cancel must surface as .cancelled, got \(outcome)")
      return
    }
    #expect(h.adapter.readiness != .ready)
  }

  @Test("#1388: a cancelled surrounding task (CancellationError) also maps to .cancelled")
  func warmupTaskCancellationMapsToCancelled() async {
    let h = makeDriver(behavior: .failLoad(CancellationError()))
    let outcome = await h.driver.ensureEngineWarm(reason: .onboarding)
    guard case .cancelled = outcome else {
      Issue.record("a cancelled task / delivery cancel must surface as .cancelled, got \(outcome)")
      return
    }
  }

  @Test("#1388: a genuine failure keeps the true underlying error")
  func warmupGenuineFailureKeepsUnderlyingError() async {
    struct BoomError: Error {}
    let h = makeDriver(behavior: .failLoad(BoomError()))
    let outcome = await h.driver.ensureEngineWarm(reason: .onboarding)
    guard case .failed(let error) = outcome else {
      Issue.record("expected .failed, got \(outcome)")
      return
    }
    #expect(error is BoomError, "the failure path must propagate the true cause, unwrapped")
  }

  @Test("#1388 boundary: classification order — a guard fire beats the cancellation error")
  func classificationOrderGuardFireBeatsCancellation() {
    // The contractual matrix (plan §4/§9): the guard's verdict wins FIRST even
    // though its teardown resumes the load with the SAME cancellation error a
    // user Cancel uses; only a user cancel (no fire) maps to .cancelled. Pure
    // function — the live guard's fire path needs real time + the shared
    // progress file, which the mid-load service-kill fault drill covers.
    typealias Classify = KernelDictationDriver
    #expect(
      Classify.classifyWarmupThrow(ASRLoadCancelledError(), guardFired: true) == .wedge,
      "guard-triggered teardown must stay a failure (WedgeError), never .cancelled")
    #expect(
      Classify.classifyWarmupThrow(ASRLoadCancelledError(), guardFired: false) == .cancelled)
    #expect(
      Classify.classifyWarmupThrow(CancellationError(), guardFired: false) == .cancelled)
    #expect(
      Classify.classifyWarmupThrow(XPCASRTransportError.serviceUnreachable, guardFired: true)
        == .wedge)
    #expect(
      Classify.classifyWarmupThrow(XPCASRTransportError.serviceUnreachable, guardFired: false)
        == .failure,
      "genuine service death (no guard fire) is a failure with the transport error")
    #expect(
      Classify.classifyWarmupThrow(ASRLoadSupersededError(), guardFired: false) == .failure)
  }

  // MARK: #1339 — sessionless wedge-guard topology

  @Test("#1339: sessionless warm-up arms EXACTLY ONE wedge guard, single slot, disarmed on exit")
  func sessionlessWedgeGuardSingleSlot() async {
    let h = makeDriver(behavior: .slowLoad(ticksToReady: 3))
    #expect(h.driver.sessionlessWedgeGuard == nil, "no guard before any warm-up")
    // First sessionless warm-up parks inside the fake's logical-clock sleep.
    let first = Task { @MainActor in _ = await h.driver.ensureEngineWarm(reason: .onboarding) }
    await drainUntil { h.adapter.warmUpCallCount == 1 }
    #expect(h.driver.sessionlessWedgeGuard != nil, "guard armed for the in-flight warm-up")
    let armed = h.driver.sessionlessWedgeGuard
    // A concurrent second sessionless warm-up (the onboarding-vs-launch /
    // prewarm race window) must NOT arm a second guard — the slot is single.
    let second = Task { @MainActor in _ = await h.driver.ensureEngineWarm(reason: .launch) }
    await drainUntil { h.adapter.warmUpCallCount == 2 }
    #expect(
      h.driver.sessionlessWedgeGuard === armed,
      "the race window must not stack a second wedge consumer on one load")
    h.clock.advance(by: 3)
    _ = await first.value
    _ = await second.value
    #expect(h.driver.sessionlessWedgeGuard == nil, "guard disarmed after the attempt resolves")
    #expect(h.adapter.readiness == .ready)
  }

  @Test("#1339: signal-free adapter (loadProgress == nil) never arms the guard")
  func signalFreeAdapterNeverArmsGuard() async {
    let h = makeDriver(behavior: .slowLoad(ticksToReady: 2), loadProgressAbsent: true)
    let warm = Task { @MainActor in _ = await h.driver.ensureEngineWarm(reason: .onboarding) }
    await drainUntil { h.adapter.warmUpCallCount == 1 }
    #expect(
      h.driver.sessionlessWedgeGuard == nil,
      "a signal-free engine (WhisperKit) must stay uncovered — no watcher, no deadline")
    h.clock.advance(by: 2)
    _ = await warm.value
    #expect(h.driver.sessionlessWedgeGuard == nil)
  }

  @Test("#1339: guard re-arms cleanly on a retry after a failed attempt")
  func guardReArmsOnRetry() async {
    let h = makeDriver(behavior: .wedgeOnLoad)
    await h.adapter.cancel()  // makes warmUp throw immediately (no park)
    let outcome = await h.driver.ensureEngineWarm(reason: .onboarding)
    guard case .failed = outcome else {
      Issue.record("expected .failed, got \(outcome)")
      return
    }
    #expect(h.driver.sessionlessWedgeGuard == nil, "guard released after the failed attempt")
    // Retry: the slot must be free to arm again (Retry re-drives the load).
    let retry = Task { @MainActor in _ = await h.driver.ensureEngineWarm(reason: .onboarding) }
    _ = await retry.value
    #expect(h.driver.sessionlessWedgeGuard == nil, "and released again after the retry resolves")
  }

  // MARK: Helpers

  private struct Harness {
    let driver: KernelDictationDriver
    let kernel: RecordingSessionKernel
    let outcome: KernelFinalizationOutcome
    let adapter: FakeEngine
    let clock: FakeClock
    /// The kernel's capture — deliver the first buffer through it to drive
    /// Arming → Live under the #1548 D1 transport gate.
    let capture: FakeAudioCapture
  }

  /// Start a session via the driver and drive it to `.live`. #1548 D1: reaching
  /// `.live` requires the first converted buffer (transport gate). The buffer
  /// only commits once the adapter session is OPEN (`beginSession` ran), so warm
  /// the engine first (a warm press opens the session immediately) and deliver
  /// the buffer with a small retry so it cannot race `beginSession`'s wiring.
  private func startDriverToLive(_ h: Harness) async throws {
    try await h.adapter.warmUp()
    try await h.driver.handle(event: .toggleRecording(.testDefault()))
    for _ in 0..<2000 {
      if h.kernel.state == .live { return }
      h.capture.deliverBuffer()
      await Task.yield()
    }
  }

  private func makeDriver(
    behavior: FakeEngineBehavior = .batchSuccess(text: "x"),
    loadProgressAbsent: Bool = false
  ) -> Harness {
    let clock = FakeClock()
    let adapter = FakeEngine(
      behavior: behavior, clock: clock, loadProgressAbsent: loadProgressAbsent)
    let capture = FakeAudioCapture()
    let kernel = RecordingSessionKernel(
      adapter: adapter,
      audioCapture: capture,
      vad: FakeVADSignalSource(),
      currentTick: { 0 },
      sleepTicks: { _ in },
      processText: { raw, _ in raw },
      store: { _, _ in },
      deliver: { _ in .pasted },
      minimumRecordingTicks: 0)  // PR-4.5 #4: clock never advances; opt out of the gate
    let observer = KernelHeartPathTelemetryObserver(
      kernel: kernel, audioCapture: FakeAudioCapture(),
      emitter: HeartPathTelemetryEmitter(
        backend: .parakeet, captureTelemetry: CaptureTelemetryState()),
      emitLifecycleEvent: { _ in })
    let outcome = KernelFinalizationOutcome()
    let steps = LimbSteps(
      wordCorrection: WordCorrectionStep(),
      fillerRemoval: FillerRemovalStep(),
      emojiFormatter: EmojiFormatterStep(),
      inverseTextNormalization: InverseTextNormalizationStep(),
      llmPolish: LLMPolishStep(keychainManager: KeychainManager()),
      emojiRestore: EmojiRestoreStep())
    let driver = KernelDictationDriver(
      kernel: kernel, observer: observer, outcome: outcome,
      context: KernelSessionContext(), steps: steps, adapter: adapter)
    driver.start()
    return Harness(
      driver: driver, kernel: kernel, outcome: outcome, adapter: adapter, clock: clock,
      capture: capture)
  }

  private func drainUntil(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<2000 {
      if condition() { return }
      await Task.yield()
    }
  }
}
