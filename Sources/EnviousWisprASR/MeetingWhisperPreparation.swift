import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprTranscribeCpp
import Foundation

/// The detected speech of one meeting run, and the decoder's input built from it (#4254 plan
/// §16.1, §16.7). The padded, merged speech stretches are joined into one reserved array (real
/// audio, no separators), followed by the decoder's synthetic look-ahead. The original run
/// stays the caller's: loudness statistics and the silent-tail filter read it, never the
/// joined speech.
///
/// Times map back stretch by stretch. A decoded start maps through the stretch that holds it
/// and an end through the stretch that holds its last sample, so at an exact join a start
/// belongs to the following stretch and an end to the preceding one. A time in the look-ahead
/// keeps its after-end place (original length plus its distance past the joined speech), so
/// the tail filter and segment binding still see it as past the real audio. Invalid times
/// are returned unchanged.
struct MeetingWhisperPreparation: Sendable, Equatable {
  /// The kept stretches, as original-run sample ranges, in order and apart.
  let stretches: [Range<Int>]
  /// The joined speech followed by `lookAhead` zeros.
  let input: [Float]
  /// Real samples in `input` (the joined speech, without the look-ahead).
  let speechSamples: Int
  /// The original run's length.
  let originalSamples: Int

  static let sampleRate = 16_000

  /// Nil when there is no stretch: the run is confirmed silence. Stretches are clamped to the
  /// run; empty ones are dropped.
  init?(samples: [Float], stretches raw: [Range<Int>], lookAhead: Int) {
    let bounds = 0..<samples.count
    let kept = raw.map { $0.clamped(to: bounds) }.filter { !$0.isEmpty }
    guard !kept.isEmpty else { return nil }
    let speech = kept.reduce(0) { $0 + $1.count }
    var joined: [Float] = []
    joined.reserveCapacity(speech + lookAhead)
    for stretch in kept { joined.append(contentsOf: samples[stretch]) }
    joined.append(contentsOf: repeatElement(0, count: lookAhead))
    stretches = kept
    input = joined
    speechSamples = speech
    originalSamples = samples.count
  }

  /// The original sample of a decoded START sample.
  func originalStart(_ decoded: Int) -> Int {
    guard decoded >= 0 else { return decoded }
    guard decoded < speechSamples else { return originalSamples + (decoded - speechSamples) }
    var offset = 0
    for stretch in stretches {
      if decoded < offset + stretch.count { return stretch.lowerBound + (decoded - offset) }
      offset += stretch.count
    }
    return originalSamples
  }

  /// The original sample of a decoded END sample (exclusive bound).
  func originalEnd(_ decoded: Int) -> Int {
    guard decoded > 0 else { return decoded }
    guard decoded <= speechSamples else { return originalSamples + (decoded - speechSamples) }
    var offset = 0
    for stretch in stretches {
      if decoded <= offset + stretch.count { return stretch.lowerBound + (decoded - offset) }
      offset += stretch.count
    }
    return originalSamples
  }

  /// `run` with every valid segment's start and end restored to the original run's timeline,
  /// separately. A segment with invalid bounds (negative, or ending before it starts) keeps
  /// them unchanged. Valid times stay in order, since the map only moves forward.
  func restore(_ run: TranscribeCppRunResult) -> TranscribeCppRunResult {
    let segments = run.segments.map { segment -> TranscribeCppSegment in
      guard segment.startMs >= 0, segment.endMs >= segment.startMs else { return segment }
      let start = originalStart(Self.samples(segment.startMs))
      let end = max(start, originalEnd(Self.samples(segment.endMs)))
      return TranscribeCppSegment(
        startMs: Self.ms(start), endMs: Self.ms(end), text: segment.text)
    }
    return TranscribeCppRunResult(
      text: run.text, detectedLanguage: run.detectedLanguage, segments: segments,
      silentTailDropped: run.silentTailDropped)
  }

  static func samples(_ ms: Int64) -> Int { Int(ms) * sampleRate / 1000 }
  static func ms(_ samples: Int) -> Int64 { Int64(samples) * 1000 / Int64(sampleRate) }
}

/// The detector a meeting decode uses: speech ranges (padded, merged) of the whole input.
/// Throws `CancellationError` when cancelled and any other error when detection cannot run.
package typealias MeetingSpeechSpans = @Sendable ([Float]) async throws -> [Range<Int>]

extension MeetingWhisperPreparation {
  /// The app's pinned bundled model, a fresh detector per call (plan §16.8).
  static let bundled: MeetingSpeechSpans = { try await MeetingSpeechDetector.spans(in: $0) }

  /// The pinned model's name, logged with each decode's outcome.
  static let detectorVersion = MeetingSpeechDetector.modelVersion
}
