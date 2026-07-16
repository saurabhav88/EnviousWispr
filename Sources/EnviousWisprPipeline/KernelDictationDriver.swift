import AppKit
import EnviousWisprAudio
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
///
/// #1388: `.cancelled` is a user-chosen terminal, NOT a failure. A user's
/// Cancel during the onboarding install (or a task cancellation of the
/// surrounding warm-up) must never surface the error UI, emit
/// `coldstart.warmup_failed`, or block the onboarding step. Classification
/// order is contractual: a wedge-guard fire (`didFire`) wins as
/// `WedgeError`/`.failed` FIRST — a guard teardown resumes the load via the
/// same cancellation error a user Cancel does, but a detector verdict is a
/// failure, a user cancel is a choice.
public enum EngineWarmupOutcome {
  case ready
  case failed(any Error)
  case cancelled
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

/// The six text-processing limb steps the App configures and the kernel's
/// `processText` closure runs. Created once, shared by the driver (which
/// exposes the accessors) and `KernelFinalizationWiring` (whose `processText`
/// consumes them). `inverseTextNormalization` runs before `llmPolish` as the
/// always-on raw-fallback floor (#145); `emojiRestore` runs AFTER `llmPolish` as
/// the final step, re-inserting emoji the on-device polish stripped (#761).
@MainActor
struct LimbSteps {
  let wordCorrection: WordCorrectionStep
  let fillerRemoval: FillerRemovalStep
  let emojiFormatter: EmojiFormatterStep
  let inverseTextNormalization: InverseTextNormalizationStep
  let llmPolish: LLMPolishStep
  let emojiRestore: EmojiRestoreStep
}

/// Issue #1339: sessionless model-load wedge guard for `ensureEngineWarm`.
///
/// The record-press path runs the kernel's session-scoped wedge detection
/// inside `RecordingSessionKernel.warmUp(sid)`. The sessionless warm-up
/// entries (onboarding / launch / engineSwap / coldPress prewarm) previously
/// had NO consumer at all — a first-run listing stall hung "Preparing
/// download..." forever with no Retry and no telemetry (the r/macapps P0).
///
/// One guard is armed per sessionless warm-up attempt (single-flighted by the
/// driver's `sessionlessWedgeGuard` slot). It feeds a `LoadProgressWatcher`
/// from an 8Hz poll of the shared progress file — the same signal source the
/// host proxy polls. Reading the file here (instead of consuming
/// `adapter.loadProgress`) avoids contending for that single-consumer
/// AsyncStream, which a mid-attempt record-press session may claim for the
/// kernel's own detector.
///
/// On a wedge it emits the existing `.modelLoadWedged` captured event +
/// PostHog `wedge_detected` (same payload fields as the session path), then
/// drives the existing heavy recovery (`adapter.recoverFromWedge()` →
/// `cancelInFlightLoad` → XPC invalidation). #1388 step 1 made that teardown
/// actually complete the parked load: `cancelInFlightLoad` resumes the
/// pending continuation with `ASRLoadCancelledError` (before #1388 nothing
/// resumed it — the await hung, the guard slot leaked, and 119 of 126
/// production fires reached no terminal outcome). `ensureEngineWarm`'s
/// classification then maps `didFire` to `WedgeError` — a detector verdict
/// stays a failure; only a user-initiated cancel maps to `.cancelled`.
///
/// #1388 also removed gate (B) — the post-signal silence gate — from this
/// guard's watcher: the CoreML install phase has ~20x-heterogeneous work
/// units, so the self-calibrated ratio was trained on the wrong distribution
/// and the 15s floor was the sole trigger on all 126 production fires, every
/// one a false positive on a healthy compile. Gate (A) survives: no signal
/// whatsoever inside `listingStallDeadlineSeconds` is a real, unambiguous
/// dead-service condition.
///
/// Stale-file trap (mirrors the host proxy's 2026-05-07 Codex finding): the
/// guard arms BEFORE `loadModel()` clears the progress file, so early reads
/// may see a PREVIOUS load's file. The mtime observed at arm time is a
/// baseline, not a signal — the watcher sees `nil` until the mtime changes.
@MainActor
package final class SessionlessLoadWedgeGuard {
  private let watcher: LoadProgressWatcher
  private let adapter: any ASREngineAdapter
  private let reasonToken: String
  private var pollTask: Task<Void, Never>?
  private var fireTask: Task<Void, Never>?
  private let staleBaselineMtime: Date?
  private(set) var didFire = false

  init(adapter: any ASREngineAdapter, reasonToken: String) {
    self.adapter = adapter
    self.reasonToken = reasonToken
    self.staleBaselineMtime = ProgressFile.shared.modificationTime()
    self.watcher = LoadProgressWatcher(
      listingPhase: ModelLoadStallPolicy.listingPhase,
      listingStallDeadlineSeconds: ModelLoadStallPolicy.listingStallDeadlineSeconds,
      // #1388: gate (B) OFF for the model-load application — its work-progress
      // stream has ~20x-heterogeneous units (CoreML compile), so the
      // post-signal silence gate false-fired on every healthy cold install.
      // Gate (A) — the listing deadline above — is this guard's only detector.
      postSignalSilenceGateEnabled: false,
      // Observation only: install duration + longest internal silence for the
      // warm-up success telemetry (the distribution gate (B) used to truncate).
      installPhase: ModelLoadStallPolicy.installPhase,
      // #1405 parking, RETAINED through #1388 (Codex r2 P1) and widened to
      // ALL delivery-owned phases (Codex r4 P2): delivery ticks — download,
      // cache validation, SHA verify — must not count as load signals, or
      // gate (A)'s pre-first-signal deadline is satisfied by delivery work
      // and a service that hangs before its first LOAD signal becomes
      // undetectable. The transition reset restarts the deadline at the
      // delivery→load boundary. The listing phase stays JUDGED (its
      // single-signal deadline is gate (A)'s listing variant). (First cut
      // deleted parking as "gate-B-only plumbing" — wrong: it protects
      // gate (A) too.)
      downloadOwnedPhases: ModelLoadStallPolicy.deliveryParkedPhases
    )
  }

  /// #1388: install-phase observation for the warm-up success telemetry.
  /// Read by `ensureEngineWarm` at completion (before disarm).
  var installObservation: InstallPhaseObservation? { watcher.installObservation }

  func arm() {
    watcher.start()
    Task { @MainActor [reasonToken] in
      await AppLogger.shared.log(
        "[WedgeGuard] armed reason=\(reasonToken)", level: .debug, category: "ASR")
    }
    pollTask = Task { @MainActor [weak self] in
      while let self, !Task.isCancelled {
        let raw = ProgressFile.shared.modificationTime()
        let mtime = (raw == self.staleBaselineMtime) ? nil : raw
        let phase = ProgressFile.shared.read()?.phase ?? ""
        self.watcher.observeTick(observedMtime: mtime, observedPhase: phase)
        try? await Task.sleep(nanoseconds: 125_000_000)
      }
    }
    fireTask = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.watcher.wedged()
      guard self.watcher.hasFired, !Task.isCancelled else { return }
      // Same-tick completion race: a load that just finished is healthy —
      // never tear down a ready engine (mirrors the kernel loop's check).
      guard self.adapter.readiness != .ready else { return }
      let snap = self.watcher.snapshot
      let backend = self.adapter.engineIdentity.rawValue
      // Live-UAT + field-diagnosis evidence line (verdicts read app.log).
      await AppLogger.shared.log(
        "[WedgeGuard] sessionless wedge fired reason=\(self.reasonToken) backend=\(backend) "
          + "phase=\(snap.lastObservedPhase) silence_ms=\(snap.silenceMs) "
          + "signals=\(snap.signalCountTotal) total_ms=\(snap.totalAttemptDurationMs)",
        level: .info, category: "ASR")
      // Deadline-edge race (cloud review, PR #1345): the log await above is a
      // suspension point — the load can complete and `disarm()` cancel this
      // task while it is parked. Cancellation does not stop a running task,
      // so re-check both signals here. Everything from this guard to
      // `recoverFromWedge()` is synchronous on MainActor, so a ready engine
      // can no longer be torn down and no wedge telemetry is emitted for a
      // load that actually finished.
      guard !Task.isCancelled, self.adapter.readiness != .ready else {
        await AppLogger.shared.log(
          "[WedgeGuard] fire aborted — load completed during fire reason=\(self.reasonToken)",
          level: .info, category: "ASR")
        return
      }
      self.didFire = true
      SentryBreadcrumb.captureError(
        ModelLoadWatchdog.WedgeError(),
        category: .modelLoadWedged,
        stage: "asr",
        extra: [
          "backend": backend,
          "silence_ms": snap.silenceMs,
          "observed_max_gap_ms": snap.maxGapMs,
          "observed_phase": snap.lastObservedPhase,
          "signal_count_total": snap.signalCountTotal,
          "first_signal_latency_ms": snap.firstSignalLatencyMs ?? -1,
          "total_attempt_duration_ms": snap.totalAttemptDurationMs,
          "warmup_reason": reasonToken,
          "sessionless": true,
        ])
      TelemetryService.shared.modelLoadWedged(
        backend: backend,
        stage: "sessionless_warmup",
        silenceMs: snap.silenceMs,
        observedMaxGapMs: snap.maxGapMs,
        observedPhase: snap.lastObservedPhase,
        signalCountTotal: snap.signalCountTotal,
        firstSignalLatencyMs: snap.firstSignalLatencyMs,
        totalAttemptDurationMs: snap.totalAttemptDurationMs)
      await self.adapter.recoverFromWedge()
    }
  }

