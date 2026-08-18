import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// The completion event's mapper (#2087, chunk 12).
///
/// Its own suite because it makes three decisions that are invisible at the
/// call site: which row it reads, what it does without a join key, and the unit
/// it converts to. Each has a wrong answer that still compiles.
@MainActor
@Suite("Escape Recovery completion report (#2087)", .tags(.observabilityContract))
struct EscapeRecoveryCompletionReportTests {

  private final class Captured {
    var calls:
      [(
        outcome: EscapeRecoveryTerminalOutcome, asrMs: Int?, polishMs: Int?, durationMs: Int?,
        backend: String?, takeID: String
      )] = []
  }

  private func row(
    takeID: String? = "take-1", asrSeconds: Double? = 0.8, polishSeconds: Double? = 1.5,
    processingTime: TimeInterval = 2.5
  ) -> Transcript {
    var metrics = ExecutionMetrics()
    metrics.asrLatencySeconds = asrSeconds
    metrics.llmLatencySeconds = polishSeconds
    // END-TO-END, which is what `duration_ms` means. `processingTime` is ASR
    // only, so a fixture keyed to it would let the event go on duplicating
    // `asr_duration_ms` without any test noticing.
    metrics.e2eSeconds = processingTime
    return Transcript(
      text: "kept", processingTime: processingTime, backendType: .parakeet, metrics: metrics,
      escapeRecoveredAt: Date(), escapeRecoveryTakeID: takeID)
  }

  private func emit(
    outcome: EscapeRecoveryTerminalOutcome, transcript: Transcript?, fallbackTakeID: String? = nil
  ) -> Captured {
    let captured = Captured()
    EscapeRecoveryCompletionReport.emit(
      outcome: outcome, transcript: transcript, fallbackTakeID: fallbackTakeID
    ) {
      captured.calls.append(
        (outcome: $0, asrMs: $1, polishMs: $2, durationMs: $3, backend: $4, takeID: $5))
    }
    return captured
  }

  @Test("a row with a take id is reported, with seconds converted to milliseconds")
  func reportsWithMilliseconds() throws {
    let captured = emit(outcome: .saved, transcript: row())

    let call = try #require(captured.calls.first)
    #expect(call.takeID == "take-1")
    #expect(call.asrMs == 800, "0.8s is 800ms — the event names its unit and must honour it")
    #expect(call.polishMs == 1500)
    #expect(call.durationMs == 2500)
    #expect(call.backend == "parakeet")
    #expect(call.outcome == .saved)
  }

  /// The join key is the whole point of the event.
  ///
  /// These fire hours later and can outlive a relaunch, so the PERSISTED take id
  /// is the only thing tying a completion back to the dictation it came from. An
  /// event without one cannot join the funnel; emitting it anyway would inflate
  /// the denominator with rows nothing can match, making the feature look worse
  /// than it is in exactly the metric used to judge it.
  @Test("a row with no take id is not reported at all")
  func silentWithoutAJoinKey() {
    let captured = emit(outcome: .saved, transcript: row(takeID: nil))

    #expect(captured.calls.isEmpty)
  }

  /// The failures are the whole reason the funnel exists.
  ///
  /// `empty`, `transcription_failed` and `abandoned` have no row BY DEFINITION,
  /// so a reporter that requires one drops exactly the outcomes worth counting
  /// and leaves a completion rate computed only over the takes that already
  /// worked. That is not a gap in the data, it is a number that reads as
  /// success no matter how badly the feature performs.
  @Test("a failure with no row is still reported, using the fallback take id")
  func failureWithoutARowStillReports() throws {
    let captured = emit(
      outcome: .transcriptionFailed, transcript: nil, fallbackTakeID: "take-failed")

    let call = try #require(captured.calls.first)
    #expect(call.takeID == "take-failed")
    #expect(call.outcome == .transcriptionFailed)
    #expect(call.asrMs == nil, "there is no row, so there are no latencies to report")
    // Was `== 0`, which pinned a fabrication rather than a behaviour: the mapper
    // defaulted a missing duration to zero and this line agreed with it. Absent
    // is the honest value, and `rowlessTerminalInventsNothing` below is the case
    // that now argues for it rather than merely recording it.
    #expect(call.durationMs == nil, "there is no row, so there is no duration either")
  }

  @Test("the row's take id wins over the fallback when both exist")
  func rowTakeIDWins() throws {
    let captured = emit(outcome: .saved, transcript: row(), fallbackTakeID: "take-fallback")

    let call = try #require(captured.calls.first)
    #expect(
      call.takeID == "take-1",
      """
      the PERSISTED id is the join key. The fallback is whatever the driver \
      currently holds, which after a fast follow-up recording is a different \
      take — the exact confusion the persisted id exists to prevent.
      """)
  }

  @Test("no row and no fallback is not reported")
  func silentWithoutARow() {
    // `.saveFailed` is the real shape of this case: the pipeline ran, the save
    // did not, so there is no row to read and no take id to join on.
    let captured = emit(outcome: .saveFailed, transcript: nil)

    #expect(
      captured.calls.isEmpty,
      "the terminals with no row have no take id either, so they cannot be joined")
  }

  /// Absent is not zero.
  ///
  /// A take that never polished has no polish latency, and reporting 0 would put
  /// it in the same bucket as one that polished instantaneously — which is the
  /// difference between "this feature costs nothing" and "this measurement was
  /// never taken". Same distinction the pending sweep's `walkComplete` exists to
  /// preserve one layer down.
  @Test("missing latencies stay nil rather than becoming zero")
  func absentLatenciesStayAbsent() throws {
    let captured = emit(
      outcome: .saved, transcript: row(asrSeconds: nil, polishSeconds: nil))

    let call = try #require(captured.calls.first)
    #expect(call.asrMs == nil)
    #expect(call.polishMs == nil)
    #expect(call.durationMs == 2500, "control: the total is still reported")
  }

  /// A row-less terminal must not be given a backend or a duration it never had.
  ///
  /// This is the sharp version of the case above, and it is worth its own test
  /// because the wrong answer is INVISIBLE in the data rather than absent from
  /// it. Only `abandoned`, `empty` and `transcriptionFailed` arrive without a
  /// row, so a default backend would stamp one engine's name on every failure
  /// and on nothing else — a query grouping failures by engine would then read
  /// as a finding about that engine, produced entirely by the default. A zero
  /// duration does the same to any latency chart. `escape_recovery.started`
  /// already carries the real backend and spoken length under the same take id,
  /// so the funnel has a place to get them from that is not a guess.
  @Test("a terminal with no row reports no backend and no duration, rather than defaults")
  func rowlessTerminalInventsNothing() throws {
    let captured = emit(
      outcome: .abandoned, transcript: nil, fallbackTakeID: "take-9")

    let call = try #require(captured.calls.first)
    #expect(call.takeID == "take-9", "control: the join key still travels")
    #expect(call.outcome == .abandoned, "control: the outcome still travels")
    #expect(
      call.backend == nil,
      "a default here would attribute every abandoned recovery to one engine")
    #expect(
      call.durationMs == nil,
      "a zero here would report a measurement that was never taken")
  }
}
