import AppKit
import EnviousWisprCore
import EnviousWisprServices
import Foundation

// MARK: - KernelDictationDriver (epic #827, PR-4 §3.1)
//
// Adapts `RecordingSessionKernel` to the recording-driver surface the App
// layer consumes. The App calls the active engine through this concrete driver
// and reads `state` / `overlayIntent` / `currentTranscript` / `lastPolishError`
// / the four limb-step accessors / `onStateChange` / DEBUG `forceCancelNow()`
// off it. The kernel exposes none of that — it has synchronous triggers and
// its own `RecordingSessionState` vocabulary.
//
// The driver translates: `PipelineEvent` -> kernel triggers, `RecordingSessionState`
// -> `PipelineState` / `OverlayIntent`. It carries real behavior (event
// translation, state mapping, the limb-step home, the external-error surface)
// and is NOT a forwarding shim — the old Parakeet pipeline path is gone. PR-9
// of #827 deleted the `DictationPipeline` protocol; this is the single concrete
// driver and the App holds it directly (`KernelOwnershipFreezeTests`).
//
// PR-4a ships this production-unwired: no App-layer caller constructs it.
// PR-4b re-points the 13 App files at this type.

/// Why a warm-up was requested (#879). Tags telemetry so the warm-up duration
/// and outcome can be attributed to the launch primer, onboarding, an engine
/// swap, or a raced cold press. Carries no behavior — `ensureEngineWarm` drives
/// the same single-flighted load regardless of reason.
public enum EngineWarmupReason: Sendable {
  case launch
  case onboarding
  case engineSwap
  case coldPress

  var telemetryToken: String {
    switch self {
    case .launch: return "launch"
    case .onboarding: return "onboarding"
    case .engineSwap: return "engine_swap"
    case .coldPress: return "cold_press"
    }
  }
}

/// The outcome of an `ensureEngineWarm` call. The helper never throws into its
/// callers (a warm-up failure must not crash the heart-path press), so it
/// reports the result as a value. Most callers discard it (they re-read live
/// readiness); onboarding consumes `.failed` to drive its "download failed →
/// Retry" UX, which needs the underlying error. Not `Sendable` — produced and
/// consumed on the `@MainActor`.
public enum EngineWarmupOutcome {
  case ready
  case failed(any Error)
}

/// Resume-once latch for `KernelDictationDriver.awaitKernelTerminal`. A
/// reference type so the closure passed to `withObservationTracking`'s
/// `onChange` and the recursive re-arm method share the same instance.
/// `@MainActor`-isolated — single writer (the main-actor Task that handles
/// each state-change tick). `Sendable` because `@MainActor` isolation acts
/// as the synchronization boundary.
@MainActor
private final class TerminalResumeLatch: Sendable {
  var resumed = false
}

/// The five text-processing limb steps the App configures and the kernel's
/// `processText` closure runs. Created once, shared by the driver (which
/// exposes the accessors) and `KernelFinalizationWiring` (whose `processText`
/// consumes them). `inverseTextNormalization` runs before `llmPolish` as the
/// always-on raw-fallback floor (#145).
@MainActor
struct LimbSteps {
  let wordCorrection: WordCorrectionStep
  let fillerRemoval: FillerRemovalStep
  let emojiFormatter: EmojiFormatterStep
  let inverseTextNormalization: InverseTextNormalizationStep
  let llmPolish: LLMPolishStep
}

/// Wraps `RecordingSessionKernel` as the App layer's recording driver.
@MainActor
@Observable
public final class KernelDictationDriver: HeartPathTelemetryTarget {

  private let kernel: RecordingSessionKernel
  private let observer: KernelHeartPathTelemetryObserver
  private let outcome: KernelFinalizationOutcome
  private let steps: LimbSteps

  /// PR-5 Rung 5 (#827): the adapter the kernel drives. Held by the driver so
  /// `ensureEngineWarm(reason:)` can read its live readiness and drive
  /// `adapter.warmUp()`. Package-scoped — the only reader outside this file is
  /// internal-test code in the same module.
  package let adapter: any ASREngineAdapter

  /// The per-session context the wiring's closures read (PR-4 §3.3 — "captured
  /// by the driver and threaded into the wiring"). PR-4a holds it; PR-4b's
  /// `handle(.toggleRecording)` is the writer — it records the frozen config
  /// and the frontmost app / focused element at recording start.
  private let context: KernelSessionContext

  /// External-error surface (PR-4 §3.7). `kernel.cancel()` alone maps to a
  /// `.hidden` overlay, so the driver owns the error state pushed in from
  /// outside (`setExternalError`). Cleared on the next start / reset.
  private var lastExternalError: String?

  /// Fired by the kernel-state observer whenever the mapped `PipelineState`
  /// changes. The App's `DictationLifecycleCoordinator` is the consumer.
  @ObservationIgnored
  public var onStateChange: ((PipelineState) -> Void)?

  /// The last mapped state `onStateChange` fired for — so a re-armed
  /// observation that fires without a mapped-state change stays quiet.
  @ObservationIgnored
  private var lastFiredState: PipelineState

  /// Fired by the finalizing-sub-status observer (`observeFinalizingSubStatus`)
  /// whenever the overlay's intent should refresh because of a `.transcribing`
  /// → `.polishing` flip that does NOT change the public `PipelineState` (both
  /// collapse to `.polishing`, so `onStateChange` never sees it). Display-only
  /// enrichment: carries NO lifecycle authority and MUST be wired only to the
  /// overlay show path — never to anything that mutates recording state,
  /// schedules warnings, or appends transcripts. Distinct from `onStateChange`,
  /// which carries the public `PipelineState` for lifecycle/menu/window
  /// consumers (#930).
  @ObservationIgnored
  public var onOverlayIntentChange: ((OverlayIntent) -> Void)?

