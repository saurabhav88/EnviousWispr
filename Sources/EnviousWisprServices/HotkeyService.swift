import Carbon.HIToolbox
import Cocoa
import EnviousWisprCore

/// #1631 — what a push-to-talk start attempt produced, reported back to
/// `HotkeyService` so it can reconcile the optimistic bookkeeping it stamped on
/// key-down.
package enum RecordingStartOutcome: Equatable, Sendable {
  /// A session is genuinely continuing when `start()` computes its result,
  /// carrying its opaque id. The id is what later publication compares against —
  /// the outcome alone is a snapshot and cannot be trusted on its own, because
  /// the session can end between this answer and the second tap.
  case recording(String)
  /// The hotkey must clear this attempt's optimistic start and hands-free
  /// bookkeeping. Lifecycle-owned teardown may still be completing; this says
  /// nothing about it.
  case noRecording

  /// The single mapping from "is the pipeline active" plus "is a session still
  /// continuing" to this outcome. Lives on the type it constructs rather than on
  /// the start path, so every `.recording`-capable exit routes through one place
  /// and the mapping is testable as a closed set without racing the kernel.
  ///
  /// A nil id means no session is continuing — which covers both "nothing is
  /// running" and "a session whose exit is already latched" — so an active-looking
  /// pipeline with a latched exit correctly reports `.noRecording`.
  /// `package`, not `public`: the only caller is `RecordingStarter` in this
  /// package, and a `public` factory would widen the shipped surface for nothing.
  package static func make(
    pipelineActive: Bool, continuingSessionID: String?
  ) -> RecordingStartOutcome {
    guard pipelineActive, let continuingSessionID else { return .noRecording }
    return .recording(continuingSessionID)
  }
}

/// #1631 — the outcome of asking the app to publish the hands-free lock.
package enum HandsFreeLockRequestResult: Equatable, Sendable {
  /// Published: shared + overlay lock state have been written.
  case published
  /// The named session is no longer the running one — nothing was written.
  case notLockable
  /// The publication path itself is missing (a nil collaborator). A FAULT, not a
  /// pipeline verdict; kept distinct so telemetry cannot launder it.
  case unavailable
}

/// Manages global hotkey registration for dictation recording control.
///
/// Uses Carbon RegisterEventHotKey for system-wide hotkeys without
/// requiring Accessibility permission.
///
/// For modifier-only hotkeys (e.g., bare Option key), NSEvent global and local
/// monitors for .flagsChanged are used so events fire even when the app is in
/// the background.
@MainActor
@Observable
public final class HotkeyService {
  // MARK: - Hotkey IDs

  private enum HotkeyID: UInt32 {
    case toggle = 1
    case cancel = 3
    /// #2381. Takes 4, not the free slot at 2: that gap is a RETIRED id whose meaning nobody wrote
    /// down, and a stale Carbon registration or an old log line could still carry it.
    case quickAdd = 4

    /// Which role this Carbon registration belongs to. A switch, so a new id must declare one
    /// rather than borrowing a neighbour's telemetry name.
    var role: ShortcutRole {
      switch self {
      case .toggle: .record
      case .cancel: .cancel
      case .quickAdd: .quickAdd
      }
    }
  }

  // MARK: - Carbon State

  private var eventHandlerRef: EventHandlerRef?
  private var toggleHotkeyRef: EventHotKeyRef?
  private var cancelHotkeyRef: EventHotKeyRef?
  private var quickAddHotkeyRef: EventHotKeyRef?

  /// Whether the cancel role is currently armed.
  ///
  /// Not derivable from `cancelHotkeyRef`: a bare-modifier cancel key has no
  /// Carbon registration to hold a ref, so a nil ref means "unarmed" for a chord
  /// and says nothing at all for a modifier. Tracking arming explicitly is what
  /// lets the modifier dispatch path know whether a recording is in flight.
  /// Whether the cancel role is armed. `package private(set)` so #2087's
  /// disarm-on-abandonment can be OBSERVED by a test — the alternative was
  /// asserting on a spy for a call the production code might simply not make.
  package private(set) var isCancelArmed = false

  /// Cancel's armed state at the moment `suspend()` ran, so `resume()` can put a
  /// still-running recording back where it was.
  private var cancelArmedBeforeSuspend = false

  // MARK: - NSEvent Modifier Monitors

  private var globalModifierMonitor: Any?
  private var localModifierMonitor: Any?

  public private(set) var isEnabled = false
  public private(set) var isModifierHeld = false

  /// Tracks the in-flight recording Task so we can cancel zombie Tasks from
  /// previous press/release events before starting new ones. This serializes
  /// recording commands — only one start or stop operation runs at a time.
  private var recordingTask: Task<Void, Never>?

  // MARK: - Hands-Free (Double-Press Lock) State

  /// True when recording is locked into hands-free mode.
  /// When locked, key releases are suppressed and recording continues
  /// until the next key press or cancel.
  public private(set) var isRecordingLocked: Bool = false

  /// Timestamp of the key-down that started the current recording session.
  /// Used for the 500ms double-press detection window.
  private var recordingStartTime: Date? = nil

  /// #1631 — identifies one start attempt, incremented only when a fresh press
  /// stamps a new one, so a late result can prove which press it belongs to.
  ///
  /// Deliberately NOT `stateGeneration`: that is bumped by every unlocked release
  /// too, so a generation captured at press time is already stale in exactly the
  /// press → release → press sequence this fix exists for.
  private var startPressID: UInt64 = 0

  /// #1631 — the press whose start confirmed a continuing session, and that
  /// session's opaque id. Together they gate publication: hands-free intent is
  /// recorded on the second press, but published only once the SAME press's
  /// start has confirmed a session that is still running.
  private var acceptedStartPressID: UInt64?
  private var acceptedSessionID: String?

  /// Debounce timer: on quick PTT release (< 500ms), waits for a possible
  /// second press before stopping. Cancelled on double-press or new recording.
  private var debounceTask: Task<Void, Never>? = nil

  /// Monotonically increasing counter incremented on every state-changing event
  /// (press, release, cleanup). Debounce callbacks compare their captured
  /// generation to the current value — if they differ, the callback is stale
  /// and must not fire. This is the primary guard against Task.isCancelled
  /// races where cancellation hasn't propagated before the closure executes.
  private var stateGeneration: UInt64 = 0

  /// Timestamp when hands-free lock was activated. Used as a cooldown guard:
  /// presses within 500ms of locking are ignored to prevent accidental
  /// finger-bounce from immediately stopping the locked recording.
  private var lockTime: Date? = nil

