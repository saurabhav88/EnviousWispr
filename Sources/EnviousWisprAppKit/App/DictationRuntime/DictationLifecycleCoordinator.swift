import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation

/// PR9 of #763 — Lifecycle home for pipeline state-change side effects plus the
/// seven PR8 backend-resolver symbols that PR8 left on the former root state (`LastCapturingBackend`
/// enum, the three resolver-state vars, and the three resolver helpers).
///
/// Owns three responsibilities the former root state god-object held:
///   1. Pipeline `onStateChange` side effects (overlay show/clear, hotkey
///      arbitration, telemetry, chip lifecycle, terminal settings sync).
///   2. Backend-resolver state + helpers for `DictationRuntime`'s routers
///      (`activeCaptureBackend()`, `isCurrentSession(_:)`).
///   3. Post-completion warning Task (cancellable, shared across backends).
///
/// Private to `DictationRuntime`'s composition — not environment-injected and
/// not consumed directly by views or AppDelegate. AppDelegate gets a weak
/// reference solely to wire `onPipelineStateChange` (icon updates).
@MainActor
final class DictationLifecycleCoordinator {
  // MARK: - Collaborators (let-counted by CeilingsTestSupport)
  //
  // Ceiling 11 (raised from parent migration plan's 10; see
  // `DictationLifecycleCoordinatorCeilingsTests` Bible-changelog comment).
  // The 11th slot is `recordingLockedAccess`, a get/set closure-pair struct
  // that lets the coordinator read AND write the hands-free `isRecordingLocked`
  // flag without storing a reference to its owner. PR-C.3 of #763 rehomed that
  // flag onto `LiveRecordingState` (the closures retarget at the call site).

  let kernelDriver: KernelDictationDriver  // 1
  let whisperKitKernelDriver: KernelDictationDriver  // 2
  let recordingOverlay: RecordingOverlayPanel  // 3
  let hotkeyService: HotkeyService  // 4
  let settingsSync: PipelineSettingsSync  // 5
  let audioCapture: any AudioCaptureInterface  // 6
  let transcriptCoordinator: TranscriptCoordinator  // 7
  let settings: SettingsManager  // 8
  let lastRecordingResult: LastRecordingResult  // 9
  let languageSuggestionPresenter: LanguageSuggestionPresenter?  // 10
  let recordingLockedAccess: RecordingLockedAccess  // 11

  /// Bidirectional accessor for the hands-free `isRecordingLocked` flag (rehomed
  /// onto `LiveRecordingState` in PR-C.3 of #763). The state-change closure both
  /// READS the lock state (to pass into
  /// `recordingOverlay.show(...)` so hands-free visuals render correctly) AND
  /// WRITES it (to clear hands-free on any transition out of `.recording`).
  /// Packaging the pair as one struct keeps the cap at 11.
  struct RecordingLockedAccess {
    let get: @MainActor () -> Bool
    let set: @MainActor (Bool) -> Void
  }

  // MARK: - Owned mutable state (var; excluded from collaborator cap)

  /// #285 tiebreaker — which backend most recently entered an active state
  /// (startup, loading, or recording). Used when both pipelines are active
  /// simultaneously (e.g. one still polishing while the other begins a new
  /// capture).
  enum LastCapturingBackend { case parakeet, whisperKit }
  var lastCapturingBackend: LastCapturingBackend = .parakeet

  /// Previous active-state of each pipeline, tracked so we flip
  /// `lastCapturingBackend` only on inactive→active transitions. Without this,
  /// `.transcribing → .polishing` (active → active) would re-steal ownership
  /// after a different backend acquired the shared capture.
  private var prevParakeetActive: Bool = false
  private var prevWhisperKitActive: Bool = false

  /// Cancellable Task for the deferred polish-failed warning overlay. Cancelled
  /// on every new recording start. Shared across both backends because the
  /// 400ms-delayed guard checks `.complete` on either driver — moving this
  /// into a per-pipeline handler would split a shared lifecycle (see
  /// `PipelineStateChangeHandler.swift:13-22`). PR-5 Rung 5 (#827) collapsed
  /// the legacy `.complete | .ready` WhisperKit gate to just `.complete`
  /// because both drivers now share `PipelineState` vocabulary.
  private var postCompletionWarningTask: Task<Void, Never>?

  /// AppDelegate sets this to update the menu-bar icon + drive update-banner
  /// suppression. Setter-injected post-init, the same precedent as PR4's
  /// `var languageSuggestionPresenter`.
  var onPipelineStateChange: ((PipelineState) -> Void)?

