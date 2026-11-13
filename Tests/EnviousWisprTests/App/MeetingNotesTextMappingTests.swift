import AppKit
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore

/// #3147 PR4 notes v2 block editor: when these fail, what the user types into the meeting notes
/// box is not what the saved notes hold (text lost, duplicated or moved to another note), or
/// Return and Backspace give notes the wrong id or time.
@MainActor
@Suite("Meeting notes editor text to block edits", .tags(.productOutcome))
struct MeetingNotesTextMappingTests {
  init() { _ = NSApplication.shared }
  private static let document = MeetingNotesDocument(blocks: [
    MeetingNoteBlock(startedAtMs: 1_000, text: "Budget"),
    MeetingNoteBlock(startedAtMs: 2_000, kind: .task, text: "send deck"),
    MeetingNoteBlock(text: "Caf\u{E9} \u{1F600}"),
    MeetingNoteBlock(startedAtMs: 4_000, text: ""),
  ])

  /// Applies `edits` in order, as the editor does, each over the previous result.
  private static func apply(_ edits: [MeetingNotesEdit], to document: MeetingNotesDocument)
    -> MeetingNotesDocument?
  {
    var current = document
    for edit in edits {
      guard let next = current.applying(edit, atMs: 9_000) else { return nil }
      current = next
    }
    return current
  }

