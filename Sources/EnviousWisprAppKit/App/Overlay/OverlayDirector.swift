import AppKit
import SwiftUI
import CoreGraphics
import EnviousWisprCore
import EnviousWisprPipeline
import Foundation

/// Owns the presentation TRANSACTION (#2292, chunk C4b).
///
/// It invokes the reducer, drives the host, and owns **exactly one** expiry and
/// **exactly one** active action binding. Everything it holds is either a
/// collaborator or a single-valued piece of transaction state; if this type ever
/// grows a per-kind field collection it has become the thing the migration is
/// removing.
///
/// **Not yet authoritative or production-owned.** C4c installs this director at
/// the composition root and injects the retained host. Nothing but the tests
/// instantiates it today — an earlier version of this comment claimed the panel
/// owned it, which was simply untrue and is the exact shape of comment this
/// migration keeps finding: confident, plausible, and describing code that does
/// not exist.
@MainActor
final class OverlayDirector {

  private var reducer: OverlayReducer
  private let host: OverlayWindowHost
  private let model: OverlayRenderModel
  private let schedule: OverlayScheduler

  /// The ONE armed expiry. Replacing it cancels whatever was armed, which is
  /// what makes a stale dismissal structurally impossible rather than merely
  /// guarded against.
  private var armedExpiry: OverlayScheduledWork?

  /// The ONE active action binding. The shipped panel keeps eight `set*Handler`
  /// closures alive for the app's lifetime whether or not the pill that uses
  /// them is showing; this holds the binding for the presentation that is
  /// actually on screen and drops it when that presentation goes.
  private var activeBinding: (id: PresentationID, deliver: (OverlayAction) -> Void)?

  /// Custody of the cancelled-transcript payload.
  ///
  /// **The director owns it, not the action.** `.pasteEscapeRecovery` carries
  /// the transcript ID as a LOOKUP KEY; the payload itself is held here and
  /// taken once. A one-shot take is what makes a stale Undo press safe — the
  /// second press finds nothing rather than pasting twice.
  private var escapeRecoveryPayload: (id: UUID, payload: CancelUndoPayload)?

  /// Required, immutable, and injected. It was a settable `var` for one round —
  /// one more mutable handler field on the type whose whole purpose is to have
  /// fewer, and one where a caller that forgot to wire it would silently discard
  /// effects a feature depends on.
  private let deliverEffect: (OverlayEffect) -> Void

  /// **ONE hosting view for THIS DIRECTOR's lifetime**, created lazily and
  /// reused. The model is observable, so the same view re-renders rather than
  /// being rebuilt — the SwiftUI half of the same claim the retained `NSPanel`
  /// makes about the window. "For the app's lifetime" is a property of the
  /// COMPOSITION ROOT holding the director, not something this file can promise.
  ///
  /// The view sends whole events and supplies the presentation's own ID; this
  /// closure no longer looks one up. It used to read `reducer.state.current?.id`
  /// at press time, which relabels a click on an outgoing pill with its
  /// SUCCESSOR's identity — so the staleness check below passes it through and
  /// the wrong pill's handler runs.
  private lazy var rootHostingView: NSView = NSHostingView(
    rootView: OverlayRootView(
      model: model,
      sendEvent: { [weak self] event in self?.send(event, actions: nil) }))

  /// The occupant the host is currently showing, so a morph can be told from a
  /// fresh presentation. The host needs that distinction to decide whether to
  /// re-anchor or preserve the live frame, and it is the CALLER's fact.
  private var presentedID: PresentationID?

  private let position: () -> OverlayPillPosition

  init(
    host: OverlayWindowHost,
    deliverEffect: @escaping (OverlayEffect) -> Void,
    position: @escaping () -> OverlayPillPosition = { .top },
    model: OverlayRenderModel = OverlayRenderModel(),
    scheduler: OverlayScheduler = .live,
    makeID: @escaping () -> PresentationID = { PresentationID() }
  ) {
    self.host = host
    self.deliverEffect = deliverEffect
    self.position = position
    self.model = model
    self.schedule = scheduler
    self.reducer = OverlayReducer(makeID: makeID)
  }

  var renderModel: OverlayRenderModel { model }

  // MARK: - The transaction

  /// `actions` is the handler for the presentation this event PRODUCES, and it
  /// arrives with the request rather than after it.
  ///
  /// A separate `bind(for:)` call made binding a post-publication operation: the
  /// caller had to bind after the presentation existed, an ordering nothing
  /// enforced, and a window in which the pill was on screen with no handler. A
  /// request carries its own handler or it has none by construction.
  /// **No default.** `actions` defaulting to nil let a call site that SHOULD
  /// carry a handler compile silently without one, which defeats the entire
  /// point of making the binding arrive with the request: the omission has to be
  /// visible at the call site, not inferred from its absence.
  func send(_ event: OverlayEvent, actions: ((OverlayAction) -> Void)?) {
    let plan = reducer.reduce(event)
    apply(plan, actions: actions)
  }

