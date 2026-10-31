import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprTranscribeCpp

/// #4254 plan §16.1, §16.7: when these fail, a meeting transcript line lands at the wrong time,
/// a line that spans a removed silence starts or ends in the wrong stretch, Whisper's invented
/// ending over the synthetic look-ahead is placed onto real speech, or the decoder is fed audio
/// that was never spoken.
///
/// All inputs are literal sample indices at 16 kHz (16 samples per millisecond).
@Suite("Meeting Whisper preparation", .tags(.productOutcome))
struct MeetingWhisperPreparationTests {
  /// Original run: 80,000 samples (5 s). Speech kept at [16,000, 32,000) and [48,000, 56,000).
  private func prepared() throws -> MeetingWhisperPreparation {
    let samples = (0..<80_000).map { Float($0 % 7) / 10 }
    return try #require(
      MeetingWhisperPreparation(
        samples: samples, stretches: [16_000..<32_000, 48_000..<56_000], lookAhead: 8_000))
  }

  @Test("no stretch is confirmed silence; empty and out-of-run stretches are dropped")
  func silence() {
    let samples = [Float](repeating: 0, count: 1_000)
    #expect(MeetingWhisperPreparation(samples: samples, stretches: [], lookAhead: 8_000) == nil)
    #expect(
      MeetingWhisperPreparation(
        samples: samples, stretches: [5..<5, 2_000..<3_000], lookAhead: 8_000) == nil)
  }

  @Test("the input is the kept stretches joined in order, then the look-ahead zeros")
  func joinedInput() throws {
    let samples = (0..<80_000).map { Float($0 % 7) / 10 }
    let p = try prepared()
    #expect(p.speechSamples == 24_000)
    #expect(p.input.count == 32_000)
    #expect(Array(p.input[0..<16_000]) == Array(samples[16_000..<32_000]))
    #expect(Array(p.input[16_000..<24_000]) == Array(samples[48_000..<56_000]))
    #expect(p.input[24_000...].allSatisfy { $0 == 0 })
    #expect(p.originalSamples == 80_000)
  }

  @Test("at an exact join a start belongs to the following stretch, an end to the preceding one")
  func joins() throws {
    let p = try prepared()
    #expect(p.originalStart(0) == 16_000)
    #expect(p.originalStart(15_999) == 31_999)
    #expect(p.originalStart(16_000) == 48_000, "start at the join: following stretch")
    #expect(p.originalEnd(16_000) == 32_000, "end at the join: preceding stretch")
    #expect(p.originalEnd(16_001) == 48_001)
    #expect(p.originalEnd(24_000) == 56_000, "end of the joined speech")
  }

  @Test("look-ahead times stay past the real end; invalid times are unchanged")
  func lookAheadAndInvalid() throws {
    let p = try prepared()
    #expect(p.originalStart(24_000) == 80_000)
    #expect(p.originalStart(26_000) == 82_000)
    #expect(p.originalEnd(30_000) == 86_000)
    #expect(p.originalStart(-5) == -5)
    #expect(p.originalEnd(-5) == -5)
  }

  @Test("segments restore start and end separately; a crossing segment spans the removed gap")
  func restoreSegments() throws {
    let p = try prepared()
    let run = TranscribeCppRunResult(
      text: " a b c d e", detectedLanguage: "en",
      segments: [
        TranscribeCppSegment(startMs: 0, endMs: 500, text: " a"),
        // Starts in stretch 1, ends in stretch 2: crosses the removed gap.
        TranscribeCppSegment(startMs: 900, endMs: 1_200, text: " b"),
        // Starts exactly at the join.
        TranscribeCppSegment(startMs: 1_000, endMs: 1_500, text: " c"),
        // Starts in the look-ahead.
        TranscribeCppSegment(startMs: 1_500, endMs: 2_000, text: " d"),
        // Invalid: ends before it starts.
        TranscribeCppSegment(startMs: 700, endMs: 600, text: " e"),
      ])
    let restored = p.restore(run)
    #expect(
      restored.segments.map { [$0.startMs, $0.endMs] } == [
        [1_000, 1_500], [1_900, 3_200], [3_000, 3_500], [5_000, 5_500], [700, 600],
      ])
    #expect(restored.text == run.text)
    #expect(restored.segments.map(\.text) == run.segments.map(\.text))
  }
}
