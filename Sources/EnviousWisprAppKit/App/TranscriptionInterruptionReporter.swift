import EnviousWisprCore
import EnviousWisprServices
import EnviousWisprStorage
import Foundation

/// #2787 — on launch, reports the take the PREVIOUS process died in the
/// middle of, from the checkpoint it left on disk.
///
/// The customer's four stuck takes each ended in a quit while the app was
/// still "transcribing", and every one of them reached us as
/// `telemetry.flush_requested app_phase=transcribing` and nothing more: no
/// stage, no Sentry event, no breadcrumbs. A force-quit does not even send
/// that. This turns the persisted `TranscriptionCheckpoint` into ONE Sentry
/// error (fingerprinted by stage, so the fleet groups by where it stuck) and
/// one PostHog event, then consumes the checkpoint so the report can never
/// repeat. Metadata only: stage names, counts, the backend, a version.
///
/// It reports an INTERRUPTION, not a proven hang: a user who quit two seconds
/// into a healthy long decode leaves the same checkpoint. `stage_age_ms` is
/// wall-clock elapsed from the last checkpoint to THIS launch, including the
/// time the app was closed. It is not a measured hang duration — the dying
/// process cannot write its own death time — and a clock change weakens even
/// that reading.
enum TranscriptionInterruptionReporter {

  struct InterruptedTranscriptionError: Error, CustomStringConvertible {
    let stage: TranscriptionStage
    var description: String { "transcription interrupted by process exit at \(stage.rawValue)" }
  }

  /// Reads and consumes the orphaned checkpoint, if any, and reports it.
  /// Returns the checkpoint it reported, for tests; nil when there was none.
  @discardableResult
  @MainActor
  static func reportOrphanIfAny(
    from store: TranscriptionCheckpointStore, now: Date = Date()
  ) -> TranscriptionCheckpoint? {
    guard let checkpoint = store.takeOrphan() else { return nil }
    let ageMs = max(0, Int(now.timeIntervalSince(checkpoint.stageEnteredAt) * 1000))
    SentryBreadcrumb.captureError(
      InterruptedTranscriptionError(stage: checkpoint.stage),
      category: .transcriptionInterrupted,
      stage: "asr",
      extra: [
        "stage": checkpoint.stage.rawValue,
        "asr_backend": checkpoint.backend,
        "chunks_scheduled": checkpoint.chunksScheduled,
        "stage_age_ms": ageMs,
        "checkpoint_app_version": checkpoint.appVersion,
        "take_id": checkpoint.takeID,
      ],
      tags: ["transcription.stage": checkpoint.stage.rawValue])
    TelemetryService.shared.transcriptionInterruptedAtQuit(
      stage: checkpoint.stage.rawValue, backend: checkpoint.backend,
      chunksScheduled: checkpoint.chunksScheduled, stageAgeMs: ageMs,
      checkpointAppVersion: checkpoint.appVersion)
    return checkpoint
  }
}

// MARK: - Sentry identity

/// Pinned once shipped. The stage is part of the descriptor so each stage is
/// its own Sentry issue: "stuck after capture stopped" and "stuck inside the
/// decode" are different bugs with different owners.
extension TranscriptionInterruptionReporter.InterruptedTranscriptionError: StableSentryErrorIdentity
{
  var sentryFingerprintDescriptor: String { "TranscriptionInterrupted#\(stage.rawValue)" }
  var sentrySemanticID: String { "transcription.interrupted.\(stage.rawValue)" }
}
