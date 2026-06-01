import AppKit
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

  @Test("the state map is total and isActive holds for every active kernel state")
  func stateMapIsTotal() {
    func mapped(_ s: RecordingSessionState) -> PipelineState {
      KernelDictationDriver.pipelineState(for: s, externalError: nil)
    }
    // Idle-class terminals collapse to idle (silent — no error surface).
    #expect(mapped(.idle) == .idle)
    #expect(mapped(.cancelled) == .idle)
    #expect(mapped(.discarded) == .idle)
    #expect(mapped(.noSpeech) == .idle)
    // Active states — every one must report `isActive` so the backend-switch
    // guard (`PipelineSettingsSync`, §3.13) sees the kernel session as active.
    for s: RecordingSessionState in [
      .preparing, .warmingUp, .recording, .stopping, .transcribing, .finalizing,
    ] {
      #expect(mapped(s).isActive, "\(s) must map to an active PipelineState")
    }
    #expect(mapped(.recording) == .recording)
    #expect(mapped(.completed) == .complete)
    // Error-surface terminals.
    if case .error = mapped(.failed(.asrEmpty)) {
    } else {
      Issue.record("failed should map to .error")
    }
    if case .error = mapped(.audioInterrupted) {
    } else {
      Issue.record("audioInterrupted should map to .error")
    }
    if case .error = mapped(.asrInterrupted) {
    } else {
      Issue.record("asrInterrupted should map to .error")
    }
  }

  @Test("an external error overrides the mapped state")
  func externalErrorOverridesState() {
    #expect(
      KernelDictationDriver.pipelineState(for: .idle, externalError: "boom") == .error("boom"))
    #expect(
      KernelDictationDriver.pipelineState(for: .recording, externalError: "boom")
        == .error("boom"))
  }

  @Test("failureMessage mirrors the shipped strings for the equivalent failures")
  func failureMessages() {
    #expect(KernelDictationDriver.failureMessage(.asrEmpty) == "Couldn't catch that -- try again")
    #expect(KernelDictationDriver.failureMessage(.noAudioCaptured) == "No audio captured")
    #expect(KernelDictationDriver.failureMessage(.storageFailed) == "Failed to save transcript")
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
    try await h.driver.handle(event: .toggleRecording(.testDefault()))
    await drainUntil { h.kernel.state == .recording }
    #expect(h.kernel.state == .recording)
    #expect(h.driver.state == .recording)
  }

  @Test("handle(.toggleRecording) while recording requests a stop")
  func toggleRecordingWhileActiveStops() async throws {
    let h = makeDriver()
    try await h.driver.handle(event: .toggleRecording(.testDefault()))
    await drainUntil { h.kernel.state == .recording }
    try await h.driver.handle(event: .toggleRecording(.testDefault()))
    await drainUntil { h.kernel.state.isTerminal }
    #expect(h.kernel.state.isTerminal, "the second toggle drove the session to a terminal")
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
    try await h.driver.handle(event: .toggleRecording(.testDefault()))
    await drainUntil { h.kernel.state == .recording }
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
      // Walk to .failed(.modelLoadFailed) through legal edges.
      #expect(h.kernel.testForceTransition(to: .preparing))
      #expect(h.kernel.testForceTransition(to: .failed(.modelLoadFailed)))
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
      // Walk the kernel to a terminal — `idle → preparing → cancelled` is
      // legal and reaches a terminal-or-idle bucket the observer will see.
      #expect(h.kernel.testForceTransition(to: .preparing))
      #expect(h.kernel.testForceTransition(to: .cancelled))
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
      #expect(h.kernel.testForceTransition(to: .preparing))
      #expect(h.kernel.testForceTransition(to: .cancelled))
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
      #expect(h.kernel.testForceTransition(to: .preparing))
      #expect(h.kernel.testForceTransition(to: .recording))
      #expect(h.kernel.testForceTransition(to: .stopping))
      #expect(h.kernel.testForceTransition(to: .transcribing))
      #expect(h.kernel.testForceTransition(to: .finalizing))
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
      #expect(h.kernel.testForceTransition(to: .preparing))
      #expect(h.kernel.testForceTransition(to: .recording))
      #expect(h.kernel.testForceTransition(to: .stopping))
      #expect(h.kernel.testForceTransition(to: .transcribing))
      #expect(h.kernel.testForceTransition(to: .finalizing))
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
      #expect(h.kernel.testForceTransition(to: .preparing))
      #expect(h.kernel.testForceTransition(to: .recording))
      #expect(h.kernel.testForceTransition(to: .stopping))
      #expect(h.kernel.testForceTransition(to: .transcribing))
      #expect(h.kernel.testForceTransition(to: .finalizing))
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
      #expect(h.kernel.testForceTransition(to: .preparing))
      #expect(h.kernel.testForceTransition(to: .recording))
      #expect(h.kernel.testForceTransition(to: .stopping))
      #expect(h.kernel.testForceTransition(to: .transcribing))
      #expect(h.kernel.testForceTransition(to: .finalizing))
      h.kernel.testSetFinalizingSubStatus(.polishing)
      await drainUntil { pushed.last == .processing(label: "Polishing...") }
      let afterSession1 = pushed.count
      #expect(afterSession1 >= 1)
      // End session 1 and reproduce the kill window: the sub-status resets to
      // .transcribing while the kernel is NOT finalizing (terminal). If the
      // re-arm sat behind the .finalizing guard, the observation would die here.
      #expect(h.kernel.testForceTransition(to: .completed))
      h.kernel.testSetFinalizingSubStatus(.transcribing)
      for _ in 0..<50 { await Task.yield() }
      // Session 2 → finalizing → polishing again. The push MUST fire a second
      // time, proving the observation re-armed across the reset.
      #expect(h.kernel.testForceTransition(to: .preparing))
      #expect(h.kernel.testForceTransition(to: .recording))
      #expect(h.kernel.testForceTransition(to: .stopping))
      #expect(h.kernel.testForceTransition(to: .transcribing))
      #expect(h.kernel.testForceTransition(to: .finalizing))
      h.kernel.testSetFinalizingSubStatus(.polishing)
      await drainUntil {
        pushed.count > afterSession1 && pushed.last == .processing(label: "Polishing...")
      }
      #expect(
        pushed.last == .processing(label: "Polishing..."),
        "session 2's polish flip must still push — the observer survived the reset")
    }

    @Test(
      "a WARM .preparing projects straight to the recording pill — no phantom 'preparing' flash, no rebuild stutter"
    )
    func warmPreparingProjectsToRecordingPill() async throws {
      let h = makeDriver()
      // Warm the engine so `adapter.readiness == .ready` (no .warmingUp follows).
      try await h.adapter.warmUp()
      #expect(h.adapter.readiness == .ready)
      #expect(h.kernel.testForceTransition(to: .preparing))
      // Same intent the real `.recording` emits, so the overlay is created once
      // at press time and the real `.recording` dedups into it (UAT 2026-05-31:
      // `.hidden` here caused a tear-down/rebuild stutter; the label was a
      // phantom flash). No "Preparing dictation..." label on a warm press.
      #expect(h.driver.overlayIntent == .recording(audioLevel: 0))
    }

    @Test("a COLD .preparing surfaces the cold-boot pill, not the bare wall (#879)")
    func coldPreparingShowsCachingPill() {
      let h = makeDriver()
      // Fresh adapter is `.notReady` — a real `.warmingUp` load will follow.
      #expect(h.adapter.readiness == .notReady)
      #expect(h.kernel.testForceTransition(to: .preparing))
      // #879: the bare "Preparing dictation…" wall is unreachable on a cold
      // path; the honest cold-boot pill (engine-named) replaces it.
      #expect(h.driver.overlayIntent == .cachingModel(engineLabel: "Parakeet v3"))
    }

    @Test(".warmingUp surfaces the cold-boot pill (a real cold load is running) (#879)")
    func warmingUpShowsCachingPill() {
      let h = makeDriver()
      // .warmingUp is only reached on a cold load, so the cold-boot pill is honest.
      #expect(h.kernel.testForceTransition(to: .preparing))
      #expect(h.kernel.testForceTransition(to: .warmingUp))
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

  // MARK: Helpers

  private struct Harness {
    let driver: KernelDictationDriver
    let kernel: RecordingSessionKernel
    let outcome: KernelFinalizationOutcome
    let adapter: FakeEngine
  }

  private func makeDriver(behavior: FakeEngineBehavior = .batchSuccess(text: "x")) -> Harness {
    let adapter = FakeEngine(behavior: behavior, clock: FakeClock())
    let kernel = RecordingSessionKernel(
      adapter: adapter,
      audioCapture: FakeAudioCapture(),
      vad: FakeVADSignalSource(),
      currentTick: { 0 },
      sleepTicks: { _ in },
      processText: { raw, _ in raw },
      store: { _ in },
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
      llmPolish: LLMPolishStep(keychainManager: KeychainManager()))
    let driver = KernelDictationDriver(
      kernel: kernel, observer: observer, outcome: outcome,
      context: KernelSessionContext(), steps: steps, adapter: adapter)
    driver.start()
    return Harness(driver: driver, kernel: kernel, outcome: outcome, adapter: adapter)
  }

  private func drainUntil(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<2000 {
      if condition() { return }
      await Task.yield()
    }
  }
}
