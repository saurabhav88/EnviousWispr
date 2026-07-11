import EnviousWisprPipeline
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #1480 — the Bluetooth cold-start card decision owner. The presenter is pure and
/// synchronous (injected closures, no clock, no `Task.sleep`), so the full §5 fire
/// matrix is asserted here as event/state transitions.

/// Controllable harness: every injected dependency is a mutable fact, and every
/// side effect (show / hide / open-settings / emit) is recorded for assertions.
@MainActor
private final class Harness {
  var currentIntent: OverlayIntent = .hidden
  var isBluetooth = false
  var isIdle = true
  var onboardingDone = true
  var tipsOn = true

  var showCount = 0
  var hideCount = 0
  var openSettingsCount = 0
  var emitted: [(BluetoothAwarenessPresenter.Action, BluetoothAwarenessPresenter.DismissReason?)] =
    []

  func makePresenter() -> BluetoothAwarenessPresenter {
    BluetoothAwarenessPresenter(
      readCurrentIntent: { self.currentIntent },
      showOverlay: {
        self.showCount += 1
        self.currentIntent = .bluetoothAwareness
      },
      hideIfCurrent: {
        if self.currentIntent == .bluetoothAwareness {
          self.hideCount += 1
          self.currentIntent = .hidden
        }
      },
      effectiveInputIsBluetooth: { self.isBluetooth },
      dictationIsIdle: { self.isIdle },
      onboardingCompleted: { self.onboardingDone },
      tipsEnabled: { self.tipsOn },
      openMicrophoneSettings: { self.openSettingsCount += 1 },
      emit: { action, reason in self.emitted.append((action, reason)) }
    )
  }

  var lastEmit: (BluetoothAwarenessPresenter.Action, BluetoothAwarenessPresenter.DismissReason?)? {
    emitted.last
  }
}

private func emitEquals(
  _ lhs: (BluetoothAwarenessPresenter.Action, BluetoothAwarenessPresenter.DismissReason?)?,
  _ action: BluetoothAwarenessPresenter.Action,
  _ reason: BluetoothAwarenessPresenter.DismissReason?
) -> Bool {
  guard let lhs else { return false }
  return lhs.0 == action && lhs.1 == reason
}

@Suite @MainActor struct BluetoothAwarenessPresenterTests {

  // MARK: - Show / no-show gating (§5 scenarios 1-3, 8, 12)

  @Test func scenario1_launchBluetoothIdle_shows() {
    let h = Harness()
    h.isBluetooth = true
    let p = h.makePresenter()
    p.reconcile(trigger: .launch)
    #expect(h.showCount == 1)
    #expect(h.currentIntent == .bluetoothAwareness)
    #expect(emitEquals(h.lastEmit, .shown, nil))
    // Once per launch: a second reconcile does not re-show.
    p.reconcile(trigger: .deviceChanged)
    #expect(h.showCount == 1)
  }

  @Test func scenario2_notBluetoothThenConnects_showsOnce() {
    let h = Harness()
    let p = h.makePresenter()
    p.reconcile(trigger: .launch)  // not BT
    #expect(h.showCount == 0)
    h.isBluetooth = true
    p.reconcile(trigger: .deviceChanged)  // BT connects later
    #expect(h.showCount == 1)
    // Still only once.
    p.reconcile(trigger: .deviceChanged)
    #expect(h.showCount == 1)
  }

  @Test func scenario3_onboardingIncomplete_suppressesUntilComplete() {
    let h = Harness()
    h.isBluetooth = true
    h.onboardingDone = false
    let p = h.makePresenter()
    p.reconcile(trigger: .launch)
    #expect(h.showCount == 0)
    h.onboardingDone = true
    p.reconcile(trigger: .settingChanged)  // onboarding completion re-eval
    #expect(h.showCount == 1)
  }

  @Test func scenario4_bluetoothWhileRecording_showsWhenIdleReturns() {
    let h = Harness()
    h.isBluetooth = true
    h.isIdle = false  // recording in flight
    let p = h.makePresenter()
    p.reconcile(trigger: .deviceChanged)  // BT connect during recording
    #expect(h.showCount == 0)
    h.isIdle = true  // dictation returns to idle
    p.reconcile(trigger: .pipelineStateChanged)
    #expect(h.showCount == 1)
  }

