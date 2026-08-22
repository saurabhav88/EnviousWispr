import AppKit
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
/// **Not yet authoritative.** `RecordingOverlayPanel` still routes its own
/// transitions; the director is introduced here with its own tests so the
/// cutover is a retargeting rather than a retargeting plus a first run. The
/// panel OWNS the director and injects its existing host — the director never
/// owns the panel, and two references to one host do not make two window owners
/// because the host still solely owns the `NSPanel`.
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

  init(
    host: OverlayWindowHost,
    model: OverlayRenderModel = OverlayRenderModel(),
    scheduler: OverlayScheduler = .live,
    makeID: @escaping () -> PresentationID = { PresentationID() }
  ) {
    self.host = host
    self.model = model
    self.schedule = scheduler
    self.reducer = OverlayReducer(makeID: makeID)
  }

  var renderModel: OverlayRenderModel { model }

  // MARK: - The transaction

  func send(_ event: OverlayEvent) {
    let plan = reducer.reduce(event)
    apply(plan)
  }

  /// Take custody of a cancelled-transcript payload and present its pill.
  func presentEscapeRecovery(_ payload: CancelUndoPayload, transcriptID: UUID) {
    escapeRecoveryPayload = (id: transcriptID, payload: payload)
    send(.pipeline(.escapeRecovery(transcriptID: transcriptID)))
  }

  /// Bind the feature handler for the CURRENT presentation. Dropped when that
  /// presentation goes, so nothing outlives the pill it belongs to.
  func bindActions(for id: PresentationID, deliver: @escaping (OverlayAction) -> Void) {
    guard reducer.state.current?.id == id else { return }
    activeBinding = (id: id, deliver: deliver)
  }

  /// Take the payload for `transcriptID`, once. Returns nil if it was already
  /// taken or if a different transcript now owns the slot.
  func takeEscapeRecoveryPayload(matching transcriptID: UUID) -> CancelUndoPayload? {
    guard let held = escapeRecoveryPayload, held.id == transcriptID else { return nil }
    escapeRecoveryPayload = nil
    return held.payload
  }

  // MARK: - Applying a plan

  private func apply(_ plan: OverlayPlan) {
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
        self?.send(.expiryFired(id))
      }
    }

    if plan.didChange {
      model.presentation = plan.presentation
      if plan.presentation == nil {
        activeBinding = nil
        escapeRecoveryPayload = nil
      } else if let binding = activeBinding, binding.id != plan.presentation?.id {
        // A new occupant invalidates the previous feature's binding, or an
        // action would be delivered to a pill that is no longer showing.
        activeBinding = nil
      }
    }

    if let action = plan.deliverAction, let binding = activeBinding {
      binding.deliver(action)
    }

    for effect in plan.effects {
      effects?(effect)
    }
  }

  /// Where side effects for feature owners go. Set by the wiring; nil until then.
  var effects: ((OverlayEffect) -> Void)?

  #if DEBUG
    var currentPresentationForTesting: OverlayPresentation? { reducer.state.current }
    var hasArmedExpiryForTesting: Bool { armedExpiry != nil }
    var hasActiveBindingForTesting: Bool { activeBinding != nil }
    var holdsEscapeRecoveryPayloadForTesting: Bool { escapeRecoveryPayload != nil }
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
