import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// Turns from a speaker-analysis outcome and the engine's timings, shared by Transcribe a File
/// and History's Transcribe again with (#4611): speaker turns for several voices, paragraph
/// turns for one voice (`SingleSpeakerParagraphs`), or the analysis to store with no turns.
///
/// Pure apart from running the scans off the main actor; callers check their own staleness
/// after the await. Cancelling the caller cancels the scans, and a cancelled call's result is
/// unusable.
@MainActor
enum FileImportTurnAssembly {
  enum Result: Equatable {
    /// Turns to store with this analysis.
    case turns([Turn], TranscriptSpeakerAnalysis)
    /// No turns: store the analysis alone. `outcome` is the turn-storage telemetry outcome
    /// (nil when the analyzer's own telemetry already reported it); `labeledWithoutTurns` is
    /// true when a labeled analysis could bind no speaker (the caller logs why).
    case none(
      TranscriptSpeakerAnalysis, outcome: TelemetryService.FileImportTurnsOutcome?,
      labeledWithoutTurns: Bool)
  }

  static func assemble(
    outcome: SpeakerAnalysis, words: [ASRWordTiming]?, segments: [ASRSegmentTiming]?,
    rawText: String
  ) async -> Result {
    let bindableSegments = FileImportCoordinator.segmentTimingsCanBind(segments) ? segments : nil
    switch outcome {
    case .single:
      // #4611 T4: one voice keeps a start time per natural paragraph when the engine gave
      // timings; without usable timings it stays one plain document, as before.
      let paragraphs = await detached { () -> [Turn]? in
        if let words, let turns = SingleSpeakerParagraphs.paragraphs(words: words, rawText: rawText)
        {
          return turns
        }
        if let bindableSegments {
          return SingleSpeakerParagraphs.paragraphs(segments: bindableSegments, rawText: rawText)
        }
        return nil
      }
      if let paragraphs { return .turns(paragraphs, .single) }
      return .none(.single, outcome: .singleNoTurns, labeledWithoutTurns: false)
    case .labeled(let count, let speakerSegments):
      guard words != nil || bindableSegments != nil else {
        return .none(.failed(.noWordTimings), outcome: .noWordTimings, labeledWithoutTurns: false)
      }
      // The word path keeps precedence; the segment path runs only when the word path has no
      // timings or binds no individual speaker.
      if let words {
        let turns = await detached {
          TurnAssembler.assemble(entries: words, segments: speakerSegments)
        }
        if FileImportCoordinator.bindsIndividualSpeaker(turns) {
          return .turns(turns, .labeled(count: count))
        }
      }
      // #3735 §3.10: a result whose segments overlapped the diarizer at all is stored even
      // when every turn is Both.
      if let bindableSegments {
        let assembly = await detached {
          TurnAssembler.assemble(
            segmentTimings: bindableSegments, rawText: rawText, segments: speakerSegments)
        }
        if assembly.anySegmentBound { return .turns(assembly.turns, .labeled(count: count)) }
      }
      return .none(.failed(.noWordTimings), outcome: .noWordTimings, labeledWithoutTurns: true)
    case .failed, .timedOut:
      // Analyzer outcomes its own telemetry already reported.
      return .none(outcome.asStorageAnalysis, outcome: nil, labeledWithoutTurns: false)
    }
  }

  /// Runs `work` off the main actor and passes cancellation in: a multi-hour recording's scan
  /// must not freeze the UI, and a Stop must shorten it.
  private nonisolated static func detached<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    let task = Task.detached(priority: .utility, operation: work)
    return await withTaskCancellationHandler(
      operation: { await task.value }, onCancel: { task.cancel() })
  }
}
