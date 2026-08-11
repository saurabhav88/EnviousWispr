import Foundation
import Testing
import os

@testable import EnviousWisprPipeline
@testable import EnviousWisprPostProcessing

// MARK: - CasingDeadlineEvidenceTests (#1946)
//
// The gate's DIAGNOSTIC record: which step the deadline caught, how long each
// took, and which oracle consultation was in flight.
//
// Why this suite exists at all: `oracle_timed_out` used to be applied to any
// miss of the 100 ms casing deadline, including misses where no oracle ran. Four
// materially different causes produced byte-identical evidence, and three
// successive causal theories were built on it and refuted. Everything here
// asserts that two different stalls now leave two different records.
//
// Time is driven, never waited on: the gate takes an injectable monotonic clock
// for the same reason `TerminalResolutionBudget` does (#1893) — a busy-wait
// guarantees a floor and never a ceiling, so a duration assertion against wall
// time can only be flaky (`test-timing.md`).
@Suite("Casing deadline evidence (#1946)")
struct CasingDeadlineEvidenceTests {

  static let resolution = DictationLanguageResolver.Resolution(
    language: "en", source: .dictation, confidenceBucket: .ge90)

  /// A clock the test advances by hand.
  private final class Clock: @unchecked Sendable {
    private let value = OSAllocatedUnfairLock(initialState: 0.0)
    var now: Double { value.withLock { $0 } }
    func advance(_ seconds: Double) { value.withLock { $0 += seconds } }
    var read: @Sendable () -> Double { { [value] in value.withLock { $0 } } }
  }

  // MARK: - The discrimination the whole change exists for

