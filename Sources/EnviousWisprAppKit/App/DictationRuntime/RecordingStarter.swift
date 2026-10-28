import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation

/// PR10 of #763 — owns the start path lifted out of the former root state. `start()` is
/// the hotkey-onStartRecording path (refresh permissions, show overlay
/// immediately, prewarm the pipeline, dispatch `.toggleRecording`, run
/// the post-condition wedge guard, log cold-start telemetry).
/// `toggle(source:)` is the lighter UI/menu path that skips prewarm and
/// threads the call site's `TriggerSource` into the session config.
/// `isProcessing` is the read-only callback target for the hotkey gate.
///
/// Does NOT own `HotkeyService` (that lives on the App-owned `@State`
/// and is shared with `PipelineSettingsSync` + `DictationLifecycleCoordinator`).
@MainActor
final class RecordingStarter {
  let audioCapture: any AudioCaptureInterface
  let asrManager: any ASRManagerInterface
  let kernelDriver: KernelDictationDriver
  let whisperKernelDriver: KernelDictationDriver
  let settings: SettingsManager
  let recordingOverlay: OverlayDirector
  /// #904 test seam — the accessibility re-arm step `start()`/`toggle()` run.
  /// Default (bound in init capturing `permissions`, since a default arg can't
  /// reference an init param) is today's block; a test injects a counting spy.
  let accessibilityRefresh: @MainActor () -> Void

  /// #1558 — narrow live mic-permission check the prewarm error router reads so a
  /// denied-permission start surfaces "Microphone access is off." Bound in init.
  let micPermissionDenied: @MainActor () -> Bool

  /// #3960 — live "macOS has never asked" read and the prompt itself. A press
  /// while never asked asks instead of recording: starting capture first makes
  /// macOS prompt mid-take, the take records exact zeros and ends blaming the
  /// hardware. Bound in init.
  let micNeedsAsking: @MainActor () -> Bool
  let requestMicrophone: @MainActor () async -> Bool

  /// #3960 — true while the microphone prompt from a press is on screen, so a
  /// second press neither asks again nor records.
  private var isAskingForMicrophone = false
  /// #3960 — the latest ask, kept so a test can await the answer being handled
  /// instead of guessing when it was.
  private(set) var microphoneAskTask: Task<Void, Never>?

  /// Arms the crash-recovery limb for a recording about to start, returning the
  /// Everything this start path needs from the crash-recovery limb, in ONE slot.
  ///
  /// **Packaged because the architectural ceiling caught the accretion**
  /// (#2292 C4b). Adding Discard as a fifth recovery closure took this type to 11
  /// closures against a cap of 10 and 17 stored dependencies against 16. Raising
  /// a ceiling needs a Bible line and a grounded review; packaging is the
  /// documented alternative and is the better answer here anyway, because these
  /// five were always one collaborator wearing five hats — every one of them is
  /// bound to `RecoveryCoordinator` by `DictationRuntime`.
  ///
  /// Still bare closures inside, for the reason each of them said individually:
  /// the kernel never sees the coordinator, and this type does not name it.
  struct RecoveryAccess {
    /// Arms crash recovery for a start, returning the durable session id and an
    /// opaque directive payload (nil when recovery is off or could not arm).
    /// (#1063 PR1.)
    let makeDirective:
      @MainActor (SettingsManager, ASRBackendType, Bool) async -> (
        recoverySessionID: String, payload: Data
      )?

    /// Cleans up a recovery key/spool armed for a start that never produced a
    /// recording — a PTT release or a concurrent-toggle stop landing in the arm
    /// window. Those paths mint no kernel session, so no terminal pipeline state
    /// fires to drive the lifecycle coordinator's cleanup; the start path must
    /// trigger it directly, passing the id armed for this start (nil ⇒ recovery
    /// was off — no-op). A pre-start abort is always a DISCARD.
    /// (#1063 PR1, Codex r3; id+terminal in PR2.)
    let cleanupArm: @MainActor (String?) -> Void

    /// Whether the limb is replaying a leftover recording behind the blocking
    /// pill (#1063 PR2). A record-press while true mints NO session — the gate
    /// shows the "recovering" pill and returns, exactly like the cold-engine
    /// not-ready gate.
    let isRecovering: @MainActor () -> Bool

    /// #1707 Phase 3 (§3.1) — set on every recovery-refusal read site so a
    /// multi-item scan yields the engine BETWEEN items rather than only after
    /// the whole scan.
    let signalPendingLiveStart: @MainActor () -> Void

    /// What the recovery notice's Discard button does (#2292 C4b).
    ///
    /// Required, and it arrives on the notice's own `PillRequest`. It used to
    /// travel out through the overlay's settable effect sink to a router holding
    /// a WEAK recovery target, so an unset target left a rendered button that
    /// reached nobody.
    let discardActive: @MainActor () -> Void

    /// The recovery-off shape, for construction that is not about recovery.
    static let disabled = RecoveryAccess(
      makeDirective: { _, _, _ in nil },
      cleanupArm: { _ in },
      isRecovering: { false },
      signalPendingLiveStart: {},
      discardActive: {})
  }

  let recovery: RecoveryAccess

  /// #2648 — the shared ASR-and-polish resource, claimed for THIS dictation.
  ///
  /// One slot, and the holder is bound at wiring time, so the start path cannot
  /// claim the resource as anything but a dictation. The starter never sees
  /// `EngineLease`; `EngineAdmissionAccess` is the same wrapper shape
  /// `RecoveryEngineClaim` uses over `EngineRecoveryGate`.
  ///
  /// This is the eighth `let` collaborator, and the ceiling suite was raised
  /// from 7 to 8 in the same change. The alternatives were worse: the existing
  /// `RecoveryAccess` package is recovery's domain, and choosing a bare closure
  /// purely because the closure bin has room would be picking a shape to satisfy
  /// a counter rather than to describe the dependency.
  let engineAdmission: EngineAdmissionAccess