  /// Heart-path error sink for the driver's own direct `.asrInterrupted`
  /// captureError emit. Defaulted to the production global so the only behavior
  /// change is testability — the factory threads the same injected sink it
  /// gives the emitter and lifecycle sink, so a test observes every driver-
  /// owned captureError path through one sink (Codex review #875).
  private let captureErrorSink: KernelDictationDriverFactory.HeartPathCaptureErrorSink

  init(
    kernel: RecordingSessionKernel,
    observer: KernelHeartPathTelemetryObserver,
    outcome: KernelFinalizationOutcome,
    context: KernelSessionContext,
    steps: LimbSteps,
    adapter: any ASREngineAdapter,
    captureErrorSink: @escaping KernelDictationDriverFactory.HeartPathCaptureErrorSink =
      KernelDictationDriverFactory.defaultCaptureErrorSink
  ) {
    self.kernel = kernel
    self.observer = observer
    self.outcome = outcome
    self.context = context
    self.steps = steps
    self.adapter = adapter
    self.captureErrorSink = captureErrorSink
    self.lastFiredState = Self.pipelineState(for: kernel.state, externalError: nil)
  }

  /// Cold-boot warm-up coordinator (#879). The SINGLE shared entry every warm-up
  /// site routes through — launch (`WisprBootstrapper` for Parakeet,
  /// `SetupCoordinator` for WhisperKit), onboarding (`OnboardingV2View`), engine
  /// swap (`PipelineSettingsSync`), and the cold press (`RecordingStarter`) — so
  /// the readiness-check + single-flight + telemetry live in one place and can't
  /// drift. Reads the live `adapter.readiness` (the ONLY gate — no persisted
  /// OS-build stamp, which would be an unsafe cache key per #879 §3); if the
  /// engine is already ready it no-ops. Otherwise it drives the engine's normal
  /// model load via `adapter.warmUp()` — idempotent and single-flighted by the
  /// backend (`WhisperKitBackend.loadTask` / `ASRManager.inFlightLoadTask`), so a
  /// press landing during a launch/onboarding warm-up JOINS the in-flight load
  /// rather than starting a second compile. "Loaded" already means "first press
  /// instant" (measured 2026-06-01: no first-inference penalty), so this drives
  /// the normal load only — no `prewarm` (it would load twice) and no
  /// dummy-transcribe.
  ///
  /// Never throws into callers (a warm-up failure must not crash the heart-path
  /// press); it returns an `EngineWarmupOutcome` instead. Most callers discard
  /// it and re-read live readiness; onboarding consumes `.failed` to drive its
  /// "download failed → Retry" UX. For the `.launch` reason it also emits the
  /// existing `launch.model_preload_completed` metric (already_loaded /
  /// joined_in_flight / success / failed) so that dashboard keeps continuity
  /// after this became the launch warm-up entry (replacing `loadModelSilently`).
  @discardableResult
  public func ensureEngineWarm(reason: EngineWarmupReason) async -> EngineWarmupOutcome {
    let engine = adapter.engineIdentity.rawValue
    if adapter.readiness == .ready {
      if reason == .launch {
        TelemetryService.shared.launchModelPreloadCompleted(
          backend: engine, result: "already_loaded", durationMs: 0)
      }
      return .ready
    }
    let warmupInFlight = adapter.readiness == .warming
    let start = ContinuousClock.now
    TelemetryService.shared.coldStartWarmupStarted(
      engine: engine, reason: reason.telemetryToken, warmupInFlight: warmupInFlight)
    do {
      try await adapter.warmUp()
      let ms = Self.elapsedMs(since: start)
      TelemetryService.shared.coldStartWarmupCompleted(
        engine: engine, reason: reason.telemetryToken, durationMs: ms)
      if reason == .launch {
        TelemetryService.shared.launchModelPreloadCompleted(
          backend: engine, result: warmupInFlight ? "joined_in_flight" : "success",
          durationMs: ms)
      }
      return .ready
    } catch {
      TelemetryService.shared.coldStartWarmupFailed(
        engine: engine, reason: reason.telemetryToken,
        error: String(describing: error))
      if reason == .launch {
        TelemetryService.shared.launchModelPreloadCompleted(
          backend: engine, result: "failed", durationMs: Self.elapsedMs(since: start))
      }
      return .failed(error)
    }
  }

  private static func elapsedMs(since instant: ContinuousClock.Instant) -> Int {
    let (s, a) = (ContinuousClock.now - instant).components
    return Int(s) * 1000 + Int(a / 1_000_000_000_000_000)
  }

  /// Begin observing the kernel for `onStateChange` fan-out and overlay
  /// sub-status flips.
  func start() {
    observeKernelState()
    observeFinalizingSubStatus()
  }

  // MARK: Limb-step accessors (read by `PipelineSettingsSync` + custom-words)

  public var wordCorrection: WordCorrectionStep { steps.wordCorrection }
  public var fillerRemoval: FillerRemovalStep { steps.fillerRemoval }
  public var emojiFormatter: EmojiFormatterStep { steps.emojiFormatter }
  public var llmPolish: LLMPolishStep { steps.llmPolish }

  // MARK: Caller-visible signals

