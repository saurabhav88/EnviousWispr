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
private final class Harness: OverlayPresenting {
  /// Whether the next `present` is admitted. False stands for "something else
  /// owns the slot" — a recording, a processing pill, a warning.
  var slotIsFree = true
  var isBluetooth = false
  var isIdle = true
  var onboardingDone = true
  var tipsOn = true

  var showCount = 0
  var hideCount = 0
  var openSettingsCount = 0
  /// `dismissCurrent` calls. Nothing in C3b should ever produce one.
  var unconditionalDismissals = 0
  var emitted: [(BluetoothAwarenessPresenter.Action, BluetoothAwarenessPresenter.DismissReason?)] =
    []

  /// Whether the CARD is the presentation on screen — the exact question the
  /// old `currentIntent == .bluetoothAwareness` asked.
  private(set) var cardIsShowing = false

  private var currentReceipt: PillReceipt?
  private var onAcknowledge: (() -> Void)?
  private var onClose: (() -> Void)?
  private var onOpenSettings: (() -> Void)?

  // MARK: - OverlayPresenting

  var featureSlotIsAvailable: Bool { slotIsFree }

  func present(_ request: PillRequest) -> PillReceipt? {
    guard case .bluetoothAwareness(let ack, let close, let settings) = request else { return nil }
    guard slotIsFree else { return nil }
    showCount += 1
    onAcknowledge = ack
    onClose = close
    onOpenSettings = settings
    let receipt = PillReceipt(presentationID: PresentationID())
    currentReceipt = receipt
    cardIsShowing = true
    slotIsFree = false
    return receipt
  }

  func update(_ update: PillUpdate) {}

  func dismissCurrent(_ mode: PillDismissal) {
    unconditionalDismissals += 1
    hideCount += 1
    currentReceipt = nil
    cardIsShowing = false
    slotIsFree = true
  }

  func dismissIfCurrent(_ receipt: PillReceipt) {
    guard receipt == currentReceipt else { return }
    hideCount += 1
    currentReceipt = nil
    cardIsShowing = false
    slotIsFree = true
  }

  func isCurrent(_ receipt: PillReceipt) -> Bool { receipt == currentReceipt }

  // MARK: - Driving the card's own buttons

  /// **The only route a press takes** (#2292 C3b). These used to be driven by
  /// calling `presenter.handleUserAction(_:)`, which no longer exists outside
  /// the presenter: the card carries its three callbacks, so a test presses the
  /// button a user presses.
  func pressGotIt() { onAcknowledge?() }
  func pressClose() { onClose?() }
  func pressAdjustSettings() { onOpenSettings?() }

  /// Something else took the slot while the card was up.
  ///
  /// The callbacks deliberately survive, so a test can fire a stale press and
  /// prove it takes nothing away.
  func simulateReplacement() {
    currentReceipt = PillReceipt(presentationID: PresentationID())
    cardIsShowing = false
    slotIsFree = false
  }

