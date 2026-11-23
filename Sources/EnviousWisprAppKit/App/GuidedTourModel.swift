import EnviousWisprCore
import Foundation
import Observation

/// #4565: the one window-local owner of what the guided-tour card is doing. It decides the three
/// things the card must never confuse: an offer REQUESTED (staged), SHOWN (consumed), and a stop
/// requested versus ARRIVED (shown). It owns every analytics row of the tour, so each action is
/// sent exactly once from here; it never navigates and never writes a setting.
@MainActor
@Observable
final class GuidedTourModel {
  enum Phase: Equatable {
    /// The automatic offer card ("Take a quick tour").
    case offer
    /// A stop of the run; the stop is the card's TARGET, which may not have arrived yet.
    case stop(GuidedTourStop)
  }

  /// What the card shows; nil means no card.
  private(set) var phase: Phase?
  /// The stops of the current run for the user's current settings.
  private(set) var plan = GuidedTourPlan(recordingsOn: true)
  /// An eligible key visit staged one offer; it waits for search and leave questions to clear.
  private(set) var staged = false

  private var viewed: Set<GuidedTourStop> = []
  @ObservationIgnored private let emit: (GuidedTourTelemetry) -> Void

  init(emit: @escaping (GuidedTourTelemetry) -> Void) {
    self.emit = emit
  }

  var isActive: Bool { phase != nil }

  /// The stop the card is on, nil on the offer or with no card.
  var currentStop: GuidedTourStop? {
    if case .stop(let stop) = phase { return stop }
    return nil
  }

  // MARK: - The automatic offer

  /// An eligible key visit stages one offer. Nothing is shown, consumed or sent yet.
  func stageOffer() {
    guard phase == nil else { return }
    staged = true
  }

  /// Resign, close or a replay discards an offer that was never shown: no event, no change.
  func discardStagedOffer() {
    staged = false
  }

  /// Shows the staged offer when nothing blocks it (search panel, leave question, window not key,
  /// eligibility lost). Returns true when the card appeared, so the caller records `consumed`.
  @discardableResult
  func presentStagedOffer(canPresent: Bool) -> Bool {
    guard staged, phase == nil, canPresent else { return false }
    staged = false
    phase = .offer
    emit(.init(action: .offered, stop: .offer))
    return true
  }

  /// Start was accepted on the offer: the first stop becomes the target.
  func start(recordingsOn: Bool) -> GuidedTourStop? {
    guard phase == .offer else { return nil }
    return begin(recordingsOn: recordingsOn, action: .started)
  }

  // MARK: - Replay

  /// A replay was accepted by the window. It ends any current presentation under the same rules
  /// as any other end, then starts at the first stop. Returns that stop.
  @discardableResult
  func replay(recordingsOn: Bool) -> GuidedTourStop {
    staged = false
    if phase != nil { end() }
    return begin(recordingsOn: recordingsOn, action: .replayed)
  }

  private func begin(recordingsOn: Bool, action: GuidedTourTelemetry.Action) -> GuidedTourStop {
    plan = GuidedTourPlan(recordingsOn: recordingsOn)
    viewed = []
    phase = .stop(plan.first)
    emit(.init(action: action, stop: plan.first.telemetry))
    return plan.first
  }

  // MARK: - Walking the stops

  /// The stop's page and tab were showing and the card was reachable (not under the search
  /// dropdown or a leave question). Counted once per stop per run.
  func noteArrival(showing: Bool, reachable: Bool) {
    guard case .stop(let stop) = phase, showing, reachable, !viewed.contains(stop) else {
      return
    }
    viewed.insert(stop)
    emit(.init(action: .stopViewed, stop: stop.telemetry))
  }

  /// Next on a stop whose page is showing: the next stop becomes the target, or nil when this was
  /// the last stop (the caller then calls `finish()`).
  func advance() -> GuidedTourStop? {
    guard case .stop(let stop) = phase, let next = plan.next(after: stop) else { return nil }
    phase = .stop(next)
    return next
  }

  /// Finish tour, after arrival at the last stop.
  func finish() {
    guard case .stop(let stop) = phase else { return }
    emit(.init(action: .completed, stop: stop.telemetry))
    clear()
  }

  /// "Recording saving" changed: the run's stops follow it. A Recordings target that no longer
  /// exists moves back to the last remaining stop, with the page left where it is.
  func settingsChanged(recordingsOn: Bool) {
    plan = GuidedTourPlan(recordingsOn: recordingsOn)
    if case .stop(let stop) = phase {
      let target = plan.target(replacing: stop)
      if target != stop { phase = .stop(target) }
    }
  }

  // MARK: - Ending

  /// End tour, Not now, window close or Quit: one `ended_early` for what the card showed, with
  /// the current target as the stop even if it never arrived. A staged offer that was never
  /// shown ends with no event.
  func end() {
    staged = false
    switch phase {
    case .offer: emit(.init(action: .endedEarly, stop: .offer))
    case .stop(let stop): emit(.init(action: .endedEarly, stop: stop.telemetry))
    case nil: break
    }
    clear()
  }

  private func clear() {
    phase = nil
    viewed = []
  }
}