  @Test func gate_requiresHiddenSlot() {
    let h = Harness()
    h.isBluetooth = true
    h.currentIntent = .warning(message: "x")  // another overlay owns the slot
    let p = h.makePresenter()
    p.reconcile(trigger: .launch)
    #expect(h.showCount == 0)  // never replaces a live overlay
  }

  // MARK: - Dismissal reasons (§5 scenarios 5-8)

  @Test func scenario5_recordStarted_dismissesWithReason_noHideOfNewerIntent() {
    let h = Harness()
    h.isBluetooth = true
    let p = h.makePresenter()
    p.reconcile(trigger: .launch)  // shown; currentIntent == .bluetoothAwareness
    // Recording synchronously replaced the slot before this reconcile ran.
    h.currentIntent = .recording(audioLevel: 0)
    h.isIdle = false
    p.reconcile(trigger: .pipelineStateChanged)
    #expect(emitEquals(h.lastEmit, .dismissed, .recordStarted))
    #expect(h.hideCount == 0)  // must NOT tear down the recording pill
  }

  @Test func scenario5b_recordStarted_hidesWhenCardStillOwnsSlot() {
    let h = Harness()
    h.isBluetooth = true
    let p = h.makePresenter()
    p.reconcile(trigger: .launch)
    // Reconcile fired before the pill replaced the card (card still owns slot).
    h.isIdle = false
    p.reconcile(trigger: .pipelineStateChanged)
    #expect(emitEquals(h.lastEmit, .dismissed, .recordStarted))
    #expect(h.hideCount == 1)  // its own card IS torn down
  }

  @Test func scenario6_routeChangedAwayFromBluetooth_dismisses() {
    let h = Harness()
    h.isBluetooth = true
    let p = h.makePresenter()
    p.reconcile(trigger: .launch)
    h.isBluetooth = false
    p.reconcile(trigger: .deviceChanged)
    #expect(emitEquals(h.lastEmit, .dismissed, .routeChanged))
    #expect(h.hideCount == 1)
    #expect(h.currentIntent == .hidden)
  }

  @Test func anotherOverlayReplacedWhileIdle_releasesOwnershipSilently() {
    let h = Harness()
    h.isBluetooth = true
    let p = h.makePresenter()
    p.reconcile(trigger: .launch)
    let emitCountAfterShow = h.emitted.count
    // A different overlay took the slot while still idle + BT.
    h.currentIntent = .clipboardFallback
    p.reconcile(trigger: .pipelineStateChanged)
    #expect(h.emitted.count == emitCountAfterShow)  // no dismiss emit
    #expect(h.hideCount == 0)  // does not touch the newer overlay
  }

  // MARK: - Setting suppression (§5 scenario 8)

  @Test func scenario8_tipsOff_neverShows_emitsSuppressedOncePerLaunch() {
    let h = Harness()
    h.isBluetooth = true
    h.tipsOn = false
    let p = h.makePresenter()
    p.reconcile(trigger: .launch)
    #expect(h.showCount == 0)
    #expect(emitEquals(h.lastEmit, .suppressedBySetting, nil))
    let count = h.emitted.count
    p.reconcile(trigger: .deviceChanged)  // dedup
    #expect(h.emitted.count == count)
  }

  @Test func tipsOff_nonBluetooth_noSuppressionEmit() {
    // Codex r2 P2: an opted-out user on a built-in/wired mic never sees the card,
    // so no `suppressed_by_setting` must fire (metric counts only eligible users).
    let h = Harness()
    h.isBluetooth = false
    h.tipsOn = false
    let p = h.makePresenter()
    p.reconcile(trigger: .launch)
    #expect(h.showCount == 0)
    #expect(h.emitted.isEmpty)
  }

  @Test func tipsOff_onboardingIncomplete_noSuppressionEmit() {
    // Suppression is gated on full eligibility, so an onboarding-incomplete BT
    // user with tips off is not counted either.
    let h = Harness()
    h.isBluetooth = true
    h.tipsOn = false
    h.onboardingDone = false
    let p = h.makePresenter()
    p.reconcile(trigger: .launch)
    #expect(h.emitted.isEmpty)
  }

