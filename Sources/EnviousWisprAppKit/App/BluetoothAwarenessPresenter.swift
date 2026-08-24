import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation

/// #1480: owns the once-per-launch Bluetooth cold-start education popover — the
/// single authority for WHEN it shows, WHEN it is torn down, and the telemetry
/// for both. Every ingress (launch, audio-device change, pipeline-state change,
/// onboarding completion, relevant setting change) forwards a `Trigger` fact to
/// one synchronous `reconcile(trigger:)`; no caller contains "should I show"
/// logic (plan §3c single-authority).
///
/// NOT `@Observable`: it is an internal collaborator, not a SwiftUI environment
/// home — no view observes it (plan §3C / Codex r1 CF2). Structural template:
/// `LanguageSuggestionPresenter`. Dependencies are narrow injected closures so
/// the presenter never knows `RecordingOverlayPanel`'s or `SettingsManager`'s
/// concrete type (clean test seam).
///
/// Three process-lifetime facts (all in-memory, reset every launch = the
/// once-per-launch cadence; a UserDefaults key for `hasShownThisLaunch` would
/// wrongly make it once-EVER). Codex r1 Q3: one "shown" flag cannot both prevent
/// re-show AND dismiss a currently-visible card, so the visible-ownership fact is
/// tracked separately.
///
/// Heart-path: pure limb. All methods no-throw, synchronous, MainActor. Never
/// blocks or touches the dictation pipeline.
@MainActor
final class BluetoothAwarenessPresenter {
  /// Which ingress asked the presenter to reconcile. Contextual only — the
  /// decision always re-reads live state, so `reconcile` never branches on the
  /// trigger; it is recorded on the breadcrumb for debugging which path surfaced
  /// or dismissed the card.
  enum Trigger: String, Sendable {
    case launch
    case deviceChanged = "device_changed"
    case pipelineStateChanged = "pipeline_state_changed"
    case settingChanged = "setting_changed"
  }

  /// A user tap on one of the card's three affordances.
  enum UserAction {
    case gotIt
    case close
    case adjustSettings
  }

  /// Telemetry actions (event name `bt_awareness.<rawValue>`). Fixed vocab.
  enum Action: String {
    case shown
    case dismissed
    case settingsOpened = "settings_opened"
    case suppressedBySetting = "suppressed_by_setting"
  }

  /// Telemetry `dismissed` reasons. Present only on `.dismissed`. Fixed vocab.
  enum DismissReason: String {
    case gotIt = "got_it"
    case recordStarted = "record_started"
    case routeChanged = "route_changed"
    case settingDisabled = "setting_disabled"
    case closed
  }

  // MARK: - Process-lifetime facts (in-memory; reset each launch)

  /// Has the card ever committed visibly this launch. Prevents re-show; never
  /// blocks cleanup of a visible card.
  private var hasShownThisLaunch = false
  /// Does the presenter currently own the Bluetooth card in the overlay slot.
  /// The accepted presentation this card owns, or nil when nothing is showing.
  ///
  /// **Replaced a `Bool` (#2292 C3b), and the difference is which questions it
  /// can answer.** `isPresented` said only "I believe a card is up", so every
  /// dismissal had to ask the overlay a SECOND question — what is on screen now
  /// — and act on the answer. The receipt names the presentation, so
  /// `dismissIfCurrent` is a no-op once the slot has moved on and the two
  /// questions collapse into one the overlay owns.
  private var currentReceipt: PillReceipt?

  /// The card is ADMITTED but the host has not drawn it yet.
  ///
  /// **Ownership and shown-ness are different moments, and only one of them can
  /// wait.** `.shown` and the launch allowance must wait for the host, because a
  /// card the host refuses was never seen. Ownership cannot wait: between
  /// admission and the first render this presenter holds a presentation, and a
  /// reconcile that finds nothing to name is a reconcile that cannot cancel it.
  /// The route-change path then returned without dismissing, the deferred block
  /// rendered the card anyway, and a user who had just unplugged their headset
  /// was left with a Bluetooth tip nothing would take down.
  private var pendingReceipt: PillReceipt?

