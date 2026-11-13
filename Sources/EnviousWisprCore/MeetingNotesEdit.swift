import Foundation

/// #3147 PR4: one edit to a meeting's notes document. Ranges and offsets count UTF-16 units, the
/// unit the native text editor reports.
public enum MeetingNotesEdit: Equatable, Sendable {
  case replaceText(blockID: UUID, rangeUTF16: Range<Int>, text: String)
  /// Return inside a block: the text after `offsetUTF16` moves to a new block.
  case split(blockID: UUID, offsetUTF16: Int, newBlockID: UUID)
  /// Backspace at a block's start: joins it to the previous block, which keeps its id and time.
  case joinWithPrevious(blockID: UUID)
  case setKind(blockID: UUID, kind: MeetingNoteBlock.Kind)
  case setDone(blockID: UUID, done: Bool)
  /// Undo and Redo: the whole draft as it was before (or after) an edit, ids, kinds and times
  /// included. Refused when its version is not the current one or two blocks share an id.
  case restore(MeetingNotesDocument)
}

extension MeetingNotesDocument {
  /// The document after `edit`, or nil when the edit does not apply: an unknown block, a
  /// range outside the block's text or inside a character's UTF-16 pair, a new id already in
  /// use, a join of the first block, a tick on a block that is not a task, or a restore of a
  /// document of another version or with a repeated id.
  ///
  /// Text with line breaks (a paste) becomes blocks: the first line joins the edited block, each
  /// further line starts a new text block. A block's time is set when its first character is
  /// typed (`atMs`); text moved to another block keeps the time it had, and no time changes
  /// after it is set.
  public func applying(
    _ edit: MeetingNotesEdit, atMs: Int?, newID: () -> UUID = { UUID() }
  ) -> MeetingNotesDocument? {
    var next = self
    switch edit {
    case .replaceText(let blockID, let range, let text):
      guard let index = blocks.firstIndex(where: { $0.id == blockID }),
        let (before, after) = Self.cut(blocks[index].text, range)
      else { return nil }
      let original = blocks[index]
      let pieces = Self.pastedLines(text)
      var edited = original
      edited.text = before + pieces[0]
      var added: [MeetingNoteBlock] = []
      if pieces.count == 1 {
        edited.text += after
      } else {
        for piece in pieces.dropFirst().dropLast() {
          added.append(
            MeetingNoteBlock(id: newID(), startedAtMs: piece.isEmpty ? nil : atMs, text: piece))
        }
        let last = pieces[pieces.count - 1]
        let lastTime: Int? = !last.isEmpty ? atMs : (after.isEmpty ? nil : original.startedAtMs)
        added.append(MeetingNoteBlock(id: newID(), startedAtMs: lastTime, text: last + after))
      }
      next.blocks[index] = edited.typed(after: original, atMs: atMs)
      next.blocks.insert(contentsOf: added, at: index + 1)

    case .split(let blockID, let offset, let newBlockID):
      guard let index = blocks.firstIndex(where: { $0.id == blockID }),
        !blocks.contains(where: { $0.id == newBlockID }),
        let (before, after) = Self.cut(blocks[index].text, offset..<offset)
      else { return nil }
      let original = blocks[index]
      next.blocks[index].text = before
      // The text after the caret moves with its own time; an empty new block gets one when typed.
      // A task continues as a task (unticked), as list editors do; other kinds start as text.
      next.blocks.insert(
        MeetingNoteBlock(
          id: newBlockID, startedAtMs: after.isEmpty ? nil : original.startedAtMs,
          kind: original.kind == .task ? .task : .text, text: after),
        at: index + 1)

    case .joinWithPrevious(let blockID):
      guard let index = blocks.firstIndex(where: { $0.id == blockID }), index > 0 else {
        return nil
      }
      let joined = blocks[index]
      var previous = blocks[index - 1]
      if previous.startedAtMs == nil, previous.text.isEmpty {
        // The joined block's text is the previous block's first text: it keeps its time.
        previous.startedAtMs = joined.startedAtMs
      }
      previous.text += joined.text
      next.blocks[index - 1] = previous
      next.blocks.remove(at: index)

    case .setKind(let blockID, let kind):
      guard let index = blocks.firstIndex(where: { $0.id == blockID }) else { return nil }
      next.blocks[index].kind = kind
      if kind != .task { next.blocks[index].done = false }

    case .setDone(let blockID, let done):
      guard let index = blocks.firstIndex(where: { $0.id == blockID }),
        blocks[index].kind == .task
      else { return nil }
      next.blocks[index].done = done

    case .restore(let document):
      guard document.version == MeetingNotesDocument.currentVersion,
        Set(document.blocks.map(\.id)).count == document.blocks.count
      else { return nil }
      next = document
    }
    return next
  }

  /// The text before and after `range` (UTF-16 offsets), or nil when the range is outside the
  /// text or a bound falls inside a character's UTF-16 pair.
  static func cut(_ text: String, _ range: Range<Int>) -> (String, String)? {
    let utf16 = text.utf16
    guard range.lowerBound >= 0, range.upperBound <= utf16.count,
      let lower = utf16.index(utf16.startIndex, offsetBy: range.lowerBound, limitedBy: utf16.endIndex)
        .flatMap({ $0.samePosition(in: text.unicodeScalars) }),
      let upper = utf16.index(utf16.startIndex, offsetBy: range.upperBound, limitedBy: utf16.endIndex)
        .flatMap({ $0.samePosition(in: text.unicodeScalars) })
    else { return nil }
    return (String(text.unicodeScalars[..<lower]), String(text.unicodeScalars[upper...]))
  }

  /// Inserted text as lines: every line break form (CR LF, CR, LF) ends a line. Never empty.
  static func pastedLines(_ text: String) -> [String] {
    let unified = text.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    return unified.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
      .map { String(String.UnicodeScalarView($0)) }
  }
}