  /// The kernel's `RecordingSessionState` mapped to the legacy `PipelineState`.
  public var state: PipelineState {
    Self.pipelineState(
      for: kernel.state, externalError: lastExternalError,
      failureDetail: kernel.lastFailureDetail)
  }

  /// The transcript the `store` closure built for the last completed session.
  public var currentTranscript: Transcript? { outcome.transcript }

  /// The polish error from the last session, or `nil`.
  public var lastPolishError: String? { outcome.polishError }

  /// PR-7 (#827): the active engine adapter's normalized readiness, exposed
  /// read-only so the App layer can stamp the cold-start cohort
  /// (`engineReadinessAtPTT`) onto the `PTT-to-recording` log line at trigger
  /// entry. `adapter` is package-scoped; this is the only App-visible window
  /// onto its readiness. Sourcing the cohort here (not `asrManager.isModelLoaded`)
  /// is correct for both engines: WhisperKit's live driver uses a separate
  /// in-process backend, so the shared ASR manager's flag does not reflect it.
  public var engineReadiness: ASREngineReadiness { adapter.readiness }

  /// The active engine's user-facing display name (e.g. "Parakeet v3" /
  /// "WhisperKit"). Exposed read-only so the App layer can label the cold-boot
  /// warm-up pill (#879) without reaching into the package-scoped `adapter`.
  public var engineDisplayName: String { adapter.engineIdentity.displayName }

  // MARK: PR-4b.2 — direct methods + property (mirror old Parakeet pipeline App surface)

  /// Async cancel request. Wraps `kernel.cancel()` for App callers
  /// (`PipelineSettingsSync.swift:195`, `RecordingFinalizer.swift:95`) that
  /// `async`-call `pipeline.cancelRecording()`. Awaits the kernel reaching a
  /// terminal state before returning — `PipelineSettingsSync` relies on this
  /// to fully tear down capture before `buildEngine(...)` for a
  /// noise-suppression rebuild (Codex review #11 r5). `kernel.cancel()` on
  /// its own is fire-and-latch: it triggers the recording-exit path or sets
  /// `cancelRequested`, but the actual transition to `.cancelled` /
  /// `.discarded` happens on the forward path's next yield.
  public func cancelRecording() async {
    kernel.cancel()
    await awaitKernelTerminal()
  }

  /// Sync reset. Wraps `kernel.reset()` + driver-side cleanup. Mirrors the
  /// existing `handle(.reset)` body for `RecordingFinalizer.swift:117`'s
  /// sync call site.
  ///
  /// Bridge matrix #5 — the App's "Try Again / dismiss" path
  /// (`RecordingFinalizer.resetActive()`) is wired to `MainWindowView`'s
  /// "Try Again" button, which renders only when the driver's
  /// `pipelineState` is `.error`. Most `.error` mappings come from
  /// terminal kernel states (`.failed`, `.audioInterrupted`,
  /// `.asrInterrupted`), but `lastExternalError` can also surface
  /// `.error` while the kernel is still in an active state — the mic
  /// disconnect / ASR crash paths route through `setExternalError(...)`
  /// from `.preparing`, `.warmingUp`, `.stopping`, `.transcribing`, and
  /// `.finalizing` (see `handleEngineInterruption` / `handleASRServiceInterruption`).
  /// Active-state `reset()` is therefore a real production path, not a
  /// test-only seam.
  ///
  /// Seam audit Div 2 (2026-05-26): the old Parakeet pipeline allowed
  /// active-state `reset()` to synchronously land `.idle`. In the kernel
  /// path that is best-effort only — `kernel.cancel()` is fire-and-latch,
  /// so the actual transition happens on the forward path's next yield,
  /// which a sync caller cannot await (Codex review #11 r5). When called
  /// from an active state, this method requests cancellation; the kernel
  /// converges to a terminal on its own, and the next sync `reset()` (or
  /// terminal-state observation) will land at `.idle`. For deterministic
  /// completion from an active state, use `cancelRecording()` + `reset()`
  /// (async-then-sync), or wait for the kernel-state observer to fire
  /// with the terminal state. The external-error surface that "Try Again"
  /// re-enters from is cleared synchronously here via `lastExternalError =
  /// nil`, so the user-visible `.error` resolves immediately even when the
  /// kernel itself takes another tick to reach `.idle`.
  public func reset() {
    lastExternalError = nil
    if !Self.isTerminal(kernel.state) {
      // Best-effort: request cancellation. Caller-visible state will not
      // reach `.idle` synchronously from `.recording` / `.transcribing` —
      // see doc-comment.
      kernel.cancel()
    }
    // From terminal (the typical caller state), this transitions to `.idle`.
    // From a state that cancel just latched, kernel.reset() refuses and
    // returns false; the kernel's forward path eventually reaches
    // `.cancelled`, at which point the App must call reset() again or rely
    // on a fresh `.toggleRecording` to mint a new session.
    kernel.reset()
    // Clear the last-session transcript only after the kernel has actually
    // landed at idle — matching the old Parakeet pipeline's `reset()` clear
    // (TP:1081-1102) without breaking the finalizing safe-point window. If
    // `kernel.cancel()` + `kernel.reset()` were no-ops because the kernel
    // sits in `.finalizing` (transcript saved, paste still completing), the
    // in-flight session can still legitimately deliver and `.completed`
    // must still see `currentTranscript` for history + completion telemetry
    // (Codex review #11 r3 / `PipelineStateChangeHandler` guard).
    if kernel.state == .idle {
      outcome.transcript = nil
      // Clear the post-recording polish error alongside the transcript — both
      // are last-session outcome fields surfaced publicly (`currentTranscript`
      // / `lastPolishError`). Idle-gated (not unconditional like
      // `lastExternalError`) for the same reason as the transcript: a `reset()`
      // that no-ops because the kernel sits in `.finalizing` must leave the
      // in-flight outcome intact for completion telemetry. Without this, a
      // prior session's "AI polish failed" surface lingered into the next
      // dictation (#859).
      outcome.polishError = nil
    }
    fireStateChangeIfNeeded()
  }