  /// #1063 PR1 — fires once per completed recording whose transcript carries a
  /// recovery session id, AFTER the durable save (the completion seam runs on
  /// `.complete`, which the kernel reaches only after `TranscriptStore.save`
  /// committed). `DictationRuntime` sets it to `RecoveryCoordinator.handleDurableSave`
  /// so that session's spool + key are deleted. Setter-injected like
  /// `onPipelineStateChange` (a `var` closure, off the collaborator cap); the
  /// default no-op keeps recovery-off behavior. Keeps the Pipeline recovery-unaware.
  var onDurableSave: (String) -> Void = { _ in }

  /// #1063 PR2 — fires when a recording reaches a NON-`.completed` terminal,
  /// carrying this session's `recoverySessionID` (or nil if recovery was off) and
  /// the terminal KIND. `DictationRuntime` sets it to `RecoveryCoordinator
  /// .handleRecordingEndedWithoutDurableSave(recoverySessionID:terminal:)`, which
  /// deletes a DISCARD-terminal spool now and RETAINS a FAILURE-terminal spool for
  /// next-launch recovery. Driven by the kernel's RAW terminal transition (via the
  /// driver's `onSessionEndedWithoutSave`), NOT the externalError-pinnable published
  /// state — so it never fires for `.completed` (whose save path runs `onDurableSave`)
  /// and the error pin can't trigger an early delete. Off-cap `var` closure,
  /// default no-op keeps recovery-off behavior. (PR1's published-state cleanup
  /// branch is replaced by this signal.)
  var onRecordingEndedWithoutDurableSave: (String?, RecordingTerminalKind) -> Void = { _, _ in }

  /// #1171 — fired on every pipeline state change (both drivers). The composition
  /// root binds it to `EngineCoordinator.poke(.driverStateChanged)` so the
  /// coordinator refreshes engine status on non-terminal transitions AND applies
  /// an engine switch that was deferred while a recording was active once the
  /// pipeline reaches a terminal. Replaces the former
  /// `settingsSync.retryDeferredBackendSwitch` terminal calls (the coordinator now
  /// owns deferred-switch application). Off-cap `var` closure; default no-op keeps
  /// legacy/test construction unchanged.
  var onEngineRelevantStateChange: () -> Void = {}

  /// Per-pipeline side-effect executors. Lazy so the closures can capture
  /// `self` after all stored properties are initialized.
  private lazy var parakeetStateHandler: PipelineStateChangeHandler =
    makeStateChangeHandler(backendLabel: "parakeet")
  private lazy var whisperKitStateHandler: PipelineStateChangeHandler =
    makeStateChangeHandler(backendLabel: "whisperKit")

  init(
    kernelDriver: KernelDictationDriver,
    whisperKitKernelDriver: KernelDictationDriver,
    recordingOverlay: RecordingOverlayPanel,
    hotkeyService: HotkeyService,
    settingsSync: PipelineSettingsSync,
    audioCapture: any AudioCaptureInterface,
    transcriptCoordinator: TranscriptCoordinator,
    settings: SettingsManager,
    lastRecordingResult: LastRecordingResult,
    languageSuggestionPresenter: LanguageSuggestionPresenter?,
    recordingLockedAccess: RecordingLockedAccess
  ) {
    self.kernelDriver = kernelDriver
    self.whisperKitKernelDriver = whisperKitKernelDriver
    self.recordingOverlay = recordingOverlay
    self.hotkeyService = hotkeyService
    self.settingsSync = settingsSync
    self.audioCapture = audioCapture
    self.transcriptCoordinator = transcriptCoordinator
    self.settings = settings
    self.lastRecordingResult = lastRecordingResult
    self.languageSuggestionPresenter = languageSuggestionPresenter
    self.recordingLockedAccess = recordingLockedAccess
  }

