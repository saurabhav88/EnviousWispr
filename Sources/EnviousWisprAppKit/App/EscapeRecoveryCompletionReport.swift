import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// Turns a finished Escape Recovery into its completion event (#2087).
///
/// A free function in its own file rather than a method on
/// `DictationLifecycleCoordinator`, for two reasons that are not style: that
/// type's terminal-handling area is already saturated (plan §3e says extract
/// rather than squeeze), and holding a reference to something that owns this
/// would spend one of its collaborator slots on a pure mapping with no state.
/// The collaborator ceiling is still live and still the one that matters here;
/// the line ceiling this note used to cite was deleted in #2292 C6.
///
/// **Reads the ROW, not the driver.** Every number here already lives on the
/// transcript that was just written. Asking the driver instead would read
/// whatever it holds at emission time, and after a fast follow-up recording
/// that is a different take — the class of join-key bug `escapeRecoveryTakeID`
/// exists to prevent.
enum EscapeRecoveryCompletionReport {

  /// The production emission, in ONE call.
  ///
  /// Exists so the composition site spends a single line, because that file is
  /// for wiring and feature logic accumulating there is what turns a composition
  /// root into a second implementation.
  @MainActor
  static func report(
    outcome: EscapeRecoveryTerminalOutcome, transcript: Transcript?, fallbackTakeID: String?
  ) {
    emit(outcome: outcome, transcript: transcript, fallbackTakeID: fallbackTakeID) {
      TelemetryService.shared.escapeRecoveryCompleted(
        outcome: $0, asrDurationMs: $1, polishDurationMs: $2, durationMs: $3,
        asrBackend: $4, takeID: $5)
    }
  }

  /// Emit `escape_recovery_completed` for a finished recovery.
  ///
  /// - Parameters:
  ///   - outcome: the terminal the pipeline reached.
  ///   - transcript: the held row, or nil when there is none — every failure
  ///     terminal has no row by definition.
  ///   - fallbackTakeID: the take id when no row carries one. The driver's
  ///     concluded key, which is what a failed recovery still has.
  ///   - emit: the telemetry seam, injected so a test can read the payload
  ///     without a network client.
  @MainActor
  static func emit(
    outcome: EscapeRecoveryTerminalOutcome,
    transcript: Transcript?,
    fallbackTakeID: String?,
    emit: (
      _ outcome: EscapeRecoveryTerminalOutcome, _ asrMs: Int?, _ polishMs: Int?,
      _ durationMs: Int?, _ backend: String?, _ takeID: String
    ) -> Void
  ) {
    // The take id comes from the ROW when there is one and from the FALLBACK
    // otherwise, because the terminals that matter most have no row by
    // definition. `empty`, `transcription_failed` and `abandoned` are exactly
    // the failures the funnel exists to count, and requiring a row dropped
    // every one of them silently — leaving a completion rate computed only over
    // the takes that already worked.
    //
    // Still dropped when NEITHER can supply one: an event with no join key
    // cannot enter the funnel at all, so emitting it would only inflate the
    // denominator with rows nothing can match.
    guard let takeID = transcript?.escapeRecoveryTakeID ?? fallbackTakeID else { return }
    // EVERY measured field comes from the row or is OMITTED. The take id has a
    // fallback because a join key is what makes the event countable at all; the
    // measurements do not, because there is nothing to fall back TO. A default
    // backend would stamp one engine's name on every row-less terminal —
    // `abandoned`, `empty`, `transcriptionFailed` — and those are the only
    // terminals that reach here without a row, so the fabrication would land on
    // exactly the population being measured and nowhere else. `escape_recovery.started`
    // already carries the real backend and spoken length under this same take
    // id, so the funnel joins for them rather than being told a guess.
    let metrics = transcript?.metrics
    emit(
      outcome,
      metrics?.asrLatencySeconds.map { Int($0 * 1000) },
      metrics?.llmLatencySeconds.map { Int($0 * 1000) },
      // END-TO-END, not `processingTime`. That field is copied straight from
      // `adapter.lastResult.processingTime`, so it measures ASR alone — it
      // would duplicate `asr_duration_ms` and understate every polished take,
      // on a field whose name claims the whole recovery. `e2eSeconds` is the
      // value this event has always meant; nil rather than a fallback to the
      // ASR figure, because a wrong number here is worse than a missing one.
      transcript?.metrics?.e2eSeconds.map { Int($0 * 1000) },
      transcript?.backendType.rawValue,
      takeID)
  }
}
