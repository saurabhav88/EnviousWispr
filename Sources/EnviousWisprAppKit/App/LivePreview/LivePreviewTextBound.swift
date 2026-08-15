import Foundation

/// The cap on how much preview text is kept alive, and the one implementation of
/// applying it (#1988).
///
/// **It lives at the PRODUCER, not the consumer.** The first version trimmed in the
/// coordinator, after the recognizer had already accumulated the whole transcript
/// and sent a full copy across an actor boundary on every update. The bound was
/// therefore true of what the pill displayed and false of what the process
/// retained, which is the worst kind of documented invariant: a 60-minute dictation
/// grew unboundedly under a comment promising it could not. Review caught it.
/// Trimming where the text is built fixes the allocation, the copy and the claim at
/// once.
enum LivePreviewTextBound {

  /// The pill shows a tail of at most two lines. The founder's longest dictation
  /// ran to 9,388 words, none of which a pill can show, so retaining more than a
  /// generous tail buys nothing and costs memory for the life of the recording.
  static let maxCharacters = 2000

  /// Keep the tail, drop the head, and do not cut a word in half.
  ///
  /// The word-boundary step must never be able to disable the bound: a script with
  /// no spaces (CJK) or a pathological unbroken run has no boundary to find, and
  /// the fallback returns the hard-trimmed tail rather than the original.
  static func apply(_ text: String) -> String {
    guard text.count > maxCharacters else { return text }
    let tail = String(text.suffix(maxCharacters))
    guard let space = tail.firstIndex(of: " ") else { return tail }
    return String(tail[tail.index(after: space)...])
  }
}