  @Test("Two different post-authorisation stalls leave two different records")
  func differentClosuresAreDistinguishable() {
    // THE load-bearing case. Both stalls are inside the oracle, both must latch
    // identically — the safety net does not change — and the ONLY difference
    // must be which consultation is named. Before #1946 these two produced the
    // same `oracle_timed_out` and nothing else, which is precisely why the
    // spell-service-tail and executor-starvation theories could not be
    // separated from the field data.
    for label in ["dictionary", "name"] {
      let clock = Clock()
      let gate = LanguageRepairDeadlineGate(now: clock.read)
      #expect(gate.beginRepair(Self.resolution))
      #expect(gate.beginOracleUse(label) != nil)
      clock.advance(0.105)
      let snapshot = gate.timeOut()

      #expect(snapshot.phase == .repairAfterOracle, "both are post-authorisation stalls")
      #expect(snapshot.shouldDisableOracle, "the safety net is identical for both")
      #expect(snapshot.oracleInFlight == label, "and the record names WHICH one stalled")
      #expect(
        (snapshot.oracleInFlightMs ?? 0) >= 105,
        "with how long it had been stuck, which is what separates a real hang from a slow moment")
    }
  }

  @Test("A healthy delivery records every phase and leaves the oracle enabled")
  func healthyDeliveryRecordsAllPhases() {
    // The two-way control. Without it, an implementation that reported a stuck
    // closure on EVERY dictation would pass the case above while disabling the
    // feature for everyone (`a-guard-nothing-arms-is-not-a-guard`).
    let clock = Clock()
    let gate = LanguageRepairDeadlineGate(now: clock.read)
    clock.advance(0.001)
    gate.mark(.languageResolved)
    clock.advance(0.002)
    #expect(gate.beginRepair(Self.resolution))
    gate.mark(.oracleFetched)
    let token = gate.beginOracleUse("dictionary")
    #expect(token != nil)
    clock.advance(0.0005)
    gate.completeOracleUse(token!)
    clock.advance(0.001)
    gate.mark(.repairReturned)
    let snapshot = gate.completeRepair()

    #expect(snapshot.phase == .completed)
    #expect(snapshot.shouldDisableOracle == false, "a finished consultation is not a stuck one")
    #expect(snapshot.oracleInFlight == nil, "nothing is in flight once it completed")
    #expect(snapshot.oracleClosuresCompleted == 1)
    #expect((snapshot.languageMs ?? 0) >= 1, "each phase carries its own duration")
    #expect((snapshot.oracleFetchMs ?? 0) >= 2)
    #expect((snapshot.repairMs ?? 0) >= 1)
  }

  // MARK: - Token correctness
  //
  // A label alone cannot correlate a completion. These four cases are why the
  // API mints a token per consultation rather than naming one.

  @Test("Sequential consultations each end cleanly")
  func sequentialConsultations() {
    let clock = Clock()
    let gate = LanguageRepairDeadlineGate(now: clock.read)
    #expect(gate.beginRepair(Self.resolution))
    let first = gate.beginOracleUse("name")!
    clock.advance(0.002)
    gate.completeOracleUse(first)
    let second = gate.beginOracleUse("dictionary")!
    clock.advance(0.001)
    gate.completeOracleUse(second)

    let snapshot = gate.timeOut()
    #expect(snapshot.oracleInFlight == nil, "both finished, so nothing is stuck")
    #expect(snapshot.oracleClosuresCompleted == 2)
    #expect((snapshot.oracleClosureMaxMs ?? 0) >= 2, "the slowest completed one is kept")
  }

  @Test("A nested consultation restores its enclosing one on completion")
  func nestedConsultationRestoresEnclosing() {
    let clock = Clock()
    let gate = LanguageRepairDeadlineGate(now: clock.read)
    #expect(gate.beginRepair(Self.resolution))
    let outer = gate.beginOracleUse("dictionary")!
    let inner = gate.beginOracleUse("name")!
    gate.completeOracleUse(inner)

    let snapshot = gate.timeOut()
    #expect(
      snapshot.oracleInFlight == "dictionary",
      "the OUTER consultation is still running and must be what the record names")
    #expect(snapshot.oracleClosuresCompleted == 1)
    _ = outer
  }

  @Test("A completion arriving after the timeout claimed is inert")
  func lateCompletionCannotRewriteReturnedEvidence() {
    // `withOrderedDeadline` cannot preempt a blocked thread
    // (`TaskTimeout.swift:123-132`), so the operation keeps running after the
    // timeout returned. If a late completion could still mutate the record, the
    // evidence handed to the caller and the evidence in the gate would disagree
    // — a diagnostic that looks self-consistent and is false.
    let clock = Clock()
    let gate = LanguageRepairDeadlineGate(now: clock.read)
    #expect(gate.beginRepair(Self.resolution))
    let token = gate.beginOracleUse("dictionary")!
    clock.advance(0.105)
    let atTimeout = gate.timeOut()
    #expect(atTimeout.oracleInFlight == "dictionary")

    clock.advance(1.0)
    gate.completeOracleUse(token)
    let afterLateCompletion = gate.timeOut()

    #expect(
      afterLateCompletion.oracleInFlight == "dictionary",
      "the frozen record must still name the stuck consultation")
    #expect(
      afterLateCompletion.oracleClosuresCompleted == atTimeout.oracleClosuresCompleted,
      "and a post-freeze completion must not be counted")
    #expect(
      (afterLateCompletion.oracleInFlightMs ?? 0) == (atTimeout.oracleInFlightMs ?? -1),
      "re-reading must not re-measure against a later clock")
  }

  @Test("A duplicate completion cannot clear a NEWER consultation with the same label")
  func duplicateCompletionCannotClearANewerSameLabelUse() {
    // The case that makes tokens necessary rather than merely tidy, and the one
    // a naive duplicate test misses: a duplicate that does not overlap a live
    // same-labelled consultation passes even under the label-collision bug it
    // exists to catch.
    let clock = Clock()
    let gate = LanguageRepairDeadlineGate(now: clock.read)
    #expect(gate.beginRepair(Self.resolution))
    let stale = gate.beginOracleUse("dictionary")!
    gate.completeOracleUse(stale)

    let live = gate.beginOracleUse("dictionary")!
    clock.advance(0.105)
    gate.completeOracleUse(stale)  // duplicate, for the ALREADY-finished token

    let snapshot = gate.timeOut()
    #expect(
      snapshot.oracleInFlight == "dictionary",
      "the live consultation must survive a stale duplicate carrying its label")
    #expect(
      (snapshot.oracleInFlightMs ?? 0) >= 105,
      "and keep its real elapsed time, not be silently reset")
    #expect(snapshot.oracleClosuresCompleted == 1, "the duplicate must not be counted twice")
    _ = live
  }

  @Test("A consultation that RETURNED is not reported as a stuck one")
  func returnedConsultationIsNotReportedAsStuck() {
    // Whole-diff review (P2). The first version reported this as `repair_oracle`
    // and therefore as `oracle_timed_out`, asserting a stall that demonstrably
    // did not happen: the consultation returned, and repair then crossed the
    // deadline in its own work.
    let clock = Clock()
    let gate = LanguageRepairDeadlineGate(now: clock.read)
    #expect(gate.beginRepair(Self.resolution))
    let token = gate.beginOracleUse("dictionary")!
    clock.advance(0.001)
    gate.completeOracleUse(token)
    clock.advance(0.105)  // repair's OWN work is what crosses the deadline
    let snapshot = gate.timeOut()

    #expect(
      snapshot.phase == .repairAfterOracleReturned,
      "the evidence must not claim an oracle was stuck when none was in flight")
    #expect(snapshot.oracleInFlight == nil)
    #expect(snapshot.oracleClosuresCompleted == 1, "it did run, and it finished")
    // The latch is UNCHANGED by design: narrowing it is a change to the safety
    // net, which is out of scope (founder, 2026-08-10). Frozen here so that a
    // later decision to narrow it is a deliberate, visible edit rather than a
    // silent drift.
    #expect(
      snapshot.shouldDisableOracle,
      "latch behaviour is deliberately unchanged; only the EVIDENCE got honest")
  }

  // MARK: - Phase honesty

  @Test("A stall before any consultation names the deadline, not the oracle")
  func preOracleStallNamesTheDeadline() {
    // Covers the main-thread oracle fetch and repair's own work: both sit in
    // `.repair(oracleTouched: false)`, neither has consulted an oracle, and
    // neither may latch. This is the arm that #1946's own first hypothesis got
    // wrong — a hop stall CANNOT disable the runtime, because nothing was
    // consulted.
    let clock = Clock()
    let gate = LanguageRepairDeadlineGate(now: clock.read)
    #expect(gate.beginRepair(Self.resolution))
    gate.mark(.oracleFetched)
    clock.advance(0.105)
    let snapshot = gate.timeOut()

    #expect(snapshot.phase == .repairBeforeOracle)
    #expect(
      snapshot.shouldDisableOracle == false,
      "an oracle that was never consulted must not be punished for a stall before it")
    #expect(snapshot.oracleInFlight == nil)
    #expect(snapshot.resolution?.language == "en", "the language answer still survives")
  }

  @Test("A stall during language resolution names the language stage")
  func languageStallNamesTheLanguageStage() {
    let clock = Clock()
    let gate = LanguageRepairDeadlineGate(now: clock.read)
    clock.advance(0.105)
    let snapshot = gate.timeOut()

    #expect(snapshot.phase == .resolvingLanguage)
    #expect(snapshot.shouldDisableOracle == false)
    #expect(snapshot.resolution == nil, "nothing was resolved, so nothing is reported")
  }
}
