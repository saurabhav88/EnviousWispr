import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLivePreview

/// #3973: EnviousMeet's live words, built per track from transcript events.
///
/// **What the user sees when this fails:** a meeting's live words repeat a sentence, lose words
/// that were already shown, mix the two speakers into one line, or show a sentence that was
/// still changing in the wrong place.
@Suite("Live words assembler (#3973)", .tags(.productOutcome))
struct LiveWordsAssemblerTests {

  private struct Shown: Equatable, CustomStringConvertible {
    let track: MeetingTrackKind
    let kind: LiveWordsAssembler.Line.Kind
    let text: String
    var description: String { "\(track.rawValue)/\(kind): \(text)" }
  }

  private static func shown(_ a: LiveWordsAssembler) -> [Shown] {
    a.lines.map { Shown(track: $0.track, kind: $0.kind, text: $0.text) }
  }

  private static func mic(_ kind: LiveWordsAssembler.Line.Kind, _ text: String) -> Shown {
    Shown(track: .microphone, kind: kind, text: text)
  }
  private static func call(_ kind: LiveWordsAssembler.Line.Kind, _ text: String) -> Shown {
    Shown(track: .callSound, kind: kind, text: text)
  }

  private static func update(_ finalized: String, _ inProgress: String) -> LiveWordsEvent {
    .update(finalized: MeetingTimedPiece.untimed(finalized), inProgress: inProgress)
  }

  @Test("finalized text is appended once and the words in progress are replaced")
  func appendAndReplace() {
    var a = LiveWordsAssembler()
    a.apply(Self.update("", " Hello wor"), track: .microphone, atMs: 1_000)
    a.apply(Self.update("", " Hello world how"), track: .microphone, atMs: 2_000)
    #expect(Self.shown(a) == [Self.mic(.provisional, "Hello world how")])
    a.apply(Self.update(" Hello world.", " How are"), track: .microphone, atMs: 3_000)
    #expect(Self.shown(a) == [Self.mic(.confirmed, "Hello world."), Self.mic(.provisional, "How are")])
    a.apply(Self.update(" How are you?", ""), track: .microphone, atMs: 4_000)
    #expect(Self.shown(a) == [Self.mic(.confirmed, "Hello world. How are you?")])
  }

  @Test("a repeated spoken word is kept every time it is finalized")
  func repeatedWordsAreWords() {
    var a = LiveWordsAssembler()
    a.apply(Self.update(" no", " no"), track: .microphone, atMs: 1_000)
    a.apply(Self.update(" no", " no"), track: .microphone, atMs: 2_000)
    a.apply(Self.update(" no.", ""), track: .microphone, atMs: 3_000)
    #expect(Self.shown(a) == [Self.mic(.confirmed, "no no no.")])
  }