  /// Wire the two pipelines' `onStateChange` callbacks. Called once by the
  /// composition root (`EnviousWisprApp.init`) after `DictationLifecycleCoordinator`
  /// and the routers are constructed.
  func install() {
    kernelDriver.onStateChange = { [weak self] newState in
      guard let self else { return }
      self.handleParakeet(newState: newState)
    }
    whisperKitKernelDriver.onStateChange = { [weak self] newState in
      guard let self else { return }
      self.handleWhisperKit(newState: newState)
    }
    // #1063 PR2: the kernel's RAW non-`.completed` terminal signal, carrying the
    // recovery id + terminal KIND. Routed to the recovery cleanup (discard deletes,
    // failure retains). Distinct from `onStateChange` (the pinnable published
    // state) — keyed off the kernel terminal so it never fires during `.finalizing`.
    kernelDriver.onSessionEndedWithoutSave = { [weak self] id, kind in
      self?.onRecordingEndedWithoutDurableSave(id, kind)
    }
    whisperKitKernelDriver.onSessionEndedWithoutSave = { [weak self] id, kind in
      self?.onRecordingEndedWithoutDurableSave(id, kind)
    }
    // #930: the overlay-only sub-status channel. A `.transcribing` →
    // `.polishing` flip mid-`.finalizing` does NOT change the public
    // `PipelineState`, so it never reaches `onStateChange`; this dedicated
    // callback refreshes the overlay label through the same show seam. It is
    // display-only — wired ONLY to `showOverlayIntent`, never to lifecycle.
    kernelDriver.onOverlayIntentChange = { [weak self] intent in
      self?.showOverlayIntent(intent)
    }
    whisperKitKernelDriver.onOverlayIntentChange = { [weak self] intent in
      self?.showOverlayIntent(intent)
    }
    // #1060: approaching-cap warning — display-only banner, no lifecycle authority.
    let onApproaching: (TimeInterval) -> Void = { [weak self] r in
      self?.showApproachingCapWarning(remainingSeconds: r)
    }
    kernelDriver.onApproachingMaxDuration = onApproaching
    whisperKitKernelDriver.onApproachingMaxDuration = onApproaching
  }

  /// The single overlay-show seam. Every overlay push — state-handler driven
  /// (`makeStateChangeHandler`) and sub-status driven (`onOverlayIntentChange`)
  /// — flows through here so the audio-level provider and lock state are
  /// threaded identically. `RecordingOverlayPanel.show(intent:)` dedups on its
  /// current intent, so a redundant identical push is dropped (#930).
  private func showOverlayIntent(_ intent: OverlayIntent) {
    let audioCapture = self.audioCapture
    recordingOverlay.show(
      intent: intent,
      audioLevelProvider: { audioCapture.audioLevel },
      isRecordingLocked: recordingLockedAccess.get()
    )
  }

  /// #1060: within the last minute before the cap. Show a PERSISTENT in-panel
  /// banner (no auto-dismiss) that stays until the recording stops; cleared by the
  /// transition out of recording. "Under a minute" reads accurately for the whole
  /// window, so no countdown or late-fire guard is needed. Copy lives here.
  private func showApproachingCapWarning(remainingSeconds: TimeInterval) {
    recordingOverlay.flashRecordingNotice("Recording auto-stops in under a minute (60-minute cap)")
    TelemetryService.shared.recordingCapWarningShown(
      backend: lastCapturingBackend == .whisperKit ? "whisperKit" : "parakeet",
      capSeconds: TimingConstants.maxRecordingDuration)
  }

  // MARK: - Per-pipeline state-change handling

  private func handleParakeet(newState: PipelineState) {
    onPipelineStateChange?(newState)
    // #1171 — every transition refreshes engine status; the terminal ones apply a
    // switch deferred while this recording was active (coordinator-owned).
    onEngineRelevantStateChange()
    switch newState {
    case .recording:
      hotkeyService.registerCancelHotkey()
      // PR7 of #763 — clear the prior recording's polish error on every new
      // recording start. Reset matrix locked in PR7 plan: cancel does NOT
      // clear (prior error stays cleared by next start). Sunset PR11.
      lastRecordingResult.polishError = nil
    case .loadingModel, .transcribing, .polishing:
      recordingLockedAccess.set(false)
      hotkeyService.unregisterCancelHotkey()
    case .error, .idle, .complete:
      recordingLockedAccess.set(false)
      hotkeyService.unregisterCancelHotkey()
      // Session ended — retry any Ollama eviction deferred because the
      // frozen session pinned the old model.
      settingsSync.retryDeferredOllamaEviction(settings: settings)
      settingsSync.retryDeferredEGOneDeactivation(settings: settings)
    // #1171 — a switch deferred while this recording was active is applied by
    // the EngineCoordinator via `onEngineRelevantStateChange()` (fired above).
    // #1063 PR2: the recovery-spool cleanup is NO LONGER keyed off this
    // externalError-pinnable published state. It is driven by the kernel's RAW
    // terminal transition via `kernelDriver.onSessionEndedWithoutSave` (wired in
    // `install()`), which carries the recovery id + terminal KIND and never
    // fires during `.finalizing` — resolving PR1's "delete a beat early" hole.
    }
    let nowActive = newState.isActive
    if nowActive && !prevParakeetActive {
      lastCapturingBackend = .parakeet
    }
    prevParakeetActive = nowActive
    parakeetStateHandler.handle(
      to: newState,
      pipelineOverlayIntent: kernelDriver.overlayIntent,
      lastPolishError: kernelDriver.lastPolishError,
      currentTranscript: kernelDriver.currentTranscript,
      historySaved: kernelDriver.lastHistorySaved,
      historySaveReason: kernelDriver.lastHistorySaveReason,
      salvagedLead: kernelDriver.lastSalvagedLeadTrimMs != nil
    )
    // PR7 of #763 — push polish error to the post-recording result home so
    // views can read `lastRecordingResult.polishError` without reaching
    // through the former root state. Sunset PR11.
    lastRecordingResult.polishError = kernelDriver.lastPolishError
    dispatchChipLifecycle(newState: newState, lastPolishError: kernelDriver.lastPolishError)
  }