  /// Which attempt `pendingReceipt` belongs to, so a late result from a CANCELLED
  /// attempt cannot clear the ownership of the attempt that replaced it.
  private var pendingGeneration: UInt64 = 0
  /// Telemetry dedup: `suppressed_by_setting` fires at most once per launch.
  private var hasEmittedSettingSuppressionThisLaunch = false

  // MARK: - Injected dependencies (narrow closures)

  /// Held STRONGLY, with `[weak self]` in every callback this presenter puts on
  /// a request (#2292 C3b). The overlay retains the active presentation's
  /// callbacks, so capturing self strongly there would make
  /// presenter -> overlay -> binding -> presenter for as long as a card is up;
  /// breaking it at the binding is right because the binding is the half that
  /// dies with the presentation.
  ///
  /// It replaced three closures — show, read-current-intent, hide-if-current.
  /// The middle one was the problem: it made this type a second authority on
  /// what was on screen, and every dismissal had to consult it first.
  private let overlay: any OverlayPresenting
  private let effectiveInputIsBluetooth: @MainActor () -> Bool
  private let dictationIsIdle: @MainActor () -> Bool
  private let onboardingCompleted: @MainActor () -> Bool
  private let tipsEnabled: @MainActor () -> Bool
  private let openMicrophoneSettings: @MainActor () -> Void
  private let emit: @MainActor (Action, DismissReason?) -> Void

  init(
    overlay: any OverlayPresenting,
    effectiveInputIsBluetooth: @escaping @MainActor () -> Bool,
    dictationIsIdle: @escaping @MainActor () -> Bool,
    onboardingCompleted: @escaping @MainActor () -> Bool,
    tipsEnabled: @escaping @MainActor () -> Bool,
    openMicrophoneSettings: @escaping @MainActor () -> Void,
    emit: @escaping @MainActor (Action, DismissReason?) -> Void
  ) {
    self.overlay = overlay
    self.effectiveInputIsBluetooth = effectiveInputIsBluetooth
    self.dictationIsIdle = dictationIsIdle
    self.onboardingCompleted = onboardingCompleted
    self.tipsEnabled = tipsEnabled
    self.openMicrophoneSettings = openMicrophoneSettings
    self.emit = emit
  }

  // MARK: - Reconcile