  func makePresenter() -> BluetoothAwarenessPresenter {
    BluetoothAwarenessPresenter(
      overlay: self,
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
    #expect(h.cardIsShowing)
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

  @Test func idleButSlotStillRecording_waitsForClear_thenShows() {
    // Cloud review P2: the pipeline callback fires before the overlay clears, so
    // on a just-completed recording dictation is idle while the slot is still
    // `.recording`. The card must NOT show until the slot is `.hidden` (the guard),
    // and it DOES show on the deferred re-check once the pill is torn down.
    let h = Harness()
    h.isBluetooth = true
    h.isIdle = true
    h.simulateReplacement()  // terminal overlay not sent yet
    let p = h.makePresenter()
    p.reconcile(trigger: .pipelineStateChanged)
    #expect(h.showCount == 0)  // slot not clear → no show
    h.slotIsFree = true  // overlay handler cleared the pill
    p.reconcile(trigger: .pipelineStateChanged)  // the deferred re-check
    #expect(h.showCount == 1)
  }

  @Test func gate_requiresHiddenSlot() {
    let h = Harness()
    h.isBluetooth = true
    h.slotIsFree = false  // another overlay owns the slot
    let p = h.makePresenter()
    p.reconcile(trigger: .launch)
    #expect(h.showCount == 0)  // never replaces a live overlay
  }

  // MARK: - Dismissal reasons (§5 scenarios 5-8)

  @Test func scenario5_recordStarted_dismissesWithReason_noHideOfNewerIntent() {
    let h = Harness()
    h.isBluetooth = true
    let p = h.makePresenter()
    p.reconcile(trigger: .launch)  // the card is shown and holds the slot
    // Recording synchronously replaced the slot before this reconcile ran.
    h.simulateReplacement()
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
    #expect(!h.cardIsShowing)
  }

  @Test func anotherOverlayReplacedWhileIdle_releasesOwnershipSilently() {
    let h = Harness()
    h.isBluetooth = true
    let p = h.makePresenter()
    p.reconcile(trigger: .launch)
    let emitCountAfterShow = h.emitted.count
    // A different overlay took the slot while still idle + BT.
    //
    // **`simulateReplacement()`, not `slotIsFree = false`** (#2292 C3b). Under
    // the receipt model a busy slot and a slot we no longer OWN are different
    // facts, and only the second reaches the release branch this case exists
    // for. Setting the flag alone leaves the card still current, so the
    // presenter takes its everything-is-fine path and the assertions below pass
    // without the branch ever running.
    h.simulateReplacement()
    p.reconcile(trigger: .pipelineStateChanged)
    #expect(h.emitted.count == emitCountAfterShow)  // no dismiss emit
    #expect(h.hideCount == 0)  // does not touch the newer overlay
    #expect(h.unconditionalDismissals == 0)
  }

  // MARK: - #2292 C3b: admission is the overlay's answer

  /// **A refused card must not spend the launch's one showing.**
  ///
  /// `hasShownThisLaunch` is committed only after a receipt comes back. Before
  /// C3b the presenter called show and then re-read the intent to confirm; if
  /// the answer and the commit ever drifted apart, a card nobody saw would burn
  /// the launch.
  ///
  /// REPRODUCIBLE: a Bluetooth user launches while a warning owns the pill. The
  /// warning clears. They must still get the card — it is the whole feature, and
  /// it only fires once per launch.
  @Test func refusedBluetoothCardRetriesWhenSlotClears() {
    let h = Harness()
    h.isBluetooth = true
    h.slotIsFree = false
    let p = h.makePresenter()

    p.reconcile(trigger: .launch)
    #expect(h.showCount == 0, "control: the card must have been refused")

    h.slotIsFree = true
    p.reconcile(trigger: .deviceChanged)

    #expect(h.showCount == 1, "the refusal spent the launch's one showing")
    #expect(h.cardIsShowing)
  }

  /// **The tips-disabled suppression metric keeps its eligibility snapshot.**
  ///
  /// NOT user-facing: nobody sees a card either way. What it protects is the
  /// meaning of `suppressed_by_setting`, which counts users who WOULD have seen
  /// the card and had it withheld by their setting. Dropping the slot check
  /// silently inflates it with every opted-out user whose pill happened to be
  /// busy, and a dashboard cannot tell the two populations apart afterwards.
  ///
  /// This is the one remaining legitimate read of `featureSlotIsAvailable`, and
  /// this case is why it still exists.
  @Test func tipsOffBusySlotDoesNotEmitSuppression() {
    let h = Harness()
    h.isBluetooth = true
    h.tipsOn = false
    h.slotIsFree = false
    let p = h.makePresenter()

    p.reconcile(trigger: .launch)

    #expect(h.emitted.isEmpty, "an opted-out user with a busy slot was counted as suppressed")

    h.slotIsFree = true
    p.reconcile(trigger: .deviceChanged)
    #expect(
      emitEquals(h.lastEmit, .suppressedBySetting, nil),
      "control: the same user with a clear slot MUST be counted")
  }

  /// **A card that was replaced must not dismiss its replacement.**
  ///
  /// REPRODUCIBLE: the card is up, the user starts dictating, and the recording
  /// pill takes the slot. The next reconcile fires — it has to report the
  /// dismissal for telemetry, and it must NOT take the recording pill off the
  /// user's screen mid-dictation.
  @Test func bluetoothReplacementDoesNotDismissRecording() {
    let h = Harness()
    h.isBluetooth = true
    let p = h.makePresenter()
    p.reconcile(trigger: .launch)
    #expect(h.cardIsShowing, "control: the card must be up first")

    h.simulateReplacement()
    h.isIdle = false
    p.reconcile(trigger: .pipelineStateChanged)

    #expect(h.hideCount == 0, "the card's dismissal tore down the recording pill")
    #expect(
      h.unconditionalDismissals == 0,
      "the card dismissed whatever was on screen instead of naming its own receipt")
    #expect(
      emitEquals(h.lastEmit, .dismissed, .recordStarted),
      "control: the telemetry must still fire — that is why ownership, not visibility, is checked")
  }

  /// **Three buttons, three answers, and the dashboard reads them apart.**
  ///
  /// Got it, Close and Adjust Settings are different things a user said.
  /// Collapsing any two — or crossing two of the three callbacks while wiring
  /// the card's own request — merges two populations silently, and nothing in
  /// the app looks wrong afterwards.
  ///
  /// Drives the callbacks the request carries, which is the only route a press
  /// takes since C3b.
  @Test func bluetoothActionsPreserveExactTelemetryIdentity() {
    for (press, action, reason) in [
      ("gotIt", BluetoothAwarenessPresenter.Action.dismissed, BluetoothAwarenessPresenter.DismissReason.gotIt),
      ("close", .dismissed, .closed),
      ("settings", .settingsOpened, nil),
    ] as [(String, BluetoothAwarenessPresenter.Action, BluetoothAwarenessPresenter.DismissReason?)] {
      let h = Harness()
      h.isBluetooth = true
      let p = h.makePresenter()
      p.reconcile(trigger: .launch)
      #expect(h.cardIsShowing, "control: \(press) needs a card on screen")

      switch press {
      case "gotIt": h.pressGotIt()
      case "close": h.pressClose()
      default: h.pressAdjustSettings()
      }

      #expect(
        emitEquals(h.lastEmit, action, reason),
        "\(press) did not emit its own action/reason pair")
      #expect(h.hideCount == 1, "\(press) left the card the user answered on screen")
      #expect(h.unconditionalDismissals == 0)
    }
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
    #expect(!h.cardIsShowing)
  }

  // MARK: - User actions (§11 user-action test)

  @Test func gotIt_dismisses_hides_emitsOnce() {
    let h = Harness()
    h.isBluetooth = true
    let p = h.makePresenter()
    p.reconcile(trigger: .launch)
    let before = h.emitted.count
    h.pressGotIt()
    #expect(!h.cardIsShowing)
    #expect(h.hideCount == 1)
    #expect(h.emitted.count == before + 1)
    #expect(emitEquals(h.lastEmit, .dismissed, .gotIt))
  }

  @Test func close_emitsClosed() {
    let h = Harness()
    h.isBluetooth = true
    let p = h.makePresenter()
    p.reconcile(trigger: .launch)
    h.pressClose()
    #expect(emitEquals(h.lastEmit, .dismissed, .closed))
    #expect(h.hideCount == 1)
  }

  @Test func adjustSettings_opensSettings_emitsSettingsOpened() {
    let h = Harness()
    h.isBluetooth = true
    let p = h.makePresenter()
    p.reconcile(trigger: .launch)
    h.pressAdjustSettings()
    #expect(h.openSettingsCount == 1)
    #expect(emitEquals(h.lastEmit, .settingsOpened, nil))
    #expect(h.hideCount == 1)
  }

  @Test func handleUserAction_whenNotPresented_isNoOp() {
    let h = Harness()
    let p = h.makePresenter()
    h.pressGotIt()
    #expect(h.emitted.isEmpty)
    #expect(h.hideCount == 0)
    #expect(h.openSettingsCount == 0)
  }

  @Test func adjustSettings_whenNewerIntentOwnsSlot_doesNotHideIt() {
    let h = Harness()
    h.isBluetooth = true
    let p = h.makePresenter()
    p.reconcile(trigger: .launch)
    h.simulateReplacement()  // pill replaced the card
    h.pressAdjustSettings()
    #expect(h.hideCount == 0)  // never tears down the recording pill
    #expect(h.openSettingsCount == 1)
    #expect(emitEquals(h.lastEmit, .settingsOpened, nil))
  }

  // MARK: - Effective-input precedence (§11 effective-input test, Codex r2/r3 CF3)

  @Test func effectiveInput_overrideWinsOverBluetoothDefault() {
    let result = BluetoothAwarenessPresenter.computeEffectiveInputIsBluetooth(
      preferredOverride: "builtin",
      autoInputIsBluetooth: { true },
      uidIsBluetooth: { $0 == "airpods" }  // "builtin" -> false
    )
    #expect(result == false)  // explicit non-BT override beats a BT default
  }

  @Test func effectiveInput_autoUsesDefaultNotRememberedSelection() {
    // Cloud review P2 (PR #1536): on Auto (empty override) HAL follows the
    // system-default input and NEVER opens `selectedInputDeviceUID`, so the card
    // must classify the DEFAULT — not a remembered device that would resolve to
    // Bluetooth. Default is non-BT here → no card, even though a stale "airpods"
    // selection would have resolved BT under the old precedence.
    let result = BluetoothAwarenessPresenter.computeEffectiveInputIsBluetooth(
      preferredOverride: "",
      autoInputIsBluetooth: { false },
      uidIsBluetooth: { $0 == "airpods" }
    )
    #expect(result == false)
  }

  @Test func effectiveInput_defaultBluetoothWhenBothEmpty() {
    let result = BluetoothAwarenessPresenter.computeEffectiveInputIsBluetooth(
      preferredOverride: "",
      autoInputIsBluetooth: { true },
      uidIsBluetooth: { _ in false }
    )
    #expect(result == true)
  }

  @Test func effectiveInput_defaultNotBluetoothWhenBothEmpty() {
    let result = BluetoothAwarenessPresenter.computeEffectiveInputIsBluetooth(
      preferredOverride: "",
      autoInputIsBluetooth: { false },
      uidIsBluetooth: { _ in true }
    )
    #expect(result == false)
  }

  @Test func effectiveInput_unresolvableUid_fallsBackToDefaultBluetooth() {
    // Cloud review P2: a disconnected pinned device records through the DEFAULT
    // input (the HAL source resolves a missing UID to the system default), so a
    // stale UID with a Bluetooth default must show the card, not fail closed.
    let result = BluetoothAwarenessPresenter.computeEffectiveInputIsBluetooth(
      preferredOverride: "ghost-device",
      autoInputIsBluetooth: { true },
      uidIsBluetooth: { _ in nil }  // removed/unknown device
    )
    #expect(result == true)
  }

  @Test func effectiveInput_unresolvableUid_defaultNotBluetooth_noCard() {
    // Stale UID but the default input is NOT Bluetooth → no card (no false positive).
    let result = BluetoothAwarenessPresenter.computeEffectiveInputIsBluetooth(
      preferredOverride: "ghost-device",
      autoInputIsBluetooth: { false },
      uidIsBluetooth: { _ in nil }
    )
    #expect(result == false)
  }

  @Test func effectiveInput_resolvedUidWins_ignoresDefault() {
    // A UID that DOES resolve is authoritative — the default is not consulted.
    let result = BluetoothAwarenessPresenter.computeEffectiveInputIsBluetooth(
      preferredOverride: "builtin",
      autoInputIsBluetooth: { true },  // default is BT...
      uidIsBluetooth: { _ in false }  // ...but the pinned built-in resolves non-BT
    )
    #expect(result == false)
  }

  @Test func effectiveInput_noDefaultDevice_failsClosed() {
    let result = BluetoothAwarenessPresenter.computeEffectiveInputIsBluetooth(
      preferredOverride: "",
      autoInputIsBluetooth: { nil },  // no default input device
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
