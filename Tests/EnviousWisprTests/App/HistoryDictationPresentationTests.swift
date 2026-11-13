import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprStorage

/// #3147 §3.4: the History dictation card's decisions. What fails when these fail is a person
/// shown an edit the cleanup never made, a struck word glued to its neighbour, a time button
/// that plays the wrong passage, or a stale comparison drawn over newer text.
@Suite("History dictation card presentation (#3147)", .tags(.productOutcome))
struct HistoryDictationPresentationTests {

  typealias P = HistoryDictationPresentation

  private static func texts(_ original: String, _ polished: String) -> P.Texts {
    P.Texts(original: original, polished: polished, language: nil)
  }

  private static func rendered(_ runs: [P.MarkRun]) -> String {
    runs.map(\.text).joined()
  }

  // MARK: - Views and preference

  @Test("each view shows its own words; the saved preference picks the opening view")
  func viewsAndPreference() {
    let t = Self.texts("so um the numbers are up", "So the numbers are up.")
    #expect(P.plainText(t, view: .polished) == "So the numbers are up.")
    #expect(P.plainText(t, view: .original) == "so um the numbers are up")
    #expect(P.defaultView(for: .polished) == .polished)
    #expect(P.defaultView(for: .original) == .original)
    #expect(P.editsView == .markedUp)
  }

  @Test("the texts come from the row: original is the stored text, polished is what History shows")
  func textsFromRow() {
    let polished = Transcript(
      text: "so um yes", polishedText: "So, yes.", language: "en", duration: 1,
      processingTime: 0.1, backendType: .parakeet)
    #expect(P.Texts(polished).original == "so um yes")
    #expect(P.Texts(polished).polished == "So, yes.")
    #expect(P.Texts(polished).differ)
    // A row with no polish compares its text with itself: nothing to show.
    let plain = Transcript(
      text: "hello there", language: nil, duration: 1, processingTime: 0.1,
      backendType: .parakeet)
    #expect(P.Texts(plain).differ == false)
    #expect(P.prepare(P.Texts(plain)).hasChanges == false)
  }

  // MARK: - Marked up

  @Test("Marked up reads removed words struck before the polished words, with real spaces")
  func markedUpReads() {
    let t = Self.texts("so um the numbers are up", "So the numbers are up.")
    let p = P.prepare(t)
    #expect(p.hasChanges)
    #expect(Self.rendered(p.markedUp) == "so um So the numbers are up up.")
    let removed = p.markedUp.filter { $0.kind == .removed }.map(\.text)
    let added = p.markedUp.filter { $0.kind == .added }.map(\.text)
    #expect(removed == ["so um", "up"])
    #expect(added == ["So", "up."])
    // Both halves of a change name the same change, so either opens the inspector for it.
    let first = p.markedUp.filter { $0.change == 0 }.map(\.kind)
    #expect(first == [.removed, .added])
  }

  @Test("a removal at the start or end never glues to its neighbour")
  func removalSpacing() {
    #expect(Self.rendered(P.prepare(Self.texts("um so", "so")).markedUp) == "um so")
    #expect(Self.rendered(P.prepare(Self.texts("it um", "it")).markedUp) == "it um")
    #expect(Self.rendered(P.prepare(Self.texts("a um b", "a b")).markedUp) == "a um b")
  }

  @Test("an insertion shows only the added words; kept text is the polished text verbatim")
  func insertionOnly() {
    let p = P.prepare(
      Self.texts("call the doctor tomorrow", "call the doctor tomorrow morning"))
    #expect(Self.rendered(p.markedUp) == "call the doctor tomorrow morning")
    #expect(p.markedUp.map(\.kind) == [.same, .same, .added])
    #expect(p.markedUp.last?.text == "morning")
  }

  @Test("repeated words and Unicode keep the right characters in Marked up")
  func repeatedAndUnicode() {
    let p = P.prepare(Self.texts("I I want 👋🏽 café", "I want 👋🏽 Café."))
    let removed = p.markedUp.filter { $0.kind == .removed }.map(\.text)
    #expect(removed == ["I", "café"])
    #expect(p.markedUp.filter { $0.kind == .added }.map(\.text) == ["Café."])
    #expect(Self.rendered(p.markedUp).contains("👋🏽"))
  }

  // MARK: - Stale results

  @Test("a comparison is shown only for the texts it was computed from")
  func staleResultsAreDropped() {
    let before = Self.texts("so um yes", "So, yes.")
    let after = Self.texts("so um yes", "So yes.")
    let result = P.prepare(before)
    #expect(P.accepts(result, current: before))
    #expect(P.accepts(result, current: after) == false)
    #expect(P.accepts(result, current: nil) == false)
    // Two Unicode spellings of one word are different content: the old result is stale.
    let composed = Self.texts("caf\u{00E9}", "caf\u{00E9}")
    let decomposed = Self.texts("caf\u{00E9}", "cafe\u{0301}")
    #expect(P.accepts(P.prepare(composed), current: decomposed) == false)
  }

  // MARK: - Paragraphs

  @Test("paragraphs are the non-empty lines, with their UTF-16 ranges")
  func paragraphs() {
    let text = "First line.\n\n- item 👋🏽\n  \nLast"
    let blocks = P.paragraphs(of: text)
    #expect(blocks.map(\.text) == ["First line.", "- item 👋🏽", "Last"])
    for block in blocks {
      #expect(P.slice(text, block.range) == block.text)
    }
  }

