import EnviousWisprCore
import Foundation

/// Decides what an EMPTY polish result MEANS (#2649, contract delta C1).
///
/// Two engines served by the bundled server disagree about empty output, and
/// the disagreement is real rather than a difference of opinion:
///
/// EG-1 is instructed to rewrite a transcript, so an empty answer is a local
/// server hiccup — `EGOneConnector.parseSuccess` records it as a crash and the
/// limb silently falls back. S1-mini's published card states the opposite for
/// its own model: "Filler-only or noise-only input correctly yields an empty
/// string, so treat an empty result as valid rather than as a failure."
/// Measured on the shipped binary in the same session: `um uh so like you know
/// um` returned `""` with `finish_reason: stop`.
///
/// **A blanket "empty is valid" would be the wrong fix and is the trap this
/// type exists to avoid.** #2634's whole signal was 161 `empty_response`
/// events from a user whose polish never worked. Declaring empty valid would
/// have hidden exactly that. So the disposition depends on the INPUT, not on
/// the output alone.
///
/// **The classifier is deliberately conservative, and the direction matters
/// more than the coverage.** A false `validEmpty` blinds the detector; a false
/// `unexpectedEmpty` costs one silent fallback the user already gets today. So
/// only NON-LEXICAL fillers count — `um`, `uh`, `er` and their kin, which are
/// not words in any other position. `like`, `so` and `you know` are excluded on
/// purpose: they are ordinary words, and a one-word `Right.` or `Okay.` is a
/// meaningful utterance whose empty polish IS a failure.
///
/// **The cost of that choice, stated rather than discovered later.** The
/// measured example `um uh so like you know um` — which really did return an
/// empty string from the shipped binary — classifies as `unexpectedEmpty`
/// here, because it contains `so`, `like`, `you` and `know`. That is a known
/// false negative: a genuinely correct empty gets recorded as a failure. It is
/// the direction to be wrong in, and the cost is one telemetry event on a take
/// the user was going to lose anyway. Widening the set to fix it would trade a
/// countable inaccuracy for a blind spot in the only signal that found #2634.
public enum LocalPolishEmptyDisposition: Sendable, Equatable {
  /// Empty was the correct answer to this input. No crash telemetry.
  case validEmpty
  /// Empty for input that had real words in it. Stays a failure.
  case unexpectedEmpty

  /// Non-lexical disfluencies only. Closed by construction: every member is a
  /// sound rather than a word, so none of them can carry meaning in a sentence.
  /// Adding a real word here is what would break the #2634 detector.
  static let nonLexicalFillers: Set<String> = [
    "um", "umm", "ummm", "uh", "uhh", "uhhh", "er", "err", "erm",
    "ah", "ahh", "eh", "hm", "hmm", "hmmm", "mm", "mmm", "mhm", "uhhuh",
  ]

  /// Classify an empty polish result against the input that produced it.
  ///
  /// Pure, with no knowledge of which engine ran: the caller supplies the
  /// engine's rule by choosing whether to consult this at all. EG-1 does not,
  /// so its behaviour is unchanged by this type existing.
  public static func classify(input: String) -> LocalPolishEmptyDisposition {
    var sawToken = false
    for rawToken in input.lowercased().split(whereSeparator: { $0.isWhitespace }) {
      // Strip punctuation from both ends so `um,` and `uh.` are still fillers,
      // while leaving inner characters alone: `mm-hmm` must not silently become
      // `mmhmm` and match something it should not.
      let token = rawToken.trimmingCharacters(
        in: CharacterSet.alphanumerics.inverted)
      if token.isEmpty { continue }
      sawToken = true
      if !nonLexicalFillers.contains(token) { return .unexpectedEmpty }
    }
    // Whitespace-or-punctuation-only input is NOT filler-only; it is nothing at
    // all, and an engine handed nothing had no work to do. Reporting that as a
    // valid empty would let a genuinely broken upstream stage look healthy.
    return sawToken ? .validEmpty : .unexpectedEmpty
  }
}