  /// #3973 C1 — the press waiting for its engine turn while a meeting holds the engine, shared
  /// with the finalizer, the hotkey callbacks and quit so any of them can end that wait.
  let pendingRequests: PendingDictationRequests

  /// #1171 — drives the SELECTED engine to ready (the coordinator owns the
  /// single-flight switch + warm) and returns the outcome (ready / notInstalled /
  /// notReady). Bound to `EngineCoordinator.ensureSelectedReadyForPress`; default
  /// `.notReady` keeps legacy/test construction unchanged. Used by the
  /// start-of-recording safety check so a press can never record on an engine
  /// other than the one the user selected.
  let ensureSelectedReadyForPress: @MainActor () async -> EngineCoordinator.PressReadiness

  /// #1171 — whether an engine switch is in flight. Bound to
  /// `EngineCoordinator.isSwitching`; default no-switch keeps legacy/test
  /// construction unchanged. A press during an in-flight switch routes through the
  /// reactive pill rather than minting a session on a transient engine.
  let isEngineSwitching: @MainActor () -> Bool

  /// #3546 A3: set by the composition root; a press during the in-session Ultra activation
  /// shows the upgrade's pills instead of the engine-switch ones.
  var isActivatingParakeetUpgrade: (@MainActor () -> Bool)?

  /// #1171 — the start-window state-gate. `beginMinting` is called the instant the
  /// start path commits to minting (selected == active confirmed, no switch in
  /// flight); while held, `EngineCoordinator` refuses to switch engines, so the
  /// active engine cannot change out from under this start (the SuperWhisper
  /// "Cannot switch in <starting> state" gate — race-free, replacing re-checks).
  /// `endMinting` runs on every exit via `defer`. Bound to
  /// `EngineCoordinator.beginMinting`/`.endMinting`; default no-ops keep legacy/test
  /// construction unchanged.
  let beginMinting: @MainActor () -> Void
  /// #1386 PR-2c: the selected engine's model-on-disk truth (EngineCoordinator's
  /// `status.selectedInstalled`), read at press time so a removed model presses
  /// into the honest not-installed pill. Defaults open (true) — a missing
  /// authority must not block dictation.
  var isSelectedModelInstalled: @MainActor () -> Bool = { true }
  /// #4069: "Turn off dictation during meetings" is on and a meeting is capturing
  /// (`MeetingCoordinator.isCapturing`). Read once per START press, before any await. Defaults
  /// open (false): a missing authority must not block dictation.
  var isDictationOffForMeeting: @MainActor () -> Bool = { false }
  let endMinting: @MainActor () -> Void

  var heartControlRecovery: HeartControlRecovery
  var recordingLockedAccess: DictationLifecycleCoordinator.RecordingLockedAccess
  var lastUserStopAccess: RecordingFinalizer.LastUserStopAccess
  weak var lastRecordingResult: LastRecordingResult?
  weak var dictationLifecycleCoordinator: DictationLifecycleCoordinator?

  /// Read by `HotkeyController`'s `onIsProcessing` callback. True when
  /// either backend is still finishing the previous session (transcribing
  /// or polishing) — blocks a new start so the user does not stack
  /// recordings on top of in-flight post-processing.
  var isProcessing: Bool {
    if asrManager.activeBackendType == .whisper {
      let state = whisperKernelDriver.state
      return state == .transcribing || state == .polishing
    } else {
      let state = kernelDriver.state
      return state == .transcribing || state == .polishing
    }
  }

  /// The driver for the currently-active engine. #879 Phase D — lets the
  /// runtime route onboarding's first-run warm-up through the active engine's
  /// shared `ensureEngineWarm`. Computed (not a stored slot or a method), so it
  /// adds no entanglement to this start-path home.
  var activeDriver: KernelDictationDriver {
    asrManager.activeBackendType == .whisper ? whisperKernelDriver : kernelDriver
  }

  /// #1707 Phase 3 — the backend + timestamp of the FIRST recovery refusal in
  /// an unbroken run of refusals ("blocked episode"). Consumed (and cleared)
  /// ONLY by a LATER press that actually mints an active kernel session — a
  /// failed or unrelated press never consumes it, so it can't misattribute
  /// one recording's wait to a different one's timing.
  ///
  /// Deliberately NOT overwritten by a later refusal within the same episode
  /// (GitHub cloud review, PR #1732): an impatient user pressing repeatedly
  /// while still refused must not make `waitSeconds` shrink toward zero each
  /// time — that would understate the real wait and could mask a genuine
  /// regression in the bounded-wait fix this telemetry exists to validate.
  /// This does not fully solve the inverse case (a user who presses once,
  /// then waits well past recovery's actual release before retrying, still
  /// inflates `waitSeconds` with real idle time) — that would need a release-
  /// side timestamp from the recovery gate itself, out of scope for this
  /// phase; disclosed in the plan as a known characteristic of this signal,
  /// not corrected here.
  private var pendingBlockedPressInfo: (backend: String, blockedAt: ContinuousClock.Instant)?

  /// Every recovery-refusal read site funnels through here: shows the pill,
  /// signals the scan to yield the engine (§3.1), records the FIRST blocked-
  /// press timestamp of this episode for the pairing `recovery.press_unblocked`
  /// telemetry below, and emits the existing `recovery.press_blocked` event.
  private func handleRecoveryPressRefused(backend: ASRBackendType) {
    // **Discard rides WITH the notice since C4b.** It used to travel out through
    // the overlay's settable effect sink to a router that held a weak recovery
    // target — a route that could be unset, leaving a rendered button that
    // reached nobody. Required here, so the omission does not compile.
    _ = recordingOverlay.present(.recoveryNotice(onDiscard: recovery.discardActive))
    recovery.signalPendingLiveStart()
    if pendingBlockedPressInfo == nil {
      pendingBlockedPressInfo = (backend.rawValue, ContinuousClock.now)
    }
    TelemetryService.shared.recoveryPressBlocked(asrBackend: backend.rawValue)
  }

