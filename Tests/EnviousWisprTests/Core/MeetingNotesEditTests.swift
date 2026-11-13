import Foundation
import Testing

@testable import EnviousWisprCore

/// #3147 PR4 notes v2: when these fail, typing into meeting notes loses or duplicates text,
/// gives a note the wrong time beside the meeting, or turns one note into another's.
@Suite("Meeting notes block edits", .tags(.productOutcome))
struct MeetingNotesEditTests {
  private static func ids(_ n: Int) -> [UUID] { (0..<n).map { _ in UUID() } }

  /// A fixed source of new ids, in order.
  private final class IDs {
    var next: [UUID]
    init(_ ids: [UUID]) { next = ids }
    func take() -> UUID { next.removeFirst() }
  }

  @Test("typing into an empty block sets its time once; later typing never moves it")
  func firstCharacterSetsTime() throws {
    let block = MeetingNoteBlock(text: "")
    let doc = MeetingNotesDocument(blocks: [block])
    let typed = try #require(
      doc.applying(.replaceText(blockID: block.id, rangeUTF16: 0..<0, text: "B"), atMs: 5_000))
    #expect(typed.blocks[0].startedAtMs == 5_000)
    let more = try #require(
      typed.applying(.replaceText(blockID: block.id, rangeUTF16: 1..<1, text: "udget"), atMs: 9_000))
    #expect(more.blocks[0].text == "Budget")
    #expect(more.blocks[0].startedAtMs == 5_000)
    // Deleting every character keeps the time it was given.
    let cleared = try #require(
      more.applying(.replaceText(blockID: block.id, rangeUTF16: 0..<6, text: ""), atMs: 12_000))
    #expect(cleared.blocks[0].startedAtMs == 5_000)
  }

  @Test("a migrated block keeps no time when edited")
  func migratedStaysUntimed() throws {
    let doc = MeetingNotesDocument(legacyMarkdown: "Agenda")
    let id = doc.blocks[0].id
    let edited = try #require(
      doc.applying(.replaceText(blockID: id, rangeUTF16: 6..<6, text: "!"), atMs: 3_000))
    #expect(edited.blocks[0].text == "Agenda!")
    #expect(edited.blocks[0].startedAtMs == nil)
  }

  @Test("Return splits: moved text keeps its time, the empty new block gets one when typed")
  func splitKeepsTimes() throws {
    let a = MeetingNoteBlock(startedAtMs: 1_000, text: "oneTwo")
    let doc = MeetingNotesDocument(blocks: [a])
    let newID = UUID()
    let split = try #require(
      doc.applying(.split(blockID: a.id, offsetUTF16: 3, newBlockID: newID), atMs: 8_000))
    #expect(split.blocks.map(\.text) == ["one", "Two"])
    #expect(split.blocks.map(\.id) == [a.id, newID])
    #expect(split.blocks[1].startedAtMs == 1_000, "moving text does not invent a new time")

    let atEnd = try #require(
      doc.applying(.split(blockID: a.id, offsetUTF16: 6, newBlockID: newID), atMs: 8_000))
    #expect(atEnd.blocks[1].text.isEmpty && atEnd.blocks[1].startedAtMs == nil)
    let typed = try #require(
      atEnd.applying(.replaceText(blockID: newID, rangeUTF16: 0..<0, text: "x"), atMs: 9_000))
    #expect(typed.blocks[1].startedAtMs == 9_000)

    // A used id, an offset past the end, or inside an emoji's UTF-16 pair is refused.
    #expect(doc.applying(.split(blockID: a.id, offsetUTF16: 1, newBlockID: a.id), atMs: nil) == nil)
    #expect(doc.applying(.split(blockID: a.id, offsetUTF16: 7, newBlockID: newID), atMs: nil) == nil)
    let emoji = MeetingNotesDocument(blocks: [MeetingNoteBlock(text: "a\u{1F600}b")])
    #expect(
      emoji.applying(.split(blockID: emoji.blocks[0].id, offsetUTF16: 2, newBlockID: newID), atMs: nil)
        == nil)
    #expect(
      emoji.applying(.split(blockID: emoji.blocks[0].id, offsetUTF16: 3, newBlockID: newID), atMs: nil)?
        .blocks.map(\.text) == ["a\u{1F600}", "b"])
  }

  @Test("a split task continues as an unticked task")
  func splitTask() throws {
    let task = MeetingNoteBlock(startedAtMs: 1, kind: .task, done: true, text: "ab")
    let doc = MeetingNotesDocument(blocks: [task])
    let split = try #require(
      doc.applying(.split(blockID: task.id, offsetUTF16: 1, newBlockID: UUID()), atMs: nil))
    #expect(split.blocks[1].kind == .task && split.blocks[1].done == false)
  }

  @Test("Backspace at a block's start joins it to the previous block, which keeps id and time")
  func joinKeepsPrevious() throws {
    let a = MeetingNoteBlock(startedAtMs: 1_000, text: "one")
    let b = MeetingNoteBlock(startedAtMs: 2_000, kind: .task, text: "two")
    let doc = MeetingNotesDocument(blocks: [a, b])
    let joined = try #require(doc.applying(.joinWithPrevious(blockID: b.id), atMs: 9_000))
    #expect(joined.blocks.count == 1)
    #expect(joined.blocks[0].id == a.id && joined.blocks[0].startedAtMs == 1_000)
    #expect(joined.blocks[0].text == "onetwo" && joined.blocks[0].kind == .text)

    // An empty untimed previous block takes the joined text's time.
    let empty = MeetingNoteBlock(text: "")
    let intoEmpty = try #require(
      MeetingNotesDocument(blocks: [empty, b]).applying(.joinWithPrevious(blockID: b.id), atMs: nil))
    #expect(intoEmpty.blocks[0].id == empty.id && intoEmpty.blocks[0].startedAtMs == 2_000)

    // The first block has nothing to join: harmless, refused.
    #expect(doc.applying(.joinWithPrevious(blockID: a.id), atMs: nil) == nil)
  }

  @Test("a multiline paste becomes one block per line, the text after the caret last")
  func multilinePaste() throws {
    let a = MeetingNoteBlock(startedAtMs: 1_000, text: "headtail")
    let doc = MeetingNotesDocument(blocks: [a])
    let new = Self.ids(3)
    let source = IDs(new)
    let pasted = try #require(
      doc.applying(
        .replaceText(blockID: a.id, rangeUTF16: 4..<4, text: "X\r\nY\rZ\n"), atMs: 7_000,
        newID: source.take))
    #expect(pasted.blocks.map(\.text) == ["headX", "Y", "Z", "tail"])
    #expect(pasted.blocks.map(\.id) == [a.id] + new)
    #expect(pasted.blocks.map(\.startedAtMs) == [1_000, 7_000, 7_000, 1_000])
    #expect(pasted.markdown == "headX\nY\nZ\ntail")
  }

  @Test("kinds: a tick needs a task; leaving task clears the tick")
  func kinds() throws {
    let a = MeetingNoteBlock(text: "send deck")
    let doc = MeetingNotesDocument(blocks: [a])
    #expect(doc.applying(.setDone(blockID: a.id, done: true), atMs: nil) == nil)
    let task = try #require(doc.applying(.setKind(blockID: a.id, kind: .task), atMs: nil))
    let done = try #require(task.applying(.setDone(blockID: a.id, done: true), atMs: nil))
    #expect(done.markdown == "- [x] send deck")
    let text = try #require(done.applying(.setKind(blockID: a.id, kind: .text), atMs: nil))
    #expect(text.blocks[0].done == false && text.markdown == "send deck")
    #expect(doc.applying(.setKind(blockID: UUID(), kind: .task), atMs: nil) == nil)
  }

  @Test("replacing the whole Markdown keeps unchanged lines' blocks and changed lines' ids")
  func replacingMarkdown() {
    let a = MeetingNoteBlock(startedAtMs: 1, text: "a")
    let b = MeetingNoteBlock(startedAtMs: 2, kind: .task, text: "b")
    let c = MeetingNoteBlock(startedAtMs: 3, text: "c")
    let doc = MeetingNotesDocument(blocks: [a, b, c])
    #expect(doc.markdown == "a\n- [ ] b\nc")

    let ticked = doc.replacingMarkdown("a\n- [x] b!\nc", atMs: 50)
    #expect(ticked.blocks.map(\.id) == [a.id, b.id, c.id])
    #expect(ticked.blocks[1].kind == .task && ticked.blocks[1].done && ticked.blocks[1].text == "b!")
    #expect(ticked.blocks.map(\.startedAtMs) == [1, 2, 3])

    let unmarked = doc.replacingMarkdown("a\nb\nc", atMs: 50)
    #expect(unmarked.blocks[1].kind == .text && unmarked.blocks[1].id == b.id)

    let newID = UUID()
    let inserted = doc.replacingMarkdown("a\n- [ ] b\nnew\nc", atMs: 50, newID: { newID })
    #expect(inserted.blocks.map(\.id) == [a.id, b.id, newID, c.id])
    #expect(inserted.blocks[2].startedAtMs == 50)

    #expect(doc.replacingMarkdown("", atMs: nil).blocks.isEmpty)
  }

  @Test("legacy Markdown round-trips byte for byte, line endings included")
  func legacyRoundTrip() {
    for text in ["", "one", "one\n", "\n\n", "a\r\nb", "e\u{301}\n\u{1F600}", "- [ ] x\n> y"] {
      let doc = MeetingNotesDocument(legacyMarkdown: text)
      #expect(Array(doc.markdown.utf8) == Array(text.utf8), "\(text.debugDescription)")
      #expect(doc.blocks.allSatisfy { $0.kind == .text && $0.startedAtMs == nil })
    }
  }

  @Test("restore puts back an earlier draft exactly; another version or a repeated id is refused")
  func restore() throws {
    let a = MeetingNoteBlock(startedAtMs: 1, text: "a")
    let b = MeetingNoteBlock(startedAtMs: 2, kind: .task, done: true, text: "b")
    let earlier = MeetingNotesDocument(blocks: [a, b])
    let now = try #require(earlier.applying(.joinWithPrevious(blockID: b.id), atMs: 9))
    #expect(now.applying(.restore(earlier), atMs: 9) == earlier)
    #expect(now.applying(.restore(MeetingNotesDocument(version: 3, blocks: [a])), atMs: nil) == nil)
    #expect(now.applying(.restore(MeetingNotesDocument(blocks: [a, a])), atMs: nil) == nil)
  }
}

