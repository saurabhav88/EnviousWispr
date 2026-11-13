import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore

/// #3147 PR4 notes v2 block editor: when these fail, what the user types into the meeting notes
/// box is not what the saved notes hold (text lost, duplicated or moved to another note), or
/// Return and Backspace give notes the wrong id or time.
@Suite("Meeting notes editor text to block edits", .tags(.productOutcome))
struct MeetingNotesTextMappingTests {
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
}