  /// PR-5 Rung 5 (#827): WhisperKit recordings now flow through a second
  /// `KernelDictationDriver`, so this handler takes `PipelineState` (same
  /// vocabulary as the Parakeet handler). The legacy bespoke WhisperKit
  /// states `.startingUp` and `.ready` mapped to `.loadingModel` and `.idle`
  /// respectively in the driver's state-mapping (`KernelDictationDriver
  /// .pipelineState(for:externalError:failureDetail:)`); the unified switch
  /// here mirrors the Parakeet handler so the chip-lifecycle dispatch can be
  /// shared (the previous WhisperKit-specific dispatcher only differed in
  /// matching `.complete` plus the now-extinct `.ready`).
  private func handleWhisperKit(newState: PipelineState) {
    onPipelineStateChange?(newState)
    // #1171 — see `handleParakeet`: refresh status + apply a deferred switch on terminal.
    onEngineRelevantStateChange()
    switch newState {
    case .recording:
      hotkeyService.registerCancelHotkey()
      lastRecordingResult.polishError = nil
    case .loadingModel, .transcribing, .polishing:
      recordingLockedAccess.set(false)
      hotkeyService.unregisterCancelHotkey()
    case .error, .idle, .complete:
      recordingLockedAccess.set(false)
      hotkeyService.unregisterCancelHotkey()
      settingsSync.retryDeferredOllamaEviction(settings: settings)
      settingsSync.retryDeferredEGOneDeactivation(settings: settings)
    // #1171 — a deferred switch is applied by the EngineCoordinator via
    // `onEngineRelevantStateChange()` (fired above).
    // #1063 PR2: recovery-spool cleanup is driven by the kernel terminal signal
    // (`onSessionEndedWithoutSave`), not this published state — see the Parakeet
    // handler. Nothing to do here.
    }
    let nowActive = newState.isActive
    if nowActive && !prevWhisperKitActive {
      lastCapturingBackend = .whisperKit
    }
    prevWhisperKitActive = nowActive
    whisperKitStateHandler.handle(
      to: newState,
      pipelineOverlayIntent: whisperKitKernelDriver.overlayIntent,
      lastPolishError: whisperKitKernelDriver.lastPolishError,
      currentTranscript: whisperKitKernelDriver.currentTranscript,
      historySaved: whisperKitKernelDriver.lastHistorySaved,
      historySaveReason: whisperKitKernelDriver.lastHistorySaveReason,
      salvagedLead: whisperKitKernelDriver.lastSalvagedLeadTrimMs != nil
    )
    lastRecordingResult.polishError = whisperKitKernelDriver.lastPolishError
    dispatchChipLifecycle(
      newState: newState,
      lastPolishError: whisperKitKernelDriver.lastPolishError
    )
  }

  // PR4 of #763 (#252): dispatch chip lifecycle to LanguageSuggestionPresenter.
  // Race guards (Codex P2 r2+r3+r7) preserved verbatim: skip surface when
  // polish failed; clearBuffer on .recording to drain stale triggers.
  private func dispatchChipLifecycle(newState: PipelineState, lastPolishError: String?) {
    switch newState {
    case .recording:
      languageSuggestionPresenter?.clearBuffer()
    case .complete:
      if lastPolishError == nil {
        languageSuggestionPresenter?.surfaceBufferedChipIfPossible(
          currentLanguageMode: settings.languageMode)
      } else {
        languageSuggestionPresenter?.clearBuffer()
      }
    case .error:
      languageSuggestionPresenter?.clearCurrentChip()
      languageSuggestionPresenter?.clearBuffer()
    default:
      break
    }
  }

  // MARK: - PR8 deferred resolver helpers

