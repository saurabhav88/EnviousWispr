import Foundation
import Testing

@testable import EnviousWisprServices

/// #2958: the record-start VAD boundaries (#1780) no longer emit PostHog rows; they
/// write the take's summary, and `dictation.terminal` carries it as `vad_*` fields.
///
/// This suite is the WIRE contract for that fold, read through the DEBUG hook that is
/// derived from the real terminal payload. It replaces the per-marker schema freeze
/// (`RecordStartTelemetryServiceTests`) and the per-marker `take_id` contract
/// (`VADMarkerTakeIDTelemetryTests`), both of which asserted rows that no longer exist.
///
/// `.serialized` because `testEventHook` is process-global and the ledger inside
/// `TelemetryService.shared` is shared state; concurrent suites would cross-capture.
#if DEBUG
  @MainActor
  @Suite(
    "dictation.terminal carries the record-start summary (#2958)",
    .serialized, .tags(.observabilityContract))
  struct TakeStageSummaryTelemetryTests {

    private static let takeA = "9F2C1D84-6B3A-4E07-9C51-0A7D2E6F1B33"
    private static let takeB = "0C4E7A21-11D2-4B8F-9E63-7A5B1C9D2E44"

    private final class EventBox: @unchecked Sendable {
      private let lock = NSLock()
      private var stored: [CapturedTelemetryEvent] = []
      func append(_ event: CapturedTelemetryEvent) { lock.withLock { stored.append(event) } }
      var events: [CapturedTelemetryEvent] { lock.withLock { stored } }
    }

    /// Captures exactly the events emitted inside `body`, then always restores the
    /// global hook so a failure cannot leak into a sibling suite.
    private func capture(_ body: () -> Void) -> [CapturedTelemetryEvent] {
      let box = EventBox()
      TelemetryService.shared.testEventHook = { event in box.append(event) }
      defer { TelemetryService.shared.testEventHook = nil }
      body()
      return box.events
    }

    private func terminal(_ events: [CapturedTelemetryEvent], take: String) throws
      -> CapturedTelemetryEvent
    {
      try #require(
        events.first { $0.name == "dictation.terminal" && $0.stringProps["take_id"] == take },
        "expected one terminal for \(take); saw \(events.map(\.name))")
    }

    private static func emitAllThree(takeID: String?) {
      TelemetryService.shared.dictationVADPreparationCompleted(
        backend: "parakeet", inputRoute: "built_in_mic", ready: true, modelReused: false,
        takeID: takeID)
      TelemetryService.shared.dictationFirstVADChunkStarted(
        backend: "parakeet", inputRoute: "built_in_mic", monitorToFirstChunkMs: 12.5,
        takeID: takeID)
      TelemetryService.shared.dictationFirstVADChunkCompleted(
        backend: "parakeet", inputRoute: "built_in_mic", chunkProcessingLatencyMs: 3.25,
        shouldStop: false, takeID: takeID)
    }

    @Test("the three markers emit no rows of their own")
    func markersEmitNothing() {
      let events = capture {
        TelemetryService.shared.dictationStarted(takeID: Self.takeA, backend: "parakeet")
        Self.emitAllThree(takeID: Self.takeA)
      }
      #expect(events.map(\.name) == ["dictation.started"])
      _ = TelemetryService.shared.takeStages.close(takeID: Self.takeA)
    }

    @Test("a take that reached every boundary carries all eight vad_* fields on its terminal")
    func fullSummaryOnTerminal() throws {
      let events = capture {
        TelemetryService.shared.dictationStarted(takeID: Self.takeA, backend: "parakeet")
        Self.emitAllThree(takeID: Self.takeA)
        TelemetryService.shared.dictationTerminal(
          takeID: Self.takeA, backend: "parakeet", result: "completed", reason: nil)
      }
      let e = try terminal(events, take: Self.takeA)
      #expect(e.stringProps["vad_stage_reached"] == "first_chunk_completed")
      #expect(e.stringProps["vad_backend"] == "parakeet")
      #expect(e.stringProps["vad_input_route"] == "built_in_mic")
      #expect(e.boolProps["vad_ready"] == true)
      #expect(e.boolProps["vad_model_reused"] == false)
      #expect(e.doubleProps["vad_monitor_to_first_chunk_ms"] == 12.5)
      #expect(e.doubleProps["vad_first_chunk_latency_ms"] == 3.25)
      #expect(e.boolProps["vad_first_chunk_should_stop"] == false)
    }

    @Test("a take that ended before any boundary reports stage none and no boundary fields")
    func earlyTerminalReportsNone() throws {
      let events = capture {
        TelemetryService.shared.dictationStarted(takeID: Self.takeA, backend: "parakeet")
        TelemetryService.shared.dictationTerminal(
          takeID: Self.takeA, backend: "parakeet", result: "failed", reason: "no_microphone_found")
      }
      let e = try terminal(events, take: Self.takeA)
      #expect(e.stringProps["vad_stage_reached"] == "none")
      #expect(e.stringProps["vad_backend"] == nil)
      #expect(e.boolProps["vad_ready"] == nil)
      #expect(e.doubleProps["vad_monitor_to_first_chunk_ms"] == nil)
    }

    @Test(
      "a take that stopped after first_chunk_started localises there and omits the completed fields"
    )
    func partialSummaryStopsAtLastBoundary() throws {
      let events = capture {
        TelemetryService.shared.dictationStarted(takeID: Self.takeA, backend: "whisperKit")
        TelemetryService.shared.dictationVADPreparationCompleted(
          backend: "whisperKit", inputRoute: "bluetooth", ready: true, modelReused: true,
          takeID: Self.takeA)
        TelemetryService.shared.dictationFirstVADChunkStarted(
          backend: "whisperKit", inputRoute: "bluetooth", monitorToFirstChunkMs: 40,
          takeID: Self.takeA)
        TelemetryService.shared.dictationTerminal(
          takeID: Self.takeA, backend: "whisperKit", result: "cancelled", reason: nil)
      }
      let e = try terminal(events, take: Self.takeA)
      #expect(e.stringProps["vad_stage_reached"] == "first_chunk_started")
      #expect(e.boolProps["vad_model_reused"] == true)
      #expect(e.doubleProps["vad_monitor_to_first_chunk_ms"] == 40)
      #expect(e.doubleProps["vad_first_chunk_latency_ms"] == nil)
      #expect(e.boolProps["vad_first_chunk_should_stop"] == nil)
    }

    @Test("a terminal for a take that was never accepted carries no summary at all")
    func unopenedTakeHasNoSummary() throws {
      let events = capture {
        Self.emitAllThree(takeID: Self.takeA)
        TelemetryService.shared.dictationTerminal(
          takeID: Self.takeA, backend: "parakeet", result: "completed", reason: nil)
      }
      let e = try terminal(events, take: Self.takeA)
      #expect(
        e.stringProps["vad_stage_reached"] == nil,
        "absence must mean no summary, never a fabricated none")
      #expect(e.stringProps["vad_backend"] == nil)
    }

    @Test("a marker with no take key writes nothing")
    func nilTakeKeyWritesNothing() throws {
      let events = capture {
        TelemetryService.shared.dictationStarted(takeID: Self.takeA, backend: "parakeet")
        Self.emitAllThree(takeID: nil)
        TelemetryService.shared.dictationTerminal(
          takeID: Self.takeA, backend: "parakeet", result: "completed", reason: nil)
      }
      let e = try terminal(events, take: Self.takeA)
      #expect(e.stringProps["vad_stage_reached"] == "none")
      #expect(e.stringProps["vad_backend"] == nil)
    }

    @Test("overlapping takes keep independent summaries, and A's late terminal still finds its own")
    func overlappingTakesAreIndependent() throws {
      let events = capture {
        TelemetryService.shared.dictationStarted(takeID: Self.takeA, backend: "parakeet")
        TelemetryService.shared.dictationVADPreparationCompleted(
          backend: "parakeet", inputRoute: "built_in_mic", ready: true, modelReused: false,
          takeID: Self.takeA)
        // Take B is accepted before A reports its ending.
        TelemetryService.shared.dictationStarted(takeID: Self.takeB, backend: "whisperKit")
        Self.emitAllThree(takeID: Self.takeB)
        TelemetryService.shared.dictationTerminal(
          takeID: Self.takeA, backend: "parakeet", result: "cancelled", reason: nil)
        TelemetryService.shared.dictationTerminal(
          takeID: Self.takeB, backend: "whisperKit", result: "completed", reason: nil)
      }
      let a = try terminal(events, take: Self.takeA)
      let b = try terminal(events, take: Self.takeB)
      #expect(a.stringProps["vad_stage_reached"] == "prepared")
      #expect(a.doubleProps["vad_first_chunk_latency_ms"] == nil)
      #expect(b.stringProps["vad_stage_reached"] == "first_chunk_completed")
      #expect(b.doubleProps["vad_first_chunk_latency_ms"] == 3.25)
    }

    @Test("a late marker after the terminal cannot reopen the take")
    func lateMarkerAfterTerminalIsIgnored() throws {
      TelemetryService.shared.dictationStarted(takeID: Self.takeA, backend: "parakeet")
      TelemetryService.shared.dictationTerminal(
        takeID: Self.takeA, backend: "parakeet", result: "completed", reason: nil)
      Self.emitAllThree(takeID: Self.takeA)
      #expect(TelemetryService.shared.takeStages.close(takeID: Self.takeA) == nil)
    }

    @Test("the stage only moves forward: a repeated earlier boundary never demotes it")
    func stageIsMonotonic() throws {
      let events = capture {
        TelemetryService.shared.dictationStarted(takeID: Self.takeA, backend: "parakeet")
        Self.emitAllThree(takeID: Self.takeA)
        TelemetryService.shared.dictationVADPreparationCompleted(
          backend: "parakeet", inputRoute: "built_in_mic", ready: false, modelReused: true,
          takeID: Self.takeA)
        TelemetryService.shared.dictationTerminal(
          takeID: Self.takeA, backend: "parakeet", result: "completed", reason: nil)
      }
      let e = try terminal(events, take: Self.takeA)
      #expect(e.stringProps["vad_stage_reached"] == "first_chunk_completed")
    }
  }