  /// #2648 — the session-claim hand-off found no lifecycle coordinator.
  ///
  /// A fault worth seeing rather than a case to handle quietly: the same shape
  /// (and the same error type) `HotkeyController` uses for its own nil
  /// collaborators, so both land in one Sentry group.
  private static func reportNilCollaborator(callback: String) {
    SentryBreadcrumb.captureError(
      HotkeyController.NilCollaboratorError(callback: callback),
      category: .pipelineDispatchFailed, stage: "recording",
      extra: ["callback": callback])
  }

  /// #2648 — every shared-resource refusal read site funnels through here.
  ///
  /// **Ordering is load-bearing and it is checked AFTER the recovery gate, not
  /// before.** Crash recovery holds the same claim while it replays, so a
  /// lease-first ladder would answer a recovery press with this generic pill
  /// instead of the recovery notice, which carries a Discard button and is the
  /// only way out of a stuck replay. Recovery refuses first; whatever reaches
  /// here is a different workload.
  private func handleSharedEngineBusyPressRefused(holder: EngineLease.Holder) {
    recordingOverlay.present(.warning(reason: .sharedEngineBusy(holder: holder)))
    // #4052: a refusal is evidence, not an absence. (A meeting transcript no longer refuses:
    // #3973 C1 waits for its turn instead, `PendingDictationRequests`.)
    Task {
      await AppLogger.shared.log(
        "record press refused holder=\(holder.rawValue)", level: .info, category: "Pipeline")
    }
  }

  /// #4069: the user turned dictation off during meetings and a meeting is capturing. Checked
  /// after the recovery gate (its notice carries Discard) and before the microphone ask and the
  /// engine claim, so a refusal neither prompts nor claims anything.
  private func handleDictationOffDuringMeeting() {
    recordingOverlay.present(.warning(reason: .dictationOffDuringMeeting))
    Task {
      await AppLogger.shared.log(
        "record press refused reason=meeting_dictation_off", level: .info, category: "Pipeline")
    }
  }

  /// Called immediately before a press commits to minting an active kernel
  /// session (every gate, including the recovery one, has already passed).
  /// Consumes any pending blocked-press info and emits the pairing
  /// `recovery.press_unblocked` event so production telemetry can measure
  /// whether the bounded-wait fix actually shrank real wait times. Reports
  /// the BLOCKED press's backend (not the current one — an engine switch
  /// could occur in between), so a backend's own wait times stay attributable
  /// to it.
  private func consumePendingBlockedPressIfAny() {
    guard let info = pendingBlockedPressInfo else { return }
    pendingBlockedPressInfo = nil
    let waitSeconds = Int((ContinuousClock.now - info.blockedAt).components.seconds)
    TelemetryService.shared.recoveryPressUnblocked(
      asrBackend: info.backend, waitSeconds: waitSeconds)
  }

  init(
    audioCapture: any AudioCaptureInterface,
    asrManager: any ASRManagerInterface,
    kernelDriver: KernelDictationDriver,
    whisperKernelDriver: KernelDictationDriver,
    settings: SettingsManager,
    permissions: PermissionsService,
    recordingOverlay: OverlayDirector,
    heartControlRecovery: HeartControlRecovery,
    recordingLockedAccess: DictationLifecycleCoordinator.RecordingLockedAccess,
    lastUserStopAccess: RecordingFinalizer.LastUserStopAccess,
    lastRecordingResult: LastRecordingResult,
    dictationLifecycleCoordinator: DictationLifecycleCoordinator?,
    accessibilityRefresh: (@MainActor () -> Void)? = nil,
    recovery: RecoveryAccess,
    engineAdmission: EngineAdmissionAccess,
    pendingRequests: PendingDictationRequests,
    ensureSelectedReadyForPress: @escaping @MainActor () async -> EngineCoordinator.PressReadiness =
      {
        .notReady
      },
    isEngineSwitching: @escaping @MainActor () -> Bool = { false },
    beginMinting: @escaping @MainActor () -> Void = {},
    endMinting: @escaping @MainActor () -> Void = {}
  ) {
    self.recovery = recovery
    self.engineAdmission = engineAdmission
    self.pendingRequests = pendingRequests
    self.ensureSelectedReadyForPress = ensureSelectedReadyForPress
    self.isEngineSwitching = isEngineSwitching
    self.beginMinting = beginMinting
    self.endMinting = endMinting
    self.audioCapture = audioCapture
    self.asrManager = asrManager
    self.kernelDriver = kernelDriver
    self.whisperKernelDriver = whisperKernelDriver
    self.settings = settings
    self.recordingOverlay = recordingOverlay
    self.heartControlRecovery = heartControlRecovery
    self.recordingLockedAccess = recordingLockedAccess
    self.lastUserStopAccess = lastUserStopAccess
    self.lastRecordingResult = lastRecordingResult
    self.dictationLifecycleCoordinator = dictationLifecycleCoordinator
    let perms = permissions
    self.accessibilityRefresh =
      accessibilityRefresh ?? {
        perms.refreshAccessibilityStatus()
        if !perms.hasAccessibilityPermission { perms.restartMonitoringIfNeeded() }
      }
    self.micPermissionDenied = { perms.microphonePermissionIsDenied }
    self.micNeedsAsking = { perms.microphoneNeedsAsking }
    self.requestMicrophone = { await perms.requestMicrophoneAccess() }
  }

