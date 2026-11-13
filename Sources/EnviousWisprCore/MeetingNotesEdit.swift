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
}