  func disarm() {
    watcher.stop()
    pollTask?.cancel()
    pollTask = nil
    fireTask?.cancel()
    fireTask = nil
  }
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

  /// External-error surface (PR-4 §3.7; #1558 typed). `kernel.cancel()` alone
  /// maps to a `.hidden` overlay, so the driver owns the terminal reason pushed
  /// in from outside (`setTerminalReason`). Carries a TYPED
  /// `TerminalNoticeReason`, never authored English — the AppKit presenter
  /// speaks the sentence. Cleared on the next start / reset.
  private var lastTerminalReason: TerminalNoticeReason?

  /// #959 — set by `ASREventRouter` when the OS reaps this engine's idle ASR
  /// service while a resident model was loaded (readiness drops to `.notReady`
  /// with no active session). It is the ONLY signal that distinguishes "warm
  /// model reaped while idle" (re-warm ~0.2s) from "never-loaded true cold boot"
  /// (~6s). `RecordingStarter` consumes it to warm-respawn instead of showing
  /// the #879 cold pill. Cleared on consume (in the starter), on any successful
  /// load reaching `.recording` (below), and on `ensureEngineWarm` success.
  @ObservationIgnored
  public var residentModelLostWhileIdle = false

  /// #959 — latch set by `RecordingStarter` immediately before it dispatches
  /// `.toggleRecording` on the warm-respawn branch. While set, `.arming` shows the
  /// recording pill immediately (no `.cachingModel` flash) even though the reaped
  /// model is transiently reloading — the sub-second re-warm must not flash a
  /// caching pill (#1548 D2: the warm case now shows the recording pill, not
  /// `.hidden`). Cleared when the kernel reaches `.live` (emitting
  /// `service_respawn_completed`) or any terminal (no emit). Set ONLY just before
  /// the kernel dispatch so a pre-toggle abort never leaks a latch.
  @ObservationIgnored
  public private(set) var warmRespawnInFlight = false
  @ObservationIgnored
  private var warmRespawnStartedAt: ContinuousClock.Instant?

  /// Fired by the kernel-state observer whenever the mapped `PipelineState`
  /// changes. The App's `DictationLifecycleCoordinator` is the consumer.
  @ObservationIgnored
  public var onStateChange: ((PipelineState) -> Void)?

  /// The last mapped state `onStateChange` fired for — so a re-armed
  /// observation that fires without a mapped-state change stays quiet.
  @ObservationIgnored
  private var lastFiredState: PipelineState

  /// #1063 PR2 — fires when the kernel reaches a NON-`.completed` terminal,
  /// carrying this session's `recoverySessionID` (captured from `context.config`
  /// BEFORE the terminal cleanup nulls it) and the terminal KIND (discard vs
  /// failure). The App's `DictationLifecycleCoordinator` routes it to
  /// `RecoveryCoordinator` so a discarded recording's spool is deleted and a
  /// failed recording's spool is RETAINED for next-launch recovery. Distinct
  /// from `onStateChange` (which fires the externalError-pinnable public
  /// `PipelineState`): this keys off the RAW kernel terminal, so it never fires
  /// for `.completed` (a durable save already ran) and the error pin can't
  /// trigger it. `@MainActor` closure, off the collaborator cap; default no-op
  /// keeps the Pipeline recovery-unaware. The first param is the optional
  /// `recoverySessionID` (nil when recovery was off for the take).
  @ObservationIgnored
  public var onSessionEndedWithoutSave: (@MainActor (String?, RecordingRecoveryEnding) -> Void)?