  /// #3960 — the press-time microphone ask, shared by `start()` and the start
  /// branch of `toggle(source:)`. Returns true when this press only asks (the
  /// caller mints nothing). The press is not kept: with push-to-talk the key is
  /// usually up by the time the user answers, so after Allow the next press
  /// records (the Meetings `fixMicrophone` precedent). A refusal shows the
  /// "Microphone access is off." notice on whichever engine is selected once
  /// the answer arrives, unless a session started meanwhile.
  private func askForMicrophoneIfNeeded() -> Bool {
    // The pending flag first: a status change while the prompt is up must not
    // let a press past the request still on screen.
    if isAskingForMicrophone { return true }
    guard micNeedsAsking() else { return false }
    isAskingForMicrophone = true
    let requestMicrophone = self.requestMicrophone
    microphoneAskTask = Task { @MainActor [weak self] in
      let granted = await requestMicrophone()
      guard let self else { return }
      self.isAskingForMicrophone = false
      // The request's answer decides, not a fresh status read: on macOS 27.2 a
      // running app's status read can lag the answer (#3960 Live UAT).
      guard !granted,
        !self.kernelDriver.state.isActive, !self.whisperKernelDriver.state.isActive
      else { return }
      self.activeDriver.setTerminalReason(.permissionDenied)
    }
    return true
  }

  /// Hotkey PTT start path. Mirrors the former root-state file (pre-PR10):
  /// overlay shows immediately for visual feedback, then prewarm, then
  /// dispatch `.toggleRecording`, then the issue #445 post-condition
  /// guard.
  func start() async -> RecordingStartOutcome {
    await start(preAdmitted: nil)
  }

  /// Whether the press that waited for `admission` was ended during its start-up (a release,
  /// Stop, cancel, second toggle, newer press or quit). Always false for a press that never
  /// waited: those keep their existing `lastUserStopAccess` checks only.
  private func endedDuringStartUp(_ admission: PendingDictationRequests.Admission?) -> Bool {
    guard let admission else { return false }
    return !pendingRequests.isStillStarting(admission.ticket)
  }

