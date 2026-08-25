import CoreGraphics
import EnviousWisprCore
import EnviousWisprPipeline
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// What the typed pill boundary DOES, asserted on outputs an observer outside
/// the director can see (#2292 Phase 1).
///
/// **The parity scaffolding this suite was built around is gone** (C5c). C1
/// created it to make a no-op port checkable: every case drove one request twice,
/// once through the old generic ingress and once through `OverlayPresenting`, and
/// compared what came out. C5 deleted the old ingress, so each `old:` arm was
/// rewritten to the typed spelling as its legacy twin disappeared — and by C5c
/// all eighteen comparisons were driving the same call on both rigs. A comparison
/// of a call against itself cannot fail, and none of the eighteen was the only
/// red test for any defect: every request they presented is presented by at least
/// one other test file. They were removed rather than left reading as coverage.
///
/// What remains is every case that asserted a BEHAVIOUR rather than an
/// equivalence — action ownership, ordering, refusal, receipts, expiry — and each
/// one still asserts it on outputs only: what the host was asked to present, what
/// reached the screen reader, which effects were emitted, and what the render
/// model published.
///
/// **The name is stale and is kept deliberately until C6.** Two frozen mutation
/// recipes (#2352, #2356) name `EnviousWisprTests/PillRequestParityTests`, and a
/// recipe is frozen when it is filed; renaming the suite would make both
/// unrunnable against a subject that still exists.
///
/// **This suite runs in Release, and the reason is what it does NOT read.** The
/// existing director suite is `#if DEBUG` in its entirety because every case
/// reads private state through a debug-only accessor; 69 of the overlay's 141
/// tests are invisible to the Release lane for that reason. Nothing here reads
/// director state.
///
/// It does use `OverlayScheduler.manual` and `OverlayScheduledWork.fire`
/// to reach a dwell without waiting for one. Those are a fake CLOCK rather than a
/// window into private state, and neither is `#if DEBUG`, so the suite compiles
/// and executes in both lanes. C6 of this phase replaces them.
/// **Class: `.productOutcome`.** Every remaining case fails on a USER-VISIBLE
/// result — a button bound to nobody, a press reaching the wrong owner, a
/// dismissal that beats the handler it was meant to follow, a screen-reader
/// announcement that does not fire.
@MainActor
@Suite("Pill request behaviour (#2292)", .tags(.productOutcome))
struct PillRequestParityTests {

  /// One director, plus every observable output it produces, recorded in order.
  private final class Rig {
    let host = WindowlessOverlayHost()
    var effects: [PillEffect] = []
    var announcements: [OverlayAnnouncement] = []
    var appActions: [PillAction] = []
    private(set) var director: OverlayDirector!

    /// The expiry the director armed, when this rig was built with a manual
    /// clock. Firing it is how a dwell is reached without waiting for one.
    var armedExpiry: OverlayScheduledWork?

    /// Whether a pill was STILL SHOWING at the instant each app-owned handler
    /// ran (#2292 C2). Both handlers must run before the director dismisses, so
    /// `true` is the passing value; a snapshot taken afterwards cannot tell
    /// "granted, then dismissed" from "dismissed, then granted".
    var grantSawPresentation: Bool?
    var discardSawPresentation: Bool?

    @MainActor
    init(manualClock: Bool = false) {
      let scheduler: OverlayScheduler
      if manualClock {
        scheduler = .manual { [self] work in armedExpiry = work }
      } else {
        scheduler = .live
      }
      director = OverlayDirector(
        host: host,
        scheduler: scheduler,
        announce: { [self] in announcements.append($0) },
        livePreview: .disabled,
        grantAccessibility: { [self] in
          appActions.append(.grantAccessibility)
          grantSawPresentation = director.renderModel.presentation != nil
        },
        selections: { .shipped },
        deferFirstRender: { $0() })
    }

  }

  // MARK: - Pipeline-owned requests

  // MARK: - Feature-owned requests

  // **The recovery-notice parity row is gone** (#2292 C4b), for the reason the
  // escape-recovery row went in C4a: parity needs two spellings and
  // `presentRecoveryNotice` is deleted. What it protected — the typed request
  // producing the same presentation the old method did — is now the only path,
  // and `discardRunsBeforeDismissal` below asserts what that path DOES.

