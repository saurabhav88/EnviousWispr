import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2811, phase 4 of #2807: what fails when these fail is the wrong text on screen or in an
/// export — a rename that doesn't show, a mode that exports the wrong text, or a solo memo
/// that stops looking like today's plain text.
@Suite("TranscriptDocumentPresenter", .tags(.productOutcome))
struct TranscriptDocumentPresenterTests {

  private static let rawText = "hello there friend"
  private static func noDiff(_ turn: Turn) -> WordDiff.Result? { nil }

  private static func turn(
    _ id: String, _ speaker: String, _ range: Range<Int>, startMs: Int? = 0,
    processedText: String? = nil
  ) -> Turn {
    Turn(
      id: id, speakerId: speaker, startMs: startMs, endMs: startMs.map { $0 + 100 },
      originalTextRange: range, processedText: processedText)
  }

  @Test("nil turns renders nil, never an empty list")
  func nilTurnsRendersNil() {
    let result = TranscriptDocumentPresenter.render(
      turns: nil, rawText: Self.rawText, speakerNames: [:], mode: .cleaned, timesOn: true,
      diffLookup: Self.noDiff)
    #expect(result == nil)
  }

  @Test("an empty turns array renders nil too — the same fallback as nil, never an empty list")
  func emptyTurnsRendersNilToo() {
    let result = TranscriptDocumentPresenter.render(
      turns: [], rawText: Self.rawText, speakerNames: [:], mode: .cleaned, timesOn: true,
      diffLookup: Self.noDiff)
    #expect(result == nil)
  }