  /// `start()`'s body. `preAdmitted` is the engine token a waited-for turn granted (#3973 C1):
  /// the press runs again from the top so every engine fact (backend, driver, readiness) and
  /// every start gate is read fresh after the wait, and only the claim is skipped. This call
  /// owns `preAdmitted` from entry and releases it on every path that mints nothing.
  private func start(preAdmitted: PendingDictationRequests.Admission?) async
    -> RecordingStartOutcome
  {
    // Handed to `DictationLifecycleCoordinator` at the moment a session is
    // minted, and released here on every path that mints nothing. `defer` reads
    // this variable's FINAL value, so the single assignment at the hand-off
    // covers every early return between here and there, however many get added
    // later — which is why the release is not repeated at each one.
    var unmintedEngineToken: EngineLease.Token? = preAdmitted?.token
    // #3973 C1: whether this call dispatched the recording start (the session owns the turn).
    var dispatchedStart = false
    defer {
      if let preAdmitted {
        pendingRequests.finishStarting(preAdmitted.ticket, minted: dispatchedStart)
      }
      if let unmintedEngineToken { engineAdmission.release(unmintedEngineToken) }
    }
    dictationLifecycleCoordinator?.cancelPendingWarning()
    let backend = asrManager.activeBackendType
    let isWhisper = backend == .whisper
    let active: KernelDictationDriver = isWhisper ? whisperKernelDriver : kernelDriver
    // PR-7 (#827): snapshot engine readiness BEFORE prewarm so the cold-start
    // log cohorts warm/cold/mid-flight; snapshot-at-entry avoids retro-labeling.
    let readinessAtEntry = (isWhisper ? whisperKernelDriver : kernelDriver).engineReadiness
    if isWhisper {
      guard !whisperKernelDriver.state.isActive else {
        return RecordingStartOutcome.make(
          pipelineActive: true, continuingSessionID: whisperKernelDriver.continuingSessionID)
      }
    } else {
      guard !kernelDriver.state.isActive else {
        return RecordingStartOutcome.make(
          pipelineActive: true, continuingSessionID: kernelDriver.continuingSessionID)
      }
    }
    // #1063 PR2 — recovery hold. While the one leftover recording backfills behind
    // the blocking pill, a record-press mints NO session: show the "recovering"
    // pill (with Discard) and bail, before warming the engine the recovery is
    // using. Takes precedence over the cold-engine gate below (same shape).
    if recovery.isRecovering() {
      handleRecoveryPressRefused(backend: backend)
      return .noRecording
    }
    // #4069 — dictation turned off during meetings: before the microphone ask and the claim.
    if isDictationOffForMeeting() {
      handleDictationOffDuringMeeting()
      return .noRecording
    }
    // #3960 — a microphone macOS never asked about is asked about now, before
    // the engine claim, so the claim is never held across the prompt.
    if askForMicrophoneIfNeeded() { return .noRecording }
    // #2648 — the shared ASR-and-polish resource. Claimed HERE, before any
    // engine work: a refusal must reach the user as a pill at press time, not
    // after a pre-warm they cannot see the point of. Recovery is refused in an
    // earlier gate, so a claim that fails here belongs to another workload.
    // #3973 C1: a meeting holding it is the exception: dictation has priority, so the press
    // waits for the meeting's turn to end and then runs again from the top with that token.
    if unmintedEngineToken == nil {
      // Quit closed dictation admission: a free engine does not let a press through either.
      if pendingRequests.isClosed { return .noRecording }
      switch engineAdmission.claim() {
      case .granted(let token):
        unmintedEngineToken = token
      case .refused(by: .meeting):
        guard let admission = await pendingRequests.waitForTurn() else {
          return .noRecording
        }
        return await start(preAdmitted: admission)
      case .refused(let holder):
        handleSharedEngineBusyPressRefused(holder: holder)
        return .noRecording
      }
    }
    // #1171 — start-of-recording safety: never record on an engine other than the
    // one the user selected (a switch deferred while busy/recovering may not have
    // applied yet). Show the reactive #879 pill for the selected engine and bail;
    // the user re-presses on the now-correct engine. Recovery precedence above.
    if reconcileSelectedBackendIfNeeded() { return .noRecording }
    // #1386 PR-2c (founder): a press while the selected model is REMOVED or
    // mid-removal mints nothing and shows the honest not-installed pill. One
    // gate, before any readiness/warm logic — a removal's first instants can
    // still read "ready", so the readiness path alone cannot cover this.
    guard isSelectedModelInstalled() else {
      recordingOverlay.present(
        .warning(reason: .modelNotDownloaded(engineLabel: active.engineDisplayName)))
      TelemetryService.shared.coldStartPressBlocked(
        asrBackend: backend.rawValue, warmupInFlight: false,
        model: active.requestedModelAttribution)
      return .noRecording
    }
    lastRecordingResult?.polishError = nil
    // #879 — cold-boot press safety. A press on a not-ready engine must NOT mint
    // a recording session (no audio captured → none discarded). Hand off to the
    // cold-press policy (pill + warm-up + READY announce) and bail; the user
    // re-presses after "Ready" and that re-press runs the full warm path below.
    // Placed after the polish-error reset (cleared on every entry), before the
    // AX-refresh / overlay / prewarm block.
    if readinessAtEntry != .ready {
      ColdPressGuard.handle(
        overlay: recordingOverlay, active: active,
        backendTag: backend.rawValue, readiness: readinessAtEntry)
      return .noRecording
    }
    // #1171 — committed to minting on `active` (selected == active confirmed above,
    // no switch in flight). Hold the start-window state-gate so the coordinator
    // cannot switch the engine out from under us across the preWarm / recovery-arm
    // awaits; released on every exit. This REPLACES the old re-check-after-await
    // guards (which could never fully close the check→act window).
    beginMinting()
    defer { endMinting() }
    accessibilityRefresh()
    recordingOverlay.present(
      .recording(
        RecordingPillInput(
          audioLevel: 0,
          audioLevelProvider: { [audioCapture] in audioCapture.audioLevel },
          // #1393: this is the FIRST `.recording` push (fires before
          // `DictationLifecycleCoordinator` sees any state change), so it must
          // carry the real provider itself — a later duplicate morphs the SAME
          // presentation, so whatever is installed here is what renders for the
          // whole recording.
          recordingElapsedProvider: { [weak active] in active?.recordingElapsedSeconds },
          isLocked: false)))
    let pttStart = ContinuousClock.now
    do {
      try await active.handle(event: .preWarm)
    } catch is CancellationError {
      audioCapture.abortPreWarm()
      recordingOverlay.dismissCurrent(.announced)
      recordingLockedAccess.set(false)
      return .noRecording
    } catch {
      audioCapture.abortPreWarm()
      recordingOverlay.dismissCurrent(.announced)
      recordingLockedAccess.set(false)
      SentryBreadcrumb.add(
        stage: "recording", message: "preWarm failed — start aborted",
        level: .warning, data: ["error": String(describing: error)]
      )
      // #1558: emit a TYPED reason (presenter authors the sentence). A denied
      // mic is the real, user-actionable cause of a prewarm failure regardless
      // of the thrown error's wording, so it is checked FIRST; only then fall
      // back to no-device vs generic capture failure.
      let reason: TerminalNoticeReason
      if micPermissionDenied() {
        reason = .permissionDenied
      } else {
        let nsError = error as NSError
        let noMic =
          nsError.domain == AudioError.errorDomain
          && nsError.code == AudioError.noBuiltInMicrophoneFound.errorCode
        reason = noMic ? .noMicrophoneFound : .micWouldNotOpen
      }
      active.setTerminalReason(reason)
      return .noRecording
    }
    guard !Task.isCancelled else {
      audioCapture.abortPreWarm()
      recordingOverlay.dismissCurrent(.announced)
      recordingLockedAccess.set(false)
      return .noRecording
    }
    // PTT key-up that fired while `preWarm()` was awaiting did not reach
    // the kernel via `requestStop` — `RecordingSessionKernel.requestStop`
    // ignores `.idle` (sessionless pre-warm leaves the kernel idle), so
    // dispatching `.toggleRecording` here would start a recording even
    // though the user had already released. Mirror the post-toggle
    // `userStoppedDuringStart` guard at lines 162-165 so the start path
    // bails out cleanly. (Codex final-review P1 on the cutover.)
    let userStoppedDuringPreWarm: Bool = {
      guard let lastStop = lastUserStopAccess.read() else { return false }
      return lastStop > pttStart
    }()
    if userStoppedDuringPreWarm || endedDuringStartUp(preAdmitted) {
      audioCapture.abortPreWarm()
      recordingOverlay.dismissCurrent(.announced)
      recordingLockedAccess.set(false)
      return .noRecording
    }
    let preWarmMs = Self.elapsedMs(since: pttStart)
    do {
      let config = await makeSessionConfig(triggerSource: .pttHotkey, armRecovery: true)
      // #1063 PR1: the recovery-arm await widened the pre-session window. If PTT
      // was released during it, `requestStop` hit the idle kernel and was ignored
      // — bail before minting a session so a quick release can't leave a recording
      // running (Codex code-diff P1). `preWarm` already started the engine, so
      // tear it down exactly like the pre-warm-release guard above does (Codex
      // code-diff r2 P2) — a bare hide/unlock would leave the mic engine running.
      // The key armed above is cleaned inline below; the launch recovery scan's
      // orphan-key sweep is only the backstop if this process dies first.
      // #3973 C1: a press that waited for its turn also ends here when the user ended it
      // during start-up, or a newer press cancelled its task.
      let releasedDuringArm = lastUserStopAccess.read().map { $0 > pttStart } ?? false
      if releasedDuringArm || endedDuringStartUp(preAdmitted) {
        audioCapture.abortPreWarm()
        // A key was armed for this take but no session will start — no terminal
        // pipeline state fires, so clean the orphan spool/key here (Codex r3).
        // Pre-start abort is always a discard (#1063 PR2: pass this take's id).
        recovery.cleanupArm(config.recoverySessionID)
        recordingOverlay.dismissCurrent(.announced)
        recordingLockedAccess.set(false)
        return .noRecording
      }
      // #1063 PR2 (Codex code-diff r2 P2): the top-of-`start()` recovery gate can
      // go STALE across the `preWarm` + recovery-arm awaits — launch recovery may
      // have started in that window. Re-check before minting a session so a new
      // recording can't contend with the recovery replay on the shared engine;
      // tear down the engine + clean the just-armed id, exactly like the guards
      // above.
      if recovery.isRecovering() {
        audioCapture.abortPreWarm()
        recovery.cleanupArm(config.recoverySessionID)
        handleRecoveryPressRefused(backend: backend)
        recordingLockedAccess.set(false)
        return .noRecording
      }
      // #1171 — no engine-changed re-check here: the `beginMinting()` state-gate
      // (held since before preWarm) guarantees the coordinator did NOT switch the
      // active engine across these awaits, so `active` is still the user's choice.
      try await active.handle(event: .toggleRecording(config))
      dispatchedStart = true
      // The session is minted, so the claim now belongs to the session rather
      // than to this call. Both start methods RETURN while the recording is
      // still running, so releasing on the way out would admit an import into
      // the middle of a live dictation; the lifecycle coordinator releases it on
      // the session's single terminal path, after ASR and polish.
      //
      // A nil coordinator is a FAULT, not a quiet case: nothing would ever
      // drive this session to a terminal, so nothing would hand the claim back
      // and every later press would be refused for a dictation that had already
      // ended. Leaving the token in `unmintedEngineToken` makes the `defer`
      // release it on the way out, which costs this session's exclusivity and
      // keeps the record button working — the right way round for a limb.
      if let coordinator = dictationLifecycleCoordinator, let engineToken = unmintedEngineToken {
        coordinator.acceptEngineToken(engineToken, mintedBy: isWhisper ? .whisper : .parakeet)
        unmintedEngineToken = nil
      } else {
        Self.reportNilCollaborator(callback: "acceptEngineToken")
      }
    } catch {
      heartControlRecovery.recover(
        error: error, op: "toggle-from-prewarm",
        reason: .modelWedged,
        setTerminalReason: active.setTerminalReason)
      return .noRecording
    }
    let totalMs = Self.elapsedMs(since: pttStart)
    let pipelineActive = active.state.isActive
    // #1925: was `pipelineInError`, matching only `.error`. A concluded
    // `.advisory` (and any other quietly-concluded outcome) is just as much
    // "something happened" as an error is, and the old check treated it like
    // silence — letting this postcondition stamp a wedge over an already-
    // correct message. `hasTerminalResult` answers the real question
    // directly instead of enumerating recognized cases.
    let pipelineConcluded = active.hasTerminalResult
    let userStoppedDuringStart: Bool = {
      guard let lastStop = lastUserStopAccess.read() else { return false }
      return lastStop > pttStart
    }()
    if Self.shouldStampPostConditionWedge(
      pipelineActive: pipelineActive, hasTerminalResult: pipelineConcluded,
      userStoppedDuringStart: userStoppedDuringStart)
    {
      SentryBreadcrumb.captureError(
        ModelLoadWatchdog.WedgeError(stage: "post_condition"),
        category: .pipelinePostConditionFailed, stage: "recording",
        extra: ["backend": backend.rawValue]
      )
      recordingOverlay.dismissCurrent(.announced)
      recordingLockedAccess.set(false)
      active.setTerminalReason(.modelWedged)
      return .noRecording
    }
    if !pipelineActive && !pipelineConcluded && userStoppedDuringStart {
      recordingOverlay.dismissCurrent(.announced)
      recordingLockedAccess.set(false)
      return .noRecording
    }
    // GitHub cloud review, PR #1732: consume the pending blocked-press info
    // (and emit `recovery.press_unblocked`) only NOW, after both post-
    // condition early-returns above have been survived — a genuine session
    // (active or a real pipeline result, not a silent wedge or a user-stop-
    // during-arm no-op) actually started. Firing this before `handle(event:)`
    // let a throw or an unactivated session get counted as "unblocked".
    consumePendingBlockedPressIfAny()
    Task {
      await AppLogger.shared.log(
        "COLD-START [RecordingStarter] PTT-to-recording: total=\(totalMs)ms preWarm=\(preWarmMs)ms startRecording=\(totalMs - preWarmMs)ms backend=\(backend.rawValue) engineReadinessAtPTT=\(readinessAtEntry.coldStartCohortToken)",
        level: .info, category: "Pipeline"
      )
    }
    // #1631: report what the hotkey needs — a session that is genuinely
    // continuing, and its id. `pipelineConcluded` is deliberately NOT treated
    // as a session here: a concluded pipeline (error, advisory, or any other
    // real ending) is not a live recording and must not keep hands-free
    // bookkeeping alive. The id also comes back nil when an exit is already
    // latched, which `state` alone cannot express.
    return RecordingStartOutcome.make(
      pipelineActive: pipelineActive, continuingSessionID: active.continuingSessionID)
  }