  /// Stop-and-await-finalize. Old `pipeline.stopAndTranscribe()` awaits the
  /// full flow; `AudioEventRouter.swift:115` does
  /// `Task { await pipeline.stopAndTranscribe() }` and the `await` is
  /// load-bearing for downstream sequencing. The driver method requests stop
  /// AND awaits the kernel reaching a terminal state.
  ///
  /// Bridge matrix #1 — guard for the active-non-recording states
  /// (`.preparing`, `.warmingUp`, `.stopping`, `.transcribing`, `.finalizing`).
  /// Old TP's `stopAndTranscribe()` (old Parakeet pipeline)
  /// only acted on `.recording`. Without the guard, the driver would force
  /// an inappropriate stop request mid-warm-up or duplicate a stop already
  /// in flight.
  public func stopAndTranscribe() async {
    guard kernel.state == .recording else { return }
    kernel.requestStop()
    await awaitKernelTerminal()
  }

  /// External engine-interruption entry — bridges App-routed
  /// audio-engine-interruption signals into the kernel FSM and the
  /// telemetry emitters.
  ///
  /// `kernel.externalEngineInterrupted()` only acts on `.recording` (its
  /// documented contract — `RecordingSessionKernel.swift:1077-1080`). For
  /// every other active state (`.preparing`, `.warmingUp`, `.stopping`,
  /// `.transcribing`, `.finalizing`) the kernel silently drops the signal,
  /// which at PR-4b.4 cutover would leave the UI stuck. Old TP's
  /// `handleEngineInterruption()` (old Parakeet pipeline)
  /// was state-agnostic: emit Sentry+PostHog state change, cancel cleanup,
  /// flip UI to the mic-disconnect error. Bridge matrix #4 ports the old
  /// behavior for those states via `setExternalError`.
  public func handleEngineInterruption() {
    switch kernel.state {
    case .recording:
      kernel.externalEngineInterrupted()
    case .preparing, .warmingUp, .stopping, .transcribing, .finalizing:
      // Direct PostHog state update — the kernel won't reach
      // `.audioInterrupted` from here, so the lifecycle sink's
      // `.audioInterrupted` handler never fires.
      SentryBreadcrumb.updateRecordingState(active: false)
      setExternalError(InterruptionMessages.micDisconnected)
    case .idle, .completed, .failed, .cancelled, .discarded, .noSpeech,
      .audioInterrupted, .asrInterrupted:
      // Already idle / terminal — no useful action. Router-stale calls
      // land here.
      break
    }
  }

  /// External ASR-XPC interruption entry — bridges App-routed ASR-service
  /// crash signals into the kernel FSM and the telemetry emitters.
  ///
  /// `kernel.externalASRInterrupted()` only acts on `.recording` /
  /// `.transcribing` (its documented contract —
  /// `RecordingSessionKernel.swift:1077-1080`). Old TP's
  /// `handleASRServiceInterruption()` (old Parakeet pipeline)
  /// was state-agnostic: always emit the `xpc_service_error` Sentry event +
  /// flip the UI to the ASR-crash error. Bridge matrix #2 ports the old
  /// behavior for `.preparing`, `.warmingUp`, `.stopping`, `.finalizing`
  /// via direct Sentry emission + `setExternalError`.
  public func handleASRServiceInterruption() {
    switch kernel.state {
    case .recording, .transcribing:
      kernel.externalASRInterrupted()
    case .preparing, .warmingUp, .stopping, .finalizing:
      // Kernel won't reach `.asrInterrupted` from here, so the lifecycle
      // sink's `.asrInterrupted(wasRecording:)` handler never fires —
      // emit the captureError directly with `was_recording == false`.
      // PR-5 Rung 5 Pass 2 #3 — restore the `backend` extra and the
      // backend-named error message from OLD `WhisperKitPipeline.swift:1215-1221`
      // so this direct-emit fallback path carries parity with the sink
      // path's tagging.
      let backendID = adapter.engineIdentity.rawValue
      // Engine display name via the identity accessor, not a hard-coded
      // engine-identity literal (`gate-on-capability-not-identity-literal`,
      // #878). This file is now an `EngineIdentityFreezeTests` reader site, so
      // the banned literal can't return. (The freeze scanner is line-regex, not
      // comment-aware, so this comment must avoid the banned token too.)
      let backendLabel = adapter.engineIdentity.displayName
      captureErrorSink(
        NSError(
          domain: "EnviousWispr", code: -3,
          userInfo: [
            NSLocalizedDescriptionKey: "ASR XPC service crashed (\(backendLabel))"
          ]),
        .xpcServiceError, "asr",
        ["was_recording": false, "backend": backendID], nil)
      setExternalError(Self.asrInterruptedMessage)
    case .idle, .completed, .failed, .cancelled, .discarded, .noSpeech,
      .audioInterrupted, .asrInterrupted:
      // Already idle / terminal — no useful action. Router-stale calls
      // land here.
      break
    }
  }

