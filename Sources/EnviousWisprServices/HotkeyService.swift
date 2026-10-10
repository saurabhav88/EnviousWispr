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
/// For modifier-only hotkeys (e.g., bare Option key), the keyboard listener (one session event
/// tap on its own thread, #3544) is the only reader, so they fire whichever app is in front.
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
    /// #3106. Paste Last and Copy Last take the next two free ids; 2 stays retired.
    case pasteLast = 5
    case copyLast = 6

    /// Which role this Carbon registration belongs to. A switch, so a new id must declare one
    /// rather than borrowing a neighbour's telemetry name.
    var role: ShortcutRole {
      switch self {
      case .toggle: .record
      case .cancel: .cancel
      case .quickAdd: .quickAdd
      case .pasteLast: .pasteLast
      case .copyLast: .copyLast
      }
    }

    /// The id an app shortcut registers under. Record and Cancel register through their own
    /// paths, so they have no answer here.
    init?(appShortcut role: ShortcutRole) {
      switch role {
      case .quickAdd: self = .quickAdd
      case .pasteLast: self = .pasteLast
      case .copyLast: self = .copyLast
      case .record, .cancel: return nil
      }
    }
  }

  // MARK: - Carbon State

  /// What this service currently has installed, as opaque tokens (#2455 C2).
  ///
  /// C0 held typed framework values here with a `.denied` case, because the OS
  /// call happened in this file and a refusal had to be representable without
  /// forging an `EventHotKeyRef`. C2 removes both problems at once: the framework
  /// values now live inside `EnviousWisprDesktopEffects`, and a test's fake hands
  /// back real tokens. Occupancy — all these guards ever ask, e.g.
  /// `guard cancelHotkeyToken == nil` — is preserved by a token being non-nil.
  private var eventHandlerToken: DesktopEffectToken?
  private var toggleHotkeyToken: DesktopEffectToken?
  private var cancelHotkeyToken: DesktopEffectToken?
  /// The Carbon registrations of the always-armed app shortcuts (Quick Add, Paste Last, Copy Last),
  /// keyed by role. One table rather than one slot each, so a reconcile pass cannot forget a member.
  private var appShortcutTokens: [ShortcutRole: DesktopEffectToken] = [:]
  /// The binding each held registration was made for (#3106). A removal Carbon refuses leaves the
  /// OLD chord registered under the role's id, so a held token alone cannot say the chord that fired
  /// is the one the user set; `carbonEventIsCurrent` compares this with the current binding.
  private var appShortcutRegisteredBindings: [ShortcutRole: ShortcutBinding] = [:]

  /// App shortcuts whose current physical press has been seen and not yet released (#3106), with
  /// the press that owns each hold. Paste Last fires on the release and Copy Last on the first
  /// press; either way a held key or an auto-repeat acts once. Only a release from the owning press
  /// ends a hold, so the release of a key from before a rebind cannot end the new shortcut's hold.
  /// Cleared on stop and suspend, where a release may never arrive.
  private var appShortcutsHeld: [ShortcutRole: AppShortcutHold] = [:]

  /// The press that owns an app shortcut hold: a Carbon chord, or one modifier key the listener saw.
  private enum AppShortcutHold: Equatable {
    case chord
    case modifier(keyCode: UInt16)
  }

  /// Whether the cancel role is currently armed.
  ///
  /// Not derivable from `cancelHotkeyToken`: a bare-modifier cancel key has no
  /// Carbon registration to hold a ref, so a nil ref means "unarmed" for a chord
  /// and says nothing at all for a modifier. Tracking arming explicitly is what
  /// lets the modifier dispatch path know whether a recording is in flight.
  /// Whether the cancel role is armed. `package private(set)` so #2087's
  /// disarm-on-abandonment can be OBSERVED by a test — the alternative was
  /// asserting on a spy for a call the production code might simply not make.
  package private(set) var isCancelArmed = false {
    didSet { engine.setCancelArmed(isCancelArmed) }
  }

  /// Cancel's armed state at the moment `suspend()` ran, so `resume()` can put a
  /// still-running recording back where it was.
  private var cancelArmedBeforeSuspend = false

  public private(set) var isEnabled = false
  /// The record key is held, as the engine's synchronized gesture snapshot reports.
  public var isModifierHeld: Bool { engine.snapshot.isHeld }

  /// Tracks the in-flight recording Task so we can cancel zombie Tasks from
  /// previous press/release events before starting new ones. This serializes
  /// recording commands — only one start or stop operation runs at a time.
  private var recordingTask: Task<Void, Never>?
  /// The listener cancel's callback, kept apart from `recordingTask` so the next start can wait for
  /// it: a start that ran while the cancel was still tearing the old session down would find that
  /// session active and resume it instead of starting a new one (#3544 P3).
  private var listenerCancellationTask: Task<Void, Never>?
  /// Test seam: a start is about to wait for a listener cancel's teardown. Production never sets it.
  package var onListenerCancellationWaitForTesting: (@MainActor () -> Void)?

  // MARK: - Hands-Free (Double-Press Lock) State

  /// The push-to-talk record gesture and its lone-tap timer (#3544 P1). The engine decides under
  /// its own lock and hands each decision to `execute(_:valid:)` on the main thread, in order.
  private let engine: RecordGestureEngine

  /// #3544 P1: main's own record of which attempt it is executing, and which attempt recorded a
  /// hands-free intent. #1631 reconciliation and publication read THESE, never the engine's newer
  /// gesture state, so a late start result is judged against the attempt it belongs to.
  private var executingAttemptID: UInt64?
  private var lockIntentAttemptID: UInt64?

  /// True when recording is locked into hands-free mode.
  /// When locked, key releases are suppressed and recording continues
  /// until the next key press or cancel.
  public var isRecordingLocked: Bool { engine.snapshot.isLocked }

  /// Test seam: the record gesture engine, for driving listener admission directly (#3544 P3).
  package var recordGestureEngineForTesting: RecordGestureEngine { engine }

  /// #1631 — the press whose start confirmed a continuing session, and that
  /// session's opaque id. Together they gate publication: hands-free intent is
  /// recorded on the second press, but published only once the SAME press's
  /// start has confirmed a session that is still running.
  private var acceptedStartPressID: UInt64?
  private var acceptedSessionID: String?
  /// Attempts the engine dismissed whose start main may still be resolving (#3544 P4), and the
  /// session each start produced, so the dismissal ends exactly that session even after a newer
  /// press replaced the attempt's execution state.
  private var pendingDismissals: Set<UInt64> = []
  private var dismissedSessions: [UInt64: String] = [:]
  /// Secure Input as the current listener installation last observed it (#3544 P4); false while
  /// no listener is installed. Logged and noticed only; it never ends, cancels or locks a take.
  private var secureInputOn = false
  /// Whether this Secure Input period has already been told to the user.
  private var secureInputNoticeShown = false

  // MARK: - Callbacks (wired by the former root state)

  public var onToggleRecording: (@MainActor () async -> Void)?
  /// #1631: returns whether a session is genuinely continuing when the start path
  /// finishes, and if so its id. `HotkeyService` reconciles its own state on that.
  package var onStartRecording: (@MainActor () async -> RecordingStartOutcome)?
  /// #3544 P4: a press made while a session was running joins it and must never create one: if
  /// that session has ended by the time this runs, it returns `.noRecording`. The engine marks
  /// such a press; nil refuses it.
  package var onJoinRecording: (@MainActor () async -> RecordingStartOutcome)?
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

  /// #3544 P4 (D2): end the recording session `String` started by a dismissed push-to-talk press,
  /// destructively, if that session is still the one running. The `String` is the same opaque
  /// session token `onLockRequested` receives.
  package var onDismissRecording: (@MainActor (String) async -> Void)?

  /// Returns true if the pipeline is in a processing state (transcribing, polishing, etc.).
  /// Used by the processing state gate to block new recordings during processing.
  public var onIsProcessing: (@MainActor () -> Bool)?

  /// Quick Add fired (#2381). Deliberately NOT gated on `onIsProcessing`: it never touches the
  /// recording path, so refusing it mid-transcription would block a limb for a heart-path reason.
  public var onQuickAdd: (@MainActor () async -> Void)?

  /// Paste Last Dictation fired (#3106). While nil the chord is not registered at all: a build in
  /// which nothing answers must not take Control-Command-V away from the frontmost app.
  /// Called synchronously on the release turn, so the owner takes its target and row before any
  /// later press can change them.
  public var onPasteLast: (@MainActor () -> Void)? {
    didSet { reconcileAppShortcutRegistrations() }
  }

  /// The Paste Last chord went DOWN (#3106). Synchronous, on the press turn, so the owner can
  /// sample which application the user was in at that moment: the paste itself fires on the
  /// release, and by then focus may have moved. Fires once per physical hold.
  public var onPasteLastPressed: (@MainActor () -> Void)?

  /// Copy Last Dictation fired (#3106). Registered only while set, for the same reason. Called
  /// synchronously on the press turn, so the row copied is the one present at the press.
  public var onCopyLast: (@MainActor () -> Void)? {
    didSet { reconcileAppShortcutRegistrations() }
  }

  // MARK: - Configuration

  // #3534: every binding and the mode below void the stop-timer measurement when they ACTUALLY
  // change (diagnostic state only; the settings sync assigns unchanged values freely).
  public var recordingMode: RecordingMode = .toggle {
    didSet {
      if recordingMode != oldValue { invalidateQuickTapDiagnostics() }
      configureEngine()
    }
  }

  // Every fallback below reads `ShortcutRole.defaultBinding`, the one owner of what a shortcut ships
  // as. These are the value a service carries before `HotkeyController` pushes the user's settings,
  // so a hard-coded one here does not show up as a wrong default anywhere a test looks — it shows up
  // as a newly constructed service holding a stale binding until synchronisation runs.
  //
  // Converting Quick Add and leaving these two was the first attempt, which is the partial migration
  // this repo's own rule refuses: old code removed and new code wired in the SAME change, never a
  // shim and a follow-up.

  /// Toggle-mode hotkey key code. Right Option, a bare modifier.
  public var toggleKeyCode: UInt16 = ShortcutRole.record.defaultKeyCode {
    didSet {
      if toggleKeyCode != oldValue { invalidateQuickTapDiagnostics() }
      configureEngine()
    }
  }

  /// Toggle-mode required modifiers — none, because a bare modifier stores empty modifiers.
  public var toggleModifiers: NSEvent.ModifierFlags = ShortcutRole.record.defaultModifiers {
    didSet {
      if toggleModifiers != oldValue { invalidateQuickTapDiagnostics() }
      configureEngine()
    }
  }

  /// Key code for the cancel hotkey. Escape.
  public var cancelKeyCode: UInt16 = ShortcutRole.cancel.defaultKeyCode {
    didSet {
      if cancelKeyCode != oldValue { invalidateQuickTapDiagnostics() }
      configureEngine()
    }
  }

  /// Required modifiers for cancel hotkey — none, bare Escape.
  public var cancelModifiers: NSEvent.ModifierFlags = ShortcutRole.cancel.defaultModifiers {
    didSet {
      if cancelModifiers != oldValue { invalidateQuickTapDiagnostics() }
      configureEngine()
    }
  }

  /// Key code for the Quick Add hotkey (#2381). The shipped value, read from its one owner.
  public var quickAddKeyCode: UInt16 = ShortcutRole.quickAdd.defaultKeyCode {
    didSet {
      if quickAddKeyCode != oldValue { invalidateQuickTapDiagnostics() }
      configureEngine()
    }
  }

  /// Required modifiers for the Quick Add hotkey, read from the same owner.
  public var quickAddModifiers: NSEvent.ModifierFlags = ShortcutRole.quickAdd.defaultModifiers {
    didSet {
      if quickAddModifiers != oldValue { invalidateQuickTapDiagnostics() }
      configureEngine()
    }
  }

  /// Paste Last Dictation's key code (#3106), read from the same owner.
  public var pasteLastKeyCode: UInt16 = ShortcutRole.pasteLast.defaultKeyCode {
    didSet {
      if pasteLastKeyCode != oldValue { invalidateQuickTapDiagnostics() }
      configureEngine()
    }
  }

  /// Paste Last Dictation's required modifiers.
  public var pasteLastModifiers: NSEvent.ModifierFlags = ShortcutRole.pasteLast.defaultModifiers {
    didSet {
      if pasteLastModifiers != oldValue { invalidateQuickTapDiagnostics() }
      configureEngine()
    }
  }

  /// Copy Last Dictation's key code (#3106), read from the same owner.
  public var copyLastKeyCode: UInt16 = ShortcutRole.copyLast.defaultKeyCode {
    didSet {
      if copyLastKeyCode != oldValue { invalidateQuickTapDiagnostics() }
      configureEngine()
    }
  }

  /// Copy Last Dictation's required modifiers.
  public var copyLastModifiers: NSEvent.ModifierFlags = ShortcutRole.copyLast.defaultModifiers {
    didSet {
      if copyLastModifiers != oldValue { invalidateQuickTapDiagnostics() }
      configureEngine()
    }
  }

  // MARK: - Lifecycle

  public private(set) var isSuspended = false


  // MARK: - Keyboard listener (#3544 P2, the only modifier ingress from P3)

  /// The keyboard listener's resource. Kept when its removal is refused, like every other token
  /// here, and a new listener is never installed while it is still owned.
  private var keyboardListenerToken: DesktopEffectToken?

  /// The listener's installation identity: bumped on every install attempt and every removal, so
  /// a retry scheduled for an earlier installation never installs one after a stop, suspend or newer
  /// install, and a delivery stamped by an earlier installation is refused.
  ///
  /// Neither lifecycle flag can identify an installation, because both are LEVEL signals that
  /// return to their permissive value: `stop()` then `start()` (what the settings sync does when the
  /// user changes a shortcut) puts `isEnabled` back to true inside one main-thread turn, so an event
  /// queued before that turn arrives after both and sees a permissive flag; `suspend()`/`resume()`
  /// has the same shape for `isSuspended` (#1993, ported from the retired modifier monitors'
  /// `monitorGeneration`). A wrapping `UInt64` could collide only after 2^64 bumps, unreachable
  /// within a queued event's lifetime.
  package private(set) var listenerGeneration: UInt64 = 0

  /// This installation's ingress (tracker, routes, reconciliation, watchdog); nil while none is
  /// installed.
  private var keyboardListenerIngress: KeyboardListenerIngress?

  /// One `registrationFailed(event_tap)` per run of failed installs, not one per retry.
  private var listenerFailureReported = false
  /// How long after a disable storm stopped the listener before a fresh one is installed
  /// (#3544 P3). An engineering backoff bound, reviewed in the P3 build: it reuses the storm window
  /// so replacements can never themselves storm faster than the rule that detects storms. It is
  /// not a P2 measurement and not a responsiveness promise.
  package static let listenerStormCooldown: TimeInterval = 60
  /// This launch's listener installs: adapter calls, the ones that returned no listener, and the
  /// ones that did. Reported with every `hotkey.listener_health` row.
  private var listenerInstallAttempts = 0
  private var listenerInstallFailures = 0
  private var listenerInstalls = 0
  /// Failed attempts since the last successful install; a success after any reports once.
  private var listenerFailuresSinceInstall = 0
  private var listenerRetry: RecordGestureEngine.TimerHandle?
  /// While no listener is installed (storm cooldown, failed installs), the check that ends a
  /// listener-owned record hold whose key came up unseen. Nil when none is pending. Install
  /// attempts do not reset it (they retry every five seconds too); a successful install, a stop, a
  /// suspend or a reinstall cancels it.
  private var orphanedHoldCheck: RecordGestureEngine.TimerHandle?
  private var orphanedHoldCheckToken: UInt64 = 0
  /// The press the previous orphaned-hold check read up, if any: a hold ends only on two
  /// consecutive up readings about the same attempt, as with the listener's own sweep (#3544 P3
  /// hotfix, P4 C2).
  private var orphanedHoldReadUp: RecordGestureEngine.OwnedListenerPress?
  /// Schedules the install retry off main; the fire hops to main to re-check the lifecycle.
  private let listenerRetryScheduler: RecordGestureEngine.Scheduler
  /// Test seam: invoked once each time a scheduled install retry runs on main, on every exit
  /// path. Production never sets it.
  package var onListenerRetryResolvedForTesting: (@MainActor () -> Void)?


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
    case pasteLast = "paste_last"
    case copyLast = "copy_last"
    case ignoredProcessing = "ignored_processing"
    case ignoredCooldown = "ignored_cooldown"
    /// #3534: a second press that came after the 500 ms window while a lone-tap stop was
    /// pending. Its outcome is unchanged (the pending stop runs; its release stops); before
    /// this it took no branch at all and left no row.
    case lateAfterWindow = "late_after_window"
  }

  /// Which hotkey delivered the press.
  private enum PressTrigger: String {
    case ptt = "ptt_hotkey"
    case toggle = "toggle_hotkey"
    case cancel = "cancel_hotkey"
    case quickAdd = "quick_add_hotkey"
    case pasteLast = "paste_last_hotkey"
    case copyLast = "copy_last_hotkey"
  }

  /// Injected clock for the 500ms double-press window and the lock cooldown.
  /// Uses system uptime for handling time (#3534). OS stamps are nominally
  /// startup-relative; sleep/wake compatibility is not verified. Acceptance
  /// bounds reject implausible stamps, and comparisons fall back as a pair.
  /// Defaults to the real clock.
  ///
  /// Tests MUST inject: the window is measured in real elapsed time, so a test
  /// that awaits anything between the two presses can be pushed outside the
  /// window by parallel load and silently take the stop or fresh-start branch
  /// instead of the lock branch. That is a genuinely load-dependent test, which
  /// `swift-patterns.md` RULE: tests-no-real-time-scheduling-precision forbids —
  /// found by the independent whole-diff review, which reproduced eight failures
  /// running this suite alongside its siblings while it passed alone.
  private let uptime: @Sendable () -> TimeInterval


  private typealias InputTime = RecordGesture.InputTime

  /// Stamp one record-key input with this service's clock, keeping the OS time
  /// only if it is plausible.
  private func capture(_ stamp: TimeInterval?) -> InputTime {
    InputTime.accepting(stamp: stamp, handled: uptime())
  }

  /// The OS calls this service is allowed to make (#2455 C2).
  ///
  /// Required and non-defaulted. Before C2 the Carbon and `NSEvent` calls were
  /// inline in this file, so constructing a `HotkeyService` in a unit test was
  /// enough to reach the developer's real desktop — which is how a running suite
  /// took the Escape key system-wide. This module now declares no implementation
  /// of this protocol at all: the live one lives in `EnviousWisprDesktopEffects`,
  /// which `EnviousWisprTests` may not import — enforced by
  /// `scripts/check-dependency-direction.sh`, since the module graph does not
  /// enforce itself under Xcode — and tests supply a recording fake. A default
  /// here would put the choice back inside the module the test target links,
  /// which is what C2 exists to remove.
  private let effects: any DesktopHotkeyEffects

  /// `package`, not `public`: `DesktopHotkeyEffects` is `package`, and Swift will
  /// not let a public initializer take a package type. That is the right
  /// constraint rather than an obstacle — widening the protocol to `public` would
  /// publish the desktop-effect seam outside this package for no caller, and every
  /// construction site (AppKit's bootstrapper, the unit-test factory) is in-package
  /// already.
  package init(
    effects: any DesktopHotkeyEffects,
    telemetry: HotkeyTelemetrySink = .noop,
    uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    // Injected one-shot scheduler for the lone-tap stop (#3534, #3544). Same reason as `uptime`:
    // the stop deadline is computed from the release's own time, so a test must control when the
    // wait ends rather than race a real timer.
    scheduler: @escaping RecordGestureEngine.Scheduler = RecordGestureEngine.liveScheduler
  ) {
    self.effects = effects
    self.telemetry = telemetry
    self.uptime = uptime
    self.listenerRetryScheduler = scheduler
    self.engine = RecordGestureEngine(
      binding: .keyboard(
        keyCode: ShortcutRole.record.defaultKeyCode, modifiers: ShortcutRole.record.defaultModifiers),
      mode: .toggle, clock: uptime, scheduler: scheduler,
      // Carbon chords still reach the engine through main until P5, so their lone-tap waits keep
      // the main hop (#3544 P1); the listener's bare-modifier input does not wait on main (P3).
      hopsMainInput: true)
    engine.setSink { @MainActor [weak self] batch, valid in self?.execute(batch, valid: valid) }
    configureEngine()
  }

  /// The single release path for anything this service installed.
  ///
  /// Keeps the token when the adapter reports a REFUSED release, so a later
  /// teardown can retry. Clearing it regardless would strand the OS resource with
  /// nothing left able to name it — the one outcome worse than releasing twice,
  /// which the adapter already makes a no-op.
  private func release(_ slot: inout DesktopEffectToken?) {
    guard let token = slot, effects.remove(token) else { return }
    slot = nil
  }
  /// Release a Carbon hotkey and drop the token even if the removal was refused: the behaviour
  /// Record, Cancel and Quick Add had before the adapter began reporting refusals (#3106). Keeping
  /// the token would stop their NEW chord registering, and nothing gates their old chord's events
  /// by binding yet; #3108 owns doing both properly. Paste Last and Copy Last, which are gated,
  /// use `releaseAppShortcut` instead.
  private func forgetHotkey(_ slot: inout DesktopEffectToken?, role: ShortcutRole) {
    guard let token = slot else { return }
    slot = nil
    let chord = registeredChords.removeValue(forKey: role)
    if effects.remove(token) { return }
    // #3273: the OS registration outlives the dropped token; remember WHICH chord, not which role.
    if let chord { possiblyRetainedChords.insert(chord) }
    Task {
      await AppLogger.shared.log(
        "Hotkey removal refused: role=\(role.rawValue); token dropped as before (#3108)",
        level: .info, category: "HotkeyService")
    }
  }

  /// Emit `hotkey.pressed` for an accepted keydown. Synchronous + cheap (computes
  /// two strings, invokes the injected closure); the `.live` sink defers the
  /// actual PostHog write off the input turn (heart path). The args ARE the
  /// snapshot — no shared-state re-read.
  private func emitHotkeyPressed(
    _ action: PressAction, trigger: PressTrigger, windowTiming: String? = nil,
    decidedUnder press: RecordGestureEngine.Press? = nil
  ) {
    // #3544: a record press decided by the engine reports the mode and key it was decided under,
    // not whatever the configuration is when main executes it.
    let inputMode = (press?.mode ?? recordingMode).rawValue
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
      case .pasteLast: pasteLastKeyCode
      case .copyLast: copyLastKeyCode
      case .toggle, .ptt: press?.keyCode ?? toggleKeyCode
      }
    let keyShape = ModifierKeyCodes.isModifierOnly(keyCode) ? "modifier_only" : "chord"
    // #1987: same key as key_shape, one level finer. `key_shape` cannot separate
    // Globe from Right Option because both are modifier-only. Content-free class,
    // never the key code itself.
    let keyIdentity = HotkeyKeyIdentity.classify(keyCode: keyCode).rawValue
    telemetry.pressed(
      trigger.rawValue, inputMode, keyShape, keyIdentity, action.rawValue, windowTiming)
  }

  public func start() {
    guard !isEnabled else { return }
    installCarbonEventHandler()
    registerToggleHotkey()
    // `isEnabled` is set BEFORE the reconciler, which reads it: the rule it enforces is "not while
    // stopped or suspended", and a reconciler run against a service that has not yet admitted it is
    // running would refuse the registration it was called to make.
    isEnabled = true
    reconcileAppShortcutRegistrations()
    installKeyboardListener()
    // Cancel hotkey is NOT registered here — only during recording
  }

  public func stop() {
    unregisterCancelHotkey()
    unregisterAppShortcuts()
    unregisterToggleHotkey()
    removeCarbonEventHandler()
    removeKeyboardListener(reason: "stop")
    isEnabled = false
    engine.forgetHeld()
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
    unregisterAppShortcuts()
    unregisterToggleHotkey()
    removeKeyboardListener(reason: "suspend")
    isSuspended = true
  }

  /// Re-register hotkeys after the recorder is done.
  public func resume() {
    guard isEnabled, isSuspended else { return }
    engine.forgetHeld()
    performCleanup()
    registerToggleHotkey()
    // No armed-state snapshot, unlike cancel: Quick Add is armed whenever the service is, so
    // restoring it is unconditional and there is nothing that could outlive its own recording.
    // WHETHER it may hold its chord is still the reconciler's call, because a recording can be in
    // flight and cancel may own that chord — `resume()` re-arms cancel two lines below.
    isSuspended = false
    reconcileAppShortcutRegistrations()
    installKeyboardListener()
    if cancelArmedBeforeSuspend { registerCancelHotkey() }
    cancelArmedBeforeSuspend = false
  }

  /// Register the cancel hotkey. Call on `.recording` entry.
  ///
  /// Arms the role for BOTH dispatch mechanisms. A chord goes to Carbon exactly
  /// as before; a bare modifier cannot be registered with Carbon at all, so for
  /// that shape arming is the flag alone and the already-installed keyboard
  /// listener does the observing. Before #1991 this called `registerHotkey`
  /// unconditionally, so a bare-modifier cancel key was handed to Carbon, failed,
  /// reported a registration failure, and left the user with a key that is
  /// stored, displayed, and inert.
  public func registerCancelHotkey() {
    isCancelArmed = true
    // Quick Add yields FIRST, before cancel asks Carbon. `RegisterEventHotKey` refuses a duplicate
    // chord, and Quick Add is registered at `start()` and holds its registration for the whole
    // session — so with both bound to one chord, cancel arrives second, is refused, and the user's
    // cancel key opens the Quick Add panel while the recording keeps running.
    reconcileAppShortcutRegistrations()
    guard cancelBinding.isCarbonRegistrable else { return }
    guard cancelHotkeyToken == nil else { return }
    cancelHotkeyToken = registerHotkey(
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
    forgetHotkey(&cancelHotkeyToken, role: .cancel)
    // Cancel has released the chord, so Quick Add may have it back. Unconditional rather than
    // guarded on a collision: the reconciler decides, and asking the question here as well would be
    // the same rule written twice.
    reconcileAppShortcutRegistrations()
  }

  /// Whether the pipeline is running a session now (`PipelineState.isActive`), reported on every
  /// lifecycle transition (#3544 P4). A record press made while one runs joins it, so other-key
  /// interference never ends it and the press keeps its stop and lock.
  public func setRecordingActive(_ active: Bool) {
    engine.setRecordingActive(active)
  }

  /// The start running now found a session already running and joined it (#3544 P4), although its
  /// press was classified before that session began: called by `onStartRecording` before it
  /// returns, so interference from here on spares the joined session and the press keeps its stop.
  package func markExecutingStartJoined() {
    guard let attempt = executingAttemptID else { return }
    engine.markJoined(attempt: attempt)
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
  /// or back — which moves it between Carbon and the keyboard listener. The
  /// listener needs nothing redone: it classifies every key under the bindings
  /// `configureEngine()` already published.
  ///
  /// Safe while idle: it preserves `isCancelArmed`, so this cannot arm a cancel
  /// key for a recording that is not running.
  package func reapplyCancelBinding() {
    guard isEnabled, !isSuspended else { return }
    let wasArmed = isCancelArmed
    unregisterCancelHotkey()
    if wasArmed { registerCancelHotkey() }
  }

  /// Reset all hands-free state. Called before every stop/cancel callback
  /// and on service stop/resume.
  ///
  /// #3544 P1: the unconditional engine reset belongs to MAIN-originated endings only (the
  /// explicit cancel hotkey, `stop()`, `resume()`); it drops every decision queued before it.
  /// Endings the engine decided itself (triple cancel, locked stop, lone-tap stop, hold stop)
  /// already cleaned the gesture and call `clearExecutionState()` alone, so a stop executed late
  /// can never erase a newer gesture.
  private func performCleanup() {
    // Main state first: `reset()` drains synchronously, and a decision applied by that drain
    // (a fresh attempt ingested from a callback) must not be cleared after it.
    clearExecutionState()
    engine.reset()
  }

  /// Main's half of a cleanup.
  private func clearExecutionState() {
    // #1631: acceptance must never outlive the attempt that earned it, or a later
    // press could inherit it and publish on a session it never started.
    acceptedStartPressID = nil
    acceptedSessionID = nil
    executingAttemptID = nil
    lockIntentAttemptID = nil
  }

  /// Refuse one attempt (#1631 `.noRecording`, publication rejected, processing): its queued
  /// decisions are dropped; a newer attempt is untouched.
  private func refuseAttempt(_ attemptID: UInt64) {
    if executingAttemptID == attemptID { clearExecutionState() }
    engine.reset(attempt: attemptID)
  }

  /// Push the record binding, mode and every role's binding to the engine (#3544): the gesture reads
  /// the first two, the listener classifies keys under all of them. Every assignment, changed or
  /// not; the engine starts a new listener generation only on an actual change.
  private func configureEngine() {
    engine.configure(bindings: bindings, mode: recordingMode)
  }

  /// #3534 §3.3: the one place the stop-timer measurement is voided. Called from
  /// `performCleanup`, actual mode and binding changes, and `removeKeyboardListener` (which
  /// every stop, suspend, storm and reinstall passes through).
  private func invalidateQuickTapDiagnostics() {
    engine.invalidateDiagnostics()
  }

  #if DEBUG
    /// #3534 §10 DEBUG timing trace. Every value is captured by the caller before this
    /// returns; the log write is asynchronous, so line order is not event order: read the
    /// captured times. A stop REQUEST and a lock INTENT are not a finished recording.
    private func traceTiming(_ line: String) {
      Task {
        await AppLogger.shared.log("[timing] \(line)", level: .info, category: "HotkeyService")
      }
    }

    private static func traceSeconds(_ value: TimeInterval?) -> String {
      value.map { String(format: "%.3f", $0) } ?? "nil"
    }
  #endif

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
    // A dismissed attempt's session is remembered whatever replaced its execution state since.
    if pendingDismissals.contains(pressID), case .recording(let sessionID) = outcome {
      dismissedSessions[pressID] = sessionID
    }
    guard pressID == executingAttemptID else { return }
    switch outcome {
    case .recording(let sessionID):
      acceptedStartPressID = pressID
      acceptedSessionID = sessionID
      publishLockIfReady()
      noticeSecureInputIfRelevant(sessionID)
    case .noRecording:
      // Only a press that already recorded hands-free intent has a decision to
      // report; a refusal landing before the second tap has nothing to resolve.
      if lockIntentAttemptID == pressID {
        emitLockResolved(committed: false, reason: .startProducedNoRecording)
      }
      refuseAttempt(pressID)
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
    guard let attemptID = executingAttemptID,
      lockIntentAttemptID == attemptID,
      acceptedStartPressID == attemptID,
      let sessionID = acceptedSessionID
    else { return }
    let result = onLockRequested?(sessionID) ?? .unavailable
    #if DEBUG
      let traced: String =
        switch result {
        case .published: "published"
        case .notLockable: "not_lockable"
        case .unavailable: "unavailable"
        }
      traceTiming("lock_publication press=\(attemptID) result=\(traced)")
    #endif
    switch result {
    case .published:
      emitLockResolved(committed: true, reason: .published)
    case .notLockable:
      emitLockResolved(committed: false, reason: .notLockableAtPublication)
      refuseAttempt(attemptID)
    case .unavailable:
      emitLockResolved(committed: false, reason: .publicationUnavailable)
      refuseAttempt(attemptID)
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
  package var onStartResolvedForTesting: (@MainActor () -> Void)?

  /// #3534 test seam — invoked once per lone-tap wait, on every exit path
  /// (cancelled, stale, locked, stopped), so a test learns the timer finished
  /// from the subject rather than from a guess. Test-only; production never sets it.
  /// #3544: delivered through the engine's ordered outbox, after any stop it decided.
  package var onDebounceResolvedForTesting: (@MainActor () -> Void)?

  // periphery:ignore - test seam
  package func awaitInFlightStartForTesting() async {
    await recordingTask?.value
  }

  /// #3544 test seam: apply every decision the engine has queued (a lone-tap stop the timer
  /// decided), through the production application path.
  package func drainGestureForTesting() {
    engine.drainForTesting()
  }

  // MARK: - Hands-Free State Machine

  /// Unified PTT + hands-free state machine.
  /// Called by `handleCarbonHotkey` for push-to-talk chord press/release events; the listener feeds
  /// bare-modifier record input to the engine directly (`ingestFromListener`).
  /// #3544 P1: the engine decides; `execute(_:valid:)` runs the decisions on this turn (A1).
  private func handleRecordAction(isPress: Bool, input: RecordGesture.InputTime) {
    engine.ingestOnMain(isPress: isPress, input: input)
  }

  /// Execute one batch of engine decisions on the main thread, in order (#3544 P1).
  private func execute(_ batch: RecordGestureEngine.Batch, valid: Bool) {
    for effect in batch.effects {
      if case .loneTapResolved = effect {
        onDebounceResolvedForTesting?()
        continue
      }
      // The one invalidation rule (plan §3.4): an older epoch or a refused attempt, re-read per
      // effect because an earlier effect in this batch may have reset or refused.
      guard valid, engine.isValid(batch) else { continue }
      switch effect {
      case .press(let press): executePress(press, attemptID: batch.attemptID)
      case .holdStop: executeHoldStop()
      case .quickRelease(let trace): executeQuickRelease(trace)
      case .loneTapStop(let trace): executeLoneTapStop(trace)
      case .cancel(let cancel): executeListenerCancel(cancel)
      case .dismiss(let dismiss): executeListenerDismiss(dismiss)
      case .loneTapResolved: break
      }
    }
  }

  /// The listener's bare cancel, decided by the engine in input order (#3544 P3). The engine
  /// already ended the attempt it captured; main runs the same cancel as the Carbon cancel chord,
  /// except that it clears execution state only for that attempt, so a newer attempt decided
  /// after the cancel keeps its start. Disarming here is what lets the key's next press belong to
  /// a lower role; the key's own release never re-enters (its route in `KeyboardListenerIngress`
  /// is cancel, which ends nowhere).
  private func executeListenerCancel(_ cancel: RecordGestureEngine.Cancel) {
    // The recording that armed it may have ended since the key was pressed; then there is
    // nothing to cancel, and the engine's ending of an attempt that no longer records is moot.
    guard isCancelArmed else { return }
    isCancelArmed = false
    if executingAttemptID == cancel.attemptID { clearExecutionState() }
    listenerCancellationTask = Task { [weak self] in
      guard let self else { return }
      await self.onCancelRecording?()
    }
    emitHotkeyPressed(.cancel, trigger: .cancel)
  }

  /// Other-key interference ended this attempt in the engine (#3544 P4, D2). Main ends the
  /// recording that attempt's start produced, once that start has resolved, and nothing else: a
  /// start main never issued (refused, replaced) has nothing to end, and the session check in
  /// `onDismissRecording` keeps a newer take safe. A press after this waits for it, as after a
  /// listener cancel (`listenerCancellationTask`).
  private func executeListenerDismiss(_ dismiss: RecordGestureEngine.Dismiss) {
    let attempt = dismiss.attemptID
    guard executingAttemptID == attempt else { return }
    pendingDismissals.insert(attempt)
    if acceptedStartPressID == attempt, let sessionID = acceptedSessionID {
      dismissedSessions[attempt] = sessionID
    }
    clearExecutionState()
    let start = recordingTask
    let earlier = listenerCancellationTask
    listenerCancellationTask = Task { [weak self] in
      await earlier?.value
      await start?.value
      guard let self else { return }
      self.pendingDismissals.remove(attempt)
      guard let sessionID = self.dismissedSessions.removeValue(forKey: attempt) else { return }
      await self.onDismissRecording?(sessionID)
    }
  }

  private func executePress(_ press: RecordGestureEngine.Press, attemptID: UInt64) {
    let input = press.input
    if let pressedMs = press.afterStopTimerMs {
      Task {
        await AppLogger.shared.log(
          "Second press arrived after the lone-tap stop (pressed \(pressedMs)ms after first)",
          level: .info, category: "HotkeyService"
        )
      }
    }
    // #3534 §3.3: offered once, BEFORE the processing guard, so a refused press can carry it.
    // Only the `start` and `ignored_processing` rows below attach it; any other role drops it.
    let afterStopTimer: String? = press.afterStopTimerMs != nil ? "after_stop_timer" : nil

    // Anti-spam Layer 1: Block new recordings while pipeline is processing.
    // #3544 P1 (plan §3.5, D3): checked when each press-derived decision EXECUTES; a refusal
    // refuses that attempt, so its later decisions are dropped and a newer attempt is untouched.
    if let isProcessing = onIsProcessing, isProcessing() {
      Task {
        await AppLogger.shared.log(
          "Key press ignored — pipeline is still processing",
          level: .info, category: "HotkeyService"
        )
      }
      // #1175 (C3): a press that never commits is exactly an under-fire case.
      emitHotkeyPressed(.ignoredProcessing, trigger: .ptt, windowTiming: afterStopTimer, decidedUnder: press)
      refuseAttempt(attemptID)
      engine.forgetHeld(ifNoInputAfter: press.inputSequence)
      return
    }

    switch press.decision {
    case .start(let pressID):
      // #1631: a fresh attempt owns a fresh identity, and inherits no acceptance.
      clearExecutionState()
      executingAttemptID = pressID
      recordingTask?.cancel()
      let pendingCancellation = listenerCancellationTask
      recordingTask = Task { [weak self] in
        guard let self else { return }
        // A listener cancel decided before this press finishes first (see
        // `listenerCancellationTask`); if this start was replaced meanwhile, the newer one owns it.
        if let pendingCancellation {
          self.onListenerCancellationWaitForTesting?()
          await pendingCancellation.value
          guard !Task.isCancelled, self.executingAttemptID == pressID else { return }
        }
        guard let handler = press.joinsRecording ? self.onJoinRecording : self.onStartRecording
        else {
          // No callback wired means nothing was recorded, so the optimistic
          // bookkeeping is exactly as wrong here as on any other refusal.
          self.resolveStart(pressID: pressID, outcome: .noRecording)
          return
        }
        var outcome = await handler()
        // #3544 P4: the session this press was to join ended before main ran it (a stop the engine
        // never saw: menu, window, auto-stop, cap). With no ordinary key held at the press, a
        // fresh take is what the press would have been, so start one rather than drop it.
        if press.joinsRecording, press.mayStartIfJoinFails, outcome == .noRecording,
          !Task.isCancelled, self.executingAttemptID == pressID,
          let start = self.onStartRecording
        {
          self.engine.unmarkJoined(attempt: pressID)
          outcome = await start()
        }
        self.resolveStart(pressID: pressID, outcome: outcome)
      }
      // #1175 (C3): emit AFTER the recording Task is created; the `.live` sink
      // defers the actual write off this turn so it never delays the callback.
      emitHotkeyPressed(.start, trigger: .ptt, windowTiming: afterStopTimer, decidedUnder: press)

    case .tripleCancel:
      Task {
        await AppLogger.shared.log(
          "Triple press — cancelling hands-free recording",
          level: .info, category: "HotkeyService"
        )
      }
      clearExecutionState()
      recordingTask?.cancel()
      recordingTask = Task { await onCancelRecording?() }
      // #1175 (Codex code-diff #2): hands-free triple-press cancel is an
      // accepted keydown too — distinguished from the Escape cancel by trigger.
      emitHotkeyPressed(.cancel, trigger: .ptt, decidedUnder: press)

    case .lockIntent(let windowTiming, let elapsedMs, let usesOccurrence):
      Task {
        await AppLogger.shared.log(
          // #1631: this records the REQUEST. Whether it becomes a lock is not
          // known yet — `Hands-free mode activated` is logged by the publisher.
          "Double press — requesting hands-free mode",
          level: .info, category: "HotkeyService"
        )
      }
      #if DEBUG
        traceTiming(
          "lock_intent press=\(attemptID) press_handled=\(Self.traceSeconds(input.handled)) "
            + "press_occurred=\(Self.traceSeconds(input.occurred)) "
            + "clock=\(usesOccurrence ? "occurrence" : "handling") "
            + "elapsed_ms=\(elapsedMs) window_timing=\(windowTiming)")
      #endif
      lockIntentAttemptID = attemptID
      // DO NOT cancel recordingTask here — the pipeline startup must
      // continue running. Cancelling it aborts preWarm/toggleRecording,
      // leaving the UI locked but no actual recording happening.
      // #1631: intent is recorded above; publication happens only if this
      // press's start has already confirmed a session that is still running.
      // If it has not yet, `resolveStart` publishes when it does.
      publishLockIfReady()
      emitHotkeyPressed(.lock, trigger: .ptt, windowTiming: windowTiming, decidedUnder: press)

    case .ignoredCooldown(let sinceLockMs):
      Task {
        await AppLogger.shared.log(
          "Press ignored — lock cooldown (\(sinceLockMs)ms since lock)",
          level: .info, category: "HotkeyService"
        )
      }
      // #1175 (Codex code-diff #2): a cooldown finger-bounce is an accepted
      // keydown that produces no recording action.
      emitHotkeyPressed(.ignoredCooldown, trigger: .ptt, decidedUnder: press)
      // D2: the base cleared the held key after this row; skip it if a later input already moved
      // the key.
      engine.forgetHeld(ifNoInputAfter: press.inputSequence)

    case .stopLocked:
      Task {
        await AppLogger.shared.log(
          "Single press while locked — stopping hands-free recording",
          level: .info, category: "HotkeyService"
        )
      }
      clearExecutionState()
      recordingTask?.cancel()
      recordingTask = Task { await onStopRecording?() }
      // #1175 (Codex code-diff #2): single press while locked stops the session.
      emitHotkeyPressed(.stop, trigger: .ptt, decidedUnder: press)

    case .lateAfterWindow(let afterFirstMs):
      Task {
        await AppLogger.shared.log(
          "Second press after the double-tap window (\(afterFirstMs)ms after first)",
          level: .info, category: "HotkeyService"
        )
      }
      emitHotkeyPressed(.lateAfterWindow, trigger: .ptt, decidedUnder: press)
    }
  }

  /// Normal PTT release (held > 500ms) → stop immediately.
  private func executeHoldStop() {
    clearExecutionState()
    recordingTask?.cancel()
    recordingTask = Task { await onStopRecording?() }
  }

  private func executeQuickRelease(_ trace: RecordGestureEngine.QuickReleaseTrace) {
    #if DEBUG
      traceTiming(
        "quick_release \(Self.quickTracePrefix(trace)) "
          + "release_occurred=\(Self.traceSeconds(trace.release.occurred)) "
          + "event_deadline=\(Self.traceSeconds(trace.eventDeadline))")
    #endif
  }

  private func executeLoneTapStop(_ trace: RecordGestureEngine.LoneTapStopTrace) {
    Task {
      await AppLogger.shared.log(
        "Debounce timer fired — stopping PTT (no double-press detected)",
        level: .info, category: "HotkeyService"
      )
    }
    // (2) Cleanup, which itself voids the measurement (bumps the epoch): done by the engine.
    clearExecutionState()
    #if DEBUG
      traceTiming(
        "stop_request \(Self.quickTracePrefix(trace.quick)) "
          + "requested_at=\(Self.traceSeconds(trace.requestedAt)) "
          + "attributable=\(trace.attributable) (a stop request, not a finished recording)")
    #endif
    // (4) Queue the normal stop, attributable or not.
    recordingTask?.cancel()
    recordingTask = Task { await onStopRecording?() }
  }

  #if DEBUG
    private static func quickTracePrefix(_ trace: RecordGestureEngine.QuickReleaseTrace) -> String {
      "press=\(trace.attemptID) release_handled=\(traceSeconds(trace.release.handled)) "
        + "deadline=\(traceSeconds(trace.deadline)) "
        + "clock=\(trace.usesOccurrence ? "occurrence" : "handling")"
    }
  #endif

  // MARK: - Carbon Event Handler

  private func installCarbonEventHandler() {
    // The event-type list, the application target and the C trampoline moved into
    // the adapter with the call that used them (#2455 C2). What stays here is the
    // only part that was ever policy: WHEN to install.
    //
    // Occupancy guard, matching every other slot: installing over a live handler
    // would orphan the first one, since the token naming it is about to be
    // overwritten. NOT reachable by calling `start()` twice — that returns early on
    // `isEnabled`. It is reachable when `stop()` KEEPS the token because the adapter
    // refused to remove the handler, and a later `start()` runs; the guard preserves
    // that retryable token instead of losing it.
    guard eventHandlerToken == nil else { return }
    // `[weak self]` because the adapter retains this callback for the life of the
    // handler; a strong capture would be service -> adapter -> callback -> service.
    eventHandlerToken = effects.installCarbonHandler { [weak self] event in
      self?.handleCarbonHotkey(id: event.id, isRelease: event.isRelease, timestamp: event.timestamp)
    }
  }

  // MARK: - Bindings

  /// Which bare-modifier role loses its dispatch if the keyboard listener is missing, or nil when
  /// none is a bare modifier.
  ///
  /// One value, so the most SEVERE loss wins — `ShortcutRole`'s declaration order is that severity
  /// order and its doc comment says so. It asks the CLOSED SET (`ShortcutBindings`) rather than a
  /// list of the roles someone remembered: #1991 and #2381 each shipped a hand-written disjunction
  /// that missed a role (bare-modifier cancel, then Quick Add) and left that shortcut stored,
  /// displayed and inert.
  package var bareModifierRoleAtRisk: ShortcutRole? {
    bindings.bareModifierRoleAtRisk
  }

  /// The binding a role is currently bound to. A switch, so a new role must be given one.
  package func binding(for role: ShortcutRole) -> ShortcutBinding {
    switch role {
    case .record: recordBinding
    case .cancel: cancelBinding
    case .quickAdd: quickAddBinding
    case .pasteLast: .keyboard(keyCode: pasteLastKeyCode, modifiers: pasteLastModifiers)
    case .copyLast: .keyboard(keyCode: copyLastKeyCode, modifiers: copyLastModifiers)
    }
  }

  /// Every role's current binding, the value the matcher reads (#3106).
  package var bindings: ShortcutBindings {
    ShortcutBindings(
      record: recordBinding, cancel: cancelBinding, quickAdd: quickAddBinding,
      pasteLast: binding(for: .pasteLast), copyLast: binding(for: .copyLast))
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

  /// Which roles a press may currently trigger: record whenever the service is, cancel only between
  /// `registerCancelHotkey()` and `unregisterCancelHotkey()`, the app shortcuts always. One owner,
  /// `ShortcutRole.armedRoles(cancelArmed:)`, also read by the listener's classification.
  private var armedRoles: Set<ShortcutRole> {
    ShortcutRole.armedRoles(cancelArmed: isCancelArmed)
  }

  private func removeCarbonEventHandler() {
    release(&eventHandlerToken)
  }

  /// Install the keyboard listener (#3544): the only reader of bare-modifier shortcuts (P3). Every
  /// event passes through to the system. A failure leaves bare-modifier shortcuts silent, as
  /// without Accessibility (plan Architecture DoD); it is reported once and retried while the
  /// service is running and not suspended, at the cadence the app already polls a missing
  /// Accessibility grant (`TimingConstants.accessibilityPollIntervalSec`), the usual cause.
  private func installKeyboardListener() {
    guard isEnabled, !isSuspended else { return }
    listenerRetry?.cancel()
    listenerRetry = nil
    listenerGeneration &+= 1
    let generation = listenerGeneration
    // A listener whose earlier removal was refused (its cleanup ran late) is removed now; until
    // that succeeds no second listener is installed, and the removal is retried.
    if keyboardListenerToken != nil { releaseKeyboardListener(reason: "reinstall") }
    guard keyboardListenerToken == nil else {
      scheduleListenerRetry(generation)
      return
    }
    // A storm stops the installation from the listener's thread; main replaces it.
    let stormed: @Sendable () -> Void = { [weak self] in
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated { self?.listenerStormed(installation: generation) }
      }
    }
    // Secure Input changes are logged on main, never on the listener's thread (plan A2).
    let secureInputSeen: @Sendable (SecureInputObservation) -> Void = { [weak self] observation in
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated {
          self?.listenerSawSecureInput(observation, installation: generation)
        }
      }
    }
    // The ingress belongs to this installation alone: its own tracker, routes and sweep.
    let ingress = KeyboardListenerIngress(
      installation: generation, engine: engine, reader: effects.keyStateReader, clock: uptime,
      scheduler: listenerRetryScheduler,
      toMain: { [weak self] edge in
        DispatchQueue.main.async { [weak self] in
          MainActor.assumeIsolated { self?.handleListenerEdge(edge) }
        }
      })
    let sink: @Sendable (KeyEventValue) -> ListenerVerdict = { event in
      ingress.receive(event)
      if event.kind == .stormStopped { stormed() }
      if let observation = event.secureInput { secureInputSeen(observation) }
      return .passThrough
    }
    listenerInstallAttempts += 1
    // Admission opens before the adapter call: the tap can deliver a press before the call
    // returns, and the engine must own that press or its hold records nothing.
    engine.openListenerAdmission(installation: generation)
    if let token = effects.installKeyboardListener(sink) {
      keyboardListenerToken = token
      listenerFailureReported = false
      listenerInstalls += 1
      keyboardListenerIngress = ingress
      // The new installation's own watchdog covers a hold it never saw down.
      cancelOrphanedHoldCheck()
      ingress.start()
      if listenerFailuresSinceInstall > 0 {
        listenerFailuresSinceInstall = 0
        reportListenerHealth(
          terminal: "none", reason: "installed_after_failures", disableEpisodes: 0, reenables: 0)
      }
      return
    }
    engine.closeListenerAdmission()
    ingress.close()
    listenerInstallFailures += 1
    listenerFailuresSinceInstall += 1
    if !listenerFailureReported {
      listenerFailureReported = true
      telemetry.registrationFailed(
        "event_tap", ShortcutRole.record.telemetryKind, nil,
        recordBinding.isBareModifier ? "modifier_only" : "chord")
    }
    scheduleListenerRetry(generation)
    armOrphanedHoldCheck()
  }

  /// A Secure Input change the listener `installation` observed (plan A2). Logged only; no take is
  /// ended, cancelled or locked by it (bare modifiers keep arriving under Secure Input, #3544 P0).
  /// Ignored for an installation that is no longer current.
  private func listenerSawSecureInput(_ observation: SecureInputObservation, installation: UInt64) {
    guard installation == listenerGeneration else { return }
    onSecureInputLoggedForTesting?(observation)
    secureInputOn = observation.enabled
    // A Secure Input period ends here: the next one may tell the user again.
    if !observation.enabled { secureInputNoticeShown = false }
    // Entered during an accepted take whose other-key rule still applies: the same policy as a
    // start. Later in a take the rule no longer applies, so nothing is paused for it.
    if observation.enabled, let sessionID = acceptedSessionID {
      noticeSecureInputIfRelevant(sessionID)
    }
    let owner = observation.ownerPID.map { "pid=\($0)" } ?? "owner=unknown"
    let line = observation.enabled ? "Secure Input on (\(owner))" : "Secure Input off"
    Task {
      await AppLogger.shared.log(line, level: .info, category: "HotkeyService")
    }
  }

  /// #3544 P4 (D4, founder 2026-10-09): a bare push-to-talk dictation just started while Secure
  /// Input is on, so the listener cannot see ordinary keys and the other-key rule (D2) is paused.
  /// Told once per Secure Input period (until it is observed off), for the session that start
  /// produced. State comes from the listener's own sampling (at install, then every 5 s), never
  /// from a hidden key or a guessed app; a period younger than one sample is not yet known.
  private func noticeSecureInputIfRelevant(_ sessionID: String) {
    // Only while the take's other-key rule still applies: a start that resolved late, or a take
    // already locked, has nothing paused.
    guard secureInputOn, !secureInputNoticeShown, recordBinding.isBareModifier,
      recordingMode == .pushToTalk, isEnabled, !isSuspended,
      engine.otherKeyRuleApplies(at: uptime())
    else { return }
    // Counted as told only when the presentation accepted it, so a refused one (a session no
    // longer running) leaves the period's notice for the next valid take.
    if onSecureInputPausedKeyFeatures?(sessionID) == true { secureInputNoticeShown = true }
  }

  /// #3544 P4: show the Secure Input notice on the recording session `String` started, if it is
  /// still the one running; returns whether it was shown. The `String` is the opaque token
  /// `onLockRequested` receives.
  package var onSecureInputPausedKeyFeatures: (@MainActor (String) -> Bool)?

  /// Test seam: a main-thread listener edge was judged current (true) or refused (false), before
  /// it acts. Production never sets it.
  package var onListenerEdgeHandledForTesting:
    (@MainActor (KeyboardListenerIngress.MainEdge, Bool) -> Void)?

  /// Test seam: a Secure Input observation was accepted for logging. Production never sets it.
  package var onSecureInputLoggedForTesting: (@MainActor (SecureInputObservation) -> Void)?

  /// The listener `installation` stopped itself after a disable storm. Remove it (its final health
  /// is accounted then) and install a fresh one after the cooldown. Ignored for an installation
  /// that is no longer current: a stop, suspend or reinstall already replaced it.
  private func listenerStormed(installation: UInt64) {
    guard installation == listenerGeneration, keyboardListenerToken != nil else { return }
    removeKeyboardListener(reason: "storm")
    // Validated when it fires: a stop, suspend or reinstall in between moves the generation on.
    scheduleListenerRetry(listenerGeneration, after: Self.listenerStormCooldown)
    armOrphanedHoldCheck()
  }

  /// Arm the orphaned-hold check: with no listener ingress (none installed, or a removal the OS
  /// refused, whose input is no longer admitted), nothing else can see the record
  /// key come up, so a push-to-talk recording would run on until a replacement's first sweep
  /// (after the storm cooldown) or, while installs keep failing, until the recording cap.
  private func armOrphanedHoldCheck() {
    // Only a press a reading may end is worth watching (#3544 P4 C2): an aggregate-only hold ends
    // on observed input, an explicit stop or cancel, or the recording cap.
    guard orphanedHoldCheck == nil, keyboardListenerIngress == nil, isEnabled, !isSuspended,
      engine.ownedListenerPress?.recovery == .readable
    else { return }
    orphanedHoldCheckToken &+= 1
    let token = orphanedHoldCheckToken
    orphanedHoldCheck = listenerRetryScheduler(KeyboardListenerIngress.sweepInterval) {
      [weak self] in
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated { self?.orphanedHoldCheckFired(token: token) }
      }
    }
  }

  private func cancelOrphanedHoldCheck() {
    orphanedHoldCheck?.cancel()
    orphanedHoldCheck = nil
    orphanedHoldReadUp = nil
  }

  private func orphanedHoldCheckFired(token: UInt64) {
    // Cancelled since it was armed (an install succeeded, or a stop or suspend removed it).
    guard token == orphanedHoldCheckToken, orphanedHoldCheck != nil else { return }
    orphanedHoldCheck = nil
    guard keyboardListenerIngress == nil, isEnabled, !isSuspended,
      let press = engine.ownedListenerPress, press.recovery == .readable
    else { return }
    // Two consecutive up readings about the SAME attempt; a newer press of the key starts over.
    let readUp = effects.keyStateReader([press.keyCode])[press.keyCode] == .up
    let confirmed = readUp && orphanedHoldReadUp == press
    orphanedHoldReadUp = readUp && !confirmed ? press : nil
    if confirmed {
      engine.releaseOrphanedListenerPress(
        press, input: RecordGesture.InputTime(handled: uptime(), occurred: nil))
      onOrphanedHoldReleasedForTesting?()
      return
    }
    armOrphanedHoldCheck()
  }

  /// Test seam: the orphaned-hold check ended a hold. Production never sets it.
  package var onOrphanedHoldReleasedForTesting: (@MainActor () -> Void)?

  /// Release the listener's token. When the removal is confirmed, its final health is read and
  /// accounted, once: a refused removal keeps the token, and is accounted when a later release
  /// succeeds. Returns that final health.
  @discardableResult
  private func releaseKeyboardListener(reason: String) -> KeyboardListenerHealth? {
    guard let token = keyboardListenerToken else {
      // No listener to release, but a failure episode still open (installs kept failing and
      // shortcuts are now stopping or suspending): report it once, so the totals leave the app.
      if listenerFailuresSinceInstall > 0 {
        listenerFailuresSinceInstall = 0
        reportListenerHealth(
          terminal: "start_failed", reason: reason, disableEpisodes: 0, reenables: 0)
      }
      return nil
    }
    release(&keyboardListenerToken)
    guard keyboardListenerToken == nil, let health = effects.keyboardListenerHealth(token) else {
      return nil
    }
    // Rare failure only: a healthy installation reports nothing.
    if health.disableEpisodes > 0 || health.terminal == .disableStorm {
      reportListenerHealth(
        terminal: health.terminal == .disableStorm ? "disable_storm" : "removed", reason: reason,
        disableEpisodes: health.disableEpisodes, reenables: health.reenables)
    }
    return health
  }

  private func reportListenerHealth(
    terminal: String, reason: String, disableEpisodes: Int, reenables: Int
  ) {
    telemetry.listenerHealth(
      HotkeyListenerHealthReport(
        terminal: terminal, reason: reason, disableEpisodes: disableEpisodes,
        reenables: reenables, installAttempts: listenerInstallAttempts,
        installFailures: listenerInstallFailures, installs: listenerInstalls))
  }

  /// Try the install again later, for this installation attempt only.
  private func scheduleListenerRetry(
    _ generation: UInt64, after delay: TimeInterval = TimingConstants.accessibilityPollIntervalSec
  ) {
    // Weak at every level: a pending retry must not keep a released service alive.
    listenerRetry = listenerRetryScheduler(delay) {
      [weak self] in
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated {
          guard let self else { return }
          // Test seam: signalled on every exit of a retry that reached main.
          defer { self.onListenerRetryResolvedForTesting?() }
          guard self.listenerGeneration == generation else { return }
          self.listenerRetry = nil
          self.installKeyboardListener()
        }
      }
    }
  }

  /// Remove the keyboard listener and retire any pending retry. A refused removal keeps the
  /// token, so no replacement is installed while the old tap may still be live.
  private func removeKeyboardListener(reason: String) {
    listenerRetry?.cancel()
    listenerRetry = nil
    cancelOrphanedHoldCheck()
    listenerGeneration &+= 1
    // No input from this installation is admitted from now on, even a callback still finishing:
    // the engine refuses it, and its ingress stops acting and retires its sweep.
    engine.closeListenerAdmission()
    keyboardListenerIngress?.close()
    keyboardListenerIngress = nil
    // Unknown until the next installation's first sample.
    secureInputOn = false
    // A bare-modifier action held now (Paste Last, Copy Last) can no longer see its release: the
    // next installation's tracker starts empty. Retire the hold without firing it, so the next
    // press acts (and Paste takes a fresh target); Carbon chord holds are not the listener's.
    appShortcutsHeld = appShortcutsHeld.filter { $0.value == .chord }
    // #3534 §3.3: an ingress teardown voids the stop-timer measurement (diagnostic only).
    invalidateQuickTapDiagnostics()
    #if DEBUG
      let removing = keyboardListenerToken
    #endif
    // Remove first: once the adapter confirms, no callback for this installation is running.
    let finalHealth = releaseKeyboardListener(reason: reason)
    #if DEBUG
      // Callback cost, read after removal so the final callback is counted; complete only when the
      // removal was confirmed (a refused one leaves the listener running).
      if let removing, let health = finalHealth ?? effects.keyboardListenerHealth(removing) {
        let line = Self.listenerHealthLine(
          reason: reason, health, complete: keyboardListenerToken == nil)
        Task { await AppLogger.shared.log(line, level: .info, category: "HotkeyService") }
      }
    #else
      _ = finalHealth
    #endif
  }

  #if DEBUG
    /// One `[listener] health` line per removed installation: whole-callback cost from entry to
    /// return, excluding the one histogram increment that records it.
    package static func listenerHealthLine(
      reason: String, _ h: KeyboardListenerHealth, complete: Bool
    ) -> String {
      let terminal = h.terminal.map { "\($0)" } ?? "running"
      var line =
        "[listener] health reason=\(reason) terminal=\(terminal) "
        + "disable_episodes=\(h.disableEpisodes) reenables=\(h.reenables)"
      if let c = h.cost {
        line +=
          " cost_subject=callback_entry_to_return_excluding_recording cost_unit=ns "
          + "samples=\(c.samples) max=\(c.maxNanoseconds) "
          + "p99_bucket=[\(c.p99LowerNanoseconds),\(c.p99UpperNanoseconds)) "
          + "recording_uncontended_mean=\(c.recordingNanoseconds) complete=\(complete)"
      } else {
        line += " cost=no_samples"
      }
      return line
    }
  #endif

  // MARK: - Registration Helpers

  private func registerToggleHotkey() {
    unregisterToggleHotkey()
    // Modifier-only hotkeys are handled by the keyboard listener —
    // Carbon RegisterEventHotKey cannot register a bare modifier key. Asked
    // through the binding, the same way the cancel path asks it: two spellings
    // of one question is how the record and cancel paths drifted apart in the
    // first place.
    guard recordBinding.isCarbonRegistrable else { return }
    toggleHotkeyToken = registerHotkey(
      id: HotkeyID.toggle.rawValue,
      keyCode: toggleKeyCode,
      modifiers: carbonModifiers(from: toggleModifiers)
    )
  }

  private func unregisterToggleHotkey() {
    forgetHotkey(&toggleHotkeyToken, role: .record)
  }

  /// The always-armed app shortcuts, most severe first.
  private static let appShortcutRoles: [ShortcutRole] = [.quickAdd, .pasteLast, .copyLast]

  /// The ONE place that decides which app shortcuts hold their Carbon chords (#2381, #3106).
  ///
  /// Asked through the BINDING, exactly as the toggle and cancel paths ask it — a bare modifier
  /// cannot go to Carbon, and for that shape the already-installed keyboard listener observes it
  /// instead. Two spellings of that question is how the record and cancel paths drifted apart.
  ///
  /// **A shared chord is a policy question, and the event-tap path already answered it while the
  /// Carbon path had no answer at all.** `ShortcutMatcher.role(forBareModifierKeyCode:...)` checks
  /// Quick Add after Record and Cancel precisely because it is less severe than both
  /// (`ShortcutRole`'s declaration order is severity order, and load-bearing). This is the same
  /// ruling for the other dispatch mechanism: a higher role outranks Quick Add on a chord they
  /// share, cancel for as long as it is armed.
  ///
  /// Every caller that used to call `registerQuickAddHotkey()` calls this instead, so the rule lives
  /// in one function rather than being asked again at each site — which is how the three shortcut
  /// defaults came to disagree in the first place (#1991 blocker 2, reproduced during this build).
  ///
  /// #3106: every refusal is applied BEFORE any grant, so a registration a role must give up is
  /// released before another role asks Carbon for the same chord.
  private func reconcileAppShortcutRegistrations() {
    let decisions = Self.appShortcutRoles.map { ($0, mayRegisterAppShortcut($0)) }
    for (role, may) in decisions where !may {
      releaseAppShortcut(role)
      // A press already seen belongs to a registration this role no longer holds; its release must
      // not fire into a chord another role now owns.
      appShortcutsHeld[role] = nil
    }
    for (role, may) in decisions where may { registerAppShortcut(role) }
  }

  /// Whether `role` may hold its chord now: the arbitration ruling, plus, for Paste Last and Copy
  /// Last, an installed action.
  private func mayRegisterAppShortcut(_ role: ShortcutRole) -> Bool {
    guard
      Self.mayHoldItsChord(
        role, isEnabled: isEnabled, isSuspended: isSuspended, bindings: bindings, armed: armedRoles)
    else { return false }
    switch role {
    case .quickAdd: return true
    case .pasteLast: return onPasteLast != nil
    case .copyLast: return onCopyLast != nil
    case .record, .cancel: return false
    }
  }

  /// The decision itself, pure.
  ///
  /// Split out for the same reason `SelectionReader.refusalBeforeReading` is: the surrounding
  /// function talks to Carbon, and a rule reachable only through `RegisterEventHotKey` is a rule no
  /// test can state. Every branch here is one a user can produce by rebinding a shortcut.
  ///
  /// #3106: generalised from `quickAddMayHoldItsChord` to any role, over `ShortcutMatcher
  /// .mayHoldCarbonChord`, which owns the ruling and the reasons for it.
  package static func mayHoldItsChord(
    _ role: ShortcutRole, isEnabled: Bool, isSuspended: Bool,
    bindings: ShortcutBindings, armed: Set<ShortcutRole>
  ) -> Bool {
    guard isEnabled, !isSuspended else { return false }
    // Cancel outranks Quick Add on a shared chord, for as long as cancel is armed — the same
    // severity order `ShortcutRole` declares and the bare-modifier matcher already applies.
    //
    // `ShortcutMatcher` owns the comparison. It was written there and asked again here with
    // `==`, and the note above `ownsItsBinding` records that as a defect on this path
    // rather than that one.
    return ShortcutMatcher.mayHoldCarbonChord(role, in: bindings, armed: armed)
  }

  /// Pure mechanism, no policy: `reconcileAppShortcutRegistrations` above decides whether to call it.
  private func registerAppShortcut(_ role: ShortcutRole) {
    guard let id = HotkeyID(appShortcut: role) else { return }
    let binding = binding(for: role)
    // A registration still held for an OLD binding is one whose removal Carbon refused. Retry it
    // here, so the next reconcile (a recording starting or ending, a resume) recovers the new
    // chord instead of leaving it dead until the user rebinds again.
    if appShortcutTokens[role] != nil, appShortcutRegisteredBindings[role] != binding {
      releaseAppShortcut(role)
    }
    guard binding.isCarbonRegistrable, appShortcutTokens[role] == nil,
      case .keyboard(let keyCode, let modifiers) = binding
    else { return }
    appShortcutTokens[role] = registerHotkey(
      id: id.rawValue, keyCode: keyCode, modifiers: carbonModifiers(from: modifiers))
    if appShortcutTokens[role] != nil { appShortcutRegisteredBindings[role] = binding }
  }

  /// Release `role`'s registration. The recorded binding goes only with the token: if Carbon refused
  /// the removal, the old chord is still registered and must stay named as the old chord. Quick Add
  /// keeps its pre-#3106 behaviour (`forgetHotkey`); its dispatch has no binding gate yet (#3108).
  private func releaseAppShortcut(_ role: ShortcutRole) {
    if role == .quickAdd {
      forgetHotkey(&appShortcutTokens[role], role: role)
      appShortcutRegisteredBindings[role] = nil
      return
    }
    release(&appShortcutTokens[role])
    guard appShortcutTokens[role] != nil else {
      appShortcutRegisteredBindings[role] = nil
      registeredChords[role] = nil
      return
    }
    Task {
      await AppLogger.shared.log(
        "App shortcut removal refused: role=\(role.rawValue); the old chord stays inert, retried on the next reconcile",
        level: .info, category: "HotkeyService")
    }
  }

  private func unregisterAppShortcuts() {
    for role in Self.appShortcutRoles { releaseAppShortcut(role) }
    appShortcutsHeld.removeAll()
  }

  /// Re-apply an app shortcut's binding after the user changes it (#2381 for Quick Add; #3106 for
  /// Paste Last and Copy Last).
  ///
  /// The binding can change SHAPE — chord to bare modifier or back — which moves it between Carbon
  /// and the keyboard listener. Carbon needs re-registering here; the listener already classifies
  /// every key under the bindings `configureEngine()` published, so a new bare-modifier shape is
  /// observed at once (#1991's failure was a shortcut stored, displayed and inert).
  package func reapplyAppShortcutBinding(_ role: ShortcutRole) {
    // The old chord's registration must go first: the token still holds it.
    releaseAppShortcut(role)
    appShortcutsHeld[role] = nil
    // The reconciler owns both questions the two guards below used to ask separately — may we
    // register at all, and may we hold THIS chord. Rebinding Quick Add onto the cancel chord during
    // a recording is exactly the case a bare `registerQuickAddHotkey()` here would get wrong.
    reconcileAppShortcutRegistrations()
  }

  /// A Carbon key chord, stored in CARBON's own modifier representation
  /// (`carbonModifiers`, the `UInt32` `registerHotkey` already receives) rather than
  /// `NSEvent.ModifierFlags`, because only the forward conversion (`carbonModifiers(from:)`
  /// below) exists — comparing in Carbon's shape needs no new, unproven inverse. #3273.
  package struct ConflictedHotkey: Hashable, Sendable {
    package let keyCode: UInt16
    package let carbonModifiers: UInt32
  }

  private static let hotKeyExistsStatus: Int32 = -9878  // Carbon eventHotKeyExistsErr

  /// The chord each role's live Carbon registration holds. Only lets `forgetHotkey` name the chord
  /// it is dropping, because the role's saved binding may already have moved on by then.
  private var registeredChords: [ShortcutRole: ConflictedHotkey] = [:]

  /// Chords this process may still hold in Carbon although no token names them: a `forgetHotkey`
  /// removal Carbon REFUSED (pre-existing, tracked by #3108), or a registration Carbon accepted
  /// without a token. `eventHotKeyExistsErr` documents "already registered in this process", so a
  /// -9878 for one of these chords, from ANY role, can be our own doing and must not be shown as
  /// a conflict with something outside this process. Cleared when Carbon accepts a registration for that same chord.
  private var possiblyRetainedChords: Set<ConflictedHotkey> = []

  /// Every role whose MOST RECENT Carbon registration attempt was refused with -9878. Carbon
  /// refused this binding; the cause is unknown. #3273 (issue #3266).
  package private(set) var conflictedBindings: [ShortcutRole: ConflictedHotkey] = [:]

  /// True only when `role`'s CURRENTLY SAVED binding is the one that most recently failed — not
  /// merely that the role has ever failed. A role fixed since its last failure, or never yet
  /// attempted on its new binding (Cancel while idle), correctly reads false. This single
  /// read-time check is what clears a stale warning; no separate invalidation write exists.
  package func isCurrentBindingConflicted(_ role: ShortcutRole) -> Bool {
    guard let failed = conflictedBindings[role],
      case .keyboard(let keyCode, let modifiers) = binding(for: role)
    else { return false }
    return failed.keyCode == keyCode && failed.carbonModifiers == carbonModifiers(from: modifiers)
  }

  private func registerHotkey(id: UInt32, keyCode: UInt16, modifiers: UInt32)
    -> DesktopEffectToken?
  {
    // The adapter reports; this module decides (#2455 C2). That split is
    // deliberate: with both sides emitting, one Carbon refusal could produce two
    // `registrationFailed` events or none, depending on which side thought the
    // other had it — the #2381 defect class, one wire signal with two owners.
    let role = HotkeyID(rawValue: id)?.role ?? .record
    let candidate = ConflictedHotkey(keyCode: keyCode, carbonModifiers: modifiers)
    switch effects.registerHotkey(
      id: id, keyCode: keyCode, rawModifiers: UInt64(modifiers))
    {
    case .registered(let token):
      registeredChords[role] = candidate
      possiblyRetainedChords.remove(candidate)
      // #3273: clear a stale external-conflict warning now that this role registered. Guarded
      // (not an unconditional `= nil`) because `@Observable` notifies on assignment regardless of
      // value equality, and `.registered` is the MOST common outcome in ordinary use.
      if conflictedBindings[role] != nil { conflictedBindings[role] = nil }
      return token

    case .refused(let status):
      // #2381: this was `id == cancel ? "cancel" : "toggle"`, which reported a quick-add
      // registration failure as a TOGGLE failure. It now resolves the id to a ROLE and asks the role
      // for its wire name, so the Carbon path and the monitor path below cannot disagree about what
      // a role is called — one owner, `ShortcutRole.telemetryKind`.
      let kind = role.telemetryKind
      let keyShape = ModifierKeyCodes.isModifierOnly(keyCode) ? "modifier_only" : "chord"
      telemetry.registrationFailed("carbon", kind, status, keyShape)
      // #3273: only `eventHotKeyExistsErr` means "already in use" — a different status has a
      // different, unattributed cause and must not carry that specific claim to the user. AND a
      // chord this process holds itself (live token in any role, or possibly retained) is not
      // evidence of an external app and must not be shown as one.
      if status == Self.hotKeyExistsStatus,
        !possiblyRetainedChords.contains(candidate),
        !registeredChords.values.contains(candidate)
      {
        if conflictedBindings[role] != candidate {  // avoid re-notifying on an identical repeat
          conflictedBindings[role] = candidate
        }
      } else if conflictedBindings[role] != nil {
        conflictedBindings[role] = nil  // a DIFFERENT failure reason is not "already in use" any more
      }
      return nil

    case .acceptedWithoutToken:
      // #1175: the noErr-but-silent trap. Carbon accepted the registration and
      // still produced no ref, so the shortcut is registered and delivers
      // nothing. It is NOT a failure — emitting one would put a false alarm into
      // the signal that says a real user's shortcut died — and the caller's
      // occupancy guard sees nil and behaves exactly as it did before C2.
      possiblyRetainedChords.insert(candidate)  // #3273: registered with no token to release it
      if conflictedBindings[role] != nil { conflictedBindings[role] = nil }  // #3273: clear stale warning
      return nil
    }
  }

  // MARK: - Event Dispatch

  /// Called from the Carbon event handler on the main thread for RegisterEventHotKey events.
  ///
  /// `timestamp`: the OS time the event happened, seconds since startup (#3534);
  /// nil when unknown, which keeps handling-time behavior.
  public func handleCarbonHotkey(id: UInt32, isRelease: Bool, timestamp: TimeInterval? = nil) {
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
        queueToggleRecording(listenerInstallation: nil)
        emitHotkeyPressed(.toggle, trigger: .toggle)
      } else {
        // Push-to-talk mode with hands-free support
        handleRecordAction(isPress: !isRelease, input: capture(timestamp))
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

    case HotkeyID.pasteLast.rawValue:
      guard carbonEventIsCurrent(for: .pasteLast) else { return }
      handleLastDictationShortcut(.pasteLast, isPress: !isRelease, hold: .chord)

    case HotkeyID.copyLast.rawValue:
      guard carbonEventIsCurrent(for: .copyLast) else { return }
      handleLastDictationShortcut(.copyLast, isPress: !isRelease, hold: .chord)

    default:
      break
    }
  }

  /// A bare-modifier shortcut edge from the keyboard listener that runs on main (#3544 P3): Quick
  /// Add, Paste Last, Copy Last, and the record key in toggle mode. Push-to-talk record and cancel
  /// never come here; the listener hands them to the engine on its own thread.
  ///
  /// **Refused unless it belongs to the CURRENT installation.** Removing the listener stops new
  /// callbacks; it cannot recall an edge already queued to main. `listenerGeneration` changes on
  /// every install and removal, so an edge from before a `stop(); start()` or `suspend(); resume()`
  /// never acts after it (#1993). A PRESS must also have been classified under the current listener
  /// configuration (a rebind or an explicit reset since then refuses it); a RELEASE needs only its
  /// installation, because it ends the press its route remembers, whatever the binding is now.
  ///
  /// The edge is explicit: the listener's tracker reads side bits, so a release is a release. The
  /// deleted `NSEvent` path had to infer "a second event for a held key is its release" from
  /// aggregate flags; nothing here infers.
  private func handleListenerEdge(_ edge: KeyboardListenerIngress.MainEdge) {
    let current =
      edge.installation == listenerGeneration && isEnabled && !isSuspended
      && (!edge.isPress || edge.generation == engine.listenerConfigurationGeneration)
    onListenerEdgeHandledForTesting?(edge, current)
    guard current else { return }

    // #2381. The old modifier path was `if role == .cancel { … return }` followed by the record
    // path, so a role the matcher resolved and that site did not name FELL THROUGH AND STARTED A
    // RECORDING, and it compiled perfectly, because an `if` over an enum asserts nothing about the
    // members it omits. A switch makes the compiler name every member, which is why `ShortcutRole`
    // is a closed set.
    switch edge.role {
    case .pasteLast, .copyLast:
      // A bare-modifier rebind: the modifier's own press and release are the gesture.
      handleLastDictationShortcut(
        edge.role, isPress: edge.isPress, hold: .modifier(keyCode: edge.keyCode))

    case .quickAdd:
      // Press only: a modifier RELEASE is not a gesture. A stray second fire opens the panel twice,
      // and the panel reuses its own window.
      guard edge.isPress else { return }
      Task { await onQuickAdd?() }
      emitHotkeyPressed(.quickAdd, trigger: .quickAdd)

    case .record:
      // Toggle mode only; push-to-talk record goes to the engine on the listener's thread.
      guard edge.isPress, recordingMode == .toggle else { return }
      Task {
        await AppLogger.shared.log(
          "Modifier-only toggle: keyCode=\(edge.keyCode)", level: .info, category: "HotkeyService"
        )
      }
      queueToggleRecording(listenerInstallation: edge.installation)
      emitHotkeyPressed(.toggle, trigger: .toggle)

    case .cancel:
      // Decided by the engine in input order (`executeListenerCancel`), never here.
      return
    }
  }

  /// Run a toggle-mode record press after any listener cancel decided before it (see
  /// `listenerCancellationTask`), so the toggle sees the cancelled session gone instead of
  /// stopping or ignoring it. A toggle that waited is dropped if the service stopped, suspended or
  /// left toggle mode meanwhile, or, for a listener press (`listenerInstallation`), if that
  /// listener was replaced. With no cancel pending it runs at once, as before.
  private func queueToggleRecording(listenerInstallation: UInt64?) {
    guard let pendingCancellation = listenerCancellationTask else {
      Task { await onToggleRecording?() }
      return
    }
    Task { [weak self] in
      self?.onListenerCancellationWaitForTesting?()
      await pendingCancellation.value
      guard let self, self.isEnabled, !self.isSuspended, self.recordingMode == .toggle,
        listenerInstallation.map({ $0 == self.listenerGeneration }) ?? true
      else { return }
      await self.onToggleRecording?()
    }
  }

  /// Whether a Carbon event for `role` still belongs to a registration this service holds (#3106).
  ///
  /// Removing a registration does not recall an event already delivered, and `release` keeps a
  /// token whose removal the adapter refused, so the id alone proves nothing. Asked of CURRENT state:
  /// running, not suspended, the chord still ours now (a higher role may have taken it since the
  /// press), and a registration held FOR THE CURRENT BINDING: after a refused removal the old chord
  /// still arrives under this id, and it is not the shortcut the user set.
  private func carbonEventIsCurrent(for role: ShortcutRole) -> Bool {
    isEnabled && !isSuspended && mayRegisterAppShortcut(role) && appShortcutTokens[role] != nil
      && appShortcutRegisteredBindings[role] == binding(for: role)
  }

  /// One press or release of Paste Last or Copy Last, from either dispatch path (#3106).
  ///
  /// **Paste fires on the RELEASE.** The action posts a synthetic Cmd+V; fired on the press, the
  /// user's fingers are still on Control and Command, and a held modifier can ride into that paste
  /// or turn it into a different chord. Wispr Flow ships the same choice for the same action
  /// (static teardown, 2026-09-22). The action waits for the modifiers themselves to come up.
  ///
  /// **Copy fires on the press**: it posts no keystroke, so there is nothing for a held key to
  /// spoil, and the clipboard is ready by the time the user reaches for Cmd+V.
  ///
  /// Either way one physical hold acts once: `appShortcutsHeld` absorbs auto-repeat and a stray
  /// second press, and a release with no press seen is ignored.
  ///
  /// No `performCleanup()`, as with Quick Add: these never touch the recording path.
  private func handleLastDictationShortcut(_ role: ShortcutRole, isPress: Bool, hold: AppShortcutHold) {
    switch role {
    case .pasteLast:
      if isPress {
        guard appShortcutsHeld[.pasteLast] == nil else { return }
        appShortcutsHeld[.pasteLast] = hold
        if onPasteLast != nil { onPasteLastPressed?() }
        return
      }
      guard appShortcutsHeld[.pasteLast] == hold else { return }
      appShortcutsHeld[.pasteLast] = nil
      guard let action = onPasteLast else { return }
      // Synchronous, not a queued Task: a second gesture arriving before a queued task ran could
      // replace this one's press-time target (final review, #3106). The owner spawns its own work.
      action()
      emitHotkeyPressed(.pasteLast, trigger: .pasteLast)

    case .copyLast:
      guard isPress else {
        if appShortcutsHeld[.copyLast] == hold { appShortcutsHeld[.copyLast] = nil }
        return
      }
      guard appShortcutsHeld[.copyLast] == nil else { return }
      appShortcutsHeld[.copyLast] = hold
      guard let action = onCopyLast else { return }
      action()  // synchronous: the row copied is the one present at this press
      emitHotkeyPressed(.copyLast, trigger: .copyLast)

    case .record, .cancel, .quickAdd:
      return
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
    return recordingMode == .pushToTalk
      ? String(
        localized: "Hold \(formatted)",
        comment: "Main window: the push-to-talk keybind. %@ is the key or chord, such as Right ⌥.")
      : formatted
  }

}