  /// #1925: the postcondition's actual decision, extracted as a pure function
  /// so it is directly testable without constructing a live driver/kernel.
  /// `pipelineActive` and `hasTerminalResult` are independent facts (a
  /// session can be neither, briefly, between conclusion and reset) —
  /// stamping a wedge is correct only when NEITHER holds AND the user did not
  /// stop it themselves.
  nonisolated static func shouldStampPostConditionWedge(
    pipelineActive: Bool,
    hasTerminalResult: Bool,
    userStoppedDuringStart: Bool
  ) -> Bool {
    !pipelineActive && !hasTerminalResult && !userStoppedDuringStart
  }

  /// UI/menu toggle path (no prewarm). Mirrors the former root-state file
  /// (pre-PR10). When this toggle initiates a START (active idle), clear
  /// the prior polish error and refresh AX status so the session config
  /// snapshot picks up the right paste capability.
  func toggle(source: TriggerSource) async {
    // #3973 C1: a toggle while a press waits for its engine turn ends that wait. It is the
    // user's second press of the same control, so it means "stop", not another start.
    // Only while nothing records yet: once a session is running, the toggle is its ordinary stop.
    if !activeDriver.state.isActive, pendingRequests.cancelPending() { return }
    await toggle(source: source, preAdmitted: nil)
  }