  /// The single show/dismiss decision. Synchronous, no `await`, so no
  /// check-then-act window exists across a suspension (plan §5 six-class check).
  ///
  /// **Invalidating facts are checked on OWNERSHIP, never on what happens to be
  /// on screen** (Codex r2, preserved through #2292 C3b). A recording may have
  /// already replaced the card synchronously, so gating the record-started
  /// branch on the visible intent would never fire and the telemetry would be
  /// lost. Holding a receipt is what "we own a card" means; whether it is still
  /// the CURRENT presentation is a separate question, and `dismissIfCurrent`
  /// asks it atomically instead of this type reading and then acting.
  func reconcile(trigger: Trigger) {
    if let receipt = currentReceipt {
      if !tipsEnabled() {
        overlay.dismissIfCurrent(receipt)
        currentReceipt = nil
        emit(.dismissed, .settingDisabled)
        breadcrumb(trigger, "dismissed", reason: DismissReason.settingDisabled.rawValue)
        return
      }
      if !effectiveInputIsBluetooth() {
        overlay.dismissIfCurrent(receipt)
        currentReceipt = nil
        emit(.dismissed, .routeChanged)
        breadcrumb(trigger, "dismissed", reason: DismissReason.routeChanged.rawValue)
        return
      }
      if !dictationIsIdle() {
        // Recording may already own the slot; the dismissal is then a no-op and
        // the telemetry still fires, which is the point of checking ownership
        // rather than visibility.
        overlay.dismissIfCurrent(receipt)
        currentReceipt = nil
        emit(.dismissed, .recordStarted)
        breadcrumb(trigger, "dismissed", reason: DismissReason.recordStarted.rawValue)
        return
      }
      if !overlay.isCurrent(receipt) {
        // Another presentation replaced us while idle — release ownership
        // silently, and do NOT dismiss: the slot is not ours to empty.
        currentReceipt = nil
        return
      }
      return
    }

    // **A card that is owned but not yet drawn is still cancellable.** Without
    // this the reconcile fell through to the eligibility guard below, which
    // simply returns — so a route change arriving in the deferral window left an
    // admitted card to render into a user it no longer applies to.
    //
    // No `.dismissed` event: this card was never `.shown`, and a dismissal with
    // no matching shown is a hole in the funnel rather than a data point. The
    // breadcrumb carries the reason instead, and `hasShownThisLaunch` stays
    // false — the user did not see it, so the allowance is not spent.
    if let pending = pendingReceipt {
      let invalidation: DismissReason?
      if !tipsEnabled() {
        invalidation = .settingDisabled
      } else if !effectiveInputIsBluetooth() {
        invalidation = .routeChanged
      } else if !dictationIsIdle() {
        invalidation = .recordStarted
      } else {
        invalidation = nil
      }
      if let invalidation {
        overlay.dismissIfCurrent(pending)
        pendingReceipt = nil
        breadcrumb(trigger, "cancelled_before_show", reason: invalidation.rawValue)
      }
      // Either way this reconcile is finished: the card is already admitted, so
      // presenting again below would be a second request for the slot it holds.
      return
    }

    // Eligibility is evaluated BEFORE the tips setting so `suppressed_by_setting`
    // counts only launches where the card WOULD have shown (a Bluetooth user, past
    // onboarding, idle, slot free) — not every opted-out user with a built-in or
    // wired mic who would never see it (Codex r2 P2: gating suppression behind the
    // same eligibility keeps the opt-out metric meaningful).
    guard !hasShownThisLaunch, onboardingCompleted(), effectiveInputIsBluetooth(),
      dictationIsIdle()
    else { return }

    guard tipsEnabled() else {
      // **The ONE place `featureSlotIsAvailable` may still be read** (#2292 C3b).
      // Nothing is being admitted here — the card is opted out — so there is no
      // `present` call whose answer could stand in. What this snapshot buys is
      // that `suppressed_by_setting` keeps counting only launches where the card
      // WOULD have shown, rather than every opted-out user whose slot happened
      // to be busy. Dropping it inflates the metric silently.
      guard overlay.featureSlotIsAvailable else { return }
      if !hasEmittedSettingSuppressionThisLaunch {
        hasEmittedSettingSuppressionThisLaunch = true
        emit(.suppressedBySetting, nil)
        breadcrumb(trigger, "suppressed_by_setting", reason: nil)
      }
      return
    }

    // **Admission and its proof are one call now.** This used to show and then
    // re-read the intent to confirm the overlay had taken it, because a
    // concurrent show could win the single slot in the same run-loop turn.
    //
    // **The RECEIPT is not that confirmation, and believing it was is the defect
    // PR #2370 fixed.** A receipt proves the request was admitted and that this
    // presenter owns the presentation; it cannot prove the host drew anything,
    // because on the FIRST presentation of a launch the host is called a run
    // loop later. This card is requested from `reconcile(trigger: .launch)`, so
    // it is exactly the request most likely to BE that first presentation — and
    // if the host then refuses, for want of a screen while the display wakes,
    // the allowance was spent on a card nobody saw and telemetry recorded a
    // `shown` that never happened.
    //
    // Committing inside `.presented` is what makes the comment above true: the
    // allowance survives a refusal and the user gets the card on a later
    // reconcile once a screen returns.
    pendingGeneration &+= 1
    let attempt = pendingGeneration
    var settledSynchronously = false
    let admitted = overlay.present(
      .bluetoothAwareness(
        onAcknowledge: { [weak self] in self?.handleUserAction(.gotIt) },
        onClose: { [weak self] in self?.handleUserAction(.close) },
        onOpenSettings: { [weak self] in self?.handleUserAction(.adjustSettings) }
      ),
      onResult: { [weak self] result in
        guard let self else { return }
        settledSynchronously = true
        // **Only this attempt's ownership.** A result arriving late from an
        // attempt that was already cancelled must not clear the ownership of the
        // attempt that replaced it.
        if self.pendingGeneration == attempt { self.pendingReceipt = nil }
        guard case .presented(let receipt) = result else { return }
        self.hasShownThisLaunch = true
        self.currentReceipt = receipt
        self.emit(.shown, nil)
        self.breadcrumb(trigger, "shown", reason: nil)
      })

    // Held ONLY while the answer is still outstanding. Reading the returned
    // receipt unconditionally would re-arm ownership for a card that had already
    // been drawn or already been refused, one statement earlier.
    if !settledSynchronously { pendingReceipt = admitted }
  }

