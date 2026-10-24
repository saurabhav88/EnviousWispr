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
    processedText: String? = nil, wasPolished: Bool = true
  ) -> Turn {
    Turn(
      id: id, speakerId: speaker, startMs: startMs, endMs: startMs.map { $0 + 100 },
      originalTextRange: range, processedText: processedText, wasPolished: wasPolished)
  }

  @Test("a finished document discloses a turn the cleanup did not polish, and only then (#2851)")
  func isUncleanedFollowsWasPolishedOnAFinishedDocument() {
    // Both turns carry text; only the flag differs, so a presenter reading `processedText`
    // instead of `wasPolished` cannot pass (second-pass review).
    let turns = [
      Self.turn("0-5", "A", 0..<5, processedText: "Hello!", wasPolished: true),
      Self.turn("6-18", "B", 6..<18, processedText: "There, friend.", wasPolished: false),
    ]
    let finished = TranscriptDocumentPresenter.render(
      turns: turns, rawText: Self.rawText, speakerNames: [:], mode: .cleaned, timesOn: false,
      documentFinished: true, diffLookup: Self.noDiff)
    #expect(finished?.map(\.isUncleaned) == [false, true])
    let running = TranscriptDocumentPresenter.render(
      turns: turns, rawText: Self.rawText, speakerNames: [:], mode: .cleaned, timesOn: false,
      documentFinished: false, diffLookup: Self.noDiff)
    #expect(
      running?.map(\.isUncleaned) == [false, false],
      "a turn the cleanup has not reached yet is not disclosed while the document still runs")
    let originalMode = TranscriptDocumentPresenter.render(
      turns: turns, rawText: Self.rawText, speakerNames: [:], mode: .original, timesOn: false,
      documentFinished: true, diffLookup: Self.noDiff)
    #expect(
      originalMode?.map(\.isUncleaned) == [false, true],
      "the disclosure does not depend on the mode")
  }

  @Test("nil turns renders nil, never an empty list")
  func nilTurnsRendersNil() {
    let result = TranscriptDocumentPresenter.render(
      turns: nil, rawText: Self.rawText, speakerNames: [:], mode: .cleaned, timesOn: true,
      documentFinished: true,
      diffLookup: Self.noDiff)
    #expect(result == nil)
  }

  @Test("an empty turns array renders nil too — the same fallback as nil, never an empty list")
  func emptyTurnsRendersNilToo() {
    let result = TranscriptDocumentPresenter.render(
      turns: [], rawText: Self.rawText, speakerNames: [:], mode: .cleaned, timesOn: true,
      documentFinished: true,
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
      timesOn: false, documentFinished: true, diffLookup: Self.noDiff)
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
      documentFinished: true,
      diffLookup: Self.noDiff)
    #expect(result?[0].content == .plain("hello"))
  }

  @Test("marked up mode consumes the supplied diff, never computing its own")
  func markedUpModeConsumesTheSuppliedDiff() {
    let turns = [Self.turn("0-5", "A", 0..<5, processedText: "Hi!")]
    let suppliedDiff = WordDiff.compare(original: "hello", cleaned: "Hi!", language: nil)
    let result = TranscriptDocumentPresenter.render(
      turns: turns, rawText: Self.rawText, speakerNames: [:], mode: .markedUp, timesOn: false,
      documentFinished: true,
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
      documentFinished: true,
      diffLookup: Self.noDiff)
    #expect(result?[0].content == .plain("Hi!"))
  }

  @Test("unknown speaker never gets a name, regardless of what speakerNames carries")
  func unknownSpeakerNeverGetsAName() {
    let turns = [Self.turn("0-5", "unknown", 0..<5)]
    let result = TranscriptDocumentPresenter.render(
      turns: turns, rawText: Self.rawText, speakerNames: ["unknown": "should never surface"],
      mode: .cleaned, timesOn: false, documentFinished: true, diffLookup: Self.noDiff)
    #expect(result?[0].speakerName == nil)
  }

  @Test("a real speaker with no name yet renders nil, never a fabricated default")
  func unnamedRealSpeakerRendersNilName() {
    let turns = [Self.turn("0-5", "A", 0..<5)]
    let result = TranscriptDocumentPresenter.render(
      turns: turns, rawText: Self.rawText, speakerNames: [:], mode: .cleaned, timesOn: false,
      documentFinished: true,
      diffLookup: Self.noDiff)
    #expect(result?[0].speakerName == nil)
  }

  @Test("times on shows a time label; times off shows none, even when the turn has real timing")
  func timesToggleControlsTheLabel() {
    let turns = [Self.turn("0-5", "A", 0..<5, startMs: 65_000)]
    let on = TranscriptDocumentPresenter.render(
      turns: turns, rawText: Self.rawText, speakerNames: [:], mode: .cleaned, timesOn: true,
      documentFinished: true,
      diffLookup: Self.noDiff)
    let off = TranscriptDocumentPresenter.render(
      turns: turns, rawText: Self.rawText, speakerNames: [:], mode: .cleaned, timesOn: false,
      documentFinished: true,
      diffLookup: Self.noDiff)
    #expect(on?[0].timeLabel == "1:05")
    #expect(off?[0].timeLabel == nil)
  }

  @Test("a turn with no timing at all never gets a time label, even with times on")
  func untimedTurnNeverGetsALabel() {
    let turns = [Self.turn("0-5", "A", 0..<5, startMs: nil)]
    let result = TranscriptDocumentPresenter.render(
      turns: turns, rawText: Self.rawText, speakerNames: [:], mode: .cleaned, timesOn: true,
      documentFinished: true,
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

  @Test("a turn two people shared exports under Both")
  func sharedTurnExportsUnderBoth() {
    let turns = [Self.turn("0-5", TurnAssembler.bothSpeakersID, 0..<5, processedText: "Hi!")]
    let result = TranscriptDocumentPresenter.exportText(
      turns: turns, rawText: Self.rawText, speakerNames: [:], timesOn: false, mode: .cleaned)
    #expect(result?.text.hasPrefix("Both\n") == true)
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
    #expect(cleaned.save == "Save as…")
    #expect(cleaned.share == "Share…")
  }

  @Test("a range mismatch against the supplied rawText renders an empty slice rather than crashing")
  func rangeMismatchRendersEmptySliceRatherThanCrashing() {
    let turns = [Self.turn("100-200", "A", 100..<200)]
    let result = TranscriptDocumentPresenter.render(
      turns: turns, rawText: "short", speakerNames: [:], mode: .original, timesOn: false,
      documentFinished: true,
      diffLookup: Self.noDiff)
    #expect(result?[0].content == .plain(""))
  }

  // MARK: - Turn identity (#4001 H11)

  @Test("each rendered turn carries its source turn's id, in order, in every mode")
  func renderCarriesTurnIDs() throws {
    let turns = [Self.turn("0-5", "sys:S1", 0..<5), Self.turn("6-11", "mic:you", 6..<11)]
    for mode in [TranscriptDocumentPresenter.ViewMode.cleaned, .original, .markedUp] {
      let rendered = try #require(
        TranscriptDocumentPresenter.render(
          turns: turns, rawText: Self.rawText, speakerNames: [:], mode: mode, timesOn: true,
          documentFinished: true, diffLookup: Self.noDiff))
      #expect(rendered.map(\.turnID) == ["0-5", "6-11"], "\(mode)")
    }
  }

  static func rendered(_ id: String) -> TranscriptDocumentPresenter.RenderedTurn {
    TranscriptDocumentPresenter.RenderedTurn(
      turnID: id, speakerId: "sys:S1", speakerName: "Maria", timeLabel: nil,
      content: .plain("Hi"), isUncleaned: false)
  }

  @Test("row keys are the turn id and its occurrence, unique and in order")
  func rowKeys() {
    let keys = TurnRowKey.keyed(["x", "x", "x#1", "", ""].map(Self.rendered))
      .map(\.key)
    #expect(
      keys == [
        TurnRowKey(turnID: "x", occurrence: 0), TurnRowKey(turnID: "x", occurrence: 1),
        TurnRowKey(turnID: "x#1", occurrence: 0), TurnRowKey(turnID: "", occurrence: 0),
        TurnRowKey(turnID: "", occurrence: 1),
      ])
    #expect(Set(keys).count == keys.count, "no two rows share a key")
  }

  @Test("a turn keeps its row key when earlier turns are hidden or the order changes")
  func rowKeysSurviveFiltering() {
    let all = ["a", "b", "c", "d"].map(Self.rendered)
    let full = Dictionary(
      uniqueKeysWithValues: TurnRowKey.keyed(all).map { ($0.turn.turnID, $0.key) })
    let hidden = TurnRowKey.keyed([all[1], all[3]])
    for entry in hidden { #expect(entry.key == full[entry.turn.turnID]) }
    let reordered = TurnRowKey.keyed(all.reversed())
    for entry in reordered { #expect(entry.key == full[entry.turn.turnID]) }
  }

  @Test("rendered turns that differ only by source id are different turns")
  func renderedTurnEquality() {
    #expect(Self.rendered("a") == Self.rendered("a"))
    #expect(Self.rendered("a") != Self.rendered("b"))
  }

  // MARK: - #4001 H10: toolbar availability and the turn document's inputs

  @Test("Save and Share availability matches what History's export would deliver")
  func exportAvailabilityMatchesTheExport() {
    let one = [Self.turn("0-5", "A", 0..<5, processedText: "Hello!")]
    for turns in [nil, [], one] as [[Turn]?] {
      for fallback in [nil, "", "words"] as [String?] {
        for mode in [TranscriptDocumentPresenter.ViewMode.cleaned, .original, .markedUp] {
          let got = TranscriptDocumentPresenter.exportAvailability(
            turns: turns, fallback: fallback)
          // History's `exportText`: nothing without its fallback, else the turn export,
          // else the fallback itself.
          let delivered = fallback.map { base in
            TranscriptDocumentPresenter.exportText(
              turns: turns, rawText: Self.rawText, speakerNames: [:], timesOn: true, mode: mode)?
              .text ?? base
          }
          let expected: TranscriptDocumentPresenter.ExportAvailability =
            delivered == nil ? .none : (delivered!.isEmpty ? .empty : .content)
          #expect(
            got == expected,
            "turns \(String(describing: turns?.count)) fallback \(String(describing: fallback))")
        }
      }
    }
    #expect(TranscriptDocumentPresenter.exportAvailability(turns: one, fallback: nil) == .none)
  }

  private static func inputs(
    text: String = rawText, turns: [Turn]? = nil, names: [String: String] = ["A": "Ann"],
    language: String? = "en", isMeeting: Bool = false,
    mode: TranscriptDocumentPresenter.ViewMode = .cleaned,
    timesOn: Bool = true, finished: Bool = true,
    rowID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  ) -> TranscriptTurnsDocument.Inputs {
    TranscriptTurnsDocument.Inputs(
      rowID: rowID, text: text,
      turns: turns ?? [Self.turn("0-5", "A", 0..<5, processedText: "Hello!")],
      speakerNames: names, language: language, isMeeting: isMeeting, mode: mode,
      timesOn: timesOn, documentFinished: finished)
  }

  @Test("the turn document's inputs differ when any one input changes")
  @MainActor
  func turnDocumentInputsCoverEveryField() {
    let base = Self.inputs()
    #expect(base == Self.inputs())
    let changed: [TranscriptTurnsDocument.Inputs] = [
      Self.inputs(rowID: UUID()),
      Self.inputs(text: "hello there friends"),
      Self.inputs(turns: [Self.turn("0-5", "A", 0..<5, processedText: "Hello?")]),
      Self.inputs(turns: [Self.turn("0-5", "B", 0..<5, processedText: "Hello!")]),
      Self.inputs(turns: [Self.turn("0-4", "A", 0..<4, processedText: "Hello!")]),
      Self.inputs(turns: [Self.turn("0-5", "A", 0..<5, startMs: 5, processedText: "Hello!")]),
      Self.inputs(
        turns: [Self.turn("0-5", "A", 0..<5, processedText: "Hello!", wasPolished: false)]),
      Self.inputs(names: ["A": "Bea"]),
      Self.inputs(language: "de"),
      Self.inputs(isMeeting: true),
      Self.inputs(mode: .markedUp),
      Self.inputs(timesOn: false),
      Self.inputs(finished: false),
    ]
    for (i, other) in changed.enumerated() { #expect(base != other, "input \(i)") }
  }

  @Test("the turn document's inputs compare bytes, not canonically equal Strings")
  @MainActor
  func turnDocumentInputsCompareBytes() {
    let composed = "caf\u{00E9}"
    let decomposed = "cafe\u{0301}"
    #expect(composed == decomposed)  // Swift calls them equal; the bytes differ.
    #expect(Self.inputs(text: composed) != Self.inputs(text: decomposed))
    #expect(Self.inputs(names: ["A": composed]) != Self.inputs(names: ["A": decomposed]))
    #expect(
      Self.inputs(turns: [Self.turn("0-5", "A", 0..<5, processedText: composed)])
        != Self.inputs(turns: [Self.turn("0-5", "A", 0..<5, processedText: decomposed)]))
    #expect(
      Self.inputs(turns: [Self.turn("0-5", "A", 0..<5, processedText: nil)])
        != Self.inputs(turns: [Self.turn("0-5", "A", 0..<5, processedText: "")]))
  }

  @Test("the byte compare answers by bytes for empty, short, long, look-alike and bridged text")
  func sameBytesCompare() {
    let same: (String, String) -> Bool = MeetingDocumentHash.sameBytes
    #expect(same("", ""))
    #expect(!same("", "a"))
    #expect(!same("ab", "abc"))
    #expect(same("caf\u{00E9}", "caf\u{00E9}"))
    #expect(!same("caf\u{00E9}", "cafe\u{0301}"))
    let long = String(repeating: "word ", count: 20_000)
    #expect(same(long, String(repeating: "word ", count: 20_000)))
    #expect(!same(long, String(repeating: "word ", count: 19_999) + "worD "))
    // A string bridged from Objective-C may not be contiguous UTF-8.
    let bridged = NSString(string: "caf\u{00E9} and more") as String
    #expect(same(bridged, "caf\u{00E9} and more"))
    #expect(!same(bridged, "cafe\u{0301} and more"))
  }

  @Test("the Marked up diff key compares bytes, so a byte change never reuses older marks")
  @MainActor
  func diffKeyComparesBytes() {
    func key(_ cleaned: String, markedUp: Bool = true, language: String? = "en")
      -> TranscriptTurnsDocument.DiffKey
    {
      TranscriptTurnsDocument.DiffKey(
        input: FileImportCoordinator.TurnDiffInput(
          pairs: [.init(id: "0-5", original: "hello", cleaned: cleaned)], language: language),
        markedUp: markedUp)
    }
    #expect(key("hello caf\u{00E9}") == key("hello caf\u{00E9}"))
    #expect(key("hello caf\u{00E9}") != key("hello cafe\u{0301}"))
    // The shared input keeps Swift's own `==` for the wizard.
    #expect(key("hello caf\u{00E9}").input == key("hello cafe\u{0301}").input)
    #expect(key("x") != key("x", markedUp: false))
    #expect(key("x") != key("x", language: "de"))
  }
}