  /// The frozen per-session config, or `nil` when no session is in flight.
  /// Mirrors old Parakeet pipeline's `currentSessionConfig`.
  /// `PipelineSettingsSync.swift:272` reads this across both pipelines as the
  /// "recording in flight" signal. The driver's terminal handler clears
  /// `context.config = nil` to honor the "nil when idle" contract (§3.4).
  public var currentSessionConfig: DictationSessionConfig? {
    context.config
  }

  // MARK: Caller-facing event + overlay surface

  public var overlayIntent: OverlayIntent {
    if let lastExternalError {
      return .error(message: lastExternalError)
    }
    switch kernel.state {
    case .idle, .completed, .cancelled, .discarded, .noSpeech:
      return .hidden
    case .warmingUp:
      // A real model load is running — `runForwardPath` only transitions to
      // `.warmingUp` when `adapter.readiness != .ready`. #879: replace the bare
      // "Preparing dictation…" wall with the honest cold-boot pill so the wall
      // is unreachable on any cold path. Both press paths (`RecordingStarter`
      // `start()` PTT and `toggle(source:)`) now return early on a cold engine
      // without minting a session, so the only way a session reaches
      // `.warmingUp` is a readiness-flip race (ready at the press-time snapshot,
      // not-ready by the time the kernel starts) — and that race gets the
      // plain-English pill here instead of the wall.
      return .cachingModel(engineLabel: adapter.engineIdentity.displayName)
    case .preparing:
      // `.preparing` is a sub-10ms bookkeeping step (mint session, spawn the
      // forward path). On a WARM engine (`adapter.readiness == .ready`) no
      // `.warmingUp` load follows, so "Preparing dictation..." is a phantom
      // flash on every press (#930). Project straight to the recording pill so
      // the overlay is created ONCE at press time and the real `.recording`
      // (same `.recording(audioLevel: 0)` intent) dedups into it — no label,
      // and no tear-down/rebuild stutter that a `.hidden` projection caused
      // (UAT 2026-05-31: `.hidden` forced a fresh-create pop; the label flash
      // was equally unwanted). On a COLD engine a real `.warmingUp` load
      // follows, so surface the honest cold-boot pill (#879), not the bare wall.
      return adapter.readiness == .ready
        ? .recording(audioLevel: 0)
        : .cachingModel(engineLabel: adapter.engineIdentity.displayName)
    case .recording:
      // The real level is supplied by `AudioCaptureManager` downstream — the
      // pipeline returns 0 here, exactly as the old Parakeet pipeline did.
      return .recording(audioLevel: 0)
    case .stopping, .transcribing:
      return .processing(label: "Transcribing...")
    case .finalizing:
      switch kernel.finalizingSubStatus {
      case .transcribing:
        return .processing(label: "Transcribing...")
      case .polishing:
        return .processing(label: "Polishing...")
      }
    case .failed(let reason):
      // Thread `kernel.lastFailureDetail` so the overlay surfaces the same
      // enriched "Model load failed: <detail>" / "Recording failed: <detail>"
      // / "Transcription failed: <detail>" string the `state` getter does —
      // overlay is the visible user-facing path, and `state` is read by the
      // lifecycle coordinator (Codex review of Div 4: keep the two paths in
      // sync).
      return .error(
        message: Self.failureMessage(reason, detail: kernel.lastFailureDetail))
    case .audioInterrupted:
      return .interruption(message: InterruptionMessages.micDisconnected)
    case .asrInterrupted:
      return .error(message: Self.asrInterruptedMessage)
    }
  }

  public func handle(event: PipelineEvent) async throws {
    switch event {
    case .preWarm:
      // PR-4.5 #1 + Codex r4: capture pre-warm is awaited end-to-end so the
      // PTT-flow caller (`RecordingStarter.start()` awaits `handle(.preWarm)`
      // and then immediately sends `.toggleRecording`) does not see the
      // recording start before BT codec negotiation completes.
      //
      // PR-4b.4 of #827: rethrow on `audioCapture.preWarm()` failure so the
      // starter's catch{} branch fires the "Microphone unavailable" overlay.
      try await kernel.preWarm()
    case .toggleRecording(let config):
      switch kernel.state {
      case .idle, .completed, .failed, .cancelled, .discarded, .noSpeech,
        .audioInterrupted, .asrInterrupted:
        // Start: clear the prior session's surfaces, capture finalization
        // context AT RECORDING START (PR-4.5 #6, parity with old
        // the old Parakeet pipeline), then mint a new session.
        //
        // The frontmost app + focused AX element are captured here so that a
        // polish step taking seconds — during which focus may shift to the
        // app's own window or another app — does not lose the original paste
        // target. The frozen `DictationSessionConfig` lands in
        // `context.config` for the wiring's `processText` / `deliver`
        // closures to read at finalize time (the wiring's optional-chained
        // reads were always-nil in production until this PR — finding #6).
        lastExternalError = nil
        outcome.transcript = nil
        outcome.polishError = nil
        outcome.rawText = nil
        outcome.polishedText = nil
        outcome.llmProvider = nil
        outcome.llmModel = nil
        outcome.polishMetadata = nil
        outcome.pipelineFellBackToRaw = false
        outcome.pipelineStartedAtSeconds = nil
        outcome.pipelineEndedAtSeconds = nil
        outcome.asrStartedAtSeconds = nil
        outcome.asrEndedAtSeconds = nil
        outcome.streamingMode = false
        outcome.polishDurationSeconds = 0
        outcome.pasteDurationSeconds = 0
        outcome.pasteResult = nil
        context.config = config
        context.targetApp = NSWorkspace.shared.frontmostApplication
        context.targetElement = PasteService.captureFocusedElement()
        applyLLMConfigToPolishStep(config)
        // GAP 1 of seam audit (TP:708-713): warm the polish provider as
        // the session starts so the polish step's cold-start latency is
        // hidden behind ASR. AppLifecycleCoordinator already warms at
        // launch + foreground; this is the per-session refresh that
        // covers long-idle paths between recordings.
        steps.llmPolish.preWarm()
        kernel.start(config: config)
      case .recording:
        kernel.requestStop()
      case .preparing, .warmingUp, .stopping, .transcribing, .finalizing:
        // Mid-session — don't interrupt processing (PR-1 §B.1.2).
        break
      }
    case .requestStop:
      kernel.requestStop()
    case .cancelRecording:
      kernel.cancel()
    case .reset:
      lastExternalError = nil
      kernel.reset()
      // Same guard as the sync `reset()` method above — only clear once the
      // kernel actually lands at idle, so a `.reset` event arriving during
      // the finalizing safe-point does not erase the transcript before
      // `.completed` is observed.
      if kernel.state == .idle {
        outcome.transcript = nil
        // Mirror the sync `reset()` method: clear the stale polish-error
        // surface alongside the transcript (#859). Both reset entry points
        // intentionally parallel each other (doc-comment at the sync method).
        outcome.polishError = nil
      }
      // PR-4.5 #9 (Codex r5): when the kernel is already idle, `reset()` is a
      // no-op, so the kernel-state observation does NOT fire. After
      // `setExternalError` parked the observer on `.error`, that observer
      // would stay stuck. Driving the fan-out directly mirrors the #9 fix on
      // the error-set side.
      fireStateChangeIfNeeded()
    }
  }