  @Test("cleaned mode shows processedText when present, falls back to the original slice otherwise")
  func cleanedModeShowsProcessedTextOrFallsBack() {
    let turns = [
      Self.turn("0-5", "A", 0..<5, processedText: "Hello!"),
      Self.turn("6-18", "B", 6..<18),
    ]
    let result = TranscriptDocumentPresenter.render(
      turns: turns, rawText: Self.rawText, speakerNames: ["A": "Zach"], mode: .cleaned,
      timesOn: false, diffLookup: Self.noDiff)
    #expect(result?.count == 2)
    #expect(result?[0].content == .plain("Hello!"))
    #expect(
      result?[1].content == .plain("there friend"),
      "no processedText yet — falls back to the raw slice")
  }

  @Test("original mode always shows the raw slice, ignoring processedText")
  func originalModeAlwaysShowsRawSlice() {
    let turns = [Self.turn("0-5", "A", 0..<5, processedText: "Hello!")]
    let result = TranscriptDocumentPresenter.render(
      turns: turns, rawText: Self.rawText, speakerNames: [:], mode: .original, timesOn: false,
      diffLookup: Self.noDiff)
    #expect(result?[0].content == .plain("hello"))
  }

  @Test("marked up mode consumes the supplied diff, never computing its own")
  func markedUpModeConsumesTheSuppliedDiff() {
    let turns = [Self.turn("0-5", "A", 0..<5, processedText: "Hi!")]
    let suppliedDiff = WordDiff.compare(original: "hello", cleaned: "Hi!", language: nil)
    let result = TranscriptDocumentPresenter.render(
      turns: turns, rawText: Self.rawText, speakerNames: [:], mode: .markedUp, timesOn: false,
      diffLookup: { _ in suppliedDiff })
    guard case .markedUp(let diff) = result?[0].content else {
      Issue.record("expected a .markedUp content case")
      return
    }
    #expect(diff == suppliedDiff)
  }

  @Test("marked up mode with no cached diff yet falls back to cleaned text, never blocking")
  func markedUpModeWithNoDiffFallsBackToCleanedText() {
    let turns = [Self.turn("0-5", "A", 0..<5, processedText: "Hi!")]
    let result = TranscriptDocumentPresenter.render(
      turns: turns, rawText: Self.rawText, speakerNames: [:], mode: .markedUp, timesOn: false,
      diffLookup: Self.noDiff)
    #expect(result?[0].content == .plain("Hi!"))
  }

  @Test("unknown speaker never gets a name, regardless of what speakerNames carries")
  func unknownSpeakerNeverGetsAName() {
    let turns = [Self.turn("0-5", "unknown", 0..<5)]
    let result = TranscriptDocumentPresenter.render(
      turns: turns, rawText: Self.rawText, speakerNames: ["unknown": "should never surface"],
      mode: .cleaned, timesOn: false, diffLookup: Self.noDiff)
    #expect(result?[0].speakerName == nil)
  }

  @Test("a real speaker with no name yet renders nil, never a fabricated default")
  func unnamedRealSpeakerRendersNilName() {
    let turns = [Self.turn("0-5", "A", 0..<5)]
    let result = TranscriptDocumentPresenter.render(
      turns: turns, rawText: Self.rawText, speakerNames: [:], mode: .cleaned, timesOn: false,
      diffLookup: Self.noDiff)
    #expect(result?[0].speakerName == nil)
  }

  @Test("times on shows a time label; times off shows none, even when the turn has real timing")
  func timesToggleControlsTheLabel() {
    let turns = [Self.turn("0-5", "A", 0..<5, startMs: 65_000)]
    let on = TranscriptDocumentPresenter.render(
      turns: turns, rawText: Self.rawText, speakerNames: [:], mode: .cleaned, timesOn: true,
      diffLookup: Self.noDiff)
    let off = TranscriptDocumentPresenter.render(
      turns: turns, rawText: Self.rawText, speakerNames: [:], mode: .cleaned, timesOn: false,
      diffLookup: Self.noDiff)
    #expect(on?[0].timeLabel == "1:05")
    #expect(off?[0].timeLabel == nil)
  }

  @Test("a turn with no timing at all never gets a time label, even with times on")
  func untimedTurnNeverGetsALabel() {
    let turns = [Self.turn("0-5", "A", 0..<5, startMs: nil)]
    let result = TranscriptDocumentPresenter.render(
      turns: turns, rawText: Self.rawText, speakerNames: [:], mode: .cleaned, timesOn: true,
      diffLookup: Self.noDiff)
    #expect(result?[0].timeLabel == nil)
  }

  @Test("exportText is nil under the same condition as render — nil or empty turns")
  func exportTextNilMatchesRenderNil() {
    #expect(
      TranscriptDocumentPresenter.exportText(
        turns: nil, rawText: Self.rawText, speakerNames: [:], timesOn: false, mode: .cleaned)
        == nil)
    #expect(
      TranscriptDocumentPresenter.exportText(
        turns: [], rawText: Self.rawText, speakerNames: [:], timesOn: false, mode: .cleaned)
        == nil)
  }

  @Test("marked up export hands over the CLEANED text and flags the fallback")
  func markedUpExportHandsOverCleanedText() {
    let turns = [Self.turn("0-5", "A", 0..<5, processedText: "Hi!")]
    let result = TranscriptDocumentPresenter.exportText(
      turns: turns, rawText: Self.rawText, speakerNames: ["A": "Zach"], timesOn: false,
      mode: .markedUp)
    #expect(result?.isCleanedFallback == true)
    #expect(result?.text.contains("Hi!") == true)
    #expect(result?.text.contains("Zach") == true)
  }

  @Test("cleaned and original export are never flagged as a fallback")
  func cleanedAndOriginalExportAreNeverFlagged() {
    let turns = [Self.turn("0-5", "A", 0..<5, processedText: "Hi!")]
    let cleaned = TranscriptDocumentPresenter.exportText(
      turns: turns, rawText: Self.rawText, speakerNames: [:], timesOn: false, mode: .cleaned)
    let original = TranscriptDocumentPresenter.exportText(
      turns: turns, rawText: Self.rawText, speakerNames: [:], timesOn: false, mode: .original)
    #expect(cleaned?.isCleanedFallback == false)
    #expect(original?.isCleanedFallback == false)
  }

  @Test("an unnamed speaker exports under an explicit label, never a blank line")
  func unnamedSpeakerExportsUnderAnExplicitLabel() {
    let turns = [Self.turn("0-5", "A", 0..<5, processedText: "Hi!")]
    let result = TranscriptDocumentPresenter.exportText(
      turns: turns, rawText: Self.rawText, speakerNames: [:], timesOn: false, mode: .cleaned)
    #expect(result?.text.hasPrefix("Unknown speaker") == true)
  }

  @Test("export button labels relabel only for marked up, and only to the cleaned-export copy")
  func exportButtonLabelsRelabelOnlyForMarkedUp() {
    let cleaned = TranscriptDocumentPresenter.exportButtonLabels(mode: .cleaned)
    let original = TranscriptDocumentPresenter.exportButtonLabels(mode: .original)
    let markedUp = TranscriptDocumentPresenter.exportButtonLabels(mode: .markedUp)
    #expect(cleaned.copy == "Copy everything")
    #expect(original.copy == "Copy everything")
    #expect(markedUp.copy == "Copy cleaned")
    #expect(markedUp.save == "Save cleaned as…")
    #expect(markedUp.share == "Share cleaned…")
  }

  @Test("a range mismatch against the supplied rawText renders an empty slice rather than crashing")
  func rangeMismatchRendersEmptySliceRatherThanCrashing() {
    let turns = [Self.turn("100-200", "A", 100..<200)]
    let result = TranscriptDocumentPresenter.render(
      turns: turns, rawText: "short", speakerNames: [:], mode: .original, timesOn: false,
      diffLookup: Self.noDiff)
    #expect(result?[0].content == .plain(""))
  }
}