  @Test func scenario8b_tipsToggledOffWhileVisible_dismissesWithSettingDisabled() {
    let h = Harness()
    h.isBluetooth = true
    let p = h.makePresenter()
    p.reconcile(trigger: .launch)  // shown
    h.tipsOn = false
    p.reconcile(trigger: .settingChanged)
    #expect(emitEquals(h.lastEmit, .dismissed, .settingDisabled))
    #expect(h.hideCount == 1)
    #expect(h.currentIntent == .hidden)
  }

  // MARK: - User actions (§11 user-action test)

  @Test func gotIt_dismisses_hides_emitsOnce() {
    let h = Harness()
    h.isBluetooth = true
    let p = h.makePresenter()
    p.reconcile(trigger: .launch)
    let before = h.emitted.count
    p.handleUserAction(.gotIt)
    #expect(h.currentIntent == .hidden)
    #expect(h.hideCount == 1)
    #expect(h.emitted.count == before + 1)
    #expect(emitEquals(h.lastEmit, .dismissed, .gotIt))
  }

  @Test func close_emitsClosed() {
    let h = Harness()
    h.isBluetooth = true
    let p = h.makePresenter()
    p.reconcile(trigger: .launch)
    p.handleUserAction(.close)
    #expect(emitEquals(h.lastEmit, .dismissed, .closed))
    #expect(h.hideCount == 1)
  }

  @Test func adjustSettings_opensSettings_emitsSettingsOpened() {
    let h = Harness()
    h.isBluetooth = true
    let p = h.makePresenter()
    p.reconcile(trigger: .launch)
    p.handleUserAction(.adjustSettings)
    #expect(h.openSettingsCount == 1)
    #expect(emitEquals(h.lastEmit, .settingsOpened, nil))
    #expect(h.hideCount == 1)
  }

  @Test func handleUserAction_whenNotPresented_isNoOp() {
    let h = Harness()
    let p = h.makePresenter()
    p.handleUserAction(.gotIt)
    #expect(h.emitted.isEmpty)
    #expect(h.hideCount == 0)
    #expect(h.openSettingsCount == 0)
  }

  @Test func adjustSettings_whenNewerIntentOwnsSlot_doesNotHideIt() {
    let h = Harness()
    h.isBluetooth = true
    let p = h.makePresenter()
    p.reconcile(trigger: .launch)
    h.currentIntent = .recording(audioLevel: 0)  // pill replaced the card
    p.handleUserAction(.adjustSettings)
    #expect(h.hideCount == 0)  // never tears down the recording pill
    #expect(h.openSettingsCount == 1)
    #expect(emitEquals(h.lastEmit, .settingsOpened, nil))
  }

  // MARK: - Effective-input precedence (§11 effective-input test, Codex r2/r3 CF3)

  @Test func effectiveInput_overrideWinsOverBluetoothDefault() {
    let result = BluetoothAwarenessPresenter.computeEffectiveInputIsBluetooth(
      preferredOverride: "builtin",
      selectedUID: "airpods",
      defaultInputIsBluetooth: { true },
      uidIsBluetooth: { $0 == "airpods" }  // "builtin" -> false
    )
    #expect(result == false)  // explicit non-BT override beats a BT default
  }

  @Test func effectiveInput_selectedUidBluetoothWhenNoOverride() {
    let result = BluetoothAwarenessPresenter.computeEffectiveInputIsBluetooth(
      preferredOverride: "",
      selectedUID: "airpods",
      defaultInputIsBluetooth: { false },
      uidIsBluetooth: { $0 == "airpods" }
    )
    #expect(result == true)
  }

  @Test func effectiveInput_defaultBluetoothWhenBothEmpty() {
    let result = BluetoothAwarenessPresenter.computeEffectiveInputIsBluetooth(
      preferredOverride: "",
      selectedUID: "",
      defaultInputIsBluetooth: { true },
      uidIsBluetooth: { _ in false }
    )
    #expect(result == true)
  }