  // MARK: - Callbacks (wired by the former root state)

  public var onToggleRecording: (@MainActor () async -> Void)?
  /// #1631: returns whether a session is genuinely continuing when the start path
  /// finishes, and if so its id. `HotkeyService` reconciles its own state on that.
  package var onStartRecording: (@MainActor () async -> RecordingStartOutcome)?
  public var onStopRecording: (@MainActor () async -> Void)?
  public var onCancelRecording: (@MainActor () async -> Void)?

  /// #1631 — asks the app to publish the hands-free lock for a SPECIFIC session,
  /// and reports what happened. Replaces the former `onLocked` notification:
  /// publication is now a decision, not an announcement, because a double-press
  /// alone does not prove a recording exists.
  ///
  /// Synchronous on purpose. The old `Task { await onLocked?() }` could run after
  /// cleanup had already happened and publish a lock for a dead attempt; calling
  /// inline closes that window rather than guarding it.
  ///
  /// The `String` is an opaque token, compared for equality only — Services never
  /// interprets it.
  package var onLockRequested: (@MainActor (String) -> HandsFreeLockRequestResult)?

  /// Returns true if the pipeline is in a processing state (transcribing, polishing, etc.).
  /// Used by the processing state gate to block new recordings during processing.
  public var onIsProcessing: (@MainActor () -> Bool)?

  /// Quick Add fired (#2381). Deliberately NOT gated on `onIsProcessing`: it never touches the
  /// recording path, so refusing it mid-transcription would block a limb for a heart-path reason.
  public var onQuickAdd: (@MainActor () async -> Void)?

  // MARK: - Configuration

  public var recordingMode: RecordingMode = .toggle

  /// Toggle-mode hotkey key code (default: Right Option = 61, modifier-only).
  public var toggleKeyCode: UInt16 = ModifierKeyCodes.rightOption

  /// Toggle-mode required modifiers (default: none — modifier-only hotkey).
  public var toggleModifiers: NSEvent.ModifierFlags = []

  /// Key code for the cancel hotkey. Default: Escape (53).
  public var cancelKeyCode: UInt16 = 53

  /// Required modifiers for cancel hotkey. Default: none (bare Escape).
  public var cancelModifiers: NSEvent.ModifierFlags = []

  /// Key code for the Quick Add hotkey (#2381). The shipped value, read from its one owner.
  public var quickAddKeyCode: UInt16 = ShortcutRole.quickAdd.defaultKeyCode

  /// Required modifiers for the Quick Add hotkey, read from the same owner.
  public var quickAddModifiers: NSEvent.ModifierFlags = ShortcutRole.quickAdd.defaultModifiers

  // MARK: - Lifecycle

  public private(set) var isSuspended = false

  /// Which modifier-monitor installation the currently installed closures belong to.
  ///
  /// Neither lifecycle flag can identify an installation, because both are LEVEL
  /// signals that return to their permissive value. `stop()` then `start()` —
  /// exactly what `PipelineSettingsSync.reregisterHotkeys()` does when the user
  /// changes their shortcut — puts `isEnabled` back to `true` inside one
  /// main-thread turn, so a press the global monitor queued before that turn is
  /// delivered after both and sees a permissive flag. `suspend()`/`resume()` has
  /// the same shape for `isSuspended`.
  ///
  /// This token changes on every teardown instead, so a delivery stamped by an
  /// earlier installation is refused. A wrapping `UInt64` could collide only
  /// after 2^64 bumps, which is unreachable during a queued event's lifetime —
  /// stated as a bound rather than as "never repeats", which is false for a
  /// wrapping counter (#1993 grounded review r1).
  ///
  /// `package private(set)`: tests read the real generation the product stamped;
  /// nothing outside this file can write it.
  ///
  /// PORTED, NOT INVENTED — and the closest precedent carries the same name.
  /// `CaptureVADSignalSource.monitorGeneration` (#1780) solves the identical
  /// problem for the VAD monitor task, bumped from its single cancellation site
  /// (`invalidateMonitor()`) and compared before every emit; its comment makes
  /// the same argument this one does, that an identity which can be REUSED is
  /// not a staleness guard. `OllamaSetupService.pullEpoch` / `hostedAddEpoch`
  /// are the same shape again. Non-trapping `&+=` follows those two rather than
  /// `CaptureVADSignalSource`'s `+= 1`, since wrapping is defined behaviour and
  /// a trap in a teardown path would be worse than a collision that cannot occur.
  package private(set) var monitorGeneration: UInt64 = 0

  // MARK: - Telemetry (Telemetry Bible Phase 6, #1175)

  /// Injected hotkey/input-silence telemetry. Default `.noop` keeps legacy/test
  /// construction inert; the app wires `.live`. HotkeyService reports its own
  /// input facts through this seam — it never reads pipeline state.
  private let telemetry: HotkeyTelemetrySink

  /// The action HotkeyService took with an accepted keydown — derived entirely
  /// from its own state, no pipeline read. `cancel` covers both the Escape
  /// cancel hotkey and a PTT triple-press cancel (told apart by `trigger`).
  private enum PressAction: String {
    case start, toggle, cancel, lock, stop
    case quickAdd = "quick_add"
    case ignoredProcessing = "ignored_processing"
    case ignoredCooldown = "ignored_cooldown"
  }

  /// Which hotkey delivered the press.
  private enum PressTrigger: String {
    case ptt = "ptt_hotkey"
    case toggle = "toggle_hotkey"
    case cancel = "cancel_hotkey"
    case quickAdd = "quick_add_hotkey"
  }

  /// Injected clock for the 500ms double-press window and the lock cooldown.
  /// Defaults to the real clock, so production is unchanged.
  ///
  /// Tests MUST inject: the window is measured in real elapsed time, so a test
  /// that awaits anything between the two presses can be pushed outside the
  /// window by parallel load and silently take the stop or fresh-start branch
  /// instead of the lock branch. That is a genuinely load-dependent test, which
  /// `swift-patterns.md` RULE: tests-no-real-time-scheduling-precision forbids —
  /// found by the independent whole-diff review, which reproduced eight failures
  /// running this suite alongside its siblings while it passed alone.
  private let now: @MainActor () -> Date

  public init(
    telemetry: HotkeyTelemetrySink = .noop,
    now: @escaping @MainActor () -> Date = { Date() }
  ) {
    self.telemetry = telemetry
    self.now = now
  }

