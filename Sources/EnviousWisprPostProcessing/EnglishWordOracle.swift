import Foundation

/// Whether a capitalised English word may be lowered where it sits.
///
/// A VALUE, not a service: the four closures are the only contact with the
/// operating system, so unit tests inject fixed answers and never touch a
/// system facility. `EnglishWordOracleRuntime` is the only thing that builds a
/// live one, which keeps `AppKit` and `NaturalLanguage` confined to that file.
///
/// Replaces `OrdinaryLowercaseLexicon`, a hand-authored 799-word allowlist that
/// could not contain the English language: `go`, `send`, `call`, `buy`, `email`
/// and `learn` were all absent, so ordinary continuations kept a wrong capital.
/// Issue #1803.
package struct EnglishWordOracle: Sendable {
  /// Why this oracle cannot decide, or `nil` when it can.
  package let unavailableReason: CursorInsertionRepair.CaseSkipReason?

  /// What the dictionary says about the lowercase form.
  ///
  /// Three-valued, not a Bool: the dictation that DISCOVERS an outage must
  /// report the outage, not a bland `.notOrdinaryWord`. Collapsing "the
  /// dictionary said no" and "the dictionary is gone" into `false` mislabels the
  /// one event worth seeing (local diff review r4).
  package enum DictionaryVerdict: Equatable, Sendable {
    case ordinary
    case notOrdinary
    case unavailable(CursorInsertionRepair.CaseSkipReason)
  }

  package let dictionaryVerdict: @Sendable (String) -> DictionaryVerdict

  /// Has the user taught this word to macOS?
  ///
  /// Learned words skew heavily toward names, brands and technical spellings,
  /// so a learned word is evidence AGAINST lowering, never for it. Measured:
  /// after `learnWord`, a nonsense string reports as correctly spelled, so
  /// without this check anything the user taught macOS would become "an
  /// ordinary English word" and be lowered.
  package let isLearnedWord: @Sendable (String) -> Bool

  /// Does the recogniser read the payload's first word as a NAME, judged
  /// against the text actually preceding the caret?
  ///
  /// This is the primary guard. Apple's model is trained on exactly the
  /// polyseme problem — "speak with Mark" reads as a personal name, "mark the
  /// page" does not — so it is asked with the real surrounding text, never a
  /// bare word.
  ///
  /// It does not catch everything. A name it has never seen falls through to
  /// the dictionary, which is why that second step exists.
  package let isRecognizedName: @Sendable (_ left: String, _ payload: String) -> Bool

  package var isAvailable: Bool { unavailableReason == nil }

  package static func unavailable(
    _ reason: CursorInsertionRepair.CaseSkipReason
  ) -> EnglishWordOracle {
    EnglishWordOracle(
      unavailableReason: reason,
      dictionaryVerdict: { _ in .unavailable(reason) },
      isLearnedWord: { _ in false },
      isRecognizedName: { _, _ in true })
  }


  /// The decision, in one place.
  ///
  /// Two steps, in this order, and the order is the whole design:
  ///
  /// 1. **Is it a name here?** The recogniser sees the real surrounding text, so
  ///    it can separate "speak with Mark" from "mark the page". A recognised
  ///    name keeps its capital and the dictionary is never consulted.
  /// 2. **Is it even English?** A word the dictionary knows is an ordinary word
  ///    and may be lowered. A word it does NOT know is an invented name —
  ///    `Ghostty`, `Vercel`, `Figma` — and keeps its capital.
  ///
  /// The dictionary is deliberately asked "is this English?", not "is this
  /// ordinary?". An earlier design asked the second question and then refused
  /// every noun to compensate, which needed a hand-maintained exception list and
  /// cost 21 points of coverage. Measured on 11,577 real continuations: 97.3%
  /// against 75.9%.
  ///
  /// Known limit: a brand that reuses an English word — `Bluetooth`, `Apple`,
  /// `Discord`, `Chrome` — is in the dictionary, so if the recogniser misses it
  /// in context it will be lowered. Custom Words is the per-user answer to that,
  /// and unlike a built-in list it scales past one person's vocabulary.
  ///
  /// Every refusal keeps the capital, which is exactly what the app did before
  /// this feature existed, so no failure here can damage text that was already
  /// correct.
  package func mayLower(
    word: String, left: String, payload: String
  ) -> CursorInsertionRepair.CaseSkipReason? {
    if let unavailableReason { return unavailableReason }
    let lower = word.lowercased()
    guard !isRecognizedName(left, payload) else { return .recognizedName }
    guard !isLearnedWord(lower) else { return .learnedWord }
    switch dictionaryVerdict(lower) {
    case .unavailable(let reason): return reason
    case .notOrdinary: return .notOrdinaryWord
    case .ordinary: break
    }
    return nil
  }
}
