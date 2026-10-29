import EnviousWisprAudio
import EnviousWisprCore
import Foundation

@testable import EnviousWisprPipeline

/// #3973 C2: the attempt most job tests run, one fixed ID so a pass resumed by a second job
/// continues the same attempt, as a launch-recovered pass does. Tests about a NEW attempt pass
/// `attempt:` themselves.
enum MeetingTestAttempt {
  static let id = UUID(uuidString: "C2C2C2C2-0000-4000-8000-000000000001")!

  static func attempt(language: String?, id: UUID = id) -> MeetingAttemptConfiguration {
    MeetingAttemptConfiguration(
      attemptID: id, requestedEngine: .parakeet, languageIntent: language,
      requestedEffectiveLanguage: language)
  }
}

extension MeetingTranscriptionJob {
  /// `run` with the shared test attempt for `language`.
  @MainActor
  func runTestAttempt(
    tracks: [MeetingTrackKind: MeetingTrackAudio], language: String?,
    checkpoint access: CheckpointAccess? = nil,
    missingAudio: [MeetingTrackKind: [MissingAudio]] = [:],
    callSpeakers: MeetingCallSpeakerEvidence = .absent,
    onStage: @escaping @MainActor (Stage) -> Void
  ) async throws -> Result {
    try await run(
      tracks: tracks, language: language, checkpoint: access, missingAudio: missingAudio,
      callSpeakers: callSpeakers, onStage: onStage, attempt: MeetingTestAttempt.attempt(language: language))
  }
}

extension MeetingTranscriptionJob.Result {
  /// This result as the pass for `attempt` returns it: resolved to the attempt's requested
  /// engine and language, as every C2 attempt is.
  func resolving(_ attempt: MeetingAttemptConfiguration) -> Self {
    .init(
      composition: composition, speakerOutcomes: speakerOutcomes, forcedCuts: forcedCuts,
      failedPieces: failedPieces, failedRanges: failedRanges, resumedPieces: resumedPieces,
      checkpointSaveFailures: checkpointSaveFailures, yieldCount: yieldCount,
      processingSeconds: processingSeconds, audioSeconds: audioSeconds,
      resolved: MeetingResolvedAttempt(
        attemptID: attempt.attemptID, requestedEngine: attempt.requestedEngine,
        resolvedEngine: attempt.requestedEngine,
        effectiveLanguage: attempt.requestedEffectiveLanguage,
        modelIdentity: resolved.modelIdentity, fallbackReason: nil), naming: naming)
  }
}