  /// Emit `hotkey.pressed` for an accepted keydown. Synchronous + cheap (computes
  /// two strings, invokes the injected closure); the `.live` sink defers the
  /// actual PostHog write off the input turn (heart path). The args ARE the
  /// snapshot — no shared-state re-read.
  private func emitHotkeyPressed(_ action: PressAction, trigger: PressTrigger) {
    let inputMode = recordingMode.rawValue
    // key_shape reflects the TRIGGERING hotkey: the cancel hotkey (Escape, a chord
    // by default) vs the toggle/PTT hotkey (modifier-only by default). The PTT
    // hands-free actions all ride the toggle key. (Codex code-diff #1.)
    // A `switch`, not a ternary (#2381). The old `trigger == .cancel ? cancel : toggle` silently
    // absorbed any new member into the toggle branch, so a Quick Add press would have reported the
    // RECORD key's shape and identity — a telemetry field asserting the wrong subject.
    let keyCode: UInt16 =
      switch trigger {
      case .cancel: cancelKeyCode
      case .quickAdd: quickAddKeyCode
      case .toggle, .ptt: toggleKeyCode
      }
    let keyShape = ModifierKeyCodes.isModifierOnly(keyCode) ? "modifier_only" : "chord"
    // #1987: same key as key_shape, one level finer. `key_shape` cannot separate
    // Globe from Right Option because both are modifier-only. Content-free class,
    // never the key code itself.
    let keyIdentity = HotkeyKeyIdentity.classify(keyCode: keyCode).rawValue
    telemetry.pressed(trigger.rawValue, inputMode, keyShape, keyIdentity, action.rawValue)
  }

  public func start() {
    guard !isEnabled else { return }
    installCarbonEventHandler()
    registerToggleHotkey()
    registerQuickAddHotkey()
    installModifierMonitors()
    // Cancel hotkey is NOT registered here — only during recording
    isEnabled = true
  }

  public func stop() {
    unregisterCancelHotkey()
    unregisterQuickAddHotkey()
    unregisterToggleHotkey()
    removeCarbonEventHandler()
    removeModifierMonitors()
    isEnabled = false
    isModifierHeld = false
    performCleanup()
  }

  /// Temporarily unregister all hotkeys so the recorder can capture key combos.
  public func suspend() {
    guard isEnabled, !isSuspended else { return }
    // Remember whether cancel was armed, because the recorder can be opened
    // while a recording is running and `resume()` must put the user back exactly
    // where they were. Before #1991 resume restored only the record hotkey and
    // the monitors, so opening the shortcut box mid-recording silently disarmed
    // cancel for the rest of that recording.
    //
    // Captured BEFORE and assigned AFTER, because `unregisterCancelHotkey()`
    // deliberately clears the snapshot too — that is what stops the snapshot
    // outliving its recording. Assigning first would have it wipe the value it
    // was just given.
    let wasArmed = isCancelArmed
    unregisterCancelHotkey()
    cancelArmedBeforeSuspend = wasArmed
    unregisterQuickAddHotkey()
    unregisterToggleHotkey()
    removeModifierMonitors()
    isSuspended = true
  }

  /// Re-register hotkeys after the recorder is done.
  public func resume() {
    guard isEnabled, isSuspended else { return }
    isModifierHeld = false
    performCleanup()
    registerToggleHotkey()
    // No armed-state snapshot, unlike cancel: Quick Add is armed whenever the service is, so
    // restoring it is unconditional and there is nothing that could outlive its own recording.
    registerQuickAddHotkey()
    installModifierMonitors()
    isSuspended = false
    if cancelArmedBeforeSuspend { registerCancelHotkey() }
    cancelArmedBeforeSuspend = false
  }

  /// Register the cancel hotkey. Call on `.recording` entry.
  ///
  /// Arms the role for BOTH dispatch mechanisms. A chord goes to Carbon exactly
  /// as before; a bare modifier cannot be registered with Carbon at all, so for
  /// that shape arming is the flag alone and the already-installed `NSEvent`
  /// monitors do the observing. Before #1991 this called `registerHotkey`
  /// unconditionally, so a bare-modifier cancel key was handed to Carbon, failed,
  /// reported a registration failure, and left the user with a key that is
  /// stored, displayed, and inert.
  public func registerCancelHotkey() {
    isCancelArmed = true
    guard cancelBinding.isCarbonRegistrable else { return }
    guard cancelHotkeyRef == nil else { return }
    cancelHotkeyRef = registerHotkey(
      id: HotkeyID.cancel.rawValue,
      keyCode: cancelKeyCode,
      modifiers: carbonModifiers(from: cancelModifiers)
    )
  }

  /// Remove the cancel hotkey. Call whenever recording ends.
  ///
  /// Clears the SUSPENDED snapshot as well as the live flag, because a recording
  /// can end while the shortcut recorder is still open — VAD auto-stop, the
  /// duration cap, or the window's own Cancel button all do it. Without this the
  /// snapshot outlived the recording that justified it, `resume()` re-armed
  /// cancel onto an idle app, and nothing later would disarm it because the
  /// recording that owned it had already finished.
  public func unregisterCancelHotkey() {
    isCancelArmed = false
    cancelArmedBeforeSuspend = false
    if let ref = cancelHotkeyRef {
      UnregisterEventHotKey(ref)
      cancelHotkeyRef = nil
    }
  }

  /// Arm or disarm the cancel hotkey from a single decision (#2087).
  ///
  /// The lifecycle used to call `registerCancelHotkey()` / `unregisterCancelHotkey()`
  /// from six places across two per-backend switches, so "when is cancel armed"
  /// was spread over six sites and could disagree with itself. `CancelAffordancePolicy`
  /// now answers that once and this applies the answer.
  ///
  /// Both underlying calls are already idempotent — `registerCancelHotkey`
  /// returns early when a ref exists, and `unregisterCancelHotkey` no-ops with
  /// none — so repeating the same answer on every transition costs nothing.
  public func setCancelHotkeyEnabled(_ enabled: Bool) {
    if enabled {
      registerCancelHotkey()
    } else {
      unregisterCancelHotkey()
    }
  }