  /// External-error sink (PR-4 §3.7). Cancels the kernel session and holds
  /// the message so `state` / `overlayIntent` surface `.error` until the next
  /// start / reset clears it.
  ///
  /// PR-4.5 #9: also fires `onStateChange` directly with the mapped `.error`
  /// state. The state mapper reads `lastExternalError`, so the *driver's*
  /// public state did change; but the kernel-state observer at
  /// `observeKernelState` only fires when `kernel.state` itself changes. When
  /// `kernel.cancel()` is a no-op (kernel already idle / terminal — common
  /// for pre-warm / mic failures routed through here), the observer never
  /// runs and the lifecycle coordinator never learns about the error. Direct
  /// fire-through ensures the error reaches the overlay / hotkey teardown
  /// path regardless of kernel-state movement.
  public func setExternalError(_ message: String) {
    kernel.cancel()
    outcome.transcript = nil
    lastExternalError = message
    fireStateChangeIfNeeded()
  }

  // MARK: HeartPathTelemetryTarget — forwards to the observer (PR-4 §3.9)

  public func handleCaptureStall(_ ctx: CaptureStallContext) {
    // Two-arm fan-out:
    //   1. observer.handleCaptureStall — drives the rich Sentry emission
    //      via `HeartPathTelemetryEmitter.stallFired(ctx:)`.
    //   2. kernel.externalCaptureStalled — flips the kernel FSM to
    //      `failed(.captureStalled)` so the session actually stops.
    // PR-4b.1 dropped the kernel's direct `audioCapture.onCaptureStalled`
    // subscription; PR-4b.2 closes the loop by fanning out from this
    // App-facing entry. Without the kernel call, a real stall would
    // leave the session stuck in `.recording` (Codex review #11 r3).
    observer.handleCaptureStall(ctx)
    kernel.externalCaptureStalled(ctx)
  }

  public func handleXPCReplyFailed(_ ctx: XPCReplyFailureContext) {
    observer.handleXPCReplyFailed(ctx)
  }

  public func handleCaptureSessionInterruption(_ ctx: CaptureSessionInterruptionContext) {
    observer.handleCaptureSessionInterruption(ctx)
  }

  // MARK: DEBUG

  #if DEBUG
    /// Drives the kernel's cancel unwind — the kernel-era equivalent of
    /// the old Parakeet pipeline's `forceCancelNow()`. Callable from `DebugFaultEndpoint`.
    package func forceCancelNow() async {
      kernel.cancel()
    }

    /// Test-only kernel handle. Unit tests that need to drive the kernel into
    /// a specific FSM state (e.g. force `.finalizing` to assert `.polishing`
    /// state mapping or to pin a safe-point invariant) reach `testForceTransition`
    /// through this accessor.
    var kernelForTesting: RecordingSessionKernel { kernel }

    /// Test-only session-context handle. Used to verify the terminal-state
    /// cleanup clears `targetApp` + `targetElement` (Div 8 of seam audit /
    /// TP:998-1000, 1128-1129, 1221-1223). The context's properties are not
    /// otherwise observable from outside the driver.
    var contextForTesting: KernelSessionContext { context }
  #endif

  // MARK: Kernel-state observation