  /// `toggle(source:)`'s body; `preAdmitted` as in `start(preAdmitted:)`.
  private func toggle(
    source: TriggerSource, preAdmitted: PendingDictationRequests.Admission?
  ) async {
    // #2648 — held from the claim below until either the mint hands it to the
    // lifecycle coordinator or this call ends without minting. Declared out here
    // because the claim happens inside the start-only gate block and the release
    // has to cover every exit after it.
    var claimedEngineToken: EngineLease.Token? = preAdmitted?.token
    // #3973 C1: whether this call dispatched the recording start (the session owns the turn).
    var dispatchedStart = false
    defer {
      if let preAdmitted {
        pendingRequests.finishStarting(preAdmitted.ticket, minted: dispatchedStart)
      }
      if let claimedEngineToken { engineAdmission.release(claimedEngineToken) }
    }
    dictationLifecycleCoordinator?.cancelPendingWarning()
    let backend = asrManager.activeBackendType
    let isWK = backend == .whisper
    let active: KernelDictationDriver = isWK ? whisperKernelDriver : kernelDriver
    let isStartingFromIdle =
      !(isWK ? whisperKernelDriver.state.isActive : kernelDriver.state.isActive)
    // A waited-for turn was a START; it never becomes a stop of some other session.
    if preAdmitted != nil, !isStartingFromIdle { return }
    if isStartingFromIdle {
      // #1063 PR2 — recovery hold, same as the PTT path. A toggle that would START
      // while recovery holds the engine mints no session: show the pill and bail.
      // A toggle that STOPS an active session is unaffected (guarded by
      // `isStartingFromIdle`).
      if recovery.isRecovering() {
        handleRecoveryPressRefused(backend: backend)
        return
      }
      // #4069 — same meeting gate as the PTT path, in the same position. A STOP toggle never
      // reaches here (guarded by `isStartingFromIdle`).
      if isDictationOffForMeeting() {
        handleDictationOffDuringMeeting()
        return
      }
      // #3960 — same microphone ask as the PTT path, in the same position.
      if askForMicrophoneIfNeeded() { return }
      // #2648 — the shared-resource claim, same as the PTT path and in the same
      // position: after recovery, before any engine work. A STOP toggle never
      // reaches here (guarded by `isStartingFromIdle`), so stopping a recording
      // is never refused.
      // #3973 C1: same meeting wait as the PTT path; the toggle then runs again from the top.
      if claimedEngineToken == nil {
        // Quit closed dictation admission: a free engine does not let a toggle start through.
        if pendingRequests.isClosed { return }
        switch engineAdmission.claim() {
        case .granted(let token):
          claimedEngineToken = token
        case .refused(by: .meeting):
          guard let admission = await pendingRequests.waitForTurn() else { return }
          await toggle(source: source, preAdmitted: admission)
          return
        case .refused(let holder):
          handleSharedEngineBusyPressRefused(holder: holder)
          return
        }
      }
      // #1171 — start-of-recording safety, same as the PTT path: never record on
      // an engine other than the one the user selected; show the reactive pill for
      // the selected engine and bail. Recovery precedence above.
      if reconcileSelectedBackendIfNeeded() { return }
      lastRecordingResult?.polishError = nil
      // #879 — same cold-boot press safety as the PTT path. A toggle press that
      // would START on a not-ready engine shows the pill + warms instead of
      // minting a session (the toggle-hotkey is a user press too). A toggle that
      // STOPS an active session is unaffected (guarded by `isStartingFromIdle`).
      // #1386 PR-2c (founder): same removal/not-installed gate as the PTT path.
      guard isSelectedModelInstalled() else {
        recordingOverlay.present(
          .warning(reason: .modelNotDownloaded(engineLabel: active.engineDisplayName)))
        TelemetryService.shared.coldStartPressBlocked(
          asrBackend: backend.rawValue, warmupInFlight: false,
          model: active.requestedModelAttribution)
        return
      }
      if active.engineReadiness != .ready {
        // #879 — same cold-boot press safety as the PTT path.
        ColdPressGuard.handle(
          overlay: recordingOverlay, active: active,
          backendTag: backend.rawValue, readiness: active.engineReadiness)
        return
      }
    }
    // #1171 — committed to a START on `active` (selected == active confirmed in the
    // gates above). Hold the start-window state-gate so the coordinator can't switch
    // the engine out across the recovery-arm await; released on every exit. Only for
    // a START (a STOP toggle never minted). Replaces the old re-check-after-await.
    if isStartingFromIdle { beginMinting() }
    defer { if isStartingFromIdle { endMinting() } }
    accessibilityRefresh()
    let toggleStart = ContinuousClock.now
    do {
      // #1063 PR1: arm recovery ONLY when this toggle STARTS a recording. A stop
      // toggle reaches here too, but the kernel ignores the config — arming there
      // would orphan a key (Codex code-diff P2).
      let config = await makeSessionConfig(
        triggerSource: source, armRecovery: isStartingFromIdle)
      // #1063 PR1 (Codex r3 P1): the recovery-arm await (when armRecovery)
      // suspended this start path. If the user cancelled, OR a concurrent toggle
      // started the kernel during that window, do NOT start a fresh recording —
      // `.toggleRecording` is DROPPED in the transient `.preparing/.warmingUp`
      // states (KernelDictationDriver:644-646), so the user's stop would be lost.
      // Re-dispatch as `.requestStop` (it LATCHES in those states), and clean the
      // key armed here (a never-started or immediately-discarded session emits no
      // terminal state for the lifecycle coordinator's cleanup to observe).
      if isStartingFromIdle {
        // #3973 C1: the same for a toggle that waited and was ended during its start-up.
        let stoppedDuringArm = lastUserStopAccess.read().map { $0 > toggleStart } ?? false
        if stoppedDuringArm || endedDuringStartUp(preAdmitted) {
          recovery.cleanupArm(config.recoverySessionID)
          return
        }
        if active.state.isActive {
          recovery.cleanupArm(config.recoverySessionID)
          try await active.handle(event: .requestStop)
          return
        }
        // #1063 PR2 (Codex code-diff r2 P2): re-check after the recovery-arm await
        // — launch recovery may have started in that window. Bail before minting a
        // session so it can't contend with the recovery replay; clean the just-
        // armed id.
        if recovery.isRecovering() {
          recovery.cleanupArm(config.recoverySessionID)
          handleRecoveryPressRefused(backend: backend)
          return
        }
        // #1171 — no engine-changed re-check here: the `beginMinting()` state-gate
        // (held since before the recovery-arm await) guarantees the coordinator did
        // NOT switch the active engine, so `active` is still the user's choice.
      }
      try await active.handle(event: .toggleRecording(config))
      dispatchedStart = true
      // Minted, so the claim belongs to the session now — same hand-off as the
      // PTT path, for the same reason: this method returns while the recording
      // is still running.
      // Same hand-off, same nil-coordinator fault handling as the PTT path: the
      // claim is only cleared here when somebody real took ownership of it.
      if let token = claimedEngineToken {
        if let coordinator = dictationLifecycleCoordinator {
          coordinator.acceptEngineToken(token, mintedBy: isWK ? .whisper : .parakeet)
          claimedEngineToken = nil
        } else {
          Self.reportNilCollaborator(callback: "acceptEngineToken")
        }
      }
      // GitHub cloud review, PR #1732: consume the pending blocked-press info
      // (and emit `recovery.press_unblocked`) only after `handle(event:)`
      // returned WITHOUT throwing AND the pipeline is genuinely active — a
      // throw, or a dispatch that silently didn't activate anything, must not
      // be counted as "unblocked". Toggle has no separate post-condition
      // check the way `start()` does, so read `active.state.isActive` here.
      if isStartingFromIdle && active.state.isActive {
        consumePendingBlockedPressIfAny()
      }
    } catch {
      heartControlRecovery.recover(
        error: error, op: "toggle",
        reason: .modelWedged,
        setTerminalReason: active.setTerminalReason)
    }
  }