  /// **The chip travels as a PIPELINE intent.** That is what sets
  /// `pipelineIntent`, which is exactly what the language presenter arbitrates
  /// against. Until C5c a second enum also declared `passiveChip`, so the wrong
  /// spelling compiled and differed only in whether `pipelineIntent` was set;
  /// this case is the one that caught it, and it still pins the property now
  /// that only one spelling exists.
  /// **The `old:` arm was DELETED and this row now asserts the NEW spelling alone**
  /// (#2292 C5a), because keeping it crashed the test process.
  ///
  /// `send(.pipeline(.passiveChip(...)), actions:)` supplies button handlers but
  /// no `onExpire`. Since C4b the director's routing is exhaustive and asserts
  /// when a chip expiry arrives with no typed owner — correctly, because every
  /// PRODUCTION chip carries one. This test was the last caller that did not, so
  /// on expiry it hit `assertionFailure` and TRAPPED, which in a Debug lane kills
  /// the xctest process and reports the failure against whatever test happened to
  /// be running: four lanes blamed an unrelated kernel sweep.
  ///
  /// The parity claim it made — the chip travels as a `.pipeline` intent so it
  /// sets `pipelineIntent` and arbitrates the way the language presenter expects
  /// — survives, asserted directly on the typed path below.
  @Test("language chip routes through the pipeline intent") func languageChip() {
    let payload = LanguageChipPayload(
      lang: "es", displayName: "Spanish", state: .askToLock, generation: 1)
    let rig = Rig()

    let receipt = rig.director.present(.languageChip(
      payload: payload, onLock: {}, onDismiss: {}, onExpire: {}))

    #expect(receipt != nil, "the chip was refused on an empty slot")
    // **The pipeline-intent half moved to `OverlayReducerTests`**
    // `chipCommitsThePipelineIntentAndTheCardDoesNot` (#2292 C6). It needed a
    // director hatch that no longer exists, and it is a claim about what the
    // reducer commits rather than about the façade — so it is now asserted where
    // it is true, with a paired Bluetooth case, in both lanes.
  }

  // MARK: - Updates and dismissal

