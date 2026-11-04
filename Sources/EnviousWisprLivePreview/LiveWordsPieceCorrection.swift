import EnviousWisprCore
import Foundation

/// Custom Words correction of a finalized update's timed pieces (#4355; coverage rule: plan
/// §3.1 amendment "Live Custom Words correction ownership").
///
/// The visible result is always the whole update's text corrected as one string, byte for
/// byte, exactly as before pieces existed. Ownership is kept wherever it is certain:
/// - When correcting each piece on its own gives those same bytes, every piece keeps its span.
/// - Otherwise the changed stretch is the bytes between the longest unchanged opening and the
///   longest unchanged ending. Pieces wholly before or after it are untouched, span included.
///   The pieces it touches become one piece carrying their corrected text: with that piece's
///   span when exactly one piece is touched, with unknown timing when the stretch crosses a
///   piece boundary. Wrong attribution is impossible; only coverage is given up.
///
/// All offsets are UTF-8 bytes: a piece's bounds are its bytes' place in the concatenation,
/// which stays exact when characters combine across a piece boundary.
package enum LiveWordsPieceCorrection {
  package static func corrected(
    _ pieces: [MeetingTimedPiece], _ correct: (String) -> String
  ) -> [MeetingTimedPiece] {
    guard !pieces.isEmpty else { return [] }
    let original = MeetingTimedPiece.text(of: pieces)
    let whole = correct(original)
    let originalBytes = Array(original.utf8)
    let wholeBytes = Array(whole.utf8)
    if wholeBytes == originalBytes { return pieces }
    let each = pieces.map { MeetingTimedPiece(text: correct($0.text), span: $0.span) }
    if Array(MeetingTimedPiece.text(of: each).utf8) == wholeBytes { return each }
    return replacingChangedStretch(pieces, original: originalBytes, corrected: wholeBytes)
  }

  /// `pieces` with the stretch where `original` and `corrected` differ replaced, in bytes.
  private static func replacingChangedStretch(
    _ pieces: [MeetingTimedPiece], original: [UInt8], corrected: [UInt8]
  ) -> [MeetingTimedPiece] {
    let shorter = min(original.count, corrected.count)
    var head = 0
    while head < shorter, original[head] == corrected[head] { head += 1 }
    var tail = 0
    while tail < shorter - head,
      original[original.count - 1 - tail] == corrected[corrected.count - 1 - tail]
    {
      tail += 1
    }
    let changedEnd = original.count - tail  // the changed bytes are original[head..<changedEnd]

    var bounds: [(start: Int, end: Int)] = []
    var offset = 0
    for piece in pieces {
      let count = piece.text.utf8.count
      bounds.append((offset, offset + count))
      offset += count
    }
    // The pieces the stretch touches. An insertion (no original bytes changed) belongs to the
    // piece holding the byte before it, or the first piece at the very start.
    let first: Int
    let last: Int
    if head == changedEnd {
      let anchor = head == 0 ? 0 : head - 1
      first = bounds.firstIndex { $0.start <= anchor && anchor < $0.end } ?? 0
      last = first
    } else {
      first = bounds.firstIndex { $0.end > head } ?? 0
      last = max(first, bounds.lastIndex { $0.start < changedEnd } ?? (pieces.count - 1))
    }
    // The touched pieces' bytes run from bounds[first].start to bounds[last].end in the
    // original; in the corrected text the same stretch ends `tail` bytes earlier from the end.
    let start = bounds[first].start
    let correctedEnd = corrected.count - (original.count - bounds[last].end)
    let text = String(decoding: corrected[start..<correctedEnd], as: UTF8.self)
    let span = first == last ? pieces[first].span : nil
    var result = Array(pieces[..<first])
    if !text.isEmpty { result.append(MeetingTimedPiece(text: text, span: span)) }
    result.append(contentsOf: pieces[(last + 1)...])
    return result
  }
}
