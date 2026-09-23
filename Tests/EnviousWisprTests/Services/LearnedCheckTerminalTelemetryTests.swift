import Foundation
import Testing

@testable import EnviousWisprServices

// #3105 — the learned-word check's counts ride on the take's `dictation.terminal`
// row through the #2958 ledger: counts, latency, arm and a closed reason, never
// text; a take with no open entry records nothing.
@MainActor
@Suite("Learned-word check terminal telemetry (#3105)", .tags(.observabilityContract))
struct LearnedCheckTerminalTelemetryTests {
  private let facts = LearnedCheckTerminalFacts(
    flagged: 3, approved: 1, applied: 1, contested: 0, latencyMs: 142, arm: "eg1_lora",
    fallbackReason: nil, checkerIdentity: "eg1c-v2", checkerStatus: "ran")

  @Test("the facts project onto the terminal row with the learned_check_ keys only")
  func projection() throws {
    let ledger = TakeStageLedger()
    let service = TelemetryService(takeStages: ledger)
    ledger.open(takeID: "A")
    service.recordLearnedCheck(takeID: "A", facts: facts)
    let props = try #require(ledger.close(takeID: "A")?.terminalProperties)
    let keys = Set(props.keys.filter { $0.hasPrefix("learned_check_") })
    #expect(
      keys == [
        "learned_check_flagged", "learned_check_approved", "learned_check_applied",
        "learned_check_contested", "learned_check_latency_ms", "learned_check_arm",
        "learned_check_checker_identity", "learned_check_checker_status",
      ])
    #expect(props["learned_check_applied"] as? Int == 1)
    #expect(props["learned_check_arm"] as? String == "eg1_lora")
    #expect(props["learned_check_checker_identity"] as? String == "eg1c-v2")
    #expect(props["learned_check_checker_status"] as? String == "ran")
    #expect(props["learned_check_absence_reason"] == nil)
  }

  @Test("each closed absence value reaches the terminal row without content",
    arguments: [
      "not_eg_one", "base_not_admitted", "adapter_downloading", "adapter_delivery_failed", "delivery_disabled",
      "base_mismatch_family", "base_mismatch_revision", "base_mismatch_variant",
      "base_mismatch_shard_hash", "base_mismatch_prompt_template", "base_mismatch_runtime",
      "unqualified_language", "server_without_adapter_adapter_missing",
      "server_without_adapter_adapter_server_exited",
      "server_without_adapter_adapter_server_never_ready", "server_unavailable",
    ])
  func absenceProjection(reason: String) throws {
    let ledger = TakeStageLedger()
    let service = TelemetryService(takeStages: ledger)
    ledger.open(takeID: "A")
    var absent = facts
    absent.checkerIdentity = nil
    absent.checkerStatus = "no_checker"
    absent.absenceReason = reason
    absent.fallbackReason = "no_checker"
    service.recordLearnedCheck(takeID: "A", facts: absent)
    let props = try #require(ledger.close(takeID: "A")?.terminalProperties)
    #expect(props["learned_check_checker_status"] as? String == "no_checker")
    #expect(props["learned_check_absence_reason"] as? String == reason)
    #expect(props["learned_check_checker_identity"] == nil)
    #expect(props["learned_check_fallback_reason"] as? String == "no_checker")
  }

  @Test("a fallback carries its closed reason")
  func fallbackReason() throws {
    let ledger = TakeStageLedger()
    let service = TelemetryService(takeStages: ledger)
    ledger.open(takeID: "A")
    var failed = facts
    failed.fallbackReason = "checker_error"
    service.recordLearnedCheck(takeID: "A", facts: failed)
    let props = try #require(ledger.close(takeID: "A")?.terminalProperties)
    #expect(props["learned_check_fallback_reason"] as? String == "checker_error")
  }

  @Test("a take with no open entry records nothing and opens nothing")
  func closedTakeIsNoOp() {
    let ledger = TakeStageLedger()
    let service = TelemetryService(takeStages: ledger)
    service.recordLearnedCheck(takeID: "gone", facts: facts)
    #expect(ledger.openCount == 0)
  }
}