  /// #1171 — start-of-recording safety check. If the active engine isn't the one
  /// the user selected (a switch deferred while busy/recovering hasn't applied
  /// yet) OR a switch is in flight, hand off to
  /// `ColdPressGuard.reconcileSelectedBackend` (reactive pill for the selected
  /// engine + coordinator-driven swap + warm) and mint NO session. Returns true
  /// when it handled the mismatch/in-flight switch (the caller must `return`).
  private func reconcileSelectedBackendIfNeeded() -> Bool {
    let selected = settings.selectedBackend
    guard asrManager.activeBackendType != selected || isEngineSwitching() else { return false }
    if selected == .parakeet, let isActivating = isActivatingParakeetUpgrade, isActivating() {
      ColdPressGuard.reconcileParakeetUpgrade(
        overlay: recordingOverlay, model: kernelDriver.requestedModelAttribution,
        isActivating: isActivating,
        ensureSelectedReady: ensureSelectedReadyForPress)
      return true
    }
    ColdPressGuard.reconcileSelectedBackend(
      overlay: recordingOverlay,
      selectedDriver: selected == .whisper ? whisperKernelDriver : kernelDriver,
      ensureSelectedReady: ensureSelectedReadyForPress)
    return true
  }

  /// Build the per-recording config, arming crash recovery first when this is a
  /// START (`armRecovery`). Arming has side effects — it mints + DURABLY stores a
  /// per-session key — so it must NOT run on a stop toggle (the kernel ignores the
  /// config there; an armed key would orphan with no spool, Codex code-diff P2).
  /// The directive is nil unless recovery is on, so the heart path is unchanged.
  /// Reads the active engine's LID CAPABILITY (not an identity literal).
  /// (#1063 PR1.)
  private func makeSessionConfig(triggerSource: TriggerSource, armRecovery: Bool) async
    -> DictationSessionConfig
  {
    let recovery =
      armRecovery
      ? await recovery.makeDirective(
        settings, asrManager.activeBackendType, activeDriver.supportsLanguageDetection)
      : nil
    return DictationSessionConfigFactory.make(
      asrManager: asrManager,
      kernelDriver: kernelDriver,
      whisperKernelDriver: whisperKernelDriver,
      settings: settings,
      triggerSource: triggerSource,
      recoverySessionID: recovery?.recoverySessionID,
      recoveryPayload: recovery?.payload)
  }

  private static func elapsedMs(since instant: ContinuousClock.Instant) -> Int {
    let (s, a) = (ContinuousClock.now - instant).components
    return Int(s) * 1000 + Int(a / 1_000_000_000_000_000)
  }
}