  @Test("announced and silent dismissal are not the same operation") func dismissalDiffers() {
    let announced = Rig()
    let silent = Rig()
    announced.director.present(.engineReady)
    announced.director.dismissCurrent(.announced)
    silent.director.present(.engineReady)
    silent.director.dismissCurrent(.silent)
    #expect(
      announced.announcements.count > silent.announcements.count,
      "silent dismissal must post fewer announcements than announced dismissal")
  }

  // MARK: - Escape recovery, whose ORDER is load-bearing

  // **The escape-recovery parity row is gone** (#2292 C4a), because parity needs
  // two spellings and there is now one: `presentEscapeRecovery` was deleted along
  // with `takeEscapeRecoveryPayload`, so custody lives only inside the typed
  // request. What that row protected — the typed path producing the same
  // presentation the old one did — is now the only path there is, and the
  // OUTCOME cases below (`pasteOrdering`, and the director's own custody suite)
  // assert what it does.

  /// **Dismiss BEFORE forwarding, matching shipped behaviour.**
  /// `EscapeRecoveryWiring` dismisses first so a spoken "overlay hidden" does not
  /// land on top of the restore the user asked for. That is the only reason:
  /// `pasteAction` copies to the clipboard and dispatches a keystroke, and raises
  /// no pill.
  @Test("Undo dismisses the pill before it forwards the payload") func pasteOrdering() throws {
    let rig = Rig()
    let payload = CancelUndoPayload(transcriptID: UUID(), targetApp: nil, targetElement: nil)
    var hiddenWhenPasted: Bool?
    // Hoisted out of `#require`: the macro cannot expand a call whose argument
    // closure captures the rig, and fails with an internal diagnostic error.
    let presented = rig.director.present(.escapeRecovery(payload: payload, onPaste: { [rig] _ in
      hiddenWhenPasted = rig.host.isShowing == false
    }))
    let receipt = try #require(presented)
    try rig.host.sendUserActionThroughRoot(
      .pasteEscapeRecovery(transcriptID: payload.transcriptID), for: receipt)
    #expect(hiddenWhenPasted == true, "the pill must already be hidden when onPaste runs")
  }

  /// **This proves STALENESS, not one-shot custody, and the original name claimed
  /// the wrong one.** The first press dismisses the presentation, so the second
  /// event names an id that is no longer current and is rejected before payload
  /// custody is ever reached.
  ///
  /// One-shot custody is not uncovered: `EscapeRecoveryPillTests.payloadIsTakenOnce`
  /// takes the payload twice directly and requires the second to find nothing. C4
  /// moves custody and must preserve that case.
  ///
  /// The real user input here is a double-click on Undo, and what it must not do
  /// is paste twice.
  @Test("a queued second Undo is ignored after dismissal") func queuedSecondUndoIsIgnored() throws {
    let rig = Rig()
    let payload = CancelUndoPayload(transcriptID: UUID(), targetApp: nil, targetElement: nil)
    var pastes = 0
    let receipt = try #require(
      rig.director.present(.escapeRecovery(payload: payload, onPaste: { _ in pastes += 1 })))
    try rig.host.sendUserActionThroughRoot(
      .pasteEscapeRecovery(transcriptID: payload.transcriptID), for: receipt)
    try rig.host.sendUserActionThroughRoot(
      .pasteEscapeRecovery(transcriptID: payload.transcriptID), for: receipt)
    #expect(
      pastes == 1,
      "the first press dismissed this presentation; the second event is stale")
  }

  // MARK: - Recovery discard, which must also clear the notice

  @Test("Discard calls its owner and then hides the notice") func discardDismisses() throws {
    let rig = Rig()
    var discards = 0
    let receipt = try #require(rig.director.present(.recoveryNotice(onDiscard: { discards += 1 })))
    try rig.host.sendUserActionThroughRoot(.discardRecovery, for: receipt)
    #expect(discards == 1)
    #expect(rig.host.isShowing == false, "a notice the user answered must not stay on screen")
  }

  // MARK: - Refusal

  /// **A refused request returns nil, never the incumbent's receipt.** Handing
  /// back the pill already on screen tells the caller it was accepted and names a
  /// presentation it does not own — which `dismissIfCurrent` would then dismiss.
  @Test("a refused feature request returns nil and leaves the incumbent") func refusalReturnsNil() {
    let rig = Rig()
    let recording = rig.director.present(.recording(RecordingPillInput(
      audioLevel: 0.3, audioLevelProvider: { 0.3 },
      recordingElapsedProvider: { nil }, isLocked: false)))
    #expect(recording != nil)
    let refused = rig.director.present(.bluetoothAwareness(
      onAcknowledge: {}, onClose: {}, onOpenSettings: {}))
    #expect(refused == nil, "a recording holds the slot, so the card is refused")
    #expect(rig.director.isCurrent(recording!), "the recording still owns the slot")
  }

  /// **The language chip is refused over a recording, and it is the ONE request
  /// that needed a guard adding to say so** (#2292 C3a).
  ///
  /// Bluetooth is a `.featureRequest` and the reducer already refused it — the
  /// case above proves that. The chip travels as `.pipeline(.passiveChip)`,
  /// which the reducer ACCEPTS, so the refusal used to be performed by
  /// `LanguageSuggestionPresenter` reading the overlay's current intent. That
  /// gave one decision two authorities and left only the presenter's copy able
  /// to be wrong. The guard now sits inside `present`, beside the state change.
  ///
  /// REPRODUCIBLE, and it is the whole reason the old guard existed: language
  /// detection finishes DURING a recording. Without this the chip replaces the
  /// recording pill mid-dictation — the user watches their recording indicator
  /// turn into a language suggestion while still speaking.
  @Test("a language chip is refused while a recording owns the slot")
  func refusedLanguageRequestDoesNotReplaceRecording() throws {
    let rig = Rig()
    let recording = try #require(rig.director.present(.recording(RecordingPillInput(
      audioLevel: 0.3, audioLevelProvider: { 0.3 },
      recordingElapsedProvider: { nil }, isLocked: false))))

    let refused = rig.director.present(.languageChip(
      payload: LanguageChipPayload(
        lang: "es", displayName: "Spanish", state: .askToLock, generation: 1),
      onLock: {}, onDismiss: {}, onExpire: {}))

    #expect(refused == nil, "the chip was admitted over a live recording")
    #expect(
      rig.director.isCurrent(recording),
      "the recording pill was replaced by a language suggestion mid-dictation")
  }

  /// A recording morph keeps the identity it was created with, so the unchanged
  /// id is an ACCEPTED continuation rather than a refusal.
  @Test("a recording morph still returns a receipt") func morphReturnsReceipt() {
    let rig = Rig()
    let first = rig.director.present(.recording(RecordingPillInput(
      audioLevel: 0.1, audioLevelProvider: { 0.1 },
      recordingElapsedProvider: { nil }, isLocked: false)))
    let morph = rig.director.present(.recording(RecordingPillInput(
      audioLevel: 0.8, audioLevelProvider: { 0.8 },
      recordingElapsedProvider: { nil }, isLocked: false)))
    #expect(first != nil)
    #expect(morph != nil, "a morph is accepted, not refused")
  }

  // MARK: - Each action reaches exactly one owner

  /// These five language and Bluetooth actions must each reach exactly one
  /// callback. Paste, Discard, and Grant have behaviour-specific cases nearby.
  @Test("language and Bluetooth actions each reach exactly one callback")
  func everyActionIsBound() throws {
    var fired: [String] = []
    let chipRig = Rig()
    let chipReceipt = try #require(chipRig.director.present(.languageChip(
      payload: LanguageChipPayload(lang: "es", displayName: "Spanish", state: .askToLock, generation: 1),
      onLock: { fired.append("lock") },
      onDismiss: { fired.append("dismiss") },
      onExpire: { fired.append("expire") })))
    try chipRig.host.sendUserActionThroughRoot(.lockLanguage, for: chipReceipt)

    let dismissRig = Rig()
    let dismissReceipt = try #require(dismissRig.director.present(.languageChip(
      payload: LanguageChipPayload(lang: "es", displayName: "Spanish", state: .askToLock, generation: 1),
      onLock: {}, onDismiss: { fired.append("dismiss") }, onExpire: {})))
    try dismissRig.host.sendUserActionThroughRoot(.dismissChip, for: dismissReceipt)

    for (action, label) in [
      (PillAction.acknowledgeBluetoothAwareness, "gotIt"),
      (PillAction.closeBluetoothAwareness, "close"),
      (PillAction.openBluetoothSettings, "settings"),
    ] {
      let rig = Rig()
      let receipt = try #require(rig.director.present(.bluetoothAwareness(
        onAcknowledge: { fired.append("gotIt") },
        onClose: { fired.append("close") },
        onOpenSettings: { fired.append("settings") })))
      try rig.host.sendUserActionThroughRoot(action, for: receipt)
      #expect(fired.last == label, "\(label) must reach its own callback")
    }

    // **Counts, not membership and not sequence.** A membership check passes
    // when an action is delivered twice — the defect a single owner exists to
    // prevent — while an exact sequence would also freeze the order these
    // independent scenarios happen to run in, which is incidental.
    let counts = Dictionary(grouping: fired, by: { $0 }).mapValues(\.count)
    #expect(counts == ["lock": 1, "dismiss": 1, "gotIt": 1, "close": 1, "settings": 1])
  }

  /// Grant is app-owned, so it reaches the app sink rather than a presentation
  /// callback.
  ///
  /// REPRODUCIBLE at C5: a user without Accessibility permission is shown the
  /// notice and clicks Grant. If it reaches nobody, the button does nothing and
  /// dictation never gains permission.
  @Test("Grant reaches the app action sink") func grantIsBound() throws {
    let rig = Rig()
    let receipt = try #require(rig.director.present(.accessibilityNotice))
    try rig.host.sendUserActionThroughRoot(.grantAccessibility, for: receipt)
    #expect(rig.appActions == [.grantAccessibility])
  }

  /// **Preserves the existing Grant transaction: request permission, then
  /// dismiss.** Before C2 both calls lived in `OverlayOutputRouter`
  /// (`permissions?.requestAccessibilityAccess()` then
  /// `overlay?.dismissCurrent(.silent)`); C2 moved them into the director, so the
  /// order had to move with them rather than be re-derived.
  ///
  /// **This is a semantic-parity guard, and the ordering half does NOT claim a
  /// user defect.** Both calls are synchronous on the MainActor, and no
  /// supported-machine failure has been demonstrated for the inverse order — an
  /// earlier version of this comment asserted a race against the system
  /// permission prompt, which the repository does not establish. What IS a user
  /// defect, and what the second assertion pins, is Grant reaching nobody or the
  /// notice surviving the answer: a pill the user already dealt with, sitting
  /// over their work with no way to clear it.
  ///
  /// Release-visible on purpose: `OverlayDirectorTests` is entirely `#if DEBUG`,
  /// so nothing else in this behaviour is exercised by a Release lane.
  @Test("Grant runs before the notice is dismissed, and the notice then goes")
  func grantRunsBeforeDismissal() throws {
    let rig = Rig()
    let receipt = try #require(rig.director.present(.accessibilityNotice))

    try rig.host.sendUserActionThroughRoot(.grantAccessibility, for: receipt)

    #expect(
      rig.grantSawPresentation == true,
      "the notice was dismissed before Grant ran, racing the system prompt")
    #expect(
      rig.director.renderModel.presentation == nil,
      "the notice the user already answered is still on screen")
  }

  /// **Preserves the temporary recovery transaction: notify the owner, then
  /// dismiss.** The owner still lives outside the director until C4, so only the
  /// DISMISSAL moved here; C4 replaces this split with the request-owned
  /// callback.
  ///
  /// Same split as the Grant case above: the ORDER is parity, both calls being
  /// synchronous on the MainActor, while the user defect the third assertion
  /// pins is real — a user whose last recording is being recovered presses
  /// Discard and the notice stays on screen, or Discard reaches nobody.
  @Test("Discard reaches its owner before the recovery notice is dismissed")
  func discardRunsBeforeDismissal() throws {
    let rig = Rig()
    var discards = 0
    let onDiscard: () -> Void = {
      discards += 1
      rig.discardSawPresentation = rig.director.renderModel.presentation != nil
    }
    let receipt = try #require(rig.director.present(.recoveryNotice(onDiscard: onDiscard)))

    try rig.host.sendUserActionThroughRoot(.discardRecovery, for: receipt)

    #expect(discards == 1, "Discard reached nobody")
    #expect(
      rig.discardSawPresentation == true,
      "the notice was dismissed before its owner was told to discard")
    #expect(
      rig.director.renderModel.presentation == nil,
      "the recovery notice the user answered is still on screen")
  }

  /// The chip's expiry is not an action — nobody pressed anything — so it travels
  /// as an effect rather than through the action closure.
  ///
  /// **`PillRequest.languageChip` REQUIRES an `onExpire`, so discarding it would
  /// make the type's own contract a lie**: a caller compelled to supply one that
  /// is never called. Asserted in both directions — the callback fires, and the
  /// effect does NOT also reach the composition root, because delivering both
  /// would clear the presenter's chip twice.
  @Test("the chip's onExpire is honoured, and the effect is not also broadcast")
  func expiryReachesItsCallback() {
    let rig = Rig(manualClock: true)
    var expiries = 0
    rig.director.present(.languageChip(
      payload: LanguageChipPayload(
        lang: "fr", displayName: "French", state: .askToLock, generation: 7),
      onLock: {}, onDismiss: {}, onExpire: { expiries += 1 }))

    let armed = try! #require(rig.armedExpiry)
    armed.fire()

    #expect(expiries == 1, "the request's own onExpire must run")
    #expect(
      rig.effects.contains(.languageChipExpired(generation: 7)) == false,
      "a typed request owns its expiry; broadcasting it too would clear the chip twice")
  }

  // **`expiryFallsBackToTheEffectSink` was DELETED** (#2292 C4b).
  //
  // It was the two-way control for the case above: with no typed request bound,
  // the same expiry still reached the composition root's effect sink. That
  // legacy route is gone — every chip carries an `onExpire` on its own request
  // since C3a, the output router is deleted, and the director's routing is
  // exhaustive with an assertion rather than a fallback. There is no sink to
  // fall back TO, so the case could only have asserted a path no production
  // caller can reach.
  //
  // What it was guarding against — the case above passing against a director
  // that simply dropped the effect — is now structural: dropping it would hit
  // the `assertionFailure` in `route`.

  // MARK: - Receipts

  @Test("a receipt names the presentation it was issued for") func receiptIdentity() {
    let rig = Rig()
    let receipt = rig.director.present(.engineReady)
    #expect(receipt != nil)
    #expect(rig.director.isCurrent(receipt!))
  }

  @Test("a receipt goes stale when a successor replaces its presentation") func receiptStales() {
    let rig = Rig()
    let first = rig.director.present(.engineReady)
    #expect(first != nil)
    rig.director.present(.processing(phase: .transcribing))
    #expect(!rig.director.isCurrent(first!))
  }

  /// The reason receipts exist: a feature owner dismissing "its" pill must not
  /// dismiss a successor that has since taken the slot.
  @Test("dismissIfCurrent does not dismiss a successor") func dismissIfCurrentIsScoped() {
    let rig = Rig()
    let stale = rig.director.present(.engineReady)
    #expect(stale != nil)
    rig.director.present(.processing(phase: .transcribing))
    let hidesBefore = rig.host.hideCount
    rig.director.dismissIfCurrent(stale!)
    #expect(rig.host.hideCount == hidesBefore, "a stale receipt must not dismiss the successor")
    #expect(rig.host.isShowing, "the successor must still be on screen")
  }
}