  /// Fire-once latch for `onSessionEndedWithoutSave` (#1548 D1). Tracks the
  /// `currentSessionID` the ended-without-save check last fired for, so a
  /// re-armed observation can't double-fire for one concluded session while two
  /// consecutive sessions each fire (each has a distinct `SessionID`). Keyed by
  /// session identity, NOT state — a conclusion now lands on `.idle` with the
  /// ending on `recordingOutcome` (r1 Q1.1). `nil` until the first conclusion.
  @ObservationIgnored
  private var lastEndedWithoutSaveSessionID: SessionID?

  /// #1063 PR2 / #1464 — the origin attributed to the CURRENT session's
  /// `.cancelled` terminal. `.cancelled` is reached by BOTH a genuine user cancel
  /// (`RecordingFinalizer.cancel()` → `cancelRecording(disposition: .user)`) AND
  /// fault/system cancels that route through `kernel.cancel()` (active `reset()`,
  /// `setTerminalReason()`, the settings-rebuild cancel). A user cancel should
  /// DELETE the spool; a fault cancel should RETAIN recoverable audio. Defaults to
  /// `.systemOrFault` (RETAIN) so any cancel NOT explicitly attributed as a user
  /// discard conservatively keeps the audio. Set at the `cancelRecording` call
  /// site, consumed + reset at the `.cancelled` signal fire, and reset on each new
  /// session start. Projected into `RecordingRecoveryEnding.cancelled(_)` for the
  /// coordinator's delete-versus-retain predicate.
  @ObservationIgnored
  private var pendingCancelOrigin: RecordingCancelOrigin = .systemOrFault

  /// Fired by the finalizing-sub-status observer (`observeDisplayOnlyOverlay`)
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

  /// Fired at most once per recording when the recording approaches the
  /// max-duration cap (#1060), carrying remaining seconds. Display-only, like
  /// `onOverlayIntentChange`: carries NO lifecycle authority; wire ONLY to the
  /// overlay banner path, never to anything that mutates recording state. The
  /// App layer owns the user-facing copy.
  @ObservationIgnored
  public var onApproachingMaxDuration: ((TimeInterval) -> Void)?