  /// Take custody of a cancelled-transcript payload and present its pill.
  ///
  /// The id comes from the PAYLOAD. An earlier signature took it separately, so
  /// two ids could disagree and the pill would offer to restore a transcript the
  /// custody did not hold — an unrepresentable state made representable by an
  /// extra parameter.
  /// **Takes its handler.** Without one this method presented a pill whose Undo
  /// button had nothing bound, so the first press hit the invariant assertion —
  /// I broke Undo outright with the change that made binding atomic, and the
  /// suite could not see it because no test pressed the button on a pill
  /// presented through this entry point.
  func presentEscapeRecovery(
    _ payload: CancelUndoPayload, actions: @escaping (OverlayAction) -> Void
  ) {
    escapeRecoveryPayload = (id: payload.transcriptID, payload: payload)
    send(.pipeline(.escapeRecovery(transcriptID: payload.transcriptID)), actions: actions)
  }

  /// Take the payload for `transcriptID`, once. Returns nil if it was already
  /// taken or if a different transcript now owns the slot.
  func takeEscapeRecoveryPayload(matching transcriptID: UUID) -> CancelUndoPayload? {
    guard let held = escapeRecoveryPayload, held.id == transcriptID else { return nil }
    escapeRecoveryPayload = nil
    return held.payload
  }

  // MARK: - Applying a plan

  private func apply(_ plan: OverlayPlan, actions: ((OverlayAction) -> Void)? = nil) {
    switch plan.expiryCommand {
    case .unchanged:
      break
    case .cancel:
      armedExpiry?.cancel()
      armedExpiry = nil
    case .arm(let id, let seconds):
      armedExpiry?.cancel()
      armedExpiry = schedule.after(seconds) { [weak self] in
        // The id is captured, never re-read: a timer fires for the presentation
        // it was armed for or it is dropped. The reducer's own identity gate
        // makes a late arrival inert.
        self?.send(.expiryFired(id), actions: nil)
      }
    }

    if plan.didChange {
      // **Custody ends on ANY replacement, not only on an empty slot.** Clearing
      // it only when the slot emptied left a cancelled transcript held while a
      // DIFFERENT pill was showing — the payload outliving the offer to restore
      // it, which is the same defect the id gate exists to prevent, one level up.
      if case .escapeRecovery(let id)? = plan.presentation?.content,
        escapeRecoveryPayload?.id == id
      {
        // The pill still on screen is the one whose payload we hold.
      } else {
        escapeRecoveryPayload = nil
      }

      // The binding for the NEW presentation is installed BEFORE the model is
      // published, so the pill is never on screen without its handler.
      //
      // **A MORPH KEEPS ITS BINDING.** The first version replaced the binding
      // with whatever this call carried, so any same-id update with no handler —
      // an audio-level tick, which arrives many times a second — silently
      // dropped the live pill's buttons. Only a CHANGE OF IDENTITY clears it.
      if let presentation = plan.presentation {
        if let actions {
          activeBinding = (id: presentation.id, deliver: actions)
        } else if activeBinding?.id != presentation.id {
          activeBinding = nil
        }
      } else {
        activeBinding = nil
      }

      // **The providers belong to a RECORDING, so they end when the recording
      // does — and a replacement ends it just as surely as an empty slot.**
      // Releasing them only when the slot emptied left a finished dictation's
      // closures being polled fifty times a second behind whatever pill replaced
      // it, which is the same lifetime defect as the payload custody above.
      // A same-id morph keeps them: an audio tick is the SAME recording.
      if case .recording? = plan.presentation?.content {
        // Still the recording pill. Its providers are still its own.
      } else {
        model.clearRecordingProviders()
      }

      model.presentation = plan.presentation
      render(plan.presentation)
    }

    if let action = plan.deliverAction {
      if let binding = activeBinding, binding.id == reducer.state.current?.id {
        binding.deliver(action)
      } else {
        // **Loud, not silent.** The reducer only emits `deliverAction` for the
        // CURRENT presentation, so arriving here without a matching binding is
        // an invariant failure, not a race. Dropping it quietly would lose a
        // button press with nothing anywhere to say so.
        assertionFailure(
          "an action for the live presentation had no binding — the request that "
            + "produced it did not carry its handler")
      }
    }

    for effect in plan.effects {
      deliverEffect(effect)
    }
  }