  /// Tear down and re-install every hotkey, preserving cancel's armed state.
  ///
  /// The settings path re-registers by calling `stop()` then `start()`, which is
  /// a full teardown: it disarms cancel, and `start()` deliberately does not
  /// re-arm it because cancel belongs to a recording, not to the service. So
  /// changing the RECORD key while a recording was in flight silently disarmed
  /// that recording's cancel key — the same defect as the recorder path, reached
  /// through a different door.
  package func restartPreservingCancelArming() {
    // `!isSuspended` is load-bearing, not defensive. Changing the RECORD binding
    // is exactly what the shortcut editor does, and the editor suspends first —
    // so while suspended the armed state lives in `cancelArmedBeforeSuspend` and
    // `isCancelArmed` reads false. Restarting here would snapshot that false,
    // and `stop()` would clear the real snapshot on its way through, leaving
    // cancel dead for the rest of the recording. Precisely the bug this whole
    // change exists to fix, reintroduced through the most realistic path of all.
    //
    // Skipping is safe because `resume()` already registers the latest binding
    // and restores arming; there is nothing for a restart to add.
    guard isEnabled, !isSuspended else { return }
    let wasArmed = isCancelArmed
    stop()
    start()
    if wasArmed { registerCancelHotkey() }
  }

  /// Re-apply the cancel binding to whichever mechanism now owns it.
  ///
  /// The cancel key can change while a recording is in flight (the Settings
  /// window is reachable then), and it can change shape — chord to bare modifier
  /// or back — which moves it between Carbon and the monitors. Re-registering
  /// without re-installing the monitors would leave the new shape unobserved, so
  /// both are redone together.
  ///
  /// Safe while idle: it preserves `isCancelArmed`, so this cannot arm a cancel
  /// key for a recording that is not running.
  package func reapplyCancelBinding() {
    guard isEnabled, !isSuspended else { return }
    let wasArmed = isCancelArmed
    unregisterCancelHotkey()
    installModifierMonitors()
    if wasArmed { registerCancelHotkey() }
  }

  /// Reset all hands-free state. Called before every stop/cancel callback
  /// and on service stop/resume.
  private func performCleanup() {
    stateGeneration &+= 1
    isRecordingLocked = false
    recordingStartTime = nil
    lockTime = nil
    // #1631: acceptance must never outlive the attempt that earned it, or a later
    // press could inherit it and publish on a session it never started.
    acceptedStartPressID = nil
    acceptedSessionID = nil
    debounceTask?.cancel()
    debounceTask = nil
  }

  // MARK: - #1631 Start reconciliation and hands-free publication

  /// Why a lock intent did or did not become a published lock. Metadata only.
  private enum LockResolutionReason: String {
    case published
    case startProducedNoRecording = "start_produced_no_recording"
    case notLockableAtPublication = "not_lockable_at_publication"
    case publicationUnavailable = "publication_unavailable"
  }

  private func emitLockResolved(committed: Bool, reason: LockResolutionReason) {
    telemetry.lockResolved(committed, reason.rawValue)
  }

  /// Reconcile a start attempt's outcome with the state stamped optimistically on
  /// key-down. Guarded on press identity AND a live stamp, so a result belonging
  /// to a superseded press — or arriving after any cleanup already ran — is
  /// dropped rather than applied to newer state.
  private func resolveStart(pressID: UInt64, outcome: RecordingStartOutcome) {
    // #1631 test seam — fires on EVERY exit, including the dropped-stale-result
    // guard below, so a test can observe that reconciliation finished rather than
    // guessing from a scheduling turn. A signal fired inside the start callback
    // cannot serve: this method runs AFTER that callback returns.
    defer { onStartResolvedForTesting?() }
    guard pressID == startPressID, recordingStartTime != nil else { return }
    switch outcome {
    case .recording(let sessionID):
      acceptedStartPressID = pressID
      acceptedSessionID = sessionID
      publishLockIfReady()
    case .noRecording:
      // Only a press that already recorded hands-free intent has a decision to
      // report; a refusal landing before the second tap has nothing to resolve.
      if isRecordingLocked {
        emitLockResolved(committed: false, reason: .startProducedNoRecording)
      }
      performCleanup()
    }
  }

  /// Publish the hands-free lock iff this press recorded intent, this press's
  /// start confirmed a session, and that session is STILL the running one.
  ///
  /// The last condition cannot be answered from the stored outcome: `start()`
  /// returns as soon as the kernel is arming, and the session can end — or be
  /// replaced by one a toolbar press started — before the second tap arrives.
  /// Asking at the moment of use is the whole design; see the plan's class table.
  private func publishLockIfReady() {
    guard isRecordingLocked,
      acceptedStartPressID == startPressID,
      let sessionID = acceptedSessionID
    else { return }
    switch onLockRequested?(sessionID) ?? .unavailable {
    case .published:
      emitLockResolved(committed: true, reason: .published)
    case .notLockable:
      emitLockResolved(committed: false, reason: .notLockableAtPublication)
      performCleanup()
    case .unavailable:
      emitLockResolved(committed: false, reason: .publicationUnavailable)
      performCleanup()
    }
  }

  /// #1631 test seam — await the in-flight start task so a test can assert the
  /// reconciliation deterministically instead of polling a clock.
  ///
  /// NOT valid proof that a SUPERSEDED attempt finished: a newer press overwrites
  /// `recordingTask`, so awaiting the slot awaits the replacement. A test that
  /// needs a superseded attempt's completion must signal from its own injected
  /// callback.
  /// #1631 test seam — invoked once per completed `resolveStart`, on every exit
  /// path. Test-only; production never sets it.
  // periphery:ignore - test seam
  package var onStartResolvedForTesting: (@MainActor () -> Void)?

  // periphery:ignore - test seam
  package func awaitInFlightStartForTesting() async {
    await recordingTask?.value
  }

  // MARK: - Hands-Free State Machine

  /// Unified PTT + hands-free state machine.
  /// Called by both `handleCarbonHotkey` and `handleFlagsChangedValues` for
  /// push-to-talk mode press/release events.
  private func handleRecordAction(isPress: Bool) {
    if isPress {
      handleRecordPress()
    } else {
      handleRecordRelease()
    }
  }