  @Test("every change to the text gives blocks whose text is exactly the new text")
  func everyChangeMatchesTheText() throws {
    let text = MeetingNotesTextMapping.text(Self.document)
    #expect(text == "Budget\nsend deck\nCaf\u{E9} \u{1F600}\n")
    let scalarBounds =
      [0]
      + text.unicodeScalars.indices.dropFirst().map {
        text.utf16.distance(from: text.utf16.startIndex, to: $0)
      } + [text.utf16.count]
    var checked = 0
    for lower in scalarBounds {
      for upper in scalarBounds where upper >= lower {
        for replacement in ["", "x", "\n", "a\nb", "\u{1F600}"] {
          let ns = text as NSString
          let expected = ns.replacingCharacters(
            in: NSRange(location: lower, length: upper - lower), with: replacement)
          let edits = try #require(
            MeetingNotesTextMapping.edits(
              Self.document, range: lower..<upper, replacement: replacement))
          let result = try #require(
            Self.apply(edits, to: Self.document),
            "\(lower)..<\(upper) \(replacement.debugDescription)")
          #expect(
            MeetingNotesTextMapping.text(result) == expected,
            "\(lower)..<\(upper) \(replacement.debugDescription)")
          #expect(result.blocks.first?.id == Self.document.blocks.first?.id || lower == 0)
          checked += 1
        }
      }
    }
    #expect(checked > 500)
  }

  @Test("Backspace at a block's start is one join; Return at a caret is one split")
  func backspaceAndReturn() throws {
    let blocks = Self.document.blocks
    // The paragraph break before "send deck" is UTF-16 offset 6.
    let join = try #require(
      MeetingNotesTextMapping.edits(Self.document, range: 6..<7, replacement: ""))
    #expect(join == [.joinWithPrevious(blockID: blocks[1].id)])
    let newID = UUID()
    let split = try #require(
      MeetingNotesTextMapping.edits(
        Self.document, range: 3..<3, replacement: "\n", newID: { newID }))
    #expect(split == [.split(blockID: blocks[0].id, offsetUTF16: 3, newBlockID: newID)])
  }

  @Test("a selection across blocks keeps the first block's id and time")
  func acrossBlocks() throws {
    let edits = try #require(
      MeetingNotesTextMapping.edits(Self.document, range: 3..<12, replacement: "!"))
    let result = try #require(Self.apply(edits, to: Self.document))
    #expect(result.blocks.map(\.text) == ["Bud!deck", "Caf\u{E9} \u{1F600}", ""])
    #expect(result.blocks[0].id == Self.document.blocks[0].id)
    #expect(result.blocks[0].startedAtMs == 1_000)
  }

  @Test("the smallest change between two texts never splits a character's UTF-16 pair")
  func changeKeepsPairs() {
    let change = MeetingNotesTextMapping.change(from: "a\u{1F600}b", to: "a\u{1F601}b")
    #expect(change.range == 1..<3)
    #expect(change.replacement == "\u{1F601}")
    let none = MeetingNotesTextMapping.change(from: "same", to: "same")
    #expect(none.range == 4..<4 && none.replacement.isEmpty)
  }

  @Test("a range outside the text gives no edits")
  func outside() {
    let length = MeetingNotesTextMapping.text(Self.document).utf16.count
    #expect(
      MeetingNotesTextMapping.edits(Self.document, range: length..<(length + 1), replacement: "")
        == nil)
  }

  // MARK: - The text view, through the real documents owner

  /// A notes text view and its coordinator over a loaded meeting holding `document`.
  private static func editor(_ document: MeetingNotesDocument) async throws -> (
    NotesTextView, MeetingNotesTextView.Coordinator, MeetingDocumentsOwner, UUID, [Any]
  ) {
    let harness = try MeetingCoordinatorTests.Harness()
    let record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try harness.store.create(record)
    _ = try harness.store.saveNotes(document, revision: 1, meeting: record.id)
    let meetings = MeetingDocumentsOwnerTests.coordinator(harness)
    let documents = meetings.documents
    #expect(await documents.load(record.id))
    let textView = NotesTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let coordinator = MeetingNotesTextView.Coordinator()
    textView.delegate = coordinator
    textView.coordinator = coordinator
    coordinator.textView = textView
    coordinator.notes = documents
    coordinator.meetingID = record.id
    coordinator.currentMs = { 60_000 }
    coordinator.sync(documents.snapshot(for: record.id))
    // The harness and coordinator stay alive for the test: they own the store and its queue.
    return (textView, coordinator, documents, record.id, [harness, meetings])
  }

  @Test("Backspace joins in the draft; Undo brings the note back with its id, kind and time")
  func backspaceUndoRedo() async throws {
    let original = MeetingNotesDocument(blocks: [
      MeetingNoteBlock(startedAtMs: 1_000, text: "one"),
      MeetingNoteBlock(startedAtMs: 20_000, kind: .task, done: true, text: "two"),
    ])
    let (textView, coordinator, documents, id, keep) = try await Self.editor(original)
    defer { withExtendedLifetime(keep) {} }
    #expect(textView.string == "one\ntwo")
    textView.setSelectedRange(NSRange(location: 4, length: 0))
    textView.deleteBackward(nil)
    #expect(documents.snapshot(for: id).document.blocks.map(\.text) == ["onetwo"])
    #expect(documents.snapshot(for: id).document.blocks[0].id == original.blocks[0].id)

    coordinator.undo.undo()
    #expect(documents.snapshot(for: id).document == original)
    #expect(textView.string == "one\ntwo")
    coordinator.undo.redo()
    #expect(documents.snapshot(for: id).document.blocks.map(\.text) == ["onetwo"])
  }

  @Test("a pasted run of lines becomes blocks in one Undo step; typed text starts at the time")
  func pasteAndType() async throws {
    let original = MeetingNotesDocument(blocks: [MeetingNoteBlock(startedAtMs: 1_000, text: "ab")])
    let (textView, coordinator, documents, id, keep) = try await Self.editor(original)
    defer { withExtendedLifetime(keep) {} }
    textView.setSelectedRange(NSRange(location: 1, length: 0))
    textView.insertText("x\r\ny", replacementRange: NSRange(location: 1, length: 0))
    let pasted = documents.snapshot(for: id).document.blocks
    #expect(pasted.map(\.text) == ["ax", "yb"])
    #expect(pasted[0].id == original.blocks[0].id)
    #expect(pasted[1].startedAtMs == 60_000)
    #expect(textView.string == "ax\nyb")
    coordinator.undo.undo()
    #expect(documents.snapshot(for: id).document == original)
    #expect(textView.string == "ab")
    #expect(coordinator.undo.canUndo == false)
  }

  @Test("a paste after typing is its own Undo step; a Unicode-only change can be undone")
  func undoSteps() async throws {
    let original = MeetingNotesDocument(blocks: [MeetingNoteBlock(startedAtMs: 1, text: "Cafe\u{301}")])
    let (textView, coordinator, documents, id, keep) = try await Self.editor(original)
    defer { withExtendedLifetime(keep) {} }
    textView.insertText("!", replacementRange: NSRange(location: 5, length: 0))
    textView.insertText("?", replacementRange: NSRange(location: 6, length: 0))
    let typed = documents.snapshot(for: id).document
    textView.insertText("x\ny", replacementRange: NSRange(location: 7, length: 0))
    #expect(documents.snapshot(for: id).document.blocks.count == 2)
    coordinator.undo.undo()
    #expect(documents.snapshot(for: id).document == typed, "only the paste is undone")
    coordinator.undo.undo()
    #expect(documents.snapshot(for: id).document == original, "then the typing")

    textView.insertText("\u{E9}", replacementRange: NSRange(location: 3, length: 2))
    #expect(Array(documents.notes(id).utf8) == Array("Caf\u{E9}".utf8))
    coordinator.undo.undo()
    #expect(Array(documents.notes(id).utf8) == Array("Cafe\u{301}".utf8))
  }

  @Test("a change made elsewhere that the text does not show still clears the Undo history")
  func externalKindChangeClearsHistory() async throws {
    let original = MeetingNotesDocument(blocks: [MeetingNoteBlock(startedAtMs: 1, text: "a")])
    let (textView, coordinator, documents, id, keep) = try await Self.editor(original)
    defer { withExtendedLifetime(keep) {} }
    textView.insertText("b", replacementRange: NSRange(location: 1, length: 0))
    #expect(coordinator.undo.canUndo)
    let snapshot = documents.snapshot(for: id)
    #expect(
      documents.apply(
        .setKind(blockID: original.blocks[0].id, kind: .task), to: id,
        expectedRevision: snapshot.revision, atMs: nil))
    coordinator.sync(documents.snapshot(for: id))
    #expect(coordinator.undo.canUndo == false)
    #expect(documents.snapshot(for: id).document.blocks[0].kind == .task)
  }
}