  /// #285 — resolve which backend owns the shared audio capture right now.
  /// Returns nil when both pipelines are fully idle. Shared helper for both
  /// telemetry routing and engine-interrupt routing so the two paths cannot
  /// drift.
  func activeCaptureBackend() -> LastCapturingBackend? {
    let pActive = kernelDriver.state.isActive
    let wkActive = whisperKitKernelDriver.state.isActive
    if pActive && wkActive { return lastCapturingBackend }
    if pActive { return .parakeet }
    if wkActive { return .whisperKit }
    return nil
  }

  /// #285 — belt-and-suspenders filter for late callbacks that somehow slip
  /// past the per-source `isCapturing` / observer-removal guards during a
  /// backend switch.
  func isCurrentSession(_ sessionID: UInt64) -> Bool {
    sessionID == audioCapture.currentCaptureSessionID
  }

  func activeTelemetryTarget() -> (any HeartPathTelemetryTarget)? {
    switch activeCaptureBackend() {
    case .whisperKit: return whisperKitKernelDriver
    case .parakeet: return kernelDriver
    case nil:
      // Idle → attribute to the backend that most recently owned a session.
      return lastCapturingBackend == .whisperKit ? whisperKitKernelDriver : kernelDriver
    }
  }

  // MARK: - Post-completion warning

  /// Cancel any pending deferred polish-failed warning. Called by the former root state's
  /// PR10-scope start paths (`hotkeyService.onStartRecording`,
  /// `toggleRecording(source:)`) BEFORE a new recording overlay shows, so a
  /// stale warning from the previous session cannot race the new dictation's
  /// visual feedback. PR10 will inline this when start/stop/cancel migrate
  /// into the recording-state homes; this method retires with it.
  func cancelPendingWarning() {
    postCompletionWarningTask?.cancel()
  }

  private func schedulePostCompletionWarning(message: String) {
    postCompletionWarningTask?.cancel()
    postCompletionWarningTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled, let self else { return }
      // Only show if we're still in the completed state (no new recording started)
      let parakeetComplete = self.kernelDriver.state == .complete
      let whisperKitComplete = self.whisperKitKernelDriver.state == .complete
      guard parakeetComplete || whisperKitComplete else { return }
      self.recordingOverlay.show(intent: .warning(message: message))
    }
  }

  // MARK: - State-handler factory

  private func makeStateChangeHandler(backendLabel: String) -> PipelineStateChangeHandler {
    // #1060: this handler's driver — completion telemetry reads its length + stop reason.
    let driver = backendLabel == "whisperKit" ? whisperKitKernelDriver : kernelDriver
    return PipelineStateChangeHandler(
      showOverlay: { [weak self] intent in self?.showOverlayIntent(intent) },
      cancelPendingWarning: { [weak self] in self?.postCompletionWarningTask?.cancel() },
      schedulePolishFailedWarning: { [weak self] in
        self?.schedulePostCompletionWarning(message: "Polish failed -- using raw text")
      },
      appendCompletedTranscript: { [weak self] t in
        self?.transcriptCoordinator.append(t)
        // #1063 PR1: the save is durable by `.complete`; delete this session's
        // spool + key. nil unless recovery was armed for this take.
        if let sid = t.recoverySessionID { self?.onDurableSave(sid) }
      },
      reportDictationCompleted: { [weak self] t in
        guard let self else { return }
        // #1376/#1434: route + capture-health + salvage argument assembly
        // lives in `DictationCompletedReporting` (thin-factory discipline).
        DictationCompletedReporting.report(
          transcript: t, inputMode: self.settings.recordingMode.rawValue, driver: driver)
      },
      reportPipelineFailed: { msg in
        TelemetryService.shared.pipelineFailed(
          stage: "transcription", errorCategory: "pipeline_error", errorCode: msg,
          recoverable: false, backend: backendLabel)
      },
      // #1167: history-save-failed pill (post-completion warning slot, ~400 ms).
      scheduleHistorySaveFailedWarning: { [weak self] reason in
        self?.schedulePostCompletionWarning(message: "Couldn't save to history: \(reason)")
      },
      // #1434: salvaged-lead disclosure pill — the degraded-lead retry
      // recovered this dictation by trimming a poisoned opening, so the
      // pasted text is missing its lead. Same generic post-completion
      // mechanism as the two pills above; the message is wired HERE, never
      // hardcoded into a shared closure (Codex r2 rev 5).
      scheduleSalvagedLeadWarning: { [weak self] in
        self?.schedulePostCompletionWarning(
          message: "Beginning of dictation was unclear and was skipped")
      }
    )
  }
}