  /// **Discharges the obligation `OverlayContent.recording` records**: the
  /// non-preview recording pill is 185 points wide in a reserved 92-point
  /// interaction frame, and the Live Preview variant is 400 wide and
  /// content-sized from its first frame so it does not visibly snap once the
  /// real height is measured.
  ///
  /// The DIRECTOR decides it and the reducer cannot, because whether preview is
  /// on arrives as a PROVIDER rather than as an event — putting it in the reducer
  /// would mean the reducer reading a closure, which stops it being a function of
  /// its events. Every other presentation takes its own width and reserved height
  /// unchanged.
  private func geometry(
    for presentation: OverlayPresentation
  ) -> (width: OverlayWidth, fixedHeight: CGFloat?) {
    guard case .recording = presentation.content, model.usesPreviewLayout() else {
      return (presentation.requestedWidth, presentation.reservesFixedHeight)
    }
    // **BOTH axes change, and the width is the one that is easy to miss.** The
    // shipped site reads `showsPreview ? previewPillWidth : 185` — 400 against
    // 185 — before it picks the sizing branch, so carrying only the height would
    // still render a preview pill less than half its intended width.
    return (.fixed(Self.previewPillWidth), nil)
  }

  /// `RecordingOverlayPanel.previewPillWidth`, duplicated because that one is
  /// `private static` and cannot be referenced from here.
  ///
  /// **A transitional duplicate with a named end**, not a value with two owners:
  /// the panel is deleted in the cutover and this becomes the only copy. Until
  /// then the two must agree, and nothing enforces it — so if the panel's width
  /// changes before the cutover lands, change both.
  private static let previewPillWidth: CGFloat = 400

  /// Push the model's new occupant to the window.
  ///
  /// **The model is set BEFORE this runs**, so the retained root has already
  /// rendered the new content by the time the host measures it — a host that
  /// measured first would size the window to the OUTGOING pill.
  private func render(_ presentation: OverlayPresentation?) {
    guard let presentation else {
      presentedID = nil
      host.hide()
      return
    }
    // `isFresh` is a change of OCCUPANT, not the absence of a window: a morph
    // keeps the live frame, a genuinely new presentation re-anchors.
    let isFresh = presentedID != presentation.id
    presentedID = presentation.id
    let recordingGeometry = geometry(for: presentation)
    let presented = host.present(
      rootHostingView,
      width: recordingGeometry.width,
      fixedHeight: recordingGeometry.fixedHeight,
      isFresh: isFresh,
      position: position())
    if !presented {
      // The host refused — no screen, or a presentation it could not size — and
      // it returns BEFORE touching the panel, so a window that was already up
      // stays up. The model has already published the new occupant by now, so
      // leaving it would show the NEW content in the OUTGOING pill's frame.
      // Clear the claim AND take the window down.
      presentedID = nil
      host.hide()
    }
  }

  #if DEBUG
    var presentedIDForTesting: PresentationID? { presentedID }
    var currentPresentationForTesting: OverlayPresentation? { reducer.state.current }
    var hasArmedExpiryForTesting: Bool { armedExpiry != nil }
    var hasActiveBindingForTesting: Bool { activeBinding != nil }
    var holdsEscapeRecoveryPayloadForTesting: Bool { escapeRecoveryPayload != nil }
    /// The window the director renders through, so a test can assert on the
    /// FRAME rather than on the argument it passed — the argument is the thing
    /// under test.
    var hostForTesting: OverlayWindowHost { host }
  #endif
}

/// A piece of scheduled work that can be cancelled.
///
/// A seam rather than a raw `Task` or `DispatchWorkItem` so a test can fire the
/// expiry deterministically. `testing-philosophy.md`
/// RULE: never-guess-when-the-subject-is-finished forbids waiting on a clock;
/// with this, a test does not wait at all — it fires the timer itself.
@MainActor
final class OverlayScheduledWork {
  private var cancelled = false
  private let body: () -> Void

  init(body: @escaping () -> Void) { self.body = body }

  func cancel() { cancelled = true }
  func fireForTesting() {
    guard !cancelled else { return }
    body()
  }
  var isCancelled: Bool { cancelled }
}

/// How the director arms its single expiry.
@MainActor
struct OverlayScheduler {
  let after: (Double, @escaping () -> Void) -> OverlayScheduledWork

  static let live = OverlayScheduler { seconds, body in
    let work = OverlayScheduledWork(body: body)
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak work] in
      guard let work, !work.isCancelled else { return }
      body()
    }
    return work
  }

  /// Arms nothing. The test fires the returned handle itself, so no interval
  /// exists anywhere in the assertion.
  static func manual(_ armed: @escaping (OverlayScheduledWork) -> Void) -> OverlayScheduler {
    OverlayScheduler { _, body in
      let work = OverlayScheduledWork(body: body)
      armed(work)
      return work
    }
  }
}
