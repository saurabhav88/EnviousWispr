import Foundation

/// One piece of a live transcript's finalized text with the written audio it came from
/// (#4355 plan §3.1).
///
/// `span` is nil when the engine gave no verified timing for exactly this text: a Universal
/// suffix cut from a segment, an engine that reports none, or audio the live pump kept without a
/// position. Nil means unresolved; it is never arrival time or "now", and attribution abstains
/// for it rather than guessing.
///
/// A finalized update is an ordered list of pieces. Its text is the pieces' texts concatenated
/// exactly (`text(of:)`); a separator added when two updates are joined belongs to the later
/// update's first piece, so the list and the joined text always agree.
package struct MeetingTimedPiece: Sendable, Equatable {
  package let text: String
  package let span: MeetingAudioSpan?

  package init(text: String, span: MeetingAudioSpan?) {
    self.text = text
    self.span = span
  }

  /// The finalized text of `pieces`: their texts, concatenated exactly.
  package static func text(of pieces: [MeetingTimedPiece]) -> String {
    pieces.map(\.text).joined()
  }

  /// One piece with unknown timing for `text`, or none for empty text.
  package static func untimed(_ text: String) -> [MeetingTimedPiece] {
    text.isEmpty ? [] : [MeetingTimedPiece(text: text, span: nil)]
  }
}
