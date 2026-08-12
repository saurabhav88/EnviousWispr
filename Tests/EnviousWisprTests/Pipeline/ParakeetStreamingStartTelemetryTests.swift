@preconcurrency import AVFoundation
import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #1654 (cloud review, second P2) — the streaming-start telemetry must report only what
/// is known when it fires.
///
/// The first version of that emission recorded `result: "fell_back_to_batch"`, justified
/// by "a start failure always ends the same way, in the batch path". That justification
/// was false and this suite is the executable form of why: `cancel()` calls
/// `discardSession()` and runs no batch decode, so a user who cancels after a failed start
/// leaves behind a permanent record of a fallback that never happened.
///
/// The defect was not the value, it was the forward-looking CLAIM — a report emitted at
/// time T asserting an outcome decided at T+1. These tests drive the real adapter through
/// the real path and read the real emitted event, rather than asserting a string constant.
@MainActor
@Suite("Streaming start telemetry claims nothing about what follows (#1654)")
struct ParakeetStreamingStartTelemetryTests {

  #if DEBUG
    /// The reviewer's exact scenario: start fails, then the user cancels. No batch decode
    /// ever runs, so nothing emitted may say one did.
    @Test("a failed start followed by cancel records no batch-fallback claim")
    func failedStartThenCancelClaimsNoFallback() async throws {
      let waiter = TelemetryEventWaiter()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { waiter.record(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      let stub = StubParakeetASRManager()
      stub.startStreamingThrows = true
      let adapter = ParakeetEngineAdapter(asrManager: stub)

      try await adapter.beginSession(SessionID(), options: .default, streaming: true)
      let event = try await waiter.waitForEvent(
        matching: { $0.stringProps["operation"] == "start" },
        describedAs: "asr_streaming start observation")

      // Cancel: discardSession() runs, no batch decode happens.
      await adapter.cancel()

      #expect(event.name == "limb.failure_observed")
      #expect(event.stringProps["limb"] == "asr_streaming")
      #expect(event.stringProps["operation"] == "start")
      // Reports the observation, not a consequence.
      #expect(event.stringProps["result"] == "failed")

      // The load-bearing negative: nothing anywhere in the recorded history may assert a
      // fallback, because none occurred. Asserted over ALL events rather than the one we
      // fetched, so a second emission elsewhere cannot smuggle the claim back in.
      for recorded in waiter.events {
        for value in recorded.stringProps.values {
          #expect(
            !value.contains("fell_back"),
            "no event may claim a batch fallback after a cancel: \(recorded.name)")
        }
      }
    }

    /// Two-way control. Without it, an adapter that emitted NOTHING would satisfy the
    /// negative assertion above perfectly — the suite would prove absence of a wrong claim
    /// rather than presence of a right one.
    @Test("the start-failure observation is actually emitted, with the classified cause")
    func startFailureIsObserved() async throws {
      let waiter = TelemetryEventWaiter()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { waiter.record(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      let stub = StubParakeetASRManager()
      stub.startStreamingThrows = true
      let adapter = ParakeetEngineAdapter(asrManager: stub)

      try await adapter.beginSession(SessionID(), options: .default, streaming: true)

      let event = try await waiter.waitForEvent(
        matching: { $0.stringProps["limb"] == "asr_streaming" },
        describedAs: "asr_streaming observation")
      #expect(event.stringProps["operation"] == "start")
      // The category must name the cause rather than be empty or a placeholder — this is
      // the field that was reaching production as the literal string "NSError".
      let category = try #require(event.stringProps["error_category"])
      #expect(!category.isEmpty)
      #expect(category != "unknown")
    }

    /// The other half of the leg: a start that SUCCEEDS must emit no failure observation
    /// at all. Guards against a guard that fires on every call, which would make the
    /// metric useless while passing both tests above.
    @Test("a successful start emits no streaming failure observation")
    func successfulStartEmitsNothing() async throws {
      let waiter = TelemetryEventWaiter()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { waiter.record(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      let stub = StubParakeetASRManager()
      stub.startStreamingThrows = false
      let adapter = ParakeetEngineAdapter(asrManager: stub)

      try await adapter.beginSession(SessionID(), options: .default, streaming: true)

      let streamingFailures = waiter.events.filter {
        $0.stringProps["limb"] == "asr_streaming"
      }
      #expect(streamingFailures.isEmpty, "a healthy start must record no failure")
    }
  #endif
}