  @Test func effectiveInput_defaultNotBluetoothWhenBothEmpty() {
    let result = BluetoothAwarenessPresenter.computeEffectiveInputIsBluetooth(
      preferredOverride: "",
      selectedUID: "",
      defaultInputIsBluetooth: { false },
      uidIsBluetooth: { _ in true }
    )
    #expect(result == false)
  }

  @Test func effectiveInput_unresolvableUid_fallsBackToDefaultBluetooth() {
    // Cloud review P2: a disconnected pinned device records through the DEFAULT
    // input (AVAudioEngineSource `resolvedDeviceID ?? defaultInputDeviceID()`), so a
    // stale UID with a Bluetooth default must show the card, not fail closed.
    let result = BluetoothAwarenessPresenter.computeEffectiveInputIsBluetooth(
      preferredOverride: "ghost-device",
      selectedUID: "",
      defaultInputIsBluetooth: { true },
      uidIsBluetooth: { _ in nil }  // removed/unknown device
    )
    #expect(result == true)
  }

  @Test func effectiveInput_unresolvableUid_defaultNotBluetooth_noCard() {
    // Stale UID but the default input is NOT Bluetooth → no card (no false positive).
    let result = BluetoothAwarenessPresenter.computeEffectiveInputIsBluetooth(
      preferredOverride: "ghost-device",
      selectedUID: "",
      defaultInputIsBluetooth: { false },
      uidIsBluetooth: { _ in nil }
    )
    #expect(result == false)
  }

  @Test func effectiveInput_resolvedUidWins_ignoresDefault() {
    // A UID that DOES resolve is authoritative — the default is not consulted.
    let result = BluetoothAwarenessPresenter.computeEffectiveInputIsBluetooth(
      preferredOverride: "builtin",
      selectedUID: "",
      defaultInputIsBluetooth: { true },  // default is BT...
      uidIsBluetooth: { _ in false }  // ...but the pinned built-in resolves non-BT
    )
    #expect(result == false)
  }

  @Test func effectiveInput_noDefaultDevice_failsClosed() {
    let result = BluetoothAwarenessPresenter.computeEffectiveInputIsBluetooth(
      preferredOverride: "",
      selectedUID: "",
      defaultInputIsBluetooth: { nil },  // no default input device
      uidIsBluetooth: { _ in true }
    )
    #expect(result == false)
  }
}

// MARK: - Copy freeze (§11 copy test) + brand dash rule

@Suite struct BluetoothTipsCopyTests {
  @Test func approvedTipStrings() {
    #expect(
      BluetoothTipsCopy.tipTiming
        == "After your mic has been idle, wait 1 to 2 seconds before speaking.")
    #expect(
      BluetoothTipsCopy.tipReadiness
        == "Microphone Readiness keeps follow-up dictations ready for up to 30 seconds (on by default)."
    )
    #expect(
      BluetoothTipsCopy.tipHeadphones == "Built-in or wired mics usually avoid this startup delay.")
    #expect(BluetoothTipsCopy.cardTitle == "Bluetooth mic detected")
    #expect(
      BluetoothTipsCopy.cardIntro == "Bluetooth microphones can take a moment on a cold start.")
    #expect(BluetoothTipsCopy.settingsHeader == "When using Bluetooth")
    #expect(
      BluetoothTipsCopy.settingsPS
        == "Built-in, wired, and USB mics do not have this Bluetooth startup delay.")
  }

  @Test func noEmOrEnDashesInUserFacingCopy() {
    let strings = [
      BluetoothTipsCopy.cardTitle, BluetoothTipsCopy.cardIntro, BluetoothTipsCopy.cardFootnote,
      BluetoothTipsCopy.gotItButton, BluetoothTipsCopy.adjustSettingsButton,
      BluetoothTipsCopy.tipTiming, BluetoothTipsCopy.tipReadiness, BluetoothTipsCopy.tipHeadphones,
      BluetoothTipsCopy.settingsHeader, BluetoothTipsCopy.settingsIntro,
      BluetoothTipsCopy.micOrder, BluetoothTipsCopy.settingsPS, BluetoothTipsCopy.showTipsToggle,
    ]
    for s in strings {
      #expect(!s.contains("\u{2014}"), "em-dash in: \(s)")
      #expect(!s.contains("\u{2013}"), "en-dash in: \(s)")
    }
  }
}
