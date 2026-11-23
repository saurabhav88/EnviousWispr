import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #4565 guided tour card: when these fail, a new user is offered the tour twice, is counted as
/// having seen a stop that never arrived, is left on a Recordings stop that no longer exists, or
/// one run reports two ends.
@MainActor
@Suite("Guided tour model", .tags(.productOutcome))
struct GuidedTourModelTests {
  final class Rows {
    var all: [GuidedTourTelemetry] = []
    var names: [String] { all.map { "\($0.action.rawValue):\($0.stop.rawValue)" } }
  }

  private func make() -> (GuidedTourModel, Rows) {
    let rows = Rows()
    return (GuidedTourModel(emit: { rows.all.append($0) }), rows)
  }

  @Test("a staged offer shows once nothing blocks it, and sends `offered` once")
  func offerWaitsForTheBlockerAndShowsOnce() {
    let (tour, rows) = make()
    tour.stageOffer()
    #expect(!tour.presentStagedOffer(canPresent: false), "blocked by search or a leave question")
    #expect(tour.phase == nil)
    #expect(rows.all.isEmpty, "staging and blocking send nothing")

    #expect(tour.presentStagedOffer(canPresent: true))
    #expect(tour.phase == .offer)
    #expect(!tour.presentStagedOffer(canPresent: true), "no second offer")
    #expect(rows.names == ["offered:offer"])
  }

  @Test("a staged offer that was never shown disappears with no event")
  func unseenOfferEndsSilently() {
    let (tour, rows) = make()
    tour.stageOffer()
    tour.discardStagedOffer()
    #expect(!tour.presentStagedOffer(canPresent: true))
    tour.stageOffer()
    tour.end()
    #expect(!tour.presentStagedOffer(canPresent: true))
    #expect(rows.all.isEmpty)
  }

  @Test("Not now ends a shown offer once, as `ended_early` at the offer")
  func notNowEndsTheOffer() {
    let (tour, rows) = make()
    tour.stageOffer()
    tour.presentStagedOffer(canPresent: true)
    tour.end()
    tour.end()
    #expect(tour.phase == nil)
    #expect(rows.names == ["offered:offer", "ended_early:offer"])
  }

  @Test("a full run counts each stop once, only after it arrived, and ends with `completed`")
  func fullRun() throws {
    let (tour, rows) = make()
    tour.stageOffer()
    tour.presentStagedOffer(canPresent: true)
    #expect(tour.start(recordingsOn: false) == .keybinds)
    #expect(tour.plan.count == 8)
    tour.noteArrival(showing: false, reachable: true)
    tour.noteArrival(showing: true, reachable: false)
    #expect(rows.names == ["offered:offer", "started:keybinds"], "requested is not arrived")

    tour.noteArrival(showing: true, reachable: true)
    tour.noteArrival(showing: true, reachable: true)
    #expect(rows.names.last == "stop_viewed:keybinds", "once per stop")

    var stop = tour.currentStop
    while let next = tour.advance() {
      stop = next
      tour.noteArrival(showing: true, reachable: true)
    }
    #expect(stop == .meetings, "with saving off, EnviousMeet is the last stop")
    tour.finish()
    #expect(rows.names.last == "completed:meetings")
    #expect(tour.phase == nil)
    #expect(rows.all.filter { $0.action == .stopViewed }.count == 8)
    #expect(rows.all.filter { $0.action == .endedEarly }.isEmpty)
  }

  @Test("ending a run that never reached its target reports that target once")
  func endBeforeArrival() {
    let (tour, rows) = make()
    tour.stageOffer()
    tour.presentStagedOffer(canPresent: true)
    _ = tour.start(recordingsOn: true)
    _ = tour.advance()
    tour.end()
    tour.end()
    #expect(rows.names.suffix(1) == ["ended_early:history"])
    #expect(rows.all.filter { $0.action == .endedEarly }.count == 1)
  }

  @Test("replay replaces an offer or a run: one end, then `replayed` at the first stop")
  func replayReplacesWhatShows() {
    let (tour, rows) = make()
    tour.stageOffer()
    tour.presentStagedOffer(canPresent: true)
    #expect(tour.replay(recordingsOn: true) == .keybinds)
    #expect(rows.names == ["offered:offer", "ended_early:offer", "replayed:keybinds"])

    tour.noteArrival(showing: true, reachable: true)
    _ = tour.advance()
    #expect(tour.replay(recordingsOn: true) == .keybinds)
    #expect(rows.names.suffix(2) == ["ended_early:history", "replayed:keybinds"])

    tour.noteArrival(showing: true, reachable: true)
    #expect(
      rows.all.filter { $0.action == .stopViewed && $0.stop == .keybinds }.count == 2,
      "a new run counts its stops again")
  }

  @Test("a replay with a staged offer waiting discards that offer")
  func replayDiscardsTheStagedOffer() {
    let (tour, _) = make()
    tour.stageOffer()
    _ = tour.replay(recordingsOn: true)
    tour.end()
    #expect(!tour.presentStagedOffer(canPresent: true))
  }

  @Test("saving turning off moves a Recordings target back to EnviousMeet without a second view")
  func recordingsTargetFollowsTheSetting() {
    let (tour, rows) = make()
    _ = tour.replay(recordingsOn: true)
    while tour.currentStop != .meetings { _ = tour.advance() }
    tour.noteArrival(showing: true, reachable: true)
    _ = tour.advance()
    #expect(tour.currentStop == .recordings)

    tour.settingsChanged(recordingsOn: false)
    #expect(tour.currentStop == .meetings)
    #expect(tour.plan.count == 8)
    tour.noteArrival(showing: true, reachable: true)
    #expect(
      rows.all.filter { $0.action == .stopViewed && $0.stop == .meetings }.count == 1,
      "returning to a stop already viewed adds no row")

    tour.settingsChanged(recordingsOn: true)
    #expect(tour.currentStop == .meetings, "turning saving back on leaves the target alone")
  }

  @Test("no event carries anything beyond the two fixed vocabularies")
  func rowsUseOnlyTheFixedVocabularies() {
    let (tour, rows) = make()
    tour.stageOffer()
    tour.presentStagedOffer(canPresent: true)
    _ = tour.start(recordingsOn: true)
    while tour.advance() != nil {}
    tour.finish()
    let actions = Set(GuidedTourTelemetry.Action.allCases)
    let stops = Set(GuidedTourTelemetry.Stop.allCases)
    #expect(rows.all.allSatisfy { actions.contains($0.action) && stops.contains($0.stop) })
  }
}