  private func handleRecordPress() {
    // Guard: if already held (duplicate press event), ignore
    guard !isModifierHeld else { return }
    isModifierHeld = true

    // Anti-spam Layer 1: Block new recordings while pipeline is processing.
    if let isProcessing = onIsProcessing, isProcessing() {
      Task {
        await AppLogger.shared.log(
          "Key press ignored — pipeline is still processing",
          level: .info, category: "HotkeyService"
        )
      }
      // #1175 (C3): a press that never commits is exactly an under-fire case.
      emitHotkeyPressed(.ignoredProcessing, trigger: .ptt)
      isModifierHeld = false
      return
    }

    let isRecording = recordingStartTime != nil

    if !isRecording {
      // Not recording → start fresh
      stateGeneration &+= 1
      isRecordingLocked = false
      recordingStartTime = now()
      // #1631: a fresh attempt owns a fresh identity, and inherits no acceptance.
      startPressID &+= 1
      acceptedStartPressID = nil
      acceptedSessionID = nil
      let pressID = startPressID
      debounceTask?.cancel()
      debounceTask = nil
      recordingTask?.cancel()
      recordingTask = Task { [weak self] in
        guard let self else { return }
        guard let handler = self.onStartRecording else {
          // No callback wired means nothing was recorded, so the optimistic
          // bookkeeping is exactly as wrong here as on any other refusal.
          self.resolveStart(pressID: pressID, outcome: .noRecording)
          return
        }
        self.resolveStart(pressID: pressID, outcome: await handler())
      }
      // #1175 (C3): emit AFTER the recording Task is created; the `.live` sink
      // defers the actual write off this turn so it never delays the callback.
      emitHotkeyPressed(.start, trigger: .ptt)
    } else if let startTime = recordingStartTime,
      now().timeIntervalSince(startTime) <= Double(TimingConstants.handsFreeDebounceDelayMs)
        / 1000.0
    {
      // Within 500ms window
      if isRecordingLocked {
        // Triple press → cancel
        Task {
          await AppLogger.shared.log(
            "Triple press — cancelling hands-free recording",
            level: .info, category: "HotkeyService"
          )
        }
        performCleanup()
        isModifierHeld = false
        recordingTask?.cancel()
        recordingTask = Task { await onCancelRecording?() }
        // #1175 (Codex code-diff #2): hands-free triple-press cancel is an
        // accepted keydown too — distinguished from the Escape cancel by trigger.
        emitHotkeyPressed(.cancel, trigger: .ptt)
      } else {
        // Double press → lock into hands-free
        Task {
          await AppLogger.shared.log(
            // #1631: this records the REQUEST. Whether it becomes a lock is not
            // known yet — `Hands-free mode activated` is logged by the publisher.
            "Double press — requesting hands-free mode",
            level: .info, category: "HotkeyService"
          )
        }
        debounceTask?.cancel()
        debounceTask = nil
        isRecordingLocked = true
        lockTime = now()
        // DO NOT cancel recordingTask here — the pipeline startup must
        // continue running. Cancelling it aborts preWarm/toggleRecording,
        // leaving the UI locked but no actual recording happening.
        // #1631: intent is recorded above; publication happens only if this
        // press's start has already confirmed a session that is still running.
        // If it has not yet, `resolveStart` publishes when it does.
        publishLockIfReady()
        emitHotkeyPressed(.lock, trigger: .ptt)
      }
    } else if isRecordingLocked {
      // Lock cooldown: ignore presses within 500ms of locking.
      // Prevents accidental finger-bounce on modifier keys from
      // immediately stopping a just-locked recording.
      if let lt = lockTime,
        now().timeIntervalSince(lt) <= Double(TimingConstants.handsFreeDebounceDelayMs) / 1000.0
      {
        Task {
          await AppLogger.shared.log(
            "Press ignored — lock cooldown (\(Int(now().timeIntervalSince(lt) * 1000))ms since lock)",
            level: .info, category: "HotkeyService"
          )
        }
        // #1175 (Codex code-diff #2): a cooldown finger-bounce is an accepted
        // keydown that produces no recording action.
        emitHotkeyPressed(.ignoredCooldown, trigger: .ptt)
        isModifierHeld = false
        return
      }
      // Single press while locked (after cooldown) → stop
      Task {
        await AppLogger.shared.log(
          "Single press while locked — stopping hands-free recording",
          level: .info, category: "HotkeyService"
        )
      }
      performCleanup()
      isModifierHeld = false
      recordingTask?.cancel()
      recordingTask = Task { await onStopRecording?() }
      // #1175 (Codex code-diff #2): single press while locked stops the session.
      emitHotkeyPressed(.stop, trigger: .ptt)
    }
  }