  @Test("Marked up paragraphs split runs at line breaks and keep original offsets right")
  func markedUpParagraphs() throws {
    let original = "first um line\r\nsecond line"
    let p = P.prepare(Self.texts(original, "First line\r\nsecond line"))
    let blocks = P.markedUpParagraphs(p.markedUp)
    #expect(blocks.count == 2)
    #expect(Self.rendered(blocks[1]) == "second line")
    // Every original offset still points at its own words after the two-unit line break.
    for run in blocks.joined() where run.originalOffset != nil {
      let offset = try #require(run.originalOffset)
      #expect(P.slice(original, offset..<(offset + run.text.utf16.count)) == run.text)
    }
  }

  // MARK: - Recording times

  private static func timing(exact: String, anchors: [(Int, Int, Double)]) -> RecordingTiming {
    RecordingTiming(
      exactASRText: exact, textVersion: P.exactASRVersionPrefix + P.sha256Hex(exact),
      anchors: anchors.map {
        RecordingTiming.Anchor(
          utf16Start: $0.0, utf16End: $0.1, startSeconds: $0.2, endSeconds: $0.2 + 1)
      })
  }

  @Test("passage times carry from the speech-engine text onto the original, then the polished text")
  func timesProject() {
    // The processing changed "twenty" to "20" in the first sentence only.
    let exact = "we have twenty items. then we ship."
    let original = "we have 20 items. then we ship."
    let t = Self.timing(exact: exact, anchors: [(0, 21, 0.0), (22, 35, 4.5)])
    let spans = P.timeline(t, original: original)
    // The first passage starts on "we" (unchanged) and ends on "items." (unchanged): kept.
    #expect(spans.map(\.seconds) == [0.0, 4.5])
    #expect(P.slice(original, spans[1].range) == "then we ship.")
    // Onto polished text that capitalised both first words: neither passage start is literal.
    let polished = "We have 20 items. Then we ship it."
    let alignment = WordDiff.alignment(original: original, cleaned: polished)
    let onPolished = P.polishedTimeline(spans, alignment: alignment)
    #expect(onPolished.isEmpty)
    // A polish that leaves both ends of a passage alone keeps its time.
    let kind = "we have 20 good items. then we ship."
    let kept = P.polishedTimeline(
      spans, alignment: WordDiff.alignment(original: original, cleaned: kind))
    #expect(kept.map(\.seconds) == [0.0, 4.5])
  }

  @Test("anchors for another text version, out of range or unplaceable stay untimed")
  func untrustedAnchorsAreDropped() {
    let exact = "hello world"
    var t = Self.timing(exact: exact, anchors: [(0, 11, 1.0)])
    #expect(P.timeline(t, original: exact).count == 1)
    t = RecordingTiming(exactASRText: exact, textVersion: "asr-sha256:deadbeef", anchors: t.anchors)
    #expect(P.timeline(t, original: exact).isEmpty)
    #expect(P.timeline(Self.timing(exact: exact, anchors: [(5, 40, 1.0)]), original: exact).isEmpty)
    #expect(P.timeline(Self.timing(exact: exact, anchors: [(3, 3, 1.0)]), original: exact).isEmpty)
    #expect(P.timeline(Self.timing(exact: exact, anchors: [(0, 5, -1)]), original: exact).isEmpty)
    // The anchor's first word was rewritten by processing: never guessed from a neighbour.
    #expect(
      P.timeline(Self.timing(exact: exact, anchors: [(0, 11, 1.0)]), original: "Hello world")
        .isEmpty)
    #expect(P.timeline(nil, original: exact).isEmpty)
    #expect(
      P.timeline(RecordingTiming(exactASRText: nil, textVersion: "x", anchors: []), original: exact)
        .isEmpty)
  }

  @Test("a block's time is the first passage starting inside it")
  func blockTimes() {
    let spans = [P.TimedSpan(range: 0..<10, seconds: 0), P.TimedSpan(range: 12..<20, seconds: 3)]
    #expect(P.time(of: 0..<11, in: spans) == 0)
    #expect(P.time(of: 11..<20, in: spans) == 3)
    #expect(P.time(of: 21..<30, in: spans) == nil)
    let block = [P.MarkRun(kind: .same, text: "abc", change: nil, originalOffset: 12)]
    #expect(P.time(ofMarkedUp: block, in: spans) == 3)
    let addedOnly = [P.MarkRun(kind: .added, text: "abc", change: 0, originalOffset: nil)]
    #expect(P.time(ofMarkedUp: addedOnly, in: spans) == nil)
  }

  // MARK: - Inspector

  @Test("the inspector shows both sides of a change and hears only changes with original words")
  func inspectorDetail() throws {
    let original = "we gonna ship it"
    let p = P.prepare(Self.texts(original, "we are going to ship it today"))
    let spans = [P.TimedSpan(range: 0..<16, seconds: 2)]
    let replace = try #require(P.detail(of: 0, in: p, timeline: spans))
    #expect(replace == .init(original: "gonna", polished: "are going to", seconds: 2))
    let insert = try #require(P.detail(of: 1, in: p, timeline: spans))
    #expect(insert == .init(original: "", polished: "today", seconds: nil))
    #expect(P.detail(of: 9, in: p, timeline: spans) == nil)
  }

  // MARK: - Footer

  @Test("the recording's end date follows the keep period, unless kept or kept forever")
  func expiry() {
    let saved = Date(timeIntervalSince1970: 1_000_000)
    #expect(
      P.recordingExpiry(savedAt: saved, keepDays: 7, pinned: false)
        == saved.addingTimeInterval(7 * 86_400))
    #expect(P.recordingExpiry(savedAt: saved, keepDays: 7, pinned: true) == nil)
    #expect(P.recordingExpiry(savedAt: saved, keepDays: nil, pinned: false) == nil)
    #expect(P.clock(65.9) == "1:05")
    #expect(P.clock(-1) == "0:00")
  }
}
