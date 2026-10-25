import EnviousWisprCore
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
    .update(finalized: finalized, inProgress: inProgress)
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
}
