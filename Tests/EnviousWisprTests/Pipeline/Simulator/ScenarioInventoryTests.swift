import Foundation
import Testing

/// Scenario-inventory completeness tests (epic #827, PR-2 plan §11.2, §3.8).
/// Asserts the EXACT canonical ID set — not a count — so a silently-dropped
/// scenario or a near-duplicate swap fails the build.
@MainActor
@Suite("ScenarioInventory")
struct ScenarioInventoryTests {

  @Test("the inventory holds exactly the 37 canonical scenarios")
  func inventoryHoldsThirtySeven() {
    // #1543 removed C7 (audio helper death — impossible with capture in-process).
    #expect(ScenarioInventory.all.count == 37)
    #expect(ScenarioInventory.canonicalIDs.count == 37)
  }

  @Test("the inventory's ID set matches the canonical ID set exactly")
  func idSetMatchesCanonical() {
    let actual = Set(ScenarioInventory.all.map(\.id))
    let missing = ScenarioInventory.canonicalIDs.subtracting(actual)
    let unexpected = actual.subtracting(ScenarioInventory.canonicalIDs)
    #expect(
      actual == ScenarioInventory.canonicalIDs,
      "missing: \(missing); unexpected: \(unexpected)")
  }

  @Test("no scenario ID is duplicated")
  func noDuplicateIDs() {
    let ids = ScenarioInventory.all.map(\.id)
    #expect(Set(ids).count == ids.count)
  }

  @Test("the two §1.3 regression locks are present by ID")
  func regressionLocksPresent() {
    let ids = Set(ScenarioInventory.all.map(\.id))
    #expect(ids.contains("R1"), "WhisperKit stop-during-startup lock — drop-resistant")
    #expect(ids.contains("R2"), "Parakeet stale-latch lock — drop-resistant")
  }

  @Test("every scenario carries a full ExpectedOutcome")
  func everyScenarioHasExpectedOutcome() {
    for scenario in ScenarioInventory.all {
      // A non-empty step list and a parseable expected outcome.
      #expect(!scenario.steps.isEmpty, "\(scenario.id) has no steps")
      // Paste count above 1 is never a valid expectation.
      #expect(
        scenario.expected.pasteCount <= 1,
        "\(scenario.id) expects pasteCount > 1 — always a failure")
    }
  }

  @Test("the concurrency-sensitive subset is the expected seven scenarios")
  func concurrencySubsetIsCorrect() {
    let concurrencyIDs = Set(ScenarioInventory.concurrencySensitive.map(\.id))
    #expect(concurrencyIDs == ["A7", "A8", "A15", "A18", "R1", "R2", "L5"])
  }
}