  private func handleRecordRelease() {
    guard isModifierHeld else { return }
    isModifierHeld = false

    let isRecording = recordingStartTime != nil

    // Not recording → ignore
    guard isRecording else { return }

    // Locked → suppress release entirely
    if isRecordingLocked { return }

    // Quick release (within 500ms) → debounce, wait for double-press
    if let startTime = recordingStartTime,
      now().timeIntervalSince(startTime) <= Double(TimingConstants.handsFreeDebounceDelayMs)
        / 1000.0
    {
      stateGeneration &+= 1
      let capturedGeneration = stateGeneration
      debounceTask?.cancel()
      debounceTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(TimingConstants.handsFreeDebounceDelayMs))
        guard !Task.isCancelled, let self else { return }
        // Stale check: if any state-changing event occurred during sleep,
        // this callback is outdated and must not fire.
        guard self.stateGeneration == capturedGeneration else { return }
        // Timer fired — user didn't double-press. Stop as normal PTT.
        guard self.recordingStartTime != nil, !self.isRecordingLocked else { return }
        Task {
          await AppLogger.shared.log(
            "Debounce timer fired — stopping PTT (no double-press detected)",
            level: .info, category: "HotkeyService"
          )
        }
        self.performCleanup()
        self.recordingTask?.cancel()
        self.recordingTask = Task { await self.onStopRecording?() }
      }
    } else {
      // Normal PTT release (held > 500ms) → stop immediately
      performCleanup()  // increments stateGeneration
      recordingTask?.cancel()
      recordingTask = Task { await onStopRecording?() }
    }
  }

  // MARK: - Carbon Event Handler

  private func installCarbonEventHandler() {
    var eventTypes = [
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyPressed)),
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyReleased)),
    ]

    let selfPtr = Unmanaged.passUnretained(self).toOpaque()

    InstallEventHandler(
      GetApplicationEventTarget(),
      carbonHotkeyHandler,
      eventTypes.count,
      &eventTypes,
      selfPtr,
      &eventHandlerRef
    )
  }

  // MARK: - NSEvent Modifier Monitors

  /// Whether either role needs the `NSEvent` modifier monitors.
  ///
  /// #1991, blocker 2. This was `isModifierOnly(toggleKeyCode)` — the RECORD key
  /// only — so a user pairing a bare-modifier CANCEL key with a chord record key
  /// got no monitor at all, and nothing could observe their cancel key. That is
  /// the default record shape, so it is the configuration the affected users are
  /// actually in. Fixing the dispatch comparison alone would have left them
  /// exactly as broken while every dispatch-level test passed.
  ///
  /// `package` so the install condition is testable directly. Testing it through
  /// `installModifierMonitors()` would assert on `NSEvent` monitor objects, which
  /// says nothing about the decision being made here.
  /// #2381 reproduced #1991's blocker 2 before this was written. The condition was
  /// `recordBinding.isBareModifier || cancelBinding.isBareModifier` — a hand-written disjunction over
  /// the roles that existed when it was authored — so a user pairing a bare-modifier QUICK ADD with a
  /// chord record key and a chord cancel key got no monitor at all, and their shortcut was stored,
  /// displayed, and completely inert. Exactly the defect the comment above describes, one role over,
  /// added by the change that quotes it.
  ///
  /// It now asks the CLOSED SET rather than a list of the roles someone remembered, so a fourth role
  /// is included by construction instead of by whoever adds it noticing this line.
  package var shouldInstallModifierMonitors: Bool {
    bareModifierRoleAtRisk != nil
  }

  /// Which role loses its dispatch if the modifier monitors are missing, or nil when none is a bare
  /// modifier and the monitors are not needed at all.
  ///
  /// One value, so the most SEVERE loss wins — `ShortcutRole`'s declaration order is that severity
  /// order and its doc comment says so. Read by both the install decision and the failure label, so
  /// the two cannot come to disagree about which roles matter.
  package var bareModifierRoleAtRisk: ShortcutRole? {
    ShortcutRole.allCases.first { binding(for: $0).isBareModifier }
  }

  /// The binding a role is currently bound to. A switch, so a new role must be given one.
  package func binding(for role: ShortcutRole) -> ShortcutBinding {
    switch role {
    case .record: recordBinding
    case .cancel: cancelBinding
    case .quickAdd: quickAddBinding
    }
  }

  /// The current record binding, as one value.
  package var recordBinding: ShortcutBinding {
    .keyboard(keyCode: toggleKeyCode, modifiers: toggleModifiers)
  }

  /// The current cancel binding, as one value.
  package var cancelBinding: ShortcutBinding {
    .keyboard(keyCode: cancelKeyCode, modifiers: cancelModifiers)
  }

  /// The current Quick Add binding, as one value.
  package var quickAddBinding: ShortcutBinding {
    .keyboard(keyCode: quickAddKeyCode, modifiers: quickAddModifiers)
  }

  /// Which roles a press may currently trigger.
  ///
  /// Record is live whenever the service is; cancel only between
  /// `registerCancelHotkey()` and `unregisterCancelHotkey()`, which the lifecycle
  /// drives on `.recording` entry and exit. The Carbon path gets this for free —
  /// an unregistered hotkey delivers no event — but the modifier monitors stay
  /// installed the whole time, so the modifier path has to ask.
  private var armedRoles: Set<ShortcutRole> {
    // Quick Add is unconditional: it belongs to the app, not to a recording.
    isCancelArmed ? [.record, .cancel, .quickAdd] : [.record, .quickAdd]
  }

  private func installModifierMonitors() {
    removeModifierMonitors()

    guard shouldInstallModifierMonitors else { return }

    // Read AFTER the teardown above, so both closures carry the identity of the
    // installation being created here rather than the one it replaced. Both
    // monitors are stamped with the same value on purpose: the generation
    // identifies the INSTALLATION, and these two closures are that installation.
    let generation = monitorGeneration

    globalModifierMonitor = recordMonitorInstall(
      NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
        [weak self] event in
        // Global monitor callbacks may arrive off the main thread.
        // Extract event data here (NSEvent is not Sendable).
        let keyCode = event.keyCode
        let flags = event.modifierFlags
        DispatchQueue.main.async {
          guard let self else { return }
          MainActor.assumeIsolated {
            self.handleInstalledMonitorFlagsChangedValues(
              keyCode: keyCode, flags: flags, generation: generation)
          }
        }
      }, scope: "global")

    localModifierMonitor = recordMonitorInstall(
      NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
        [weak self] event in
        MainActor.assumeIsolated {
          self?.handleInstalledMonitorFlagsChangedValues(
            keyCode: event.keyCode, flags: event.modifierFlags, generation: generation)
        }
        return event  // pass the event through
      }, scope: "local")
  }

  /// #1175 (C2): the single chokepoint for an `NSEvent` modifier-monitor install.
  /// A `nil` return means a modifier-only hotkey is silently dead → report it.
  /// Returns the monitor unchanged so the call site assigns it as before.
  /// `internal` (not `private`) so the nil path is unit-testable without
  /// abstracting the whole `NSEvent` stack.
  func recordMonitorInstall(_ monitor: Any?, scope: String) -> Any? {
    if monitor == nil {
      // Which ROLE dies if this monitor is missing. It used to hard-code
      // "toggle", which was true while the monitors only ever existed for a
      // modifier-only RECORD key. Now they also install when only CANCEL is a
      // bare modifier, so a hard-coded kind would report a dead cancel shortcut
      // as a toggle failure — mislabelling the telemetry for exactly the users
      // this change is for, in the one signal that would tell us it broke.
      //
      // Record wins when several are bare modifiers: it is armed for the whole
      // session while cancel is armed only during a recording, so it is the
      // more severe loss and the field holds one value.
      //
      // #2381: this was `recordBinding.isBareModifier ? "toggle" : "cancel"`, a THIRD two-role
      // ternary alongside the two the switch repairs elsewhere in this file, and it reported a dead
      // bare-modifier Quick Add as a dead CANCEL shortcut. It now reads the same closed enumeration
      // the install decision does.
      let kind = bareModifierRoleAtRisk?.telemetryKind ?? "unknown"
      telemetry.registrationFailed("nsevent_\(scope)", kind, nil, "modifier_only")
    }
    return monitor
  }

  private func removeModifierMonitors() {
    if let monitor = globalModifierMonitor {
      NSEvent.removeMonitor(monitor)
      globalModifierMonitor = nil
    }
    if let monitor = localModifierMonitor {
      NSEvent.removeMonitor(monitor)
      localModifierMonitor = nil
    }
    // Bump on EVERY teardown, including one that removed nothing. This is the
    // single writer of `monitorGeneration`, and it is the only NSEvent-monitor
    // teardown path: `stop()` and `suspend()` call it directly, and
    // `installModifierMonitors()` calls it first, so `stop(); start()` and
    // `suspend(); resume()` each burn two generations. An event queued against
    // any earlier installation can therefore never match again.
    monitorGeneration &+= 1
  }

  private func removeCarbonEventHandler() {
    if let ref = eventHandlerRef {
      RemoveEventHandler(ref)
      eventHandlerRef = nil
    }
  }

  // MARK: - Registration Helpers

  private func registerToggleHotkey() {
    unregisterToggleHotkey()
    // Modifier-only hotkeys are handled via NSEvent flagsChanged monitors —
    // Carbon RegisterEventHotKey cannot register a bare modifier key. Asked
    // through the binding, the same way the cancel path asks it: two spellings
    // of one question is how the record and cancel paths drifted apart in the
    // first place.
    guard recordBinding.isCarbonRegistrable else { return }
    toggleHotkeyRef = registerHotkey(
      id: HotkeyID.toggle.rawValue,
      keyCode: toggleKeyCode,
      modifiers: carbonModifiers(from: toggleModifiers)
    )
  }

  private func unregisterToggleHotkey() {
    if let ref = toggleHotkeyRef {
      UnregisterEventHotKey(ref)
      toggleHotkeyRef = nil
    }
  }

  /// Register the Quick Add hotkey (#2381).
  ///
  /// Asked through the BINDING, exactly as the toggle and cancel paths ask it — a bare modifier
  /// cannot go to Carbon, and for that shape the already-installed `NSEvent` monitors observe it
  /// instead. Two spellings of that question is how the record and cancel paths drifted apart.
  private func registerQuickAddHotkey() {
    guard quickAddBinding.isCarbonRegistrable else { return }
    guard quickAddHotkeyRef == nil else { return }
    quickAddHotkeyRef = registerHotkey(
      id: HotkeyID.quickAdd.rawValue,
      keyCode: quickAddKeyCode,
      modifiers: carbonModifiers(from: quickAddModifiers)
    )
  }

  private func unregisterQuickAddHotkey() {
    if let ref = quickAddHotkeyRef {
      UnregisterEventHotKey(ref)
      quickAddHotkeyRef = nil
    }
  }

  /// Re-apply the Quick Add binding after the user changes it.
  ///
  /// Both halves, because the binding can change SHAPE — chord to bare modifier or back — which
  /// moves it between Carbon and the monitors. Re-registering without re-installing the monitors
  /// would leave the new shape unobserved, which is #1991's exact failure: a shortcut that is
  /// stored, displayed, and inert.
  public func reapplyQuickAddBinding() {
    unregisterQuickAddHotkey()
    guard isEnabled, !isSuspended else { return }
    registerQuickAddHotkey()
    installModifierMonitors()
  }

  private func registerHotkey(id: UInt32, keyCode: UInt16, modifiers: UInt32) -> EventHotKeyRef? {
    let hotkeyID = EventHotKeyID(signature: hotkeySignature, id: id)
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(
      UInt32(keyCode),
      modifiers,
      hotkeyID,
      GetApplicationEventTarget(),
      0,
      &ref
    )
    guard status == noErr else {
      // #1175: the noErr-but-silent trap means success can't confirm delivery, so
      // we only report FAILURE. This is the single Carbon chokepoint — every registration routes
      // through here.
      // #2381: this was `id == cancel ? "cancel" : "toggle"`, which reported a quick-add
      // registration failure as a TOGGLE failure. It now resolves the id to a ROLE and asks the role
      // for its wire name, so the Carbon path and the monitor path below cannot disagree about what
      // a role is called — one owner, `ShortcutRole.telemetryKind`.
      let kind = (HotkeyID(rawValue: id)?.role ?? .record).telemetryKind
      let keyShape = ModifierKeyCodes.isModifierOnly(keyCode) ? "modifier_only" : "chord"
      telemetry.registrationFailed("carbon", kind, status, keyShape)
      return nil
    }
    return ref
  }

  // MARK: - Event Dispatch

  /// Called from the Carbon event handler on the main thread for RegisterEventHotKey events.
  public func handleCarbonHotkey(id: UInt32, isRelease: Bool) {
    Task {
      await AppLogger.shared.log(
        "Carbon hotkey event: id=\(id), isRelease=\(isRelease), mode=\(recordingMode)",
        level: .info, category: "HotkeyService"
      )
    }
    switch id {
    case HotkeyID.toggle.rawValue:
      if recordingMode == .toggle {
        guard !isRelease else { return }
        Task { await onToggleRecording?() }
        emitHotkeyPressed(.toggle, trigger: .toggle)
      } else {
        // Push-to-talk mode with hands-free support
        handleRecordAction(isPress: !isRelease)
      }

    case HotkeyID.cancel.rawValue:
      guard !isRelease else { return }
      performCleanup()
      Task { await onCancelRecording?() }
      emitHotkeyPressed(.cancel, trigger: .cancel)

    case HotkeyID.quickAdd.rawValue:
      guard !isRelease else { return }
      // No `performCleanup()`: Quick Add does not touch the recording path, so tearing down
      // press-tracking state here would disturb an in-flight dictation for a limb's sake.
      Task { await onQuickAdd?() }
      emitHotkeyPressed(.quickAdd, trigger: .quickAdd)

    default:
      break
    }
  }

  /// The lifecycle gate for a modifier event arriving from an INSTALLED monitor.
  ///
  /// Removing a monitor stops NEW callbacks; it cannot recall one the global
  /// monitor has already queued with `DispatchQueue.main.async`. Such an event is
  /// refused here on arrival rather than trusted to have been prevented by the
  /// teardown — removing an event source does not un-queue what it emitted.
  ///
  /// Deliberately separate from `handleFlagsChangedValues`: this answers "is this
  /// event from the monitor installation we currently have", while the seam below
  /// answers "a modifier changed, what gesture is that". Folding the generation
  /// check into the seam would silently re-scope every existing test that drives
  /// it, none of which installs a monitor.
  ///
  /// `isSuspended` is NOT re-checked here — the seam owns it, and duplicating it
  /// would not help anyway, because `suspend()`/`resume()` leaves it permissive
  /// for exactly the delivery this guard exists to refuse (#1993).
  package func handleInstalledMonitorFlagsChangedValues(
    keyCode: UInt16, flags: NSEvent.ModifierFlags, generation: UInt64
  ) {
    guard generation == monitorGeneration else { return }
    handleFlagsChangedValues(keyCode: keyCode, flags: flags)
  }

  /// Processes modifier key changes from pre-extracted values.
  /// Reached from both NSEvent modifier monitors through
  /// `handleInstalledMonitorFlagsChangedValues`, which owns the installation
  /// check; this function assumes that has already passed.
  /// Test seam (#1987): `package` rather than `private` so tests drive the REAL
  /// modifier dispatch path on a plain import. `internal` would work only through
  /// `@testable`, which couples the seam to a compilation mode.
  package func handleFlagsChangedValues(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
    guard !isSuspended else { return }

    let currentFlags = flags.intersection(.deviceIndependentFlagsMask)

    // Only known standalone modifier key codes; this also supplies the flag, so a
    // member can never reach the press/release test without one (#1987).
    guard let flag = ModifierKeyCodes.flag(for: keyCode) else { return }

    // Determine press vs. release by checking whether the flag is present
    let isPress = currentFlags.contains(flag)

    // #1991, blocker 1. This was `guard keyCode == toggleKeyCode`, which asked
    // "is this the RECORD key" and returned early for everything else — so a
    // bare modifier bound to CANCEL reached here and was dropped on the floor.
    // The comparison now goes through the matcher, which is the single authority
    // both dispatch paths consult, so a role cannot be handled by one mechanism
    // and silently omitted from the other again.
    guard
      let role = ShortcutMatcher.role(
        forBareModifierKeyCode: keyCode,
        record: recordBinding,
        cancel: cancelBinding,
        quickAdd: quickAddBinding,
        armed: armedRoles)
    else { return }

    // #2381. This was `if role == .cancel { … return }` followed by the record path, so a role the
    // matcher resolved and this site did not name FELL THROUGH AND STARTED A RECORDING — and it
    // compiled perfectly, because an `if` over an enum asserts nothing about the members it omits.
    // A bare-modifier Quick Add would have begun dictating instead of opening the panel. The switch
    // below is what makes the compiler name every member, which is the entire reason `ShortcutRole`
    // was made a closed set.
    switch role {
    case .quickAdd:
      // Press only: a modifier RELEASE is not a gesture. Quick Add carries none of cancel's
      // aggregate-flag hazard, because it disarms nothing and destroys nothing — a stray second
      // fire opens the panel twice, and the panel reuses its own window.
      guard isPress else { return }
      Task { await onQuickAdd?() }
      emitHotkeyPressed(.quickAdd, trigger: .quickAdd)
      return

    case .cancel:
      // A modifier RELEASE is not a press, on the common path.
      guard isPress else { return }

      // But `isPress` is NOT proof of a key-down, and this guard alone is not
      // enough. `.command` / `.option` / `.shift` / `.control` are AGGREGATE,
      // device-independent flags: with Left Command held, releasing Right
      // Command leaves `.command` set, so the release reads as a press and the
      // same physical tap cancels twice. An earlier version of this comment
      // claimed the guard above prevented exactly that, which was wrong — the
      // two-key case defeats it, and cloud review caught the claim.
      //
      // Disarming here closes it: cancelling ENDS the recording, so the role is
      // no longer armed the instant it fires, and the stray release finds
      // nothing to cancel. The lifecycle still calls `unregisterCancelHotkey()`
      // on the way down; doing it synchronously here also closes the async
      // window that call leaves open, since `onCancelRecording` is awaited in a
      // Task that has not run yet when the release arrives.
      //
      // Residual, stated rather than engineered around: the aggregate-flag
      // imprecision is pre-existing and still governs the RECORD path, which
      // computes `isPress` the same way. Narrowing that needs the device-
      // dependent left/right masks and would change heart-path dispatch, so it
      // is not folded into a cancel-key fix.
      isCancelArmed = false
      performCleanup()
      Task { await onCancelRecording?() }
      emitHotkeyPressed(.cancel, trigger: .cancel)
      return

    case .record:
      break
    }

    if recordingMode == .toggle {
      guard isPress else { return }
      Task {
        await AppLogger.shared.log(
          "Modifier-only toggle: keyCode=\(keyCode)", level: .info, category: "HotkeyService"
        )
      }
      Task { await onToggleRecording?() }
      emitHotkeyPressed(.toggle, trigger: .toggle)
    } else {
      // Push-to-talk mode with hands-free support
      handleRecordAction(isPress: isPress)
    }
  }

  // MARK: - Modifier Conversion

  private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var carbon: UInt32 = 0
    if flags.contains(.command) { carbon |= UInt32(cmdKey) }
    if flags.contains(.option) { carbon |= UInt32(optionKey) }
    if flags.contains(.control) { carbon |= UInt32(controlKey) }
    if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
    return carbon
  }

  // MARK: - Display

  /// Human-readable description of the current hotkey.
  public var hotkeyDescription: String {
    let formatted = KeySymbols.formatHotkey(keyCode: toggleKeyCode, modifiers: toggleModifiers)
    return recordingMode == .pushToTalk ? "Hold \(formatted)" : formatted
  }

}

