import EnviousWisprAudio
import EnviousWisprCore
import Foundation

/// The speaker-analysis unit of an EnviousMeet pass for one track (#3972 R25): load the bundled
/// models, analyse the whole track from its segment files, release the models when this returns.
///
/// Same bundled models and vendor configuration as Transcribe a File, never a download. The
/// race against the deadline and the join of the worker are `SpeakerLabeler`'s, unchanged (the
/// deadline itself is the meeting policy below):
/// the outcome is decided only after the worker or the deadline genuinely finished, a timed-out
/// or cancelled worker is joined before this returns, and the models (owned by the worker) are
/// released with it. A failed or timed-out analysis returns no segments; the composer then
/// keeps every word under one speaker per track.
package enum MeetingSpeakerAnalyzer {
  /// The analysis work for `audio`, as a task the labeler races and joins. A seam so tests can
  /// substitute work without models.
  package typealias MakeWork = @Sendable (MeetingTrackAudio) -> Task<[SpeakerSegment], Error>

  package static let liveWork: MakeWork = { audio in
    Task<[SpeakerSegment], Error> {
      try Task.checkCancellation()
      let models = try BundledSpeakerModelLoader.load(in: .main)
      let analyzer = OfflineSpeakerAnalyzer()
      analyzer.initialize(models: models)
      return try await analyzer.analyze(meetingTrack: audio) { _, _ in }
    }
  }

  /// The meeting deadline (plan R33): `max(20 s, 2 s per audio minute)`. The file-import
  /// bound (0.5 s/min) is a wait the user sits through; a meeting's speaker pass runs in the
  /// background after every word is committed, and that bound made every meeting longer than
  /// about 1.5 h time out on an M5 Max. Basis: 35 shipped-diarizer runs in the #3972 bake-off,
  /// p99 0.955 s per audio minute, times the same roughly 2x headroom `SpeakerLabeler` uses for
  /// unmeasured slower Macs. File import is unchanged.
  package static func meetingDeadlineSeconds(forDurationSeconds durationSeconds: Double) -> Double {
    max(20, 2 * (durationSeconds / 60))
  }

  package static func analyze(
    _ audio: MeetingTrackAudio, labeler: SpeakerLabeler? = nil,
    makeWork: MakeWork = liveWork
  ) async -> MeetingSpeakerAnalysis {
    let durationSeconds = Double(audio.endSample) / MeetingAudioFormat.sampleRate
    let labeler =
      labeler
      ?? SpeakerLabeler(
        deadlineSecondsOverride: meetingDeadlineSeconds(forDurationSeconds: durationSeconds),
        analysisTask: { _ in Task { [] } })
    let outcome = await labeler.run(analysisTask: makeWork(audio), durationSeconds: durationSeconds)
    return analysis(from: outcome)
  }

  /// The meeting outcome for a labeler outcome. Words are never dropped for any of these.
  package static func analysis(from outcome: SpeakerAnalysis) -> MeetingSpeakerAnalysis {
    switch outcome {
    case .labeled(_, let segments):
      return MeetingSpeakerAnalysis(outcome: .labeled, segments: segments)
    case .single(let segments):
      return MeetingSpeakerAnalysis(outcome: .single, segments: segments)
    case .failed(.noSpeakerSegments):
      return MeetingSpeakerAnalysis(outcome: .noSpeech, segments: [])
    case .failed:
      return MeetingSpeakerAnalysis(outcome: .failed, segments: [])
    case .timedOut:
      return MeetingSpeakerAnalysis(outcome: .timedOut, segments: [])
    }
  }
}
