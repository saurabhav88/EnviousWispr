import EnviousWisprCore
import Foundation
import Testing
@preconcurrency import WhisperKit

@testable import EnviousWisprASR

/// #2809 chunk 1: `WhisperKitBackend.mapResults` is the adapter between WhisperKit's own
/// segment/word shape and `ASRResult.wordTimings`. What fails when these fail is a word
/// later attributed to the wrong speaker, or a timestamp toggle silently losing its own
/// meaning (Bypass collapsing into "engine tried and got nothing", or the reverse).
@Suite("WhisperKitBackend word timings", .tags(.productOutcome))
struct WhisperKitWordTimingTests {

  private func makeResult(segments: [TranscriptionSegment], text: String) -> TranscriptionResult {
    TranscriptionResult(
      text: text, segments: segments, language: "en", timings: TranscriptionTimings())
  }

  @Test("timestamps disabled means Bypass: both fields nil, regardless of segment content")
  func timestampsDisabledIsBypass() {
    let segment = TranscriptionSegment(
      text: "hello world",
      words: [WordTiming(word: " hello", tokens: [], start: 0, end: 0.4, probability: 1)])
    let result = makeResult(segments: [segment], text: "hello world")
    let asrResult = WhisperKitBackend.mapResults(
      [result], processingTime: 1, enableTimestamps: false, audioDurationMs: 1000)
    #expect(asrResult.wordTimings == nil)
    #expect(asrResult.wordTimingCoverage == nil)
  }

  @Test("segments with words bind them onto the joined text")
  func segmentsWithWordsBindOntoText() {
    let segment = TranscriptionSegment(
      start: 0, end: 0.9, text: "hello world",
      words: [
        WordTiming(word: " hello", tokens: [], start: 0, end: 0.4, probability: 1),
        WordTiming(word: " world", tokens: [], start: 0.4, end: 0.9, probability: 1),
      ])
    let result = makeResult(segments: [segment], text: "hello world")
    let asrResult = WhisperKitBackend.mapResults(
      [result], processingTime: 1, enableTimestamps: true, audioDurationMs: 900)
    let bound = try! #require(asrResult.wordTimings)
    #expect(bound.map(\.word) == ["hello", "world"])
    #expect(bound[0].startMs == 0 && bound[0].endMs == 400)
    #expect(bound[1].startMs == 400 && bound[1].endMs == 900)
    let coverage = try! #require(asrResult.wordTimingCoverage)
    #expect(coverage.timed == coverage.total)
    #expect(coverage.total == "helloworld".utf16.count)
  }

  @Test(
    "words == nil on one segment leaves that span untimed; an end-before-start word becomes untimed too"
  )
  func mixedMissingAndInvalidWords() {
    // First segment: no words at all (engine gave nothing for this span). Second: a word
    // whose bounds are invalid (end < start).
    let first = TranscriptionSegment(start: 0, end: 0.4, text: "hello", words: nil)
    let second = TranscriptionSegment(
      start: 0.4, end: 0.9, text: "world",
      words: [WordTiming(word: " world", tokens: [], start: 0.9, end: 0.4, probability: 1)])
    let result = makeResult(segments: [first, second], text: "hello world")
    let asrResult = WhisperKitBackend.mapResults(
      [result], processingTime: 1, enableTimestamps: true, audioDurationMs: 900)
    let bound = try! #require(asrResult.wordTimings)
    #expect(bound.map(\.word) == ["hello", "world"])
    #expect(bound.allSatisfy { $0.startMs == nil && $0.endMs == nil })
    let coverage = try! #require(asrResult.wordTimingCoverage)
    #expect(coverage.timed == 0)
    #expect(coverage.total == "hello world".utf16.count - 1)  // minus the joining space
  }

  @Test(
    "timestamps enabled but no segment carries a words array: coverage=none, not nil — the earliest signal an engine stopped returning timings"
  )
  func enabledButNoWordsAnywhereReportsCoverageNone() {
    let segment = TranscriptionSegment(start: 0, end: 0.9, text: "hello world", words: nil)
    let result = makeResult(segments: [segment], text: "hello world")
    let asrResult = WhisperKitBackend.mapResults(
      [result], processingTime: 1, enableTimestamps: true, audioDurationMs: 900)
    #expect(asrResult.wordTimings != nil)
    let coverage = try! #require(asrResult.wordTimingCoverage)
    #expect(coverage.timed == 0)
    #expect(coverage.total > 0)
  }

  @Test(
    "a word beyond the recording's own audio length is untimed, even when a segment's own end overruns it"
  )
  func wordBeyondRealAudioLengthIsUntimed() {
    // WhisperKit decodes padded audio (500ms of trailing silence appended before decode),
    // so a segment can report an end inside that padding. `audioDurationMs` here is the
    // REAL recording length passed by the caller, shorter than the segment's own end.
    let segment = TranscriptionSegment(
      start: 0, end: 1.4, text: "hello",
      words: [WordTiming(word: " hello", tokens: [], start: 1.1, end: 1.3, probability: 1)])
    let result = makeResult(segments: [segment], text: "hello")
    let asrResult = WhisperKitBackend.mapResults(
      [result], processingTime: 1, enableTimestamps: true, audioDurationMs: 1000)
    let bound = try! #require(asrResult.wordTimings)
    #expect(bound[0].startMs == nil && bound[0].endMs == nil)
    #expect(try! #require(asrResult.wordTimingCoverage).timed == 0)
  }

  @Test(
    "preserves text and time over punctuation, a numeral, a hyphenated word and a non-Latin script"
  )
  func preservesTextAndTimeOverMixedScript() {
    let text = "Well, 42 café-style 東京 done."
    let segment = TranscriptionSegment(
      start: 0, end: 3.0, text: text,
      words: [
        WordTiming(word: " Well,", tokens: [], start: 0, end: 0.4, probability: 1),
        WordTiming(word: " 42", tokens: [], start: 0.4, end: 0.7, probability: 1),
        WordTiming(word: " café-style", tokens: [], start: 0.7, end: 1.5, probability: 1),
        WordTiming(word: " 東京", tokens: [], start: 1.5, end: 2.0, probability: 1),
        WordTiming(word: " done.", tokens: [], start: 2.0, end: 2.6, probability: 1),
      ])
    let result = makeResult(segments: [segment], text: text)
    let asrResult = WhisperKitBackend.mapResults(
      [result], processingTime: 1, enableTimestamps: true, audioDurationMs: 3000)
    #expect(asrResult.text == text)
    let bound = try! #require(asrResult.wordTimings)
    #expect(bound.map(\.word) == ["Well,", "42", "café-style", "東京", "done."])
    #expect(bound.allSatisfy { $0.startMs != nil && $0.endMs != nil })
    let coverage = try! #require(asrResult.wordTimingCoverage)
    #expect(coverage.timed == coverage.total)
  }
}