#endif

/// The ledger's bound and its refusal rules, tested on a private instance so the
/// capacity case never touches the shared service.
@Suite("TakeStageLedger (#2958)", .tags(.observabilityContract))
struct TakeStageLedgerTests {

  @Test("the oldest open take is evicted past capacity and renders no summary")
  func evictsOldestPastCapacity() {
    let ledger = TakeStageLedger(capacity: 2)
    ledger.open(takeID: "A")
    ledger.open(takeID: "B")
    ledger.open(takeID: "C")
    #expect(ledger.openCount == 2)
    #expect(ledger.close(takeID: "A") == nil, "A was evicted, not closed")
    #expect(ledger.close(takeID: "B") != nil)
    #expect(ledger.close(takeID: "C") != nil)
  }

  @Test("an update for an unknown take writes nothing and says so")
  func updateUnknownTakeRefuses() {
    let ledger = TakeStageLedger(capacity: 2)
    #expect(ledger.update(takeID: "ghost") { $0.stageReached = .prepared } == false)
    #expect(ledger.openCount == 0)
  }

  @Test("close consumes: the second close of the same take returns nil")
  func closeConsumesOnce() {
    let ledger = TakeStageLedger(capacity: 2)
    ledger.open(takeID: "A")
    #expect(ledger.close(takeID: "A") != nil)
    #expect(ledger.close(takeID: "A") == nil)
  }

  @Test("reopening a take resets its summary")
  func reopenResets() {
    let ledger = TakeStageLedger(capacity: 2)
    ledger.open(takeID: "A")
    ledger.update(takeID: "A") { $0.stageReached = .firstChunkCompleted }
    ledger.open(takeID: "A")
    #expect(ledger.close(takeID: "A")?.stageReached == TakeStageSummary.Stage.none)
  }

  @Test("the terminal projection always names the stage and omits unreached boundaries")
  func projectionOmitsUnreached() {
    var summary = TakeStageSummary()
    #expect(summary.terminalProperties.keys.sorted() == ["vad_stage_reached"])
    summary.stageReached = .prepared
    summary.backend = "parakeet"
    summary.ready = true
    let keys = summary.terminalProperties.keys.sorted()
    #expect(keys == ["vad_backend", "vad_ready", "vad_stage_reached"])
  }
}
