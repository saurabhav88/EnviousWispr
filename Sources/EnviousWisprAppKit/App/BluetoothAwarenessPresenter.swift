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
  private var isPresented = false
  /// Telemetry dedup: `suppressed_by_setting` fires at most once per launch.
  private var hasEmittedSettingSuppressionThisLaunch = false

  // MARK: - Injected dependencies (narrow closures)

  private let readCurrentIntent: @MainActor () -> OverlayIntent
  private let showOverlay: @MainActor () -> Void
  /// Hides the overlay ONLY when it currently shows `.bluetoothAwareness`, so it
  /// never removes a newer recording / processing / warning / error intent.
  private let hideIfCurrent: @MainActor () -> Void
  private let effectiveInputIsBluetooth: @MainActor () -> Bool
  private let dictationIsIdle: @MainActor () -> Bool
  private let onboardingCompleted: @MainActor () -> Bool
  private let tipsEnabled: @MainActor () -> Bool
  private let openMicrophoneSettings: @MainActor () -> Void
  private let emit: @MainActor (Action, DismissReason?) -> Void

  init(
    readCurrentIntent: @escaping @MainActor () -> OverlayIntent,
    showOverlay: @escaping @MainActor () -> Void,
    hideIfCurrent: @escaping @MainActor () -> Void,
    effectiveInputIsBluetooth: @escaping @MainActor () -> Bool,
    dictationIsIdle: @escaping @MainActor () -> Bool,
    onboardingCompleted: @escaping @MainActor () -> Bool,
    tipsEnabled: @escaping @MainActor () -> Bool,
    openMicrophoneSettings: @escaping @MainActor () -> Void,
    emit: @escaping @MainActor (Action, DismissReason?) -> Void
  ) {
    self.readCurrentIntent = readCurrentIntent
    self.showOverlay = showOverlay
    self.hideIfCurrent = hideIfCurrent
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
  /// When already presenting, invalidating facts are checked on `isPresented`,
  /// NOT on `readCurrentIntent()`: recording may already have synchronously
  /// replaced the intent, so gating the record-started branch on the current
  /// intent would never fire and the telemetry would be lost (Codex r2). Each
  /// hide is still guarded by `currentIntent == .bluetoothAwareness` so a newer
  /// intent is never torn down.
  func reconcile(trigger: Trigger) {
    let currentIntent = readCurrentIntent()
    if isPresented {
      if !tipsEnabled() {
        if currentIntent == .bluetoothAwareness { hideIfCurrent() }
        isPresented = false
        emit(.dismissed, .settingDisabled)
        breadcrumb(trigger, "dismissed", reason: DismissReason.settingDisabled.rawValue)
        return
      }
      if !effectiveInputIsBluetooth() {
        if currentIntent == .bluetoothAwareness { hideIfCurrent() }
        isPresented = false
        emit(.dismissed, .routeChanged)
        breadcrumb(trigger, "dismissed", reason: DismissReason.routeChanged.rawValue)
        return
      }
      if !dictationIsIdle() {
        // Recording may already own the slot; hide is a no-op then, telemetry still fires.
        if currentIntent == .bluetoothAwareness { hideIfCurrent() }
        isPresented = false
        emit(.dismissed, .recordStarted)
        breadcrumb(trigger, "dismissed", reason: DismissReason.recordStarted.rawValue)
        return
      }
      if currentIntent != .bluetoothAwareness {
        // Another overlay replaced us while idle — release ownership silently.
        isPresented = false
        return
      }
      return
    }

    // Eligibility is evaluated BEFORE the tips setting so `suppressed_by_setting`
    // counts only launches where the card WOULD have shown (a Bluetooth user, past
    // onboarding, idle, slot free) — not every opted-out user with a built-in or
    // wired mic who would never see it (Codex r2 P2: gating suppression behind the
    // same eligibility keeps the opt-out metric meaningful).
    guard !hasShownThisLaunch, onboardingCompleted(), effectiveInputIsBluetooth(),
      dictationIsIdle(), readCurrentIntent() == .hidden
    else { return }

    guard tipsEnabled() else {
      if !hasEmittedSettingSuppressionThisLaunch {
        hasEmittedSettingSuppressionThisLaunch = true
        emit(.suppressedBySetting, nil)
        breadcrumb(trigger, "suppressed_by_setting", reason: nil)
      }
      return
    }

    showOverlay()
    // Confirm the overlay actually took the intent before committing state (a
    // concurrent show could have won the single slot in the same run-loop turn).
    guard readCurrentIntent() == .bluetoothAwareness else { return }
    hasShownThisLaunch = true
    isPresented = true
    emit(.shown, nil)
    breadcrumb(trigger, "shown", reason: nil)
  }

  // MARK: - User actions

  /// The card's buttons call this; the presenter alone clears `isPresented`,
  /// hides only when Bluetooth still owns the slot, emits exactly one event, and
  /// opens settings for the explicit action (Codex r3 Q2). A call when not
  /// presenting is a no-op.
  func handleUserAction(_ action: UserAction) {
    guard isPresented else { return }
    if readCurrentIntent() == .bluetoothAwareness { hideIfCurrent() }
    isPresented = false
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

  /// Resolve whether the CONFIGURED input is Bluetooth using the settings-sync
  /// precedence: `preferredInputDeviceIDOverride` first, `selectedInputDeviceUID`
  /// second, the CoreAudio default only when both are empty (Codex r2/r3). A
  /// nonempty UID that no longer resolves does NOT fail closed — it falls back to
  /// the default input, mirroring the capture path's `resolvedDeviceID ??
  /// defaultInputDeviceID()` so a disconnected pinned device still surfaces the
  /// card when the real (default) input is Bluetooth (cloud review P2).
  /// Pure over two injected resolvers so the precedence is unit-tested without
  /// real CoreAudio devices; the bootstrapper supplies the live `AudioDeviceEnumerator`
  /// resolvers.
  /// - Parameters:
  ///   - defaultInputIsBluetooth: `nil` when there is no resolvable default device.
  ///   - uidIsBluetooth: `nil` when the UID does not resolve (removed/unknown device).
  static func computeEffectiveInputIsBluetooth(
    preferredOverride: String,
    selectedUID: String,
    defaultInputIsBluetooth: () -> Bool?,
    uidIsBluetooth: (String) -> Bool?
  ) -> Bool {
    let effectiveUID = preferredOverride.isEmpty ? selectedUID : preferredOverride
    if effectiveUID.isEmpty {
      return defaultInputIsBluetooth() ?? false
    }
    // A remembered UID that still resolves is authoritative. But one that no longer
    // resolves is NOT fail-closed: the capture path binds `resolvedDeviceID ??
    // defaultInputDeviceID()` (AVAudioEngineSource.swift:289), so a disconnected
    // pinned device actually records through the DEFAULT input. Mirror that — fall
    // back to the default input's transport so a user whose stale UID resolves to a
    // Bluetooth default still gets the card (cloud review P2). Otherwise a Bluetooth
    // user would record through the cold Bluetooth mic and never be warned.
    if let resolved = uidIsBluetooth(effectiveUID) {
      return resolved
    }
    return defaultInputIsBluetooth() ?? false
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