  /// Arm `withObservationTracking` on `kernel.state`; the `onChange` closure
  /// hops to `@MainActor` before re-reading state and re-arming (PR-4 §3.7,
  /// Gemini concurrency premise — the explicit hop is the safe pattern).
  private func observeKernelState() {
    withObservationTracking {
      _ = kernel.state
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.clearContextConfigIfTerminalOrIdle()
        self.fireStateChangeIfNeeded()
        self.observeKernelState()
      }
    }
  }

  private func fireStateChangeIfNeeded() {
    let mapped = state
    guard mapped != lastFiredState else { return }
    lastFiredState = mapped
    onStateChange?(mapped)
  }

  /// Arm a SECOND, separate `withObservationTracking` on
  /// `kernel.finalizingSubStatus` (NOT `kernel.state`) so the overlay can flip
  /// "Transcribing…" → "Polishing…" mid-`.finalizing` — a sub-status change the
  /// public `PipelineState` collapses to `.polishing`, so `observeKernelState`
  /// never sees it (#930).
  ///
  /// Two deliberate shapes:
  /// 1. Re-arm UNCONDITIONALLY via `defer`, BEFORE the `.finalizing` guard.
  ///    `finalizingSubStatus` resets to `.transcribing` during
  ///    `resetSessionState()` at the START of the next session, while the
  ///    kernel is NOT `.finalizing`; if the re-arm sat behind the guard the
  ///    observation would silently die after the first session.
  /// 2. Push the overlay intent ONLY while `kernel.state == .finalizing`, and
  ///    ONLY through `onOverlayIntentChange` — never `fireStateChangeIfNeeded` /
  ///    `onStateChange`. The public `PipelineState` fan-out and `ASREventRouter`
  ///    routing stay byte-identical; this channel is display-only.
  ///
  /// A late flip whose `@MainActor` hop lands after a new session is finalizing
  /// re-reads the CURRENT `overlayIntent`, so the worst case is one redundant
  /// push of the correct label, which the overlay dedups (`show(intent:)`).
  private func observeFinalizingSubStatus() {
    withObservationTracking {
      _ = kernel.finalizingSubStatus
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self else { return }
        defer { self.observeFinalizingSubStatus() }
        if self.kernel.state == .finalizing {
          self.onOverlayIntentChange?(self.overlayIntent)
        }
      }
    }
  }

  /// Apply the session's frozen LLM config to the polish step. Mirrors the
  /// LLM portion of old Parakeet pipeline's `applySessionConfig(_:)`
  /// (old Parakeet pipeline). VAD + device UID portions
  /// are already handled by `RecordingSessionKernel`.
  private func applyLLMConfigToPolishStep(_ config: DictationSessionConfig) {
    steps.llmPolish.llmProvider = config.llmProvider
    steps.llmPolish.llmModel = config.llmModel
    steps.llmPolish.polishInstructions = config.polishInstructions
    steps.llmPolish.useExtendedThinking = config.useExtendedThinking
  }

  /// Clear `context.config` + paste-target references whenever the kernel is
  /// in a "no in-flight session" state. That's the union of the 7 terminal
  /// states (per `RecordingSessionState.isTerminal` — `.completed`,
  /// `.cancelled`, `.failed`, `.noSpeech`, `.discarded`, `.audioInterrupted`,
  /// `.asrInterrupted`) plus `.idle`. Honors the old TP "nil when idle"
  /// contract that `PipelineSettingsSync` relies on for its backend-switch
  /// guard (PR-4b.2 §3.4).
  ///
  /// Also clears `context.targetApp` + `context.targetElement` for parity
  /// with the old Parakeet pipeline (TP:998-1000 / 1128-1129 / 1221-1223 —
  /// cleared after success, audio interruption, and cancel). The kernel's
  /// finalize wiring consumes both during `.finalizing`; by the time the
  /// kernel reaches a terminal state, paste has already completed.
  /// Otherwise these references can linger across sessions and surface a
  /// stale `NSRunningApplication` / `AXUIElement` to any reader between
  /// sessions.
  private func clearContextConfigIfTerminalOrIdle() {
    switch kernel.state {
    case .idle, .completed, .cancelled, .failed, .noSpeech, .discarded,
      .audioInterrupted, .asrInterrupted:
      // Stamp the bundle id into the recording snapshot BEFORE nulling
      // `targetApp` — the lifecycle sink's snapshot read
      // (`KernelLifecycleTelemetrySink:370`) falls back to `context.targetApp`,
      // and the driver-observer can race ahead of the lifecycle observer.
      // Codex review of the Div 8 patch caught this — without the stamp,
      // terminal Sentry events would drop `target_app_bundle_id`.
      kernel.stampRecordingSnapshotTargetApp(context.targetApp?.bundleIdentifier)
      context.config = nil
      context.targetApp = nil
      context.targetElement = nil
    case .preparing, .warmingUp, .recording, .stopping, .transcribing, .finalizing:
      break
    }
  }

  /// Suspend until `kernel.state` reaches a terminal state. Uses
  /// `withObservationTracking` + `withCheckedContinuation` with a
  /// reference-typed resume-once latch so concurrent kernel-state changes
  /// during the suspension cannot double-resume the continuation (which would
  /// crash). The latch is `@MainActor`-isolated; every re-arm path passes
  /// through it before any work.
  ///
  /// REVIEWED_OK(#827): the signal source is the kernel's observable terminal
  /// state transition. A hang here means a lower-level kernel await failed to
  /// produce its own transition signal; the driver has no separate recovery
  /// action beyond observing the kernel state it adapts.
  private func awaitKernelTerminal() async {
    if Self.isTerminal(kernel.state) { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let latch = TerminalResumeLatch()
      armTerminalObservation(continuation: continuation, latch: latch)
    }
  }

  /// Re-armable observation arm for `awaitKernelTerminal`. Split out so the
  /// `withObservationTracking` re-arm reaches a `@MainActor`-isolated method
  /// (matches the Swift 6 idiom used by `observeKernelState()`).
  private func armTerminalObservation(
    continuation: CheckedContinuation<Void, Never>, latch: TerminalResumeLatch
  ) {
    withObservationTracking {
      _ = kernel.state
    } onChange: { [weak self, latch] in
      Task { @MainActor [weak self, latch] in
        guard let self else { return }
        guard !latch.resumed else { return }
        if Self.isTerminal(self.kernel.state) {
          latch.resumed = true
          continuation.resume()
        } else {
          self.armTerminalObservation(continuation: continuation, latch: latch)
        }
      }
    }
  }

  private static func isTerminal(_ s: RecordingSessionState) -> Bool {
    switch s {
    case .idle, .completed, .cancelled, .discarded, .noSpeech, .failed,
      .audioInterrupted, .asrInterrupted:
      return true
    case .preparing, .warmingUp, .recording, .stopping, .transcribing, .finalizing:
      return false
    }
  }

  // MARK: State mapping — total, mechanical (PR-4 §3.7)

  /// Map a kernel state to the legacy `PipelineState`. Total over all 14 kernel
  /// states. `state.isActive` is `true` for every active kernel state, which
  /// the `PipelineSettingsSync` backend-switch guard depends on (§3.13).
  ///
  /// `failureDetail` is the underlying-error `localizedDescription` for the
  /// three reasons the old Parakeet pipeline embedded into its error strings
  /// (model load, recording start, transcription); the static map embeds it
  /// when present and falls back to the parity-bare string when nil. The
  /// driver's instance `state` getter threads `kernel.lastFailureDetail`
  /// through; existing test callers pass nil for byte-parity coverage.
  public static func pipelineState(
    for state: RecordingSessionState, externalError: String?,
    failureDetail: String? = nil
  ) -> PipelineState {
    if let externalError {
      return .error(externalError)
    }
    switch state {
    case .idle, .cancelled, .discarded, .noSpeech:
      return .idle
    case .preparing, .warmingUp:
      return .loadingModel
    case .recording:
      return .recording
    case .stopping, .transcribing:
      return .transcribing
    case .finalizing:
      // Seam audit Div 3 (2026-05-26): the old Parakeet pipeline set public
      // `.polishing` only when the polish step's `onWillProcess` fired
      // (TP:187-188). The kernel collapses both the early-finalizing
      // (transcript save / `.transcribing` sub-status) AND the polish
      // sub-status into public `.polishing`. WONTFIX: routing through
      // `kernel.finalizingSubStatus` cascades into two real safe-point
      // bugs — (1) `observeKernelState` only watches `kernel.state`, so the
      // sub-status flip never reaches `onStateChange`; (2)
      // `ASREventRouter` would route ASR crashes during the early window
      // into `handleASRServiceInterruption`, which sets an external error
      // and breaks the `.finalizing` safe point (verified Codex r1 on the
      // attempted Div 3 fix). The user-visible cost of the current
      // collapse is "Polishing..." appears a few hundred ms early in
      // MainWindow. The floating OVERLAY does not pay that cost: the
      // `overlayIntent` getter routes through `finalizingSubStatus`, and the
      // dedicated `observeFinalizingSubStatus` channel (#930) refreshes the
      // overlay live on the flip WITHOUT touching this public mapper.
      return .polishing
    case .completed:
      return .complete
    case .failed(let reason):
      return .error(failureMessage(reason, detail: failureDetail))
    case .audioInterrupted:
      return .error(InterruptionMessages.micDisconnected)
    case .asrInterrupted:
      return .error(asrInterruptedMessage)
    }
  }

  /// Mirrors the shipped the old Parakeet pipeline string verbatim (em-dash
  /// included) — PR-4 parity; the em-dash cleanup is a separate content change.
  static let asrInterruptedMessage = "Transcription service crashed — please try again"

  /// User-facing message for a `failed` terminal. The plan does not enumerate
  /// this map; each message mirrors today's the old Parakeet pipeline string for
  /// the equivalent failure verbatim (parity — PR-4's bar is "user feels
  /// nothing change"), or a sensible message where the kernel splits a reason
  /// today's pipeline did not name distinctly. The `captureStalled` em-dash is
  /// preserved to match the shipped string byte-for-byte; fixing it is a
  /// separate content-lane change, out of PR-4 scope.
  static func failureMessage(_ reason: RecordingFailureReason, detail: String? = nil)
    -> String
  {
    switch reason {
    case .prepareFailed:
      return "Couldn't start dictation. Please try again."
    case .permissionDenied:
      return "Microphone permission denied."
    case .modelWedged:
      return ModelLoadWatchdog.userMessage
    case .modelLoadFailed:
      // Old Parakeet pipeline shape: "Model load failed: <error.localizedDescription>"
      // (TP:440-445). Fall back to the bare string when no detail is captured.
      return detail.map { "Model load failed: \($0)" } ?? "Model load failed."
    case .captureStartFailed:
      // Old Parakeet pipeline shape: "Recording failed: <error.localizedDescription>"
      // (TP:577-588).
      return detail.map { "Recording failed: \($0)" } ?? "Recording failed."
    case .noAudioCaptured:
      return "No audio captured"
    case .asrEmpty:
      return "Couldn't catch that -- try again"
    case .asrFailed:
      // Old Parakeet pipeline shape: "Transcription failed: <error.localizedDescription>"
      // (TP:1045-1051).
      return detail.map { "Transcription failed: \($0)" } ?? "Transcription failed."
    case .asrWedged:
      return "Transcription stalled. Please try again."
    case .emptyAfterProcessing:
      return "No speech detected. Your clipboard is unchanged. Try again."
    case .storageFailed:
      return "Failed to save transcript"
    case .captureStalled:
      return "No audio detected — try again."
    }
  }
}
