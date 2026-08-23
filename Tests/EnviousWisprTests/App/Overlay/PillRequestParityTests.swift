import CoreGraphics
import EnviousWisprCore
import EnviousWisprPipeline
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// Chunk C1 is a semantic no-op port, and this suite is what makes that claim
/// checkable rather than asserted (#2292 Phase 1).
///
/// **Every case drives the SAME request twice — once through the old ingress,
/// once through `OverlayPresenting` — and compares what an observer outside the
/// director can see.** Comparing the two requests to each other would prove
/// nothing: the whole risk of a port is that two spellings of the same intent
/// diverge in what they PRODUCE. So the comparison is on outputs only — what the
/// host was asked to present, what reached the screen reader, which effects were
/// emitted, and what the render model published.
///
/// **This suite runs in Release, and the reason is what it does NOT read.** The
/// existing director suite is `#if DEBUG` in its entirety because every case
/// reads private state through a debug-only accessor; 69 of the overlay's 141
/// tests are invisible to the Release lane for that reason. Nothing here reads
/// director state.
///
/// It does use `OverlayScheduler.manual` and `OverlayScheduledWork.fireForTesting`
/// to reach a dwell without waiting for one. Those are a fake CLOCK rather than a
/// window into private state, and neither is `#if DEBUG`, so the suite compiles
/// and executes in both lanes. C6 of this phase replaces them.
/// **Class: `.productOutcome`, and the judgment is worth stating because a parity suite could read as a
/// drift guard.** A drift guard freezes an internal property and fails when we change our own code. This
/// fails when the two spellings of one request produce DIFFERENT USER-VISIBLE RESULTS — a pill with a
/// button bound to nobody, the wrong copy, a screen-reader announcement that does not fire. Nothing calls
/// the façade in C1, so that divergence reaches a user only once C3 and C5 migrate the callers; the tag
/// describes what the suite PROTECTS, not when it activates.
@MainActor
@Suite("Pill request parity (#2292 C1)", .tags(.productOutcome))
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
        deliverEffect: { [self] in effects.append($0) },
        deliverAppAction: { [self] in
          appActions.append($0)
          if case .discardRecovery = $0 {
            discardSawPresentation = director.renderModel.presentation != nil
          }
        },
        scheduler: scheduler,
        announce: { [self] in announcements.append($0) },
        livePreview: .disabled,
        grantAccessibility: { [self] in
          appActions.append(.grantAccessibility)
          grantSawPresentation = director.renderModel.presentation != nil
        },
        deferFirstRender: { $0() })
    }

    /// What an observer outside the director can see, as one comparable value.
    @MainActor
    var observed: Observed {
      Observed(
        presentedWidths: host.presented.map(\.width),
        presentedFixedHeights: host.presented.map(\.fixedHeight),
        presentedFreshness: host.presented.map(\.isFresh),
        hideCount: host.hideCount,
        isShowing: host.isShowing,
        effects: effects,
        announcements: announcements,
        content: director.renderModel.presentation?.content,
        expiry: director.renderModel.presentation?.expiry,
        recordingLayout: director.renderModel.recordingLayout,
        // **The one public value that separates a pipeline intent from a feature
        // request.** Without it the two routing cases below compare identical
        // observations and cannot fail when a request travels through the wrong
        // enum — which is the exact defect they were written to catch.
        featureSlotIsAvailable: director.featureSlotIsAvailable)
    }
  }

  private struct Observed: Equatable {
    let presentedWidths: [OverlayWidth]
    let presentedFixedHeights: [CGFloat?]
    let presentedFreshness: [Bool]
    let hideCount: Int
    let isShowing: Bool
    let effects: [PillEffect]
    let announcements: [OverlayAnnouncement]
    let content: OverlayContent?
    let expiry: OverlayExpiry?
    let recordingLayout: OverlayRecordingLayout
    let featureSlotIsAvailable: Bool
  }

  /// Drive `old` on one rig and `new` on another, then compare every output.
  private func parity(
    _ label: String,
    old: (OverlayDirector) -> Void,
    new: (any OverlayPresenting) -> Void
  ) {
    let a = Rig()
    let b = Rig()
    old(a.director)
    new(b.director)
    #expect(a.observed == b.observed, "\(label): the façade diverged from the old ingress")
  }

  // MARK: - Pipeline-owned requests

  @Test("recording") func recording() {
    parity(
      "recording",
      old: {
        $0.presentRecording(
          audioLevel: 0.4, audioLevelProvider: { 0.4 },
          recordingElapsedProvider: { 3 }, isRecordingLocked: false, actions: nil)
      },
      new: {
        $0.present(.recording(RecordingPillInput(
          audioLevel: 0.4, audioLevelProvider: { 0.4 },
          recordingElapsedProvider: { 3 }, isLocked: false)))
      })
  }

  @Test("recording, born locked") func recordingLocked() {
    parity(
      "recording locked",
      old: {
        $0.presentRecording(
          audioLevel: 0.2, audioLevelProvider: { 0.2 },
          recordingElapsedProvider: { nil }, isRecordingLocked: true, actions: nil)
      },
      new: {
        $0.present(.recording(RecordingPillInput(
          audioLevel: 0.2, audioLevelProvider: { 0.2 },
          recordingElapsedProvider: { nil }, isLocked: true)))
      })
  }

  @Test("processing") func processing() {
    parity(
      "processing",
      old: { $0.send(.pipeline(.processing(phase: .transcribing)), actions: nil) },
      new: { $0.present(.processing(phase: .transcribing)) })
  }

  @Test("clipboard fallback") func clipboardFallback() {
    parity(
      "clipboardFallback",
      old: { $0.send(.pipeline(.clipboardFallback), actions: nil) },
      new: { $0.present(.clipboardFallback) })
  }

  @Test("warning") func warning() {
    parity(
      "warning",
      old: { $0.send(.pipeline(.warning(reason: .polishFailed)), actions: nil) },
      new: { $0.present(.warning(reason: .polishFailed)) })
  }

  @Test("error") func error() {
    parity(
      "error",
      old: { $0.send(.pipeline(.error(reason: .modelLoadFailed)), actions: nil) },
      new: { $0.present(.error(reason: .modelLoadFailed)) })
  }

  @Test("advisory") func advisory() {
    parity(
      "advisory",
      old: { $0.send(.pipeline(.advisory(reason: .zeroSignal)), actions: nil) },
      new: { $0.present(.advisory(reason: .zeroSignal)) })
  }

  @Test("interruption") func interruption() {
    parity(
      "interruption",
      old: { $0.send(.pipeline(.interruption(reason: .captureStalled)), actions: nil) },
      new: { $0.present(.interruption(reason: .captureStalled)) })
  }

  @Test("caching model") func cachingModel() {
    parity(
      "cachingModel",
      old: { $0.send(.pipeline(.cachingModel(engineLabel: "Parakeet")), actions: nil) },
      new: { $0.present(.cachingModel(engineLabel: "Parakeet")) })
  }

  @Test("engine ready") func engineReady() {
    parity(
      "engineReady",
      old: { $0.send(.pipeline(.engineReady), actions: nil) },
      new: { $0.present(.engineReady) })
  }

  @Test("recovery succeeded") func recoverySucceeded() {
    parity(
      "recoverySucceeded",
      old: { $0.send(.pipeline(.recoverySucceeded), actions: nil) },
      new: { $0.present(.recoverySucceeded) })
  }

  @Test("import status") func importStatus() {
    parity(
      "importStatus",
      old: { $0.send(.featureRequest(.importStatus(message: "Importing 12")), actions: nil) },
      new: { $0.present(.importStatus(message: "Importing 12")) })
  }

  // MARK: - Feature-owned requests

  @Test("accessibility notice") func accessibilityNotice() {
    parity(
      "accessibilityNotice",
      old: { $0.presentAccessibilityNotice() },
      new: { $0.present(.accessibilityNotice) })
  }

  @Test("recovery notice") func recoveryNotice() {
    parity(
      "recoveryNotice",
      old: { $0.presentRecoveryNotice() },
      new: { $0.present(.recoveryNotice(onDiscard: {})) })
  }

  /// **The chip travels as a `.pipeline` intent, not a `.featureRequest`.**
  /// `OverlayIntent` and `OverlayRequest` both declare a `passiveChip` case, so
  /// the wrong one compiles and only differs in whether `pipelineIntent` is set
  /// — which is exactly what the language presenter arbitrates against. This
  /// case is the one that catches it.
  @Test("language chip routes through the pipeline intent") func languageChip() {
    let payload = LanguageChipPayload(
      lang: "es", displayName: "Spanish", state: .askToLock, generation: 1)
    parity(
      "languageChip",
      old: { $0.send(.pipeline(.passiveChip(payload: payload)), actions: { _ in }) },
      new: {
        $0.present(.languageChip(
          payload: payload, onLock: {}, onDismiss: {}, onExpire: {}))
      })
  }

  /// The mirror image of the chip: Bluetooth genuinely IS a `.featureRequest`.
  @Test("bluetooth awareness routes through the feature request") func bluetooth() {
    parity(
      "bluetoothAwareness",
      old: { $0.send(.featureRequest(.bluetoothAwareness), actions: { _ in }) },
      new: {
        $0.present(.bluetoothAwareness(
          onAcknowledge: {}, onClose: {}, onOpenSettings: {}))
      })
  }

  // MARK: - Updates and dismissal

  @Test("recording lock update") func lockUpdate() {
    parity(
      "recordingLock",
      old: {
        $0.presentRecording(
          audioLevel: 0.1, audioLevelProvider: { 0.1 },
          recordingElapsedProvider: { nil }, isRecordingLocked: false, actions: nil)
        $0.send(.lockStateChanged(true), actions: nil)
      },
      new: {
        $0.present(.recording(RecordingPillInput(
          audioLevel: 0.1, audioLevelProvider: { 0.1 },
          recordingElapsedProvider: { nil }, isLocked: false)))
        $0.update(.recordingLock(true))
      })
  }

  @Test("in-panel notice update") func inPanelNoticeUpdate() {
    parity(
      "inPanelNotice",
      old: {
        $0.presentRecording(
          audioLevel: 0.1, audioLevelProvider: { 0.1 },
          recordingElapsedProvider: { nil }, isRecordingLocked: false, actions: nil)
        $0.send(.inPanelNotice(.approachingCap, dismissAfter: 2), actions: nil)
      },
      new: {
        $0.present(.recording(RecordingPillInput(
          audioLevel: 0.1, audioLevelProvider: { 0.1 },
          recordingElapsedProvider: { nil }, isLocked: false)))
        $0.update(.inPanelNotice(.approachingCap, dismissAfter: 2))
      })
  }

  /// **Announced and silent dismissal are different operations and the
  /// difference is audible.** A chip dismissal that announced "Recording
  /// complete" would be a false statement to a VoiceOver user, so the two must
  /// not collapse into one façade call.
  @Test("announced dismissal") func announcedDismissal() {
    parity(
      "dismiss announced",
      old: {
        $0.send(.pipeline(.engineReady), actions: nil)
        $0.send(.pipeline(.hidden), actions: nil)
      },
      new: {
        $0.present(.engineReady)
        $0.dismissCurrent(.announced)
      })
  }

  @Test("silent dismissal") func silentDismissal() {
    parity(
      "dismiss silent",
      old: {
        $0.send(.pipeline(.engineReady), actions: nil)
        $0.dismissSilently()
      },
      new: {
        $0.present(.engineReady)
        $0.dismissCurrent(.silent)
      })
  }

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

  @Test("escape recovery") func escapeRecovery() {
    let payload = CancelUndoPayload(transcriptID: UUID(), targetApp: nil, targetElement: nil)
    parity(
      "escapeRecovery",
      old: { $0.presentEscapeRecovery(payload, actions: { _ in }) },
      new: { $0.present(.escapeRecovery(payload: payload, onPaste: { _ in })) })
  }

  /// **Dismiss BEFORE forwarding, matching shipped behaviour.**
  /// `EscapeRecoveryWiring` dismisses first so a spoken "overlay hidden" does not
  /// land on top of the restore the user asked for. That is the only reason:
  /// `pasteAction` copies to the clipboard and dispatches a keystroke, and raises
  /// no pill.
  @Test("Undo dismisses the pill before it forwards the payload") func pasteOrdering() {
    let rig = Rig()
    let payload = CancelUndoPayload(transcriptID: UUID(), targetApp: nil, targetElement: nil)
    var hiddenWhenPasted: Bool?
    rig.director.present(.escapeRecovery(payload: payload, onPaste: { [rig] _ in
      hiddenWhenPasted = rig.host.isShowing == false
    }))
    rig.director.send(
      .action(rig.director.renderModel.presentation!.id, .pasteEscapeRecovery(transcriptID: payload.transcriptID)),
      actions: nil)
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
  @Test("a queued second Undo is ignored after dismissal") func queuedSecondUndoIsIgnored() {
    let rig = Rig()
    let payload = CancelUndoPayload(transcriptID: UUID(), targetApp: nil, targetElement: nil)
    var pastes = 0
    rig.director.present(.escapeRecovery(payload: payload, onPaste: { _ in pastes += 1 }))
    let id = rig.director.renderModel.presentation!.id
    let press = OverlayEvent.action(id, .pasteEscapeRecovery(transcriptID: payload.transcriptID))
    rig.director.send(press, actions: nil)
    rig.director.send(press, actions: nil)
    #expect(
      pastes == 1,
      "the first press dismissed this presentation; the second event is stale")
  }

  // MARK: - Recovery discard, which must also clear the notice

  @Test("Discard calls its owner and then hides the notice") func discardDismisses() {
    let rig = Rig()
    var discards = 0
    rig.director.present(.recoveryNotice(onDiscard: { discards += 1 }))
    let id = rig.director.renderModel.presentation!.id
    rig.director.send(.action(id, .discardRecovery), actions: nil)
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
  func everyActionIsBound() {
    var fired: [String] = []
    let chipRig = Rig()
    chipRig.director.present(.languageChip(
      payload: LanguageChipPayload(lang: "es", displayName: "Spanish", state: .askToLock, generation: 1),
      onLock: { fired.append("lock") },
      onDismiss: { fired.append("dismiss") },
      onExpire: { fired.append("expire") }))
    let chipID = chipRig.director.renderModel.presentation!.id
    chipRig.director.send(.action(chipID, .lockLanguage), actions: nil)

    let dismissRig = Rig()
    dismissRig.director.present(.languageChip(
      payload: LanguageChipPayload(lang: "es", displayName: "Spanish", state: .askToLock, generation: 1),
      onLock: {}, onDismiss: { fired.append("dismiss") }, onExpire: {}))
    let dismissID = dismissRig.director.renderModel.presentation!.id
    dismissRig.director.send(.action(dismissID, .dismissChip), actions: nil)

    for (action, label) in [
      (PillAction.acknowledgeBluetoothAwareness, "gotIt"),
      (PillAction.closeBluetoothAwareness, "close"),
      (PillAction.openBluetoothSettings, "settings"),
    ] {
      let rig = Rig()
      rig.director.present(.bluetoothAwareness(
        onAcknowledge: { fired.append("gotIt") },
        onClose: { fired.append("close") },
        onOpenSettings: { fired.append("settings") }))
      let id = rig.director.renderModel.presentation!.id
      rig.director.send(.action(id, action), actions: nil)
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
    rig.director.present(.accessibilityNotice)
    let id = try #require(rig.director.renderModel.presentation?.id)
    rig.director.send(.action(id, .grantAccessibility), actions: nil)
    #expect(rig.appActions == [.grantAccessibility])
  }

  /// **Grant, THEN dismiss — the shipped order, and the two halves are separate
  /// claims.** Before C2 both lived in `OverlayOutputRouter`
  /// (`permissions?.requestAccessibilityAccess()` then
  /// `overlay?.dismissSilently()`); C2 moved them into the director, so the
  /// ordering had to move with them rather than be re-derived.
  ///
  /// REPRODUCIBLE, and it is the same user in both directions. Someone without
  /// Accessibility permission is shown the notice and clicks Grant. Dismissing
  /// first races the system's own permission prompt against the pill's teardown;
  /// never dismissing leaves a pill the user has already answered sitting over
  /// their work with no way to clear it.
  ///
  /// Release-visible on purpose: `OverlayDirectorTests` is entirely `#if DEBUG`,
  /// so nothing else in this behaviour is exercised by a Release lane.
  @Test("Grant runs before the notice is dismissed, and the notice then goes")
  func grantRunsBeforeDismissal() throws {
    let rig = Rig()
    rig.director.present(.accessibilityNotice)
    let id = try #require(rig.director.renderModel.presentation?.id)

    rig.director.send(.action(id, .grantAccessibility), actions: nil)

    #expect(
      rig.grantSawPresentation == true,
      "the notice was dismissed before Grant ran, racing the system prompt")
    #expect(
      rig.director.renderModel.presentation == nil,
      "the notice the user already answered is still on screen")
  }

  /// The same two claims for Discard, whose owner still lives outside the
  /// director until C4 — so only the DISMISSAL moved here, and this is what pins
  /// that it did not also move ahead of the owner.
  ///
  /// REPRODUCIBLE: a user whose last recording is being recovered presses
  /// Discard. Dismissing first would leave the recovery running with its notice
  /// gone; never dismissing leaves an answered pill on screen.
  @Test("Discard reaches its owner before the recovery notice is dismissed")
  func discardRunsBeforeDismissal() throws {
    let rig = Rig()
    rig.director.presentRecoveryNotice()
    let id = try #require(rig.director.renderModel.presentation?.id)

    rig.director.send(.action(id, .discardRecovery), actions: nil)

    #expect(rig.appActions == [.discardRecovery], "Discard reached nobody")
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
    armed.fireForTesting()

    #expect(expiries == 1, "the request's own onExpire must run")
    #expect(
      rig.effects.contains(.languageChipExpired(generation: 7)) == false,
      "a typed request owns its expiry; broadcasting it too would clear the chip twice")
  }

  /// The two-way control: with no typed request bound, the same expiry still
  /// reaches the composition root exactly as it does today. Without this, the
  /// case above would pass just as well against a director that dropped the
  /// effect entirely.
  @Test("with no typed request, the expiry still reaches the effect sink")
  func expiryFallsBackToTheEffectSink() {
    let rig = Rig(manualClock: true)
    rig.director.send(
      .pipeline(.passiveChip(payload: LanguageChipPayload(
        lang: "fr", displayName: "French", state: .askToLock, generation: 9))),
      actions: { _ in })

    let armed = try! #require(rig.armedExpiry)
    armed.fireForTesting()

    #expect(
      rig.effects.contains(.languageChipExpired(generation: 9)),
      "the legacy route is unchanged for callers that supplied no onExpire")
  }

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