  // MARK: - User actions

  /// The card's buttons call this. The presenter alone releases the receipt,
  /// dismisses only its own presentation, emits exactly one event, and opens
  /// settings for the explicit action (Codex r3 Q2). A call with no receipt is a
  /// no-op.
  ///
  /// **The three actions stay three actions.** Got it, Close and Adjust Settings
  /// emit `.dismissed/.gotIt`, `.dismissed/.closed` and `.settingsOpened`, and
  /// the dashboard reads them apart — collapsing any two would silently merge
  /// two different answers a user gave.
  private func handleUserAction(_ action: UserAction) {
    guard let receipt = currentReceipt else { return }
    overlay.dismissIfCurrent(receipt)
    currentReceipt = nil
    switch action {
    case .gotIt:
      emit(.dismissed, .gotIt)
    case .close:
      emit(.dismissed, .closed)
    case .adjustSettings:
      emit(.settingsOpened, nil)
      openMicrophoneSettings()
    }
  }

  // MARK: - Configured-input precedence (pure, testable)

  /// Resolve whether the CONFIGURED input is Bluetooth, mirroring the capture
  /// path exactly: HAL binds the explicit `preferredInputDeviceIDOverride` when
  /// set, otherwise follows the CoreAudio default input. It NEVER consults
  /// `selectedInputDeviceUID` (only remembered settings state), so this
  /// classification must not either — on Auto (empty override) the card has to
  /// reflect the DEFAULT input HAL actually opens, or it can show/hide opposite
  /// to the real route (cloud review P2, PR #1536). A nonempty override that no
  /// longer resolves does NOT fail closed — it falls back to the default input,
  /// mirroring HAL's own fallback so a disconnected pinned device still surfaces
  /// the card when the real (default) input is Bluetooth.
  /// Pure over two injected resolvers so the precedence is unit-tested without
  /// real CoreAudio devices; the bootstrapper supplies the live `AudioDeviceEnumerator`
  /// resolvers.
  /// - Parameters:
  ///   - autoInputIsBluetooth: `nil` when Auto resolves to no device at all.
  ///   - uidIsBluetooth: `nil` when the UID does not resolve (removed/unknown device).
  static func computeEffectiveInputIsBluetooth(
    preferredOverride: String,
    autoInputIsBluetooth: () -> Bool?,
    uidIsBluetooth: (String) -> Bool?
  ) -> Bool {
    // Auto (empty override): classify the device capture would actually OPEN —
    // never a remembered selected device HAL won't open, and since #2022 not
    // simply the system default either, because a virtual or aggregate default
    // loses to a real microphone and the fallback may be the Bluetooth one.
    guard !preferredOverride.isEmpty else {
      return autoInputIsBluetooth() ?? false
    }
    // Explicit override: authoritative when it resolves; a stale/unresolvable
    // override falls back to the default input, mirroring HAL's own fallback.
    if let resolved = uidIsBluetooth(preferredOverride) {
      return resolved
    }
    return autoInputIsBluetooth() ?? false
  }

  // MARK: - Helpers

  private func breadcrumb(_ trigger: Trigger, _ outcome: String, reason: String?) {
    var data: [String: Any] = ["trigger": trigger.rawValue, "outcome": outcome]
    if let reason { data["reason"] = reason }
    SentryBreadcrumb.add(stage: "bt_awareness", message: outcome, data: data)
  }
}

/// Late-binding holder so the single `settings.onChange` closure — assigned early
/// in bootstrap, before the presenter's dependencies (overlay, coordinators,
/// live-recording state) exist — can forward setting-change facts to the presenter
/// once it is constructed. Mirrors `OutputClassifierHolder` / `UpdateCoordinatorHolder`.
@MainActor
final class BluetoothAwarenessPresenterHolder {
  var presenter: BluetoothAwarenessPresenter?
  init() {}
}
