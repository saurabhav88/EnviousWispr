import Foundation

/// Lexical-content classification for the #1358 raw-ASR recovery floor.
///
/// When the limb chain empties the transcript, `KernelFinalizationWiring`'s
/// `processText` uses this to decide whether the raw ASR still holds a real
/// word worth delivering (a step over-deleted lexical content) versus a bare
/// filler / non-speech artifact that must end quietly as no-speech.
///
/// It delegates to the ONE filler transform (`FillerRemovalStep.removingFillers`)
/// so there is never a second filler algorithm. It ALWAYS strips fillers
/// regardless of the `fillerRemovalEnabled` setting — the raw floor is a
/// defensive recovery for erased real content, and pasting a bare filler as a
/// recovery floor is never desired (founder directive 2026-07-11).
public enum TextLexicalContent {
  /// `true` iff removing fillers from `text` leaves at least one alphanumeric
  /// scalar (a letter or digit). "uh" → false; "OK" / "1988" / "I" → true;
  /// "..." → false; "uh OK" → true.
  @MainActor
  public static func hasLexicalContentAfterRemovingFillers(_ text: String) -> Bool {
    let stripped = FillerRemovalStep.removingFillers(from: text)
    return stripped.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
  }
}