// MARK: - Carbon Helpers

/// Four-char-code signature for EnviousWispr hotkeys.
private let hotkeySignature: OSType = {
  var result: OSType = 0
  for char in "EWSP".utf8.prefix(4) {
    result = (result << 8) | OSType(char)
  }
  return result
}()

/// C-function callback for Carbon event handler.
///
/// Handles kEventHotKeyPressed/Released for key+modifier combos registered
/// via RegisterEventHotKey. Modifier-only hotkeys are handled separately via
/// NSEvent flagsChanged monitors, which work globally regardless of app focus.
private func carbonHotkeyHandler(
  _: EventHandlerCallRef?,
  _ event: EventRef?,
  _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
  guard let event = event, let userData = userData else {
    return OSStatus(eventNotHandledErr)
  }

  let service = Unmanaged<HotkeyService>.fromOpaque(userData).takeUnretainedValue()
  let eventKind = GetEventKind(event)

  // --- kEventHotKeyPressed / kEventHotKeyReleased ---
  var hotkeyID = EventHotKeyID()
  let status = GetEventParameter(
    event,
    UInt32(kEventParamDirectObject),
    UInt32(typeEventHotKeyID),
    nil,
    MemoryLayout<EventHotKeyID>.size,
    nil,
    &hotkeyID
  )
  guard status == noErr else {
    return OSStatus(eventNotHandledErr)
  }

  let isRelease = eventKind == UInt32(kEventHotKeyReleased)
  let hotkeyIDValue = hotkeyID.id

  MainActor.assumeIsolated {
    service.handleCarbonHotkey(id: hotkeyIDValue, isRelease: isRelease)
  }

  return noErr
}