  /// #1339 — the single active sessionless load-wedge guard, or nil when no
  /// sessionless warm-up attempt is in flight. The driver-level single-flight
  /// slot: exactly one guard per underlying load attempt, asserted by the
  /// topology test. Package-visible for that test only.
  @ObservationIgnored
  package private(set) var sessionlessWedgeGuard: SessionlessLoadWedgeGuard?

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
    self.lastFiredState = Self.pipelineState(
      for: kernel.state, outcome: kernel.recordingOutcome, externalReason: nil)
    self.lastEndedWithoutSaveSessionID = nil
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
  /// rather than starting a second compile. This drives the normal load only
  /// — no `prewarm` (it would load twice). #1275: the earlier "loaded already
  /// means first press instant, no dummy-transcribe" claim here (measured
  /// 2026-06-01) turned out to be path-dependent — a warm-cache relaunch
  /// showed a real first-decode penalty, contradicting that cold-load
  /// measurement. WhisperKit's backend now runs its own silent warm-up
  /// inference inside `loadFromPath` before flipping `isReady`, so "loaded"
  /// now genuinely means "first press instant" regardless of load path; see
  /// `whisperkit-research.md` for the full finding.
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
      // #959: a load has succeeded — drop any stale idle-reap marker so a later
      // genuine cold boot still shows the pill. Covers the launch/backend-swap
      // warm paths, which complete here WITHOUT a kernel state transition.
      residentModelLostWhileIdle = false
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
    // #1339: arm the sessionless load-wedge guard — exactly one per attempt.
    // Gated to file-backed signal sources (`warmupStallGuardEligible`:
    // Parakeet-over-XPC yes; WhisperKit and the in-process debug manager are
    // signal-free for the guard's poll and stay uncovered — Codex r1 P2) and
    // to the driver-level single-flight slot (a concurrent second warm-up
    // joins the same underlying load; the first caller's guard covers it).
    // The record-press session path never enters here — the kernel runs its
    // own detector.
    var wedgeGuard: SessionlessLoadWedgeGuard?
    if adapter.warmupStallGuardEligible, sessionlessWedgeGuard == nil {
      let armed = SessionlessLoadWedgeGuard(
        adapter: adapter, reasonToken: reason.telemetryToken)
      sessionlessWedgeGuard = armed
      wedgeGuard = armed
      armed.arm()
    }
    // Joined callers (armed slot taken) must still CLASSIFY a wedge fire:
    // capture the live guard — theirs or the armer's — before awaiting, so
    // the catch below reads `didFire` from the guard that actually covered
    // this load (Codex r1 P2 #2). The reference outlives the armer's disarm.
    let observedGuard = wedgeGuard ?? sessionlessWedgeGuard
    defer {
      if let wedgeGuard {
        wedgeGuard.disarm()
        sessionlessWedgeGuard = nil
      }
    }
    do {
      try await adapter.warmUp()
      residentModelLostWhileIdle = false  // #959: load succeeded — drop stale marker.
      let ms = Self.elapsedMs(since: start)
      // #1388: un-truncated install-phase observation. With gate (B) removed
      // there is no auto-abort at 15s, so the success event finally records
      // what real installs look like (duration + longest internal silence).
      // Nil when no guard covered this warm-up (WhisperKit, in-process debug).
      let install = observedGuard?.installObservation
      TelemetryService.shared.coldStartWarmupCompleted(
        engine: engine, reason: reason.telemetryToken, durationMs: ms,
        inferenceWarmupMs: adapter.lastWarmupInferenceMs,
        installDurationMs: install?.durationMs,
        installSilenceMaxMs: install?.silenceMaxMs)
      if reason == .launch {
        TelemetryService.shared.launchModelPreloadCompleted(
          backend: engine, result: warmupInFlight ? "joined_in_flight" : "success",
          durationMs: ms)
      }
      return .ready
    } catch {
      let ms = Self.elapsedMs(since: start)
      switch Self.classifyWarmupThrow(error, guardFired: observedGuard?.didFire == true) {
      case .wedge:
        // A guard fire is a detector VERDICT — with gate (B) removed this can
        // only be gate (A): the service reported nothing whatsoever inside
        // the deadline. Classified as the wedge it actually is so onboarding
        // shows the setup-failure copy + Retry, not a raw transport string.
        let classified: any Error = ModelLoadWatchdog.WedgeError()
        TelemetryService.shared.coldStartWarmupFailed(
          engine: engine, reason: reason.telemetryToken,
          error: String(describing: classified))
        if reason == .launch {
          TelemetryService.shared.launchModelPreloadCompleted(
            backend: engine, result: "failed", durationMs: ms)
        }
        return .failed(classified)
      case .cancelled:
        // A deliberate cancel (user Cancel via `cancelInFlightLoad`, or a
        // cancelled surrounding task / delivery download cancel) is a CHOICE:
        // never `warmup_failed`, never the error UI. `install_cancelled` is
        // the population signal for how often users bail out of the wait.
        TelemetryService.shared.installCancelled(
          engine: engine, reason: reason.telemetryToken, durationMs: ms)
        if reason == .launch {
          TelemetryService.shared.launchModelPreloadCompleted(
            backend: engine, result: "cancelled", durationMs: ms)
        }
        return .cancelled
      case .failure:
        // Everything else is a genuine failure with the true underlying
        // error (typed transport error on service death — step 1 made that
        // path actually resume; before #1388 it hung with no outcome).
        TelemetryService.shared.coldStartWarmupFailed(
          engine: engine, reason: reason.telemetryToken,
          error: String(describing: error))
        if reason == .launch {
          TelemetryService.shared.launchModelPreloadCompleted(
            backend: engine, result: "failed", durationMs: ms)
        }
        return .failed(error)
      }
    }
  }

  /// #1388: how a warm-up throw maps to a terminal outcome.
  package enum WarmupThrowClassification: Equatable {
    case wedge
    case cancelled
    case failure
  }

  /// #1388: pure classification for a warm-up throw. The ORDER is contractual
  /// (plan §4/§9): (1) a wedge-guard fire wins — a guard teardown resumes the
  /// load via the same cancellation error a user Cancel uses (shared resume
  /// vehicle, so the auto transport-retry can never resurrect either), but a
  /// detector verdict is a failure while a user cancel is a choice; (2) only
  /// then does the cancellation error (or a cancelled surrounding task) map
  /// to `.cancelled`; (3) everything else is a genuine failure. Static + pure
  /// so the boundary matrix is unit-testable without a live guard (the
  /// guard's fire path needs real time + the shared progress file; the
  /// mid-load service-kill fault drill covers that integration).
  package static func classifyWarmupThrow(
    _ error: any Error, guardFired: Bool
  ) -> WarmupThrowClassification {
    if guardFired { return .wedge }
    if error is ASRLoadCancelledError || error is CancellationError { return .cancelled }
    return .failure
  }

  /// #1388 step 3: cancel the in-flight sessionless warm-up (the onboarding
  /// install Cancel button's seam). Engines with a cancellable delivery stage
  /// (Parakeet) cancel BOTH halves — the download fetch and the in-flight
  /// load; others fall back to the plain model-preserving discard.
  /// `cancelInFlightLoad()` resumes the pending load with the dedicated
  /// cancellation error, which the classification above maps to `.cancelled`
  /// (the guard did not fire). Safe against a just-completed load — the
  /// adapter's in-flight gate and the delivery controller's
  /// completion-wins-the-race handling both make it a no-op then.
  public func cancelSessionlessWarmup() async {
    if let cancelling = adapter as? ASREngineWarmupCancelling {
      await cancelling.cancelSessionlessWarmup()
    } else {
      await adapter.cancel()
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
    observeDisplayOnlyOverlay()
    kernel.onApproachingMaxDuration = { [weak self] remaining in
      self?.onApproachingMaxDuration?(remaining)
    }
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
      for: kernel.state, outcome: kernel.recordingOutcome,
      deliveringPhase: kernel.deliveringPhase,
      externalReason: lastTerminalReason,
      interruptionCause: kernel.lastAudioInterruptionCause)
  }

  /// #1393: the pipeline's own single source of truth for monotonic elapsed
  /// recording time. `nil` outside an active/just-finished session.
  public var recordingElapsedSeconds: TimeInterval? { kernel.recordingElapsedSeconds }

  /// The transcript the `store` closure built for the last completed session.
  public var currentTranscript: Transcript? { outcome.transcript }

  /// The polish error from the last session, or `nil`.
  public var lastPolishError: String? { outcome.polishError }

  /// #1167: whether the last session's durable history save succeeded. `false`
  /// ⟺ the save threw but delivery still proceeded (best-effort save). The App
  /// layer gates the recovery-spool cleanup, the in-memory history append, and
  /// the history-save-failed pill on this.
  public var lastHistorySaved: Bool { outcome.historySaved }

  /// #1167: privacy-safe user reason for the history-save-failed pill, or `nil`
  /// on a successful save. Rendered as "Couldn't save to history: <reason>".
  public var lastHistorySaveReason: String? {
    outcome.historySaveError.map { HistorySaveErrorClass(storageError: $0).userReason }
  }

  /// #1167: normalized error class for the `dictation.completed` telemetry
  /// dimension, or `nil` on a successful save. No raw error strings / paths.
  public var lastHistorySaveErrorClass: String? {
    outcome.historySaveError.map { HistorySaveErrorClass(storageError: $0).rawValue }
  }

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

  /// Whether the active engine can detect spoken language. Exposed read-only so
  /// the App layer can capture it into the crash-recovery settings snapshot at
  /// record start (#1063 PR1) without reaching into the package-scoped `adapter`
  /// — and so recovery gates on the CAPABILITY, never an engine-identity literal
  /// (`gate-on-capability-not-identity-literal`). Mirrors `engineReadiness`.
  public var supportsLanguageDetection: Bool { adapter.capabilities.supportsLanguageDetection }

  // MARK: PR-4b.2 — direct methods + property (mirror old Parakeet pipeline App surface)

  /// Async cancel request. Wraps `kernel.cancel()` for App callers
  /// (`RecordingFinalizer.swift`) that `async`-call `pipeline.cancelRecording()`.
  /// Awaits the kernel reaching a terminal state before returning — callers rely
  /// on this to fully tear down capture before starting again. `kernel.cancel()`
  /// on its own is fire-and-latch: it triggers the recording-exit path or sets
  /// `cancelRequested`, but the actual transition to `.cancelled` /
  /// `.discarded` happens on the forward path's next yield.
  /// `disposition` (#1063 PR2 / #1464) attributes a `.cancelled` terminal for
  /// crash recovery: `.user` (genuine USER cancel — delete the spool) vs the
  /// default `.systemOrFault` (a system cancel — RETAIN recoverable audio). The
  /// user-cancel path passes `.user`; system cancels use the retain default.
  public func cancelRecording(disposition: RecordingCancelOrigin = .systemOrFault) async {
    pendingCancelOrigin = disposition
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
  /// `.asrInterrupted`), but `lastTerminalReason` can also surface
  /// `.error` while the kernel is still in an active state — the mic
  /// disconnect / ASR crash paths route through `setTerminalReason(...)`
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
  /// re-enters from is cleared synchronously here via `lastTerminalReason =
  /// nil`, so the user-visible `.error` resolves immediately even when the
  /// kernel itself takes another tick to reach `.idle`.
  public func reset() {
    lastTerminalReason = nil
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
      // `lastTerminalReason`) for the same reason as the transcript: a `reset()`
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
    guard kernel.state == .live else { return }
    kernel.requestStop()
    await awaitKernelTerminal()
  }

  /// External engine-interruption entry — bridges App-routed
  /// audio-engine-interruption signals into the kernel FSM and the
  /// telemetry emitters.
  ///
  /// `kernel.externalEngineInterrupted()` only acts on `.live` (its documented
  /// contract). For every other active state (`.arming`, `.stopping`,
  /// `.delivering`) the kernel silently drops the signal, which at PR-4b.4
  /// cutover would leave the UI stuck. Old TP's
  /// `handleEngineInterruption()` (old Parakeet pipeline)
  /// was state-agnostic: emit Sentry+PostHog state change, cancel cleanup,
  /// flip UI to the mic-disconnect error. Bridge matrix #4 ports the old
  /// behavior for those states via `setTerminalReason`.
  public func handleEngineInterruption(_ cause: EngineInterruptionCause) {
    switch kernel.state {
    case .live:
      kernel.externalEngineInterrupted(cause)
    case .arming, .stopping, .delivering:
      // Direct PostHog state update — the kernel won't reach
      // `.audioInterrupted` from here (§5.2 parity), so the lifecycle sink's
      // `.audioInterrupted` handler never fires.
      SentryBreadcrumb.updateRecordingState(active: false)
      setTerminalReason(Self.terminalNoticeReason(for: cause))
    case .idle:
      // Already idle / concluded — no useful action. Router-stale calls
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
  /// via direct Sentry emission + `setTerminalReason`.
  public func handleASRServiceInterruption() {
    // `.live` and `.delivering(.transcribing)` route to the kernel FSM; every
    // other active state (including the `delivering(.finalizing(_))` safe point)
    // takes the driver fallback (§5.2 parity).
    let routesToKernel: Bool
    switch kernel.state {
    case .live:
      routesToKernel = true
    case .delivering:
      routesToKernel = (kernel.deliveringPhase == .transcribing)
    case .arming, .stopping:
      routesToKernel = false
    case .idle:
      // Already idle / concluded — no useful action. Router-stale calls
      // land here.
      return
    }
    if routesToKernel {
      kernel.externalASRInterrupted()
    } else {
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
      setTerminalReason(.asrInterrupted)
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

  /// #1060: stop reason + wall-clock length of the most recent recording, for
  /// the App layer's `dictation.completed` telemetry. LIVE pass-through from the
  /// kernel; never persisted. Reason strings only, never user content.
  public var lastStopReason: String? { kernel.lastStopReason }
  public var lastRecordingDurationSeconds: Double? { kernel.lastRecordingDurationSeconds }
  /// #1408: non-nil when the most recent recording's capture was interrupted
  /// mid-flight (device died, cap reached). Drives the disconnect disclosure pill
  /// and `dictation.completed.interrupted_by`. LIVE pass-through from the kernel;
  /// never persisted; a low-cardinality reason string, no user content.
  public var lastAudioInterruptionCause: EngineInterruptionCause? {
    kernel.lastAudioInterruptionCause
  }
  /// #1317: non-nil when the most recent recording was classified as the
  /// mic-harness all-zero glitch (`allZeroFromStart` = the `.zeroSignal`
  /// pill; `becameZeroMidCapture` = a normal completion whose disclosure
  /// must say "may be missing its tail" instead of the interruption-cause
  /// derived sentence, since no `EngineInterruptionCause` is ever stamped
  /// for this path, §3.5). LIVE pass-through from the kernel; never
  /// persisted.
  public var lastZeroSignalFailureMode: CaptureStallFailureMode? {
    kernel.zeroSignalFailureMode
  }
  /// #1376: the resolved-route transports for the most recent recording, for
  /// the App layer's `dictation.completed` telemetry. LIVE pass-through from the
  /// kernel; never persisted. Low-cardinality transport/reason strings only.
  public var lastResolvedRoute: ResolvedRouteTransports? { kernel.lastResolvedRoute }
  /// #1434: non-nil when the most recent completion was a degraded-lead
  /// SALVAGE (the transcript was recovered by trimming a poisoned opening) —
  /// drives the post-completion disclosure pill and `dictation.completed`
  /// salvage fields. LIVE pass-through; never persisted; a number, no content.
  public var lastSalvagedLeadTrimMs: Int? { kernel.lastSalvagedLeadTrimMs }
  /// #1434: the capture-health record for the most recent recording (native
  /// rate, drop/error counters, stabilization flags). LIVE pass-through for
  /// the App layer's `dictation.completed` telemetry; hardware-class facts
  /// only, no identifiers.
  public var lastCaptureHealth: CaptureHealthTransports? { kernel.lastCaptureHealth }

  // MARK: Caller-facing event + overlay surface

  /// #1060/#1064/#1564: the transcribing phase as a TYPED fact. After a
  /// max-duration auto-stop the pill prefixes the cap notice (#1064) — the words
  /// are authored by `DictationNarrator`, not here. E2 (#1564) replaced the
  /// pre-authored String label with this typed `ProcessingPhase`.
  private var transcribingProcessingPhase: ProcessingPhase {
    kernel.lastStopReason == "max_duration"
      ? .transcribingMaxDurationReached
      : .transcribing
  }

  public var overlayIntent: OverlayIntent {
    if let lastTerminalReason {
      return .error(reason: lastTerminalReason)
    }
    // A concluded session carries its ending category on `recordingOutcome`
    // (state has returned to `.idle`, #1548 D1). The ending pill reads from the
    // outcome, not an FSM terminal state.
    if let outcome = kernel.recordingOutcome {
      switch outcome {
      case .completed, .cancelled, .discarded, .noSpeech:
        return .hidden
      case .failed(let reason):
        // #1558: emit the TYPED reason; the raw detail stays owned by the
        // producer's Sentry site and never reaches the pill.
        return .error(reason: Self.terminalNoticeReason(for: reason))
      case .noTransport:
        // No audio transport arrived — same "no audio to turn into text"
        // outcome as an empty buffer (parity with the prior "No audio captured").
        return .error(reason: .noAudioCaptured)
      case .audioInterrupted:
        return .interruption(
          reason: Self.terminalNoticeReason(for: kernel.lastAudioInterruptionCause))
      case .asrInterrupted:
        return .error(reason: .asrInterrupted)
      }
    }
    switch kernel.state {
    case .idle:
      return .hidden
    case .arming:
      // Immediate acknowledgement (#1548 D2): the moment the press is accepted,
      // show the recording pill when the model is warm — OR when a sub-second
      // warm-respawn is in flight (the reaped model is reloading, but flashing a
      // caching pill for that ~20ms re-warm is the pointless flash #959 avoids;
      // now it shows the recording pill instead of `.hidden`). A GENUINE cold
      // model load (`adapter.readiness != .ready`, not a warm-respawn) still
      // surfaces the honest caching pill.
      return (warmRespawnInFlight || adapter.readiness == .ready)
        ? .recording(audioLevel: 0)
        : .cachingModel(engineLabel: adapter.engineIdentity.displayName)
    case .live:
      // The real level is supplied by `AudioCaptureManager` downstream — the
      // pipeline returns 0 here, exactly as the old Parakeet pipeline did.
      return .recording(audioLevel: 0)
    case .stopping:
      return .processing(phase: transcribingProcessingPhase)
    case .delivering:
      // The transcribing/polishing phase comes from the delivering sub-phase
      // (nested `FinalizingSubStatus`), replacing the old `finalizingSubStatus`.
      switch kernel.deliveringPhase {
      case .transcribing, .finalizing(.transcribing):
        return .processing(phase: transcribingProcessingPhase)
      case .finalizing(.polishing):
        return .processing(phase: .polishing)
      }
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
      case .idle:
        // Start: clear the prior session's surfaces, capture finalization
        // context AT RECORDING START (PR-4.5 #6, parity with old
        // the old Parakeet pipeline), then mint a new session. `.idle` is also
        // where a concluded session rests (its outcome is cleared by `start`).
        //
        // The frontmost app + focused AX element are captured here so that a
        // polish step taking seconds — during which focus may shift to the
        // app's own window or another app — does not lose the original paste
        // target. The frozen `DictationSessionConfig` lands in
        // `context.config` for the wiring's `processText` / `deliver`
        // closures to read at finalize time (the wiring's optional-chained
        // reads were always-nil in production until this PR — finding #6).
        lastTerminalReason = nil
        // #1063 PR2: a fresh session starts with the conservative cancel origin
        // (RETAIN) — only a genuine user cancel during this session flips it to
        // `.user`. Prevents a stale user-discard from a prior session leaking onto
        // this session's fault-cancel.
        pendingCancelOrigin = .systemOrFault
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
        // #1167: a fresh session starts assuming the save will succeed; the
        // best-effort `store` closure flips these only on a real save throw.
        outcome.historySaved = true
        outcome.historySaveError = nil
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
      case .live:
        kernel.requestStop()
      case .arming:
        // A stop toggle during Arming (while capture is still being established —
        // a cold model load can make this window last seconds) is a REAL stop: the
        // user pressed to stop before recording was even established. Dropping the
        // toggle here would leave the mic recording against the user's explicit
        // intent (Codex code-diff P1). `requestStop()` latches the stop, which the
        // forward path's checkpoint concludes `.discarded(.releasedBeforeRecording)`
        // (#1548 D2 — the kernel handles the `.arming` case).
        kernel.requestStop()
      case .stopping, .delivering:
        // Mid-session — don't interrupt processing past the point of no return
        // (PR-1 §B.1.2 safe point: a transcript is being produced/delivered).
        break
      }
    case .requestStop:
      kernel.requestStop()
    case .cancelRecording:
      kernel.cancel()
    case .reset:
      lastTerminalReason = nil
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
      // `setTerminalReason` parked the observer on `.error`, that observer
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
  /// state. The state mapper reads `lastTerminalReason`, so the *driver's*
  /// public state did change; but the kernel-state observer at
  /// `observeKernelState` only fires when `kernel.state` itself changes. When
  /// `kernel.cancel()` is a no-op (kernel already idle / terminal — common
  /// for pre-warm / mic failures routed through here), the observer never
  /// runs and the lifecycle coordinator never learns about the error. Direct
  /// fire-through ensures the error reaches the overlay / hotkey teardown
  /// path regardless of kernel-state movement.
  public func setTerminalReason(_ reason: TerminalNoticeReason) {
    kernel.cancel()
    outcome.transcript = nil
    lastTerminalReason = reason
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
    // periphery:ignore - test seam
    var kernelForTesting: RecordingSessionKernel { kernel }

    /// Test-only session-context handle. Used to verify the terminal-state
    /// cleanup clears `targetApp` + `targetElement` (Div 8 of seam audit /
    /// TP:998-1000, 1128-1129, 1221-1223). The context's properties are not
    /// otherwise observable from outside the driver.
    // periphery:ignore - test seam
    var contextForTesting: KernelSessionContext { context }
  #endif

  // MARK: Kernel-state observation

  /// Arm `withObservationTracking` on the kernel lifecycle tuple; the `onChange`
  /// closure hops to `@MainActor` before re-reading and re-arming (PR-4 §3.7,
  /// Gemini concurrency premise — the explicit hop is the safe pattern). #1548
  /// D1: tracks `recordingOutcome` (a conclusion lands on `.idle`) and
  /// `deliveringPhase` (the public `.transcribing → .polishing` boundary is a
  /// phase change, not a state transition) in addition to `state`. Every
  /// downstream fire dedupes (public `PipelineState` for `fireStateChangeIfNeeded`,
  /// `currentSessionID` for the ended-without-save latch), so the extra wake-ups
  /// are safe.
  private func observeKernelState() {
    withObservationTracking {
      _ = kernel.state
      _ = kernel.recordingOutcome
      _ = kernel.deliveringPhase
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self else { return }
        // #1063 PR2 — FIRST, before `clearContextConfigIfTerminalOrIdle()` nulls
        // `context.config`: capture this session's recovery id off the still-live
        // config and fire the ended-without-save signal on a fresh non-`.completed`
        // terminal. Ordering is load-bearing — the id is gone after the clear.
        self.fireSessionEndedWithoutSaveIfNeeded()
        self.clearContextConfigIfTerminalOrIdle()
        self.updateWarmRespawnLatch()
        self.fireStateChangeIfNeeded()
        self.observeKernelState()
      }
    }
  }

  /// #959 — called by `RecordingStarter` immediately before the warm-respawn
  /// `.toggleRecording` dispatch (after the pre-warm cancellation guards), so a
  /// pre-toggle abort never leaves a latch set. Latches the warm overlay morph
  /// and the start instant for the respawn-duration metric.
  public func beginWarmRespawnOverlay() {
    warmRespawnInFlight = true
    warmRespawnStartedAt = ContinuousClock.now
  }

  /// #959 — called by `ASREventRouter` when the OS reaps this engine's idle ASR
  /// service while a resident model was loaded. Sets the marker AND emits the
  /// reclaim telemetry here (the driver already owns the `EnviousWisprServices`
  /// import) so `ASREventRouter` keeps its minimal import set.
  public func markResidentModelLostWhileIdle() {
    residentModelLostWhileIdle = true
    TelemetryService.shared.serviceReclaimed(asrBackend: adapter.engineIdentity.rawValue)
  }

  /// #959 — clear the warm-respawn latch + idle-reap marker as the kernel moves.
  /// On the first `.recording`: the model loaded successfully — clear the marker
  /// and, if the latch was set, emit `service_respawn_completed` (start→recording)
  /// and drop the latch. On any terminal reached without recording (cancel /
  /// fail / abort): drop the latch WITHOUT emitting completed.
  private func updateWarmRespawnLatch() {
    switch kernel.state {
    case .live:
      residentModelLostWhileIdle = false
      guard warmRespawnInFlight else { return }
      if let started = warmRespawnStartedAt {
        TelemetryService.shared.serviceRespawnCompleted(
          engine: adapter.engineIdentity.rawValue,
          durationMs: Self.elapsedMs(since: started))
      }
      warmRespawnInFlight = false
      warmRespawnStartedAt = nil
    case .idle, .stopping, .delivering:
      // Reached a non-recording state — if a warm-respawn latch is still set the
      // start aborted before capture (or the latch was cleared at `.live`
      // already; the guard makes the post-recording states a no-op). Drop it
      // without emitting completed.
      guard warmRespawnInFlight else { return }
      warmRespawnInFlight = false
      warmRespawnStartedAt = nil
    case .arming:
      break  // still warming — keep the latch so the overlay stays morphed
    }
  }

  private func fireStateChangeIfNeeded() {
    let mapped = state
    guard mapped != lastFiredState else { return }
    lastFiredState = mapped
    onStateChange?(mapped)
  }

  /// #1063 PR2 — fire `onSessionEndedWithoutSave` when the kernel enters a fresh
  /// non-`.completed` terminal. Reads `context.config?.recoverySessionID` BEFORE
  /// the caller's `clearContextConfigIfTerminalOrIdle()` nulls it. The latch
  /// (`lastEndedWithoutSaveObservedState`) is updated on EVERY transition so a
  /// re-armed observation can't double-fire for one terminal, while back-to-back
  /// sessions ending at the same terminal still each fire (intervening states
  /// change the latch). `.completed` is never a signal here (its durable-save
  /// callback owns cleanup); `.idle` and the transient states map to nil.
  private func fireSessionEndedWithoutSaveIfNeeded() {
    // A concluded session carries its ending on `recordingOutcome`; fire once
    // per concluded session, deduped by `currentSessionID` (NOT by state — two
    // sessions may publish an outcome with idle between them, r1 Q1.1). #1548 D1.
    guard let outcome = kernel.recordingOutcome else { return }
    guard kernel.currentSessionID != lastEndedWithoutSaveSessionID else { return }
    lastEndedWithoutSaveSessionID = kernel.currentSessionID
    let ending: RecordingRecoveryEnding?
    if case .cancelled = outcome {
      // `.cancelled` is ambiguous (Codex terminal-kind matrix): a genuine user
      // cancel DELETES, but a fault/system cancel (active reset, external-error,
      // settings rebuild) RETAINS recoverable audio. Resolve via the per-cancel
      // origin attributed at the `kernel.cancel()` call site; consume + reset to
      // the conservative default so a stale user-discard can't leak to a later
      // fault cancel. The delete-versus-retain decision itself lives in the
      // coordinator's predicate (#1464) — the driver only projects the origin.
      ending = .cancelled(pendingCancelOrigin)
      pendingCancelOrigin = .systemOrFault
    } else {
      ending = Self.recoveryEnding(for: outcome)
    }
    guard let ending else { return }
    onSessionEndedWithoutSave?(context.config?.recoverySessionID, ending)
  }

  /// Project the non-`.completed` terminal `RecordingOutcome` into the narrow
  /// public `RecordingRecoveryEnding` the crash-recovery cleanup signal crosses
  /// into AppKit with (#1464). The kernel has ALREADY floored an interrupted
  /// `.discarded`/`.noSpeech`/`.failed(.noAudioCaptured)` to `.audioInterrupted`
  /// upstream (`RecordingSessionKernel.interruptedTerminalFloor`), so those reach
  /// here already as `.audioInterrupted`. Payloads are dropped — the coordinator's
  /// predicate keys only on the terminal FAMILY, never `DiscardReason`/
  /// `NoSpeechSource`, keeping the internal enum inside Pipeline. `.cancelled` is
  /// EXCLUDED (returns nil) — resolved at the fire site via `pendingCancelOrigin`.
  /// Also nil for `.completed` (durable save ran). Exhaustive so a new
  /// `RecordingOutcome` forces a routing decision. Internal (not private) so the
  /// split is unit-tested directly (`matcher-set-adversarial-tests`).
  static func recoveryEnding(for outcome: RecordingOutcome)
    -> RecordingRecoveryEnding?
  {
    switch outcome {
    case .discarded:
      return .discarded
    case .noSpeech:
      return .noSpeech
    case .failed:
      return .failed
    case .audioInterrupted:
      return .audioInterrupted
    case .asrInterrupted:
      return .asrInterrupted
    case .noTransport:
      return .noTransport
    case .cancelled, .completed:
      return nil
    }
  }

  /// Arm a SECOND, separate `withObservationTracking` for the DISPLAY-ONLY
  /// overlay refreshes whose trigger the public `PipelineState` collapses, so
  /// `observeKernelState` / `onStateChange` never sees them. Two such cases:
  ///
  /// - `deliveringPhase` flip "Transcribing…" → "Polishing…" mid-`.delivering`
  ///   (`PipelineState` collapses both to `.polishing`, #930).
  /// - `didLoadModelThisSession` flip while `.arming`: a cold model load that
  ///   STARTS mid-Arming (adapter was `.ready` at first render, then went
  ///   not-ready before the readiness check) must morph the pill `.hidden` →
  ///   `.cachingModel`. Arming ALWAYS maps to `.loadingModel`, so no
  ///   `onStateChange` re-fires and the cold load would otherwise stay invisible
  ///   until Live or failure (Codex code-diff r3 P2). The kernel stamps the flag
  ///   BEFORE `warmUp` while `adapter.readiness != .ready` (`:970-974`), so
  ///   `overlayIntent` reads the cold pill at this fire.
  ///
  /// Two deliberate shapes:
  /// 1. Re-arm UNCONDITIONALLY via `defer`, BEFORE the state guard. Both tracked
  ///    fields reset during `resetSessionState()` at the START of the next
  ///    session, while the kernel is NOT in the pushing state; if the re-arm sat
  ///    behind the guard the observation would silently die after one session.
  /// 2. Push ONLY through `onOverlayIntentChange` — never `fireStateChangeIfNeeded`
  ///    / `onStateChange`. The `PipelineState` fan-out and `ASREventRouter`
  ///    routing stay byte-identical; this channel is display-only. Level-triggered
  ///    (re-reads the CURRENT `overlayIntent`), so a coalesced fire and a late
  ///    `@MainActor` hop both push the correct overlay, which the overlay dedups
  ///    (`show(intent:)`).
  private func observeDisplayOnlyOverlay() {
    withObservationTracking {
      _ = kernel.deliveringPhase
      _ = kernel.didLoadModelThisSession
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self else { return }
        defer { self.observeDisplayOnlyOverlay() }
        switch self.kernel.state {
        case .delivering, .arming:
          self.onOverlayIntentChange?(self.overlayIntent)
        case .idle, .live, .stopping:
          break
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
    case .idle:
      // `.idle` is both pre-start and post-conclusion (#1548 D1); clearing here
      // fires once per conclusion (state returns to `.idle`) and is idempotent
      // pre-start. Paste has already completed by the time the kernel concludes.
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
    case .arming, .live, .stopping, .delivering:
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

  /// `true` when the session is NOT in flight — `.idle` is both pre-start and
  /// post-conclusion (a conclusion returns to `.idle` with the ending on
  /// `recordingOutcome`, #1548 D1). Every active state carries a nil outcome, so
  /// `state == .idle` is the exact "done / resting" predicate the old
  /// `{idle + 7 terminals}` set expressed.
  private static func isTerminal(_ s: RecordingSessionState) -> Bool {
    s == .idle
  }

  // MARK: State mapping — total, mechanical (PR-4 §3.7)

  /// Map a kernel state to the legacy `PipelineState`. Total over all 14 kernel
  /// states. `state.isActive` is `true` for every active kernel state, which
  /// the `PipelineSettingsSync` backend-switch guard depends on (§3.13).
  ///
  /// #1558: `externalReason` and the outcome map now yield a TYPED
  /// `TerminalNoticeReason`; the AppKit presenter authors the sentence, so the
  /// raw underlying-error detail (once embedded here as
  /// "Model load failed: <detail>") never reaches a user surface — it stays
  /// owned by the producer's Sentry site. `interruptionCause` selects the
  /// audio-interruption reason (#1408): nil yields `.unknownInterruption` (the
  /// neutral "Recording interrupted." line), never a disconnect claim. Only the
  /// instance `state` getter has a kernel to read the real cause from.
  // Internal (was public): the signature now names the internal
  // `RecordingOutcome` / `DeliveringPhase` types. No App-layer caller exists
  // (only same-module `state` getter + `@testable` tests); the App reads the
  // public `state` getter's `PipelineState` (#1548 D1, §2.5).
  static func pipelineState(
    for state: RecordingSessionState,
    outcome: RecordingOutcome?,
    deliveringPhase: DeliveringPhase = .transcribing,
    externalReason: TerminalNoticeReason?,
    interruptionCause: EngineInterruptionCause? = nil
  ) -> PipelineState {
    if let externalReason {
      return .error(externalReason)
    }
    // A concluded session's public state comes from `recordingOutcome` (state
    // has returned to `.idle`, #1548 D1).
    if let outcome {
      switch outcome {
      case .completed:
        return .complete
      case .cancelled, .discarded, .noSpeech:
        return .idle
      case .failed(let reason):
        return .error(terminalNoticeReason(for: reason))
      case .noTransport:
        return .error(.noAudioCaptured)
      case .audioInterrupted:
        return .error(terminalNoticeReason(for: interruptionCause))
      case .asrInterrupted:
        return .error(.asrInterrupted)
      }
    }
    switch state {
    case .idle:
      return .idle
    case .arming:
      return .loadingModel
    case .live:
      return .recording
    case .stopping:
      return .transcribing
    case .delivering:
      // The transcribe → polish PUBLIC boundary is the delivering sub-phase
      // `.transcribing → .finalizing(_)`. Byte-parity with the old
      // `.transcribing`-state → `.transcribing` / `.finalizing`-state →
      // `.polishing` mapping. Seam audit Div 3 (2026-05-26): the old pipeline
      // set public `.polishing` only when the polish step fired; the kernel
      // collapses both the early-finalizing (transcript save) AND polish into
      // public `.polishing`, so "Polishing..." appears a few hundred ms early
      // in MainWindow (accepted cost). `observeKernelState` now tracks
      // `deliveringPhase`, so the public flip reaches `onStateChange`; the
      // `.finalizing(.transcribing) → .finalizing(.polishing)` flip dedupes to
      // no public change. The floating overlay refreshes live via
      // `observeDisplayOnlyOverlay` (#930).
      switch deliveringPhase {
      case .transcribing:
        return .transcribing
      case .finalizing:
        return .polishing
      }
    }
  }

  /// #1558: map a kernel `RecordingFailureReason` to the typed, presentation-
  /// neutral `TerminalNoticeReason`. PURE — no telemetry side effect (this map
  /// is read from BOTH the state and overlay projections, so emitting here
  /// would double-fire; the raw error is already captured at its producer's
  /// Sentry site). Total over all 12 cases (no `default`), so a new
  /// `RecordingFailureReason` reds the build until it is assigned a reason.
  nonisolated static func terminalNoticeReason(for reason: RecordingFailureReason)
    -> TerminalNoticeReason
  {
    switch reason {
    case .prepareFailed: return .prepareFailed
    case .permissionDenied: return .permissionDenied
    case .modelWedged: return .modelWedged
    case .modelLoadFailed: return .modelLoadFailed
    case .captureStartFailed: return .captureStartFailed
    case .noMicrophoneFound: return .noMicrophoneFound
    case .noAudioCaptured: return .noAudioCaptured
    case .asrEmpty: return .asrEmptyWithSpeech
    case .asrFailed: return .asrFailed
    case .asrWedged: return .asrWedged
    case .emptyAfterProcessing: return .emptyAfterProcessing
    case .captureStalled: return .captureStalled
    case .zeroSignal: return .zeroSignal
    }
  }

  /// #1558: map a stamped `EngineInterruptionCause` (optional) to the typed
  /// interruption reason. `nil` → `.unknownInterruption` (neutral line), the
  /// same choice the retired `InterruptionMessages` made. Exhaustive.
  nonisolated static func terminalNoticeReason(for cause: EngineInterruptionCause?)
    -> TerminalNoticeReason
  {
    switch cause {
    case .some(.deviceRemoved): return .deviceRemoved
    case .some(.engineLost): return .engineLost
    case .none: return .unknownInterruption
    }
  }
}