  @Test("each track keeps its own lines, and a new turn starts a new line")
  func tracksAndTurns() {
    var a = LiveWordsAssembler()
    a.apply(Self.update(" Did you see it?", ""), track: .microphone, atMs: 1_000)
    a.apply(Self.update(" Yes, this morning.", ""), track: .callSound, atMs: 3_000)
    a.apply(Self.update(" Great.", ""), track: .microphone, atMs: 5_000)
    a.apply(Self.update(" It looked fine.", ""), track: .callSound, atMs: 6_000)
    #expect(
      Self.shown(a) == [
        Self.mic(.confirmed, "Did you see it?"), Self.call(.confirmed, "Yes, this morning."),
        Self.mic(.confirmed, "Great."), Self.call(.confirmed, "It looked fine."),
      ])
  }

  @Test("when the other speaker talks, words still in progress move to a new line and finish there")
  func provisionalAcrossATurn() {
    var a = LiveWordsAssembler()
    a.apply(Self.update(" We should", " ship on"), track: .microphone, atMs: 1_000)
    a.apply(Self.update(" Agreed.", ""), track: .callSound, atMs: 2_000)
    a.apply(Self.update("", " ship on Friday"), track: .microphone, atMs: 3_000)
    #expect(
      Self.shown(a) == [
        Self.mic(.confirmed, "We should"), Self.call(.confirmed, "Agreed."),
        Self.mic(.provisional, "ship on Friday"),
      ])
    a.apply(Self.update(" ship on Friday.", ""), track: .microphone, atMs: 4_000)
    a.apply(Self.update(" Then the demo.", ""), track: .microphone, atMs: 5_000)
    #expect(
      Self.shown(a) == [
        Self.mic(.confirmed, "We should"), Self.call(.confirmed, "Agreed."),
        Self.mic(.confirmed, "ship on Friday. Then the demo."),
      ],
      "the final version lands on the line that owned its words in progress")
  }

  @Test("a line past 400 characters closes even while words are still in progress")
  func sizeBoundary() {
    let exactly400 = " " + String(repeating: "a", count: 399)
    var atLimit = LiveWordsAssembler()
    atLimit.apply(Self.update(exactly400, ""), track: .microphone, atMs: 1_000)
    atLimit.apply(Self.update(" c", ""), track: .microphone, atMs: 2_000)
    #expect(Self.shown(atLimit).count == 1, "400 characters still accept more on the same line")

    var a = LiveWordsAssembler()
    a.apply(Self.update(exactly400, " tail"), track: .microphone, atMs: 1_000)
    // This update finalizes onto the 400-character line, taking it past the limit, while more
    // words are still in progress: those move to a new line.
    a.apply(Self.update(" b", " tail words"), track: .microphone, atMs: 2_000)
    #expect(Self.shown(a).last == Self.mic(.provisional, "tail words"))
    #expect(Self.shown(a).first?.text.hasSuffix("a b") == true, "confirmed text stays put")
    a.apply(Self.update(" tail words.", ""), track: .microphone, atMs: 3_000)
    a.apply(Self.update(" next", ""), track: .microphone, atMs: 4_000)
    #expect(Self.shown(a).count == 2)
    #expect(Self.shown(a).last == Self.mic(.confirmed, "tail words. next"))
  }

  @Test("after a long pause, words still in progress move to a new line")
  func provisionalAfterAPause() {
    var a = LiveWordsAssembler()
    a.apply(Self.update(" Hi", " there"), track: .microphone, atMs: 1_000)
    a.apply(Self.update(" there.", " and"), track: .microphone, atMs: 26_000)
    #expect(Self.shown(a) == [Self.mic(.confirmed, "Hi there."), Self.mic(.provisional, "and")])
    a.apply(Self.update(" and more.", ""), track: .microphone, atMs: 27_000)
    #expect(Self.shown(a) == [Self.mic(.confirmed, "Hi there."), Self.mic(.confirmed, "and more.")])
  }

  @Test("a pause of more than 20 seconds starts a new line; exactly 20 seconds does not")
  func pauseBoundary() {
    var a = LiveWordsAssembler()
    a.apply(Self.update(" One.", ""), track: .microphone, atMs: 1_000)
    a.apply(Self.update(" Two.", ""), track: .microphone, atMs: 21_000)
    #expect(Self.shown(a) == [Self.mic(.confirmed, "One. Two.")])
    a.apply(Self.update(" Three.", ""), track: .microphone, atMs: 41_001)
    #expect(Self.shown(a) == [Self.mic(.confirmed, "One. Two."), Self.mic(.confirmed, "Three.")])
  }

  @Test("a discontinuity keeps the words in progress as uncertain and clears them")
  func discontinuityFreezes() {
    var a = LiveWordsAssembler()
    a.apply(Self.update(" Budget is", " about forty"), track: .callSound, atMs: 1_000)
    a.apply(.discontinuity, track: .callSound, atMs: 2_000)
    #expect(
      Self.shown(a) == [Self.call(.confirmed, "Budget is"), Self.call(.uncertain, "about forty")])
    a.apply(Self.update("", ""), track: .callSound, atMs: 3_000)
    #expect(Self.shown(a).count == 2, "nothing in progress any more")
  }

  @Test("later words that overlap uncertain text are added, never merged into it")
  func overlapAfterUncertain() {
    var a = LiveWordsAssembler()
    a.apply(Self.update("", " about forty"), track: .callSound, atMs: 1_000)
    a.apply(.discontinuity, track: .callSound, atMs: 2_000)
    a.apply(Self.update(" forty thousand.", ""), track: .callSound, atMs: 3_000)
    #expect(
      Self.shown(a) == [
        Self.call(.uncertain, "about forty"), Self.call(.confirmed, "forty thousand."),
      ])
  }

  @Test("a session's end keeps its last words in progress as uncertain")
  func endFreezes() {
    var a = LiveWordsAssembler()
    a.apply(Self.update(" Thanks", " everyone for"), track: .microphone, atMs: 1_000)
    a.apply(.ended(.failed("service")), track: .microphone, atMs: 2_000)
    #expect(
      Self.shown(a) == [Self.mic(.confirmed, "Thanks"), Self.mic(.uncertain, "everyone for")])
  }

  @Test("pieces without their own spacing are joined with one space, unspaced scripts with none")
  func spacing() {
    var a = LiveWordsAssembler()
    a.apply(Self.update("Hello there.", ""), track: .microphone, atMs: 1_000)
    a.apply(Self.update("How are you?", ""), track: .microphone, atMs: 2_000)
    a.apply(Self.update("今日は", ""), track: .callSound, atMs: 3_000)
    a.apply(Self.update("いい天気です。", ""), track: .callSound, atMs: 4_000)
    #expect(
      Self.shown(a) == [
        Self.mic(.confirmed, "Hello there. How are you?"), Self.call(.confirmed, "今日はいい天気です。"),
      ])
  }

  @Test("line identities stay the same as text is added")
  func stableIdentity() {
    var a = LiveWordsAssembler()
    a.apply(Self.update(" One", ""), track: .microphone, atMs: 1_000)
    let first = a.lines.first?.id
    a.apply(Self.update(" two", ""), track: .microphone, atMs: 2_000)
    #expect(first != nil && a.lines.first?.id == first)
    #expect(a.lines.first?.startMs == 1_000 && a.lines.first?.endMs == 2_000)
  }

  // MARK: - Timed pieces (#4355)

  private static let recording = UUID()
  private static func timed(_ text: String, _ start: Int) -> MeetingTimedPiece {
    MeetingTimedPiece(
      text: text,
      span: MeetingAudioSpan(
        recording: recording, track: .callSound, run: 0, startSample: start, sampleCount: 160))
  }

  @Test("joining two updates keeps every piece and its span; the added space joins the later piece")
  func pieceJoinKeepsSpans() {
    let a = [Self.timed("Hello", 0)]
    let b = [Self.timed("there", 1_600), Self.timed(".", 3_200)]
    let joined = LiveWordsAssembler.join(a, b)
    #expect(MeetingTimedPiece.text(of: joined) == LiveWordsAssembler.join("Hello", "there."))
    #expect(joined.map(\.text) == ["Hello", " there", "."])
    #expect(joined.map(\.span) == [a[0].span, b[0].span, b[1].span], "no span merged or widened")
    #expect(LiveWordsAssembler.join(a, []) == a)
  }

  @Test("a line keeps its finalized pieces in order, untimed ones included, and has no speaker in PR A")
  func linesKeepPieces() {
    var a = LiveWordsAssembler()
    a.apply(.update(finalized: [Self.timed("One", 0)], inProgress: ""), track: .callSound, atMs: 0)
    a.apply(.update(finalized: MeetingTimedPiece.untimed("two"), inProgress: "thr"), track: .callSound, atMs: 1)
    let lines = a.lines
    #expect(lines.map(\.kind) == [.confirmed, .provisional])
    let confirmed = lines[0]
    #expect(confirmed.text == "One two")
    #expect(MeetingTimedPiece.text(of: confirmed.pieces) == "One two", "pieces agree with the text")
    #expect(confirmed.pieces.map(\.span) == [Self.timed("One", 0).span, nil])
    #expect(lines[1].pieces == MeetingTimedPiece.untimed("thr"), "provisional words carry no timing")
    #expect(lines.allSatisfy { $0.speakerKey == nil })
  }

  @Test("correction inside one piece keeps every span, even when it changes the length")
  func correctionKeepsOwnership() {
    let pieces = [Self.timed(" teh", 0), Self.timed(" cat", 160)]
    let fixed = LiveWordsPieceCorrection.corrected(pieces) {
      $0.replacingOccurrences(of: "teh", with: "the very")
    }
    #expect(fixed.map(\.text) == [" the very", " cat"])
    #expect(fixed.map(\.span) == pieces.map(\.span))
  }

  @Test("a correction across a piece boundary shows the corrected words and gives up their timing")
  func correctionAcrossBoundaryUntimed() {
    let pieces = [Self.timed(" new", 0), Self.timed(" york", 160)]
    let fixed = LiveWordsPieceCorrection.corrected(pieces) {
      $0.replacingOccurrences(of: "new york", with: "New York")
    }
    #expect(MeetingTimedPiece.text(of: fixed) == " New York", "the visible text as a whole correction")
    #expect(fixed == MeetingTimedPiece.untimed(" New York"), "never credited to one piece's audio")
  }

  @Test("a correction across a boundary leaves the pieces around it, spans included, untouched")
  func correctionKeepsUnaffectedPieces() {
    let pieces = [
      Self.timed("I flew", 0), Self.timed(" to new", 160), Self.timed(" york", 320),
      MeetingTimedPiece(text: " today.", span: nil), Self.timed(" Then home.", 480),
    ]
    let fixed = LiveWordsPieceCorrection.corrected(pieces) {
      $0.replacingOccurrences(of: "new york", with: "New York")
    }
    #expect(MeetingTimedPiece.text(of: fixed) == "I flew to New York today. Then home.")
    #expect(fixed.map(\.text) == ["I flew", " to New York", " today.", " Then home."])
    #expect(fixed.map(\.span) == [pieces[0].span, nil, nil, pieces[4].span])
  }

  @Test("an insertion or deletion inside one piece keeps that piece's span")
  func insertionAndDeletionKeepSpan() {
    let pieces = [Self.timed("Hello", 0), Self.timed(" wrld", 160), Self.timed(" again", 320)]
    // Context-dependent rule: only the whole text sees "Hello wrld", so per-piece correction differs.
    let inserted = LiveWordsPieceCorrection.corrected(pieces) {
      $0.replacingOccurrences(of: "Hello wrld", with: "Hello world")
    }
    #expect(MeetingTimedPiece.text(of: inserted) == "Hello world again")
    #expect(inserted.map(\.span) == pieces.map(\.span), "the change sits inside one piece")
    let deleted = LiveWordsPieceCorrection.corrected(pieces) {
      $0.replacingOccurrences(of: "Hello wrld again", with: "Hello wrl again")
    }
    #expect(MeetingTimedPiece.text(of: deleted) == "Hello wrl again")
    #expect(deleted.map(\.span) == pieces.map(\.span))
  }

  @Test("two separated cross-boundary corrections give up timing from the first through the last touched piece, as the plan's coverage rule says")
  func separatedCorrectionsCoverageRule() {
    let pieces = [
      Self.timed("I like new", 0), Self.timed(" york", 160), Self.timed(" and the beach in", 320),
      Self.timed(" los", 480), Self.timed(" angeles.", 640),
    ]
    let fixed = LiveWordsPieceCorrection.corrected(pieces) {
      $0.replacingOccurrences(of: "new york", with: "New York")
        .replacingOccurrences(of: "los angeles", with: "Los Angeles")
    }
    #expect(MeetingTimedPiece.text(of: fixed) == "I like New York and the beach in Los Angeles.")
    #expect(fixed.count == 1 && fixed.first?.span == nil, "every piece is touched: no timing guessed")
  }

  @Test("piece bounds are bytes: a character combining across a piece boundary never breaks the mapping")
  func combiningMarkAcrossBoundary() {
    let pieces = [Self.timed("Cafe", 0), Self.timed("\u{0301} cat", 160), Self.timed(" again", 320)]
    let fixed = LiveWordsPieceCorrection.corrected(pieces) {
      $0.replacingOccurrences(of: "Cafe\u{0301} cat", with: "Cafe\u{0301} dog")
    }
    #expect(Array(MeetingTimedPiece.text(of: fixed).utf8) == Array("Cafe\u{0301} dog again".utf8))
    #expect(fixed.map(\.span) == pieces.map(\.span), "the change sits inside the second piece")
  }

  @Test("a correction to a canonically equal but different spelling is applied byte for byte")
  func canonicalSpellingIsBytes() {
    let decomposed = "Cafe\u{0301}"
    let composed = "Caf\u{00E9}"
    let pieces = [Self.timed(decomposed, 0)]
    let fixed = LiveWordsPieceCorrection.corrected(pieces) { $0 == decomposed ? composed : $0 }
    #expect(Array(MeetingTimedPiece.text(of: fixed).utf8) == Array(composed.utf8))
    #expect(fixed.first?.span == pieces[0].span)
  }

  @Test("queues charge every piece, so many tiny timed pieces cannot slip under a text budget")
  func pieceCharge() {
    let tiny = (0..<1_000).map { Self.timed("a", $0 * 160) }
    #expect(LiveWordsAssembler.charge(of: tiny) == 1_000 * (LiveWordsAssembler.pieceCharge + 1))
    #expect(LiveWordsAssembler.charge(of: []) == 0)
  }
}
