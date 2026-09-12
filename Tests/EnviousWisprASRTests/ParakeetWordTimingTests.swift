import EnviousWisprCore
import FluidAudio
import Foundation
import Testing

@testable import EnviousWisprASR

/// #2809 chunk 1: `ParakeetBackend.mapWordTimings` is the adapter between the fork's raw
/// token timings and `ASRResult.wordTimings`. What fails when these fail is a word later
/// attributed to the wrong speaker, or an engine that stopped returning timings going
/// unnoticed because it silently reported `nil` instead of `word_timing_coverage_bucket=none`.
@Suite("ParakeetBackend word timings", .tags(.productOutcome))
struct ParakeetWordTimingTests {

  @Test("no token timings at all means Bypass: both fields nil")
  func noTokenTimingsIsBypass() {
    let (words, coverage) = ParakeetBackend.mapWordTimings(
      from: nil, text: "hello world", audioDurationMs: 1000)
    #expect(words == nil)
    #expect(coverage == nil)
  }

  @Test("real token timings build words and bind them onto the text")
  func realTokenTimingsBindOntoText() {
    // Each token starts a new word (leading space = boundary marker); this mirrors the
    // fork's own SentencePiece output shape closely enough to exercise the adapter's
    // ms-rounding and its call into `buildWordTimings`.
    let timings = [
      TokenTiming(token: " hello", tokenId: 1, startTime: 0.0, endTime: 0.4, confidence: 0.9),
      TokenTiming(token: " world", tokenId: 2, startTime: 0.4, endTime: 0.9, confidence: 0.9),
    ]
    let (words, coverage) = ParakeetBackend.mapWordTimings(
      from: timings, text: "hello world", audioDurationMs: 1000)
    let bound = try! #require(words)
    #expect(bound.map(\.word) == ["hello", "world"])
    #expect(bound[0].startMs == 0 && bound[0].endMs == 400)
    #expect(bound[1].startMs == 400 && bound[1].endMs == 900)
    let resolvedCoverage = try! #require(coverage)
    #expect(resolvedCoverage.timed == resolvedCoverage.total)
  }

  @Test(
    "an engine that stops returning usable timings on a healthy run reports coverage, not nil"
  )
  func degradedTimingsStillReportCoverage() {
    // Empty (but non-nil) token timings: the engine ran, gave nothing usable. This must
    // stay OBSERVABLE via coverage=0/N, never collapse to `nil` (which would read as
    // "never asked"), so `word_timing_coverage_bucket=none` is reachable in telemetry.
    let (words, coverage) = ParakeetBackend.mapWordTimings(
      from: [], text: "hello world", audioDurationMs: 1000)
    #expect(words != nil)
    let resolvedCoverage = try! #require(coverage)
    #expect(resolvedCoverage.timed == 0)
    #expect(resolvedCoverage.total > 0)
  }

  @Test(
    "a punctuation-only trailing piece assembles onto its word through the fork's real boundary rule"
  )
  func punctuationOnlyTrailingPieceAssemblesThroughBuildWordTimings() {
    // "." carries no leading space / "▁" boundary marker, so `buildWordTimings` appends it
    // to the PRECEDING word rather than starting a new one — this exercises that real
    // assembly path, not a hand-built word tuple standing in for it.
    let timings = [
      TokenTiming(token: " well", tokenId: 1, startTime: 0.0, endTime: 0.3, confidence: 0.9),
      TokenTiming(token: ".", tokenId: 2, startTime: 0.3, endTime: 0.3, confidence: 0.9),
      TokenTiming(token: " done", tokenId: 3, startTime: 0.3, endTime: 0.6, confidence: 0.9),
    ]
    let (words, coverage) = ParakeetBackend.mapWordTimings(
      from: timings, text: "well. done", audioDurationMs: 1000)
    let bound = try! #require(words)
    #expect(bound.map(\.word) == ["well.", "done"])
    #expect(bound[0].startMs == 0 && bound[0].endMs == 300)
    #expect(bound[1].startMs == 300 && bound[1].endMs == 600)
    let resolvedCoverage = try! #require(coverage)
    #expect(resolvedCoverage.timed == resolvedCoverage.total)
  }

  @Test(
    "preserves text and time over punctuation, a numeral, a hyphenated word and a non-Latin script"
  )
  func preservesTextAndTimeOverMixedScript() {
    let text = "Well, 42 café-style 東京 done."
    let timings = [
      TokenTiming(token: " Well,", tokenId: 1, startTime: 0.0, endTime: 0.4, confidence: 0.9),
      TokenTiming(token: " 42", tokenId: 2, startTime: 0.4, endTime: 0.7, confidence: 0.9),
      TokenTiming(
        token: " café-style", tokenId: 3, startTime: 0.7, endTime: 1.5, confidence: 0.9),
      TokenTiming(token: " 東京", tokenId: 4, startTime: 1.5, endTime: 2.0, confidence: 0.9),
      TokenTiming(token: " done.", tokenId: 5, startTime: 2.0, endTime: 2.6, confidence: 0.9),
    ]
    let (words, coverage) = ParakeetBackend.mapWordTimings(
      from: timings, text: text, audioDurationMs: 3000)
    let bound = try! #require(words)
    #expect(bound.map(\.word) == ["Well,", "42", "café-style", "東京", "done."])
    #expect(bound.allSatisfy { $0.startMs != nil && $0.endMs != nil })
    let resolvedCoverage = try! #require(coverage)
    #expect(resolvedCoverage.timed == resolvedCoverage.total)
  }
}
