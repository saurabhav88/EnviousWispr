import EnviousWisprCore
import EnviousWisprPipeline
import Foundation

/// #3973 C1 — the one owner of a dictation press that is WAITING for its engine turn.
///
/// Dictation has priority over EnviousMeet's after-meeting transcript (decision 11). A record
/// press that finds a meeting holding the shared engine does not get the "please wait"
/// refusal any more: it reserves the next turn on `EngineLease` and waits for the meeting to
/// give the engine back. That wait is a new lifetime the start path did not have — a press
/// that existed while no recording did — so every way a user ends a press has to reach it:
/// push-to-talk release, Stop, cancel, a second toggle, a newer press, and quit. They all come
/// here, because the starter, finalizer, hotkey callbacks and termination wiring each hold
/// this same instance (`DictationRuntime` builds one and hands it out).
///
/// **Why its own owner, not the starter.** The finalizer must cancel a waiting press, and the
/// finalizer does not (and should not) hold the starter; the starter, finalizer and quit path
/// already share no other object that lives across a press. The lease stays the only
/// ADMISSION authority: this type never grants, it only names the request, withdraws its
/// reservation and keeps the log honest.
///
/// **One terminal outcome per request.** Each request logs `admitted`, `cancelled`, `refused`
/// or `superseded` exactly once, with its id and monotonic start and end times; `admitted`
/// means the engine was granted to it, not that a recording followed (the start path's own
/// later gates can still decline). The admitted wait is reported apart from the others
/// (plan §3a).
@MainActor
final class PendingDictationRequests {
  enum Outcome: String {
    case admitted
    case cancelled
    case refused
    case superseded
  }

  private struct Pending {
    let id: UUID
    let startedAt: ContinuousClock.Instant
    var reservation: EngineLease.Reservation?
  }

  /// A granted turn, still owed to the press that waited for it. `ticket` keeps the press's
  /// identity alive through the start-up that follows the wait (prewarm, recovery arming), so a
  /// press ended there mints nothing (`isStillStarting`).
  struct Admission {
    let token: EngineLease.Token
    let ticket: UUID
  }

  private let access: EngineAdmissionAccess
  private let now: @MainActor () -> ContinuousClock.Instant
  /// The one monotonic reference every logged timestamp is measured from.
  private let reference: ContinuousClock.Instant
  private let log: @MainActor (String) -> Void
  private var pending: Pending? {
    didSet {
      if (oldValue == nil) != (pending == nil) { onWaitingChanged?(pending != nil) }
    }
  }

  /// Told true when a press starts waiting and false when no press waits any more, so the
  /// cancel shortcut can be armed for a press that has no recording yet (`HotkeyController`).
  var onWaitingChanged: (@MainActor (Bool) -> Void)?
  /// Quit closed dictation admission (`close()`): no press waits or starts from here on. Both
  /// start paths read this before their claim, so a free engine does not let one through.
  private(set) var isClosed = false
  /// The admitted press still starting up, until it mints or gives up (`finishStarting`).
  private var starting: UUID?

  init(
    access: EngineAdmissionAccess,
    now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now },
    log: @escaping @MainActor (String) -> Void = { line in
      Task { await AppLogger.shared.log(line, level: .info, category: "Pipeline") }
    }
  ) {
    self.access = access
    self.now = now
    self.log = log
    reference = now()
  }

  /// A press is waiting for its turn now.
  var isPending: Bool { pending != nil }

  /// Waits for the engine turn, as one request. Returns the granted turn, or nil when the
  /// request ended without one (cancelled, superseded, the calling task cancelled, or admission
  /// closed for quit). The token belongs to the caller; the caller ends the ticket with
  /// `finishStarting` once its start-up mints or gives up.
  ///
  /// A newer request supersedes a waiting one: the older wait returns nil.
  func waitForTurn() async -> Admission? {
    let id = UUID()
    let startedAt = now()
    if isClosed {
      finish(id: id, startedAt: startedAt, outcome: .refused)
      return nil
    }
    if let older = pending {
      end(older, outcome: .superseded)
    }
    pending = Pending(id: id, startedAt: startedAt, reservation: nil)
    log(
      "dictation_turn request=\(id.uuidString) event=waiting startMs=\(Self.milliseconds(startedAt - reference))"
    )
    let token = await access.waitForReservedTurn { [weak self] reservation in
      guard let self, self.pending?.id == id else { return }
      self.pending?.reservation = reservation
    }
    // This request's outcome was already logged when it was superseded or cancelled; a token
    // that reached it anyway (the hand-off and the cancel crossed) goes straight back.
    guard let current = pending, current.id == id else {
      if let token { access.release(token) }
      return nil
    }
    pending = nil
    guard let token, !Task.isCancelled else {
      if let token { access.release(token) }
      finish(
        id: id, startedAt: startedAt, outcome: token == nil && isClosed ? .refused : .cancelled)
      return nil
    }
    finish(id: id, startedAt: startedAt, outcome: .admitted)
    starting = id
    return Admission(token: token, ticket: id)
  }

  /// Whether the admitted press `ticket` may still mint: nothing ended it since admission and
  /// its task was not cancelled (a newer push-to-talk press cancels the older press's task).
  func isStillStarting(_ ticket: UUID) -> Bool {
    starting == ticket && !Task.isCancelled
  }

  /// The admitted press minted its session or gave up; its ticket stops mattering.
  func finishStarting(_ ticket: UUID) {
    if starting == ticket { starting = nil }
  }

  /// Ends the waiting request, or the admitted one still starting up, if any: the press ended
  /// (release, Stop, cancel, a second toggle). Returns whether one was ended.
  @discardableResult
  func cancelPending() -> Bool {
    if let current = pending {
      end(current, outcome: .cancelled)
      return true
    }
    guard let ticket = starting else { return false }
    starting = nil
    log("dictation_turn request=\(ticket.uuidString) event=ended_during_start")
    return true
  }

  /// Quit: no request waits or starts from here on.
  func close() {
    isClosed = true
    starting = nil
    if let current = pending { end(current, outcome: .cancelled) }
  }

  private func end(_ request: Pending, outcome: Outcome) {
    pending = nil
    if let reservation = request.reservation { access.cancelReservation(reservation) }
    finish(id: request.id, startedAt: request.startedAt, outcome: outcome)
  }

  private func finish(id: UUID, startedAt: ContinuousClock.Instant, outcome: Outcome) {
    let endedAt = now()
    let startMs = Self.milliseconds(startedAt - reference)
    let endMs = Self.milliseconds(endedAt - reference)
    let waitMs = Self.milliseconds(endedAt - startedAt)
    log(
      "dictation_turn request=\(id.uuidString) outcome=\(outcome.rawValue) waitMs=\(waitMs) startMs=\(startMs) endMs=\(endMs)"
    )
  }

  private static func milliseconds(_ duration: Duration) -> Int {
    let (seconds, attoseconds) = duration.components
    return Int(seconds) * 1_000 + Int(attoseconds / 1_000_000_000_000_000)
  }
}
