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
  let whisperKitKernelDriver: KernelDictationDriver
  let settings: SettingsManager
  let recordingOverlay: RecordingOverlayPanel
  /// #904 test seam — the accessibility re-arm step `start()`/`toggle()` run.
  /// Default (bound in init capturing `permissions`, since a default arg can't
  /// reference an init param) is today's block; a test injects a counting spy.
  let accessibilityRefresh: @MainActor () -> Void

  /// #1558 — narrow live mic-permission check the prewarm error router reads so a
  /// denied-permission start surfaces "Microphone access is off." Bound in init.
  let micPermissionDenied: @MainActor () -> Bool

  /// Arms the crash-recovery limb for a recording about to start, returning the
  /// durable session id + opaque directive payload (nil when recovery is off or
  /// could not arm). A bare closure so it stays off this start-path home's
  /// collaborator count; `DictationRuntime` binds it to `RecoveryCoordinator`.
  /// Default is a no-op (recovery off) so test/legacy construction is unchanged.
  /// (#1063 PR1.)
  let makeRecoveryDirective:
    @MainActor (SettingsManager, ASRBackendType, Bool) async -> (
      recoverySessionID: String, payload: Data
    )?

  /// Cleans up a recovery key/spool armed for a start that never produced a
  /// recording — a PTT release or a concurrent-toggle stop landing in the arm
  /// window. Those paths mint no kernel session, so no terminal pipeline state
  /// fires to drive the lifecycle coordinator's cleanup; the start path must
  /// trigger it directly, passing the id armed for this start (nil ⇒ recovery was
  /// off — no-op). A pre-start abort is always a DISCARD. Bare closure (off the
  /// collaborator cap); bound to `RecoveryCoordinator
  /// .handleRecordingEndedWithoutDurableSave(recoverySessionID:terminal:)`.
  /// (#1063 PR1, Codex r3; id+terminal in PR2.)
  let cleanupRecoveryArm: @MainActor (String?) -> Void

  /// Whether the crash-recovery limb is replaying a leftover recording behind the
  /// blocking pill (#1063 PR2). A record-press while true mints NO session — the
  /// gate shows the "recovering" pill and returns, exactly like the cold-engine
  /// not-ready gate. Bare closure (off the collaborator cap); bound to
  /// `RecoveryCoordinator.isRecovering`. Default `false` keeps recovery-off and
  /// legacy/test construction unchanged.
  let isRecovering: @MainActor () -> Bool

  /// #1707 Phase 3 (§3.1) — set on every recovery-refusal read site so a
  /// multi-item recovery scan yields the engine BETWEEN items instead of only
  /// after the whole scan. Bare closure (off the collaborator cap); bound to
  /// `RecoveryCoordinator.pendingLiveStartSignal = true`. Default no-op keeps
  /// recovery-off and legacy/test construction unchanged.
  let signalPendingLiveStart: @MainActor () -> Void

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
    if asrManager.activeBackendType == .whisperKit {
      let state = whisperKitKernelDriver.state
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
    asrManager.activeBackendType == .whisperKit ? whisperKitKernelDriver : kernelDriver
  }

  /// #1707 Phase 3 — the backend + timestamp of the most recent recovery
  /// refusal. Consumed (and cleared) ONLY by a LATER press that actually
  /// mints an active kernel session — a failed or unrelated press never
  /// consumes it, so it can't misattribute one recording's wait to a
  /// different one's timing.
  private var pendingBlockedPressInfo: (backend: String, blockedAt: ContinuousClock.Instant)?

  /// Every recovery-refusal read site funnels through here: shows the pill,
  /// signals the scan to yield the engine (§3.1), records the blocked-press
  /// timestamp for the pairing `recovery.press_unblocked` telemetry below, and
  /// emits the existing `recovery.press_blocked` event.
  private func handleRecoveryPressRefused(backend: ASRBackendType) {
    recordingOverlay.show(intent: .recoveringLastRecording)
    signalPendingLiveStart()
    pendingBlockedPressInfo = (backend.rawValue, ContinuousClock.now)
    TelemetryService.shared.recoveryPressBlocked(asrBackend: backend.rawValue)
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
    whisperKitKernelDriver: KernelDictationDriver,
    settings: SettingsManager,
    permissions: PermissionsService,
    recordingOverlay: RecordingOverlayPanel,
    heartControlRecovery: HeartControlRecovery,
    recordingLockedAccess: DictationLifecycleCoordinator.RecordingLockedAccess,
    lastUserStopAccess: RecordingFinalizer.LastUserStopAccess,
    lastRecordingResult: LastRecordingResult,
    dictationLifecycleCoordinator: DictationLifecycleCoordinator?,
    accessibilityRefresh: (@MainActor () -> Void)? = nil,
    makeRecoveryDirective: @escaping @MainActor (SettingsManager, ASRBackendType, Bool) async -> (
      recoverySessionID: String, payload: Data
    )? = { _, _, _ in nil },
    cleanupRecoveryArm: @escaping @MainActor (String?) -> Void = { _ in },
    isRecovering: @escaping @MainActor () -> Bool = { false },
    signalPendingLiveStart: @escaping @MainActor () -> Void = {},
    ensureSelectedReadyForPress: @escaping @MainActor () async -> EngineCoordinator.PressReadiness =
      {
        .notReady
      },
    isEngineSwitching: @escaping @MainActor () -> Bool = { false },
    beginMinting: @escaping @MainActor () -> Void = {},
    endMinting: @escaping @MainActor () -> Void = {}
  ) {
    self.makeRecoveryDirective = makeRecoveryDirective
    self.cleanupRecoveryArm = cleanupRecoveryArm
    self.isRecovering = isRecovering
    self.signalPendingLiveStart = signalPendingLiveStart
    self.ensureSelectedReadyForPress = ensureSelectedReadyForPress
    self.isEngineSwitching = isEngineSwitching
    self.beginMinting = beginMinting
    self.endMinting = endMinting
    self.audioCapture = audioCapture
    self.asrManager = asrManager
    self.kernelDriver = kernelDriver
    self.whisperKitKernelDriver = whisperKitKernelDriver
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
  }

  /// Hotkey PTT start path. Mirrors the former root-state file (pre-PR10):
  /// overlay shows immediately for visual feedback, then prewarm, then
  /// dispatch `.toggleRecording`, then the issue #445 post-condition
  /// guard.
  func start() async {
    dictationLifecycleCoordinator?.cancelPendingWarning()
    let backend = asrManager.activeBackendType
    let isWhisperKit = backend == .whisperKit
    let active: KernelDictationDriver = isWhisperKit ? whisperKitKernelDriver : kernelDriver
    // PR-7 (#827): snapshot engine readiness BEFORE prewarm so the cold-start
    // log cohorts warm/cold/mid-flight; snapshot-at-entry avoids retro-labeling.
    let readinessAtEntry = (isWhisperKit ? whisperKitKernelDriver : kernelDriver).engineReadiness
    if isWhisperKit {
      guard !whisperKitKernelDriver.state.isActive else { return }
    } else {
      guard !kernelDriver.state.isActive else { return }
    }
    // #1063 PR2 — recovery hold. While the one leftover recording backfills behind
    // the blocking pill, a record-press mints NO session: show the "recovering"
    // pill (with Discard) and bail, before warming the engine the recovery is
    // using. Takes precedence over the cold-engine gate below (same shape).
    if isRecovering() {
      handleRecoveryPressRefused(backend: backend)
      return
    }
    // #1171 — start-of-recording safety: never record on an engine other than the
    // one the user selected (a switch deferred while busy/recovering may not have
    // applied yet). Show the reactive #879 pill for the selected engine and bail;
    // the user re-presses on the now-correct engine. Recovery precedence above.
    if reconcileSelectedBackendIfNeeded() { return }
    // #1386 PR-2c (founder): a press while the selected model is REMOVED or
    // mid-removal mints nothing and shows the honest not-installed pill. One
    // gate, before any readiness/warm logic — a removal's first instants can
    // still read "ready", so the readiness path alone cannot cover this.
    guard isSelectedModelInstalled() else {
      recordingOverlay.show(
        intent: .warning(reason: .modelNotDownloaded(engineLabel: active.engineDisplayName)))
      TelemetryService.shared.coldStartPressBlocked(
        asrBackend: backend.rawValue, warmupInFlight: false)
      return
    }
    lastRecordingResult?.polishError = nil
    // #879 — cold-boot press safety. A press on a not-ready engine must NOT mint
    // a recording session (no audio captured → none discarded). Hand off to the
    // cold-press policy (pill + warm-up + READY announce) and bail; the user
    // re-presses after "Ready" and that re-press runs the full warm path below.
    // Placed after the polish-error reset (cleared on every entry), before the
    // AX-refresh / overlay / prewarm block.
    // #959: a not-ready press is EITHER a warm-respawn (idle-reaped warm model,
    // re-warm ~0.2s → fall through and record) OR a genuine cold boot (#879 pill,
    // no session). `resolveNotReadyPress` owns that decision off this type.
    if readinessAtEntry != .ready {
      let warmRespawn = ColdPressGuard.resolveNotReadyPress(
        overlay: recordingOverlay, active: active,
        backendTag: backend.rawValue,
        readiness: readinessAtEntry, modelUnloadPolicy: settings.modelUnloadPolicy)
      if !warmRespawn { return }
    }
    let isWarmRespawn = readinessAtEntry != .ready
    // #1171 — committed to minting on `active` (selected == active confirmed above,
    // no switch in flight). Hold the start-window state-gate so the coordinator
    // cannot switch the engine out from under us across the preWarm / recovery-arm
    // awaits; released on every exit. This REPLACES the old re-check-after-await
    // guards (which could never fully close the check→act window).
    beginMinting()
    defer { endMinting() }
    accessibilityRefresh()
    recordingOverlay.show(
      intent: .recording(audioLevel: 0),
      audioLevelProvider: { [audioCapture] in audioCapture.audioLevel },
      // #1393: this is the FIRST `.recording` overlay push (fires before
      // `DictationLifecycleCoordinator` sees any state change), so it must
      // carry the real provider itself — the panel's identical-intent dedup
      // guard means whatever is passed here is what actually renders for the
      // whole recording if a later push is a no-op duplicate.
      recordingElapsedProvider: { [weak active] in active?.recordingElapsedSeconds },
      isRecordingLocked: false
    )
    let pttStart = ContinuousClock.now
    do {
      try await active.handle(event: .preWarm)
    } catch is CancellationError {
      audioCapture.abortPreWarm()
      recordingOverlay.show(intent: .hidden)
      recordingLockedAccess.set(false)
      return
    } catch {
      audioCapture.abortPreWarm()
      recordingOverlay.show(intent: .hidden)
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
      return
    }
    guard !Task.isCancelled else {
      audioCapture.abortPreWarm()
      recordingOverlay.show(intent: .hidden)
      recordingLockedAccess.set(false)
      return
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
    if userStoppedDuringPreWarm {
      audioCapture.abortPreWarm()
      recordingOverlay.show(intent: .hidden)
      recordingLockedAccess.set(false)
      return
    }
    let preWarmMs = Self.elapsedMs(since: pttStart)
    // #959: set the warm-respawn overlay latch ONLY here — after every pre-toggle
    // abort guard has passed and immediately before the kernel dispatch — so an
    // aborted start never leaves a latch set (which would wrongly morph a later
    // genuine-cold press's overlay). The driver clears it at `.recording`/terminal.
    if isWarmRespawn { active.beginWarmRespawnOverlay() }
    do {
      let config = await makeSessionConfig(triggerSource: .pttHotkey, armRecovery: true)
      // #1063 PR1: the recovery-arm await widened the pre-session window. If PTT
      // was released during it, `requestStop` hit the idle kernel and was ignored
      // — bail before minting a session so a quick release can't leave a recording
      // running (Codex code-diff P1). `preWarm` already started the engine, so
      // tear it down exactly like the pre-warm-release guard above does (Codex
      // code-diff r2 P2) — a bare hide/unlock would leave the mic engine running.
      // Any key armed above is swept by the launch purge's orphan-key pass.
      if let lastStop = lastUserStopAccess.read(), lastStop > pttStart {
        audioCapture.abortPreWarm()
        // A key was armed for this take but no session will start — no terminal
        // pipeline state fires, so clean the orphan spool/key here (Codex r3).
        // Pre-start abort is always a discard (#1063 PR2: pass this take's id).
        cleanupRecoveryArm(config.recoverySessionID)
        recordingOverlay.show(intent: .hidden)
        recordingLockedAccess.set(false)
        return
      }
      // #1063 PR2 (Codex code-diff r2 P2): the top-of-`start()` recovery gate can
      // go STALE across the `preWarm` + recovery-arm awaits — launch recovery may
      // have started in that window. Re-check before minting a session so a new
      // recording can't contend with the recovery replay on the shared engine;
      // tear down the engine + clean the just-armed id, exactly like the guards
      // above.
      if isRecovering() {
        audioCapture.abortPreWarm()
        cleanupRecoveryArm(config.recoverySessionID)
        handleRecoveryPressRefused(backend: backend)
        recordingLockedAccess.set(false)
        return
      }
      // #1171 — no engine-changed re-check here: the `beginMinting()` state-gate
      // (held since before preWarm) guarantees the coordinator did NOT switch the
      // active engine across these awaits, so `active` is still the user's choice.
      consumePendingBlockedPressIfAny()
      try await active.handle(event: .toggleRecording(config))
    } catch {
      heartControlRecovery.recover(
        error: error, op: "toggle-from-prewarm",
        reason: .modelWedged,
        setTerminalReason: active.setTerminalReason)
      return
    }
    let totalMs = Self.elapsedMs(since: pttStart)
    let pipelineActive: Bool
    let pipelineInError: Bool
    if isWhisperKit {
      pipelineActive = whisperKitKernelDriver.state.isActive
      if case .error = whisperKitKernelDriver.state {
        pipelineInError = true
      } else {
        pipelineInError = false
      }
    } else {
      pipelineActive = kernelDriver.state.isActive
      if case .error = kernelDriver.state {
        pipelineInError = true
      } else {
        pipelineInError = false
      }
    }
    let userStoppedDuringStart: Bool = {
      guard let lastStop = lastUserStopAccess.read() else { return false }
      return lastStop > pttStart
    }()
    if !pipelineActive && !pipelineInError && !userStoppedDuringStart {
      SentryBreadcrumb.captureError(
        ModelLoadWatchdog.WedgeError(stage: "post_condition"),
        category: .pipelinePostConditionFailed, stage: "recording",
        extra: ["backend": backend.rawValue]
      )
      recordingOverlay.show(intent: .hidden)
      recordingLockedAccess.set(false)
      active.setTerminalReason(.modelWedged)
      return
    }
    if !pipelineActive && !pipelineInError && userStoppedDuringStart {
      recordingOverlay.show(intent: .hidden)
      recordingLockedAccess.set(false)
      return
    }
    Task {
      await AppLogger.shared.log(
        "COLD-START [RecordingStarter] PTT-to-recording: total=\(totalMs)ms preWarm=\(preWarmMs)ms startRecording=\(totalMs - preWarmMs)ms backend=\(backend.rawValue) engineReadinessAtPTT=\(readinessAtEntry.coldStartCohortToken)",
        level: .info, category: "Pipeline"
      )
    }
  }

  /// UI/menu toggle path (no prewarm). Mirrors the former root-state file
  /// (pre-PR10). When this toggle initiates a START (active idle), clear
  /// the prior polish error and refresh AX status so the session config
  /// snapshot picks up the right paste capability.
  func toggle(source: TriggerSource) async {
    dictationLifecycleCoordinator?.cancelPendingWarning()
    let backend = asrManager.activeBackendType
    let isWK = backend == .whisperKit
    let active: KernelDictationDriver = isWK ? whisperKitKernelDriver : kernelDriver
    let isStartingFromIdle =
      !(isWK ? whisperKitKernelDriver.state.isActive : kernelDriver.state.isActive)
    var isWarmRespawn = false
    if isStartingFromIdle {
      // #1063 PR2 — recovery hold, same as the PTT path. A toggle that would START
      // while recovery holds the engine mints no session: show the pill and bail.
      // A toggle that STOPS an active session is unaffected (guarded by
      // `isStartingFromIdle`).
      if isRecovering() {
        handleRecoveryPressRefused(backend: backend)
        return
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
        recordingOverlay.show(
          intent: .warning(reason: .modelNotDownloaded(engineLabel: active.engineDisplayName)))
        TelemetryService.shared.coldStartPressBlocked(
          asrBackend: backend.rawValue, warmupInFlight: false)
        return
      }
      if active.engineReadiness != .ready {
        // #959: warm-respawn falls through to record; genuine cold keeps the
        // #879 pill. Same decision helper as the PTT path.
        isWarmRespawn = ColdPressGuard.resolveNotReadyPress(
          overlay: recordingOverlay, active: active,
          backendTag: backend.rawValue,
          readiness: active.engineReadiness, modelUnloadPolicy: settings.modelUnloadPolicy)
        if !isWarmRespawn { return }
      }
    }
    // #1171 — committed to a START on `active` (selected == active confirmed in the
    // gates above). Hold the start-window state-gate so the coordinator can't switch
    // the engine out across the recovery-arm await; released on every exit. Only for
    // a START (a STOP toggle never minted). Replaces the old re-check-after-await.
    if isStartingFromIdle { beginMinting() }
    defer { if isStartingFromIdle { endMinting() } }
    accessibilityRefresh()
    // #959: set the overlay latch immediately before the kernel dispatch (toggle
    // has no pre-warm abort path, but keep the set-just-before-dispatch rule).
    if isWarmRespawn { active.beginWarmRespawnOverlay() }
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
        if let lastStop = lastUserStopAccess.read(), lastStop > toggleStart {
          cleanupRecoveryArm(config.recoverySessionID)
          return
        }
        if active.state.isActive {
          cleanupRecoveryArm(config.recoverySessionID)
          try await active.handle(event: .requestStop)
          return
        }
        // #1063 PR2 (Codex code-diff r2 P2): re-check after the recovery-arm await
        // — launch recovery may have started in that window. Bail before minting a
        // session so it can't contend with the recovery replay; clean the just-
        // armed id.
        if isRecovering() {
          cleanupRecoveryArm(config.recoverySessionID)
          handleRecoveryPressRefused(backend: backend)
          return
        }
        // #1171 — no engine-changed re-check here: the `beginMinting()` state-gate
        // (held since before the recovery-arm await) guarantees the coordinator did
        // NOT switch the active engine, so `active` is still the user's choice.
        consumePendingBlockedPressIfAny()
      }
      try await active.handle(event: .toggleRecording(config))
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
    ColdPressGuard.reconcileSelectedBackend(
      overlay: recordingOverlay,
      selectedDriver: selected == .whisperKit ? whisperKitKernelDriver : kernelDriver,
      selected: selected,
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
      ? await makeRecoveryDirective(
        settings, asrManager.activeBackendType, activeDriver.supportsLanguageDetection)
      : nil
    return DictationSessionConfigFactory.make(
      asrManager: asrManager,
      kernelDriver: kernelDriver,
      whisperKitKernelDriver: whisperKitKernelDriver,
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
