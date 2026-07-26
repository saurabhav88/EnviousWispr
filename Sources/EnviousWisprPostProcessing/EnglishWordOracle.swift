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
struct EnglishWordOracle: Sendable {
  /// Why this oracle cannot decide, or `nil` when it can.
  let unavailableReason: CursorInsertionRepair.CaseSkipReason?

  /// Is the LOWERCASE form an ordinary English word?
  let isOrdinaryWord: @Sendable (String) -> Bool

  /// Has the user taught this word to macOS?
  ///
  /// Learned words skew heavily toward names, brands and technical spellings,
  /// so a learned word is evidence AGAINST lowering, never for it. Measured:
  /// after `learnWord`, a nonsense string reports as correctly spelled, so
  /// without this check anything the user taught macOS would become "an
  /// ordinary English word" and be lowered.
  let isLearnedWord: @Sendable (String) -> Bool

  /// Is the payload's first word behaving as something other than a noun,
  /// judged against the text actually preceding the caret?
  ///
  /// A conservative safety FILTER rather than a name recogniser: a proper name
  /// is always a noun, so refusing nouns blocks most name readings — but the
  /// converse does not hold, and this also refuses ordinary noun-led
  /// continuations. `pay the Bill` and `call Bill` produce identical tags and
  /// opposite correct answers; both keep the capital.
  let wordClassIsSafe: @Sendable (_ left: String, _ payload: String) -> Bool

  var isAvailable: Bool { unavailableReason == nil }

  static func unavailable(
    _ reason: CursorInsertionRepair.CaseSkipReason
  ) -> EnglishWordOracle {
    EnglishWordOracle(
      unavailableReason: reason,
      isOrdinaryWord: { _ in false },
      isLearnedWord: { _ in false },
      wordClassIsSafe: { _, _ in false })
  }

  /// Words the tagger classifies as nouns despite ordinary continuation use.
  ///
  /// Twelve entries, each earning its place in a measured ablation over 11,577
  /// real continuation rows: they buy 79 additional correct lowerings and zero
  /// additional errors. Three further candidates (`nobody`, `somebody`, `none`)
  /// contributed nothing in two independent runs and were cut.
  ///
  /// This is NOT presented as the complete grammatical class of English
  /// indefinite pronouns or deictic time words — those classes have other
  /// members. It is a frozen compatibility list, and it is deliberately the
  /// only hand-maintained word data that survives. Growing it requires a
  /// re-measurement, never a reflex: a set that grows to rescue individual
  /// misses has become the word list this change exists to delete.
  static let compatibilityExceptions: Set<String> = [
    "everything", "something", "nothing", "anything",
    "everyone", "someone", "anyone", "everybody",
    "yesterday", "today", "tomorrow", "tonight",
  ]

  /// The decision, in one place.
  ///
  /// Every refusal keeps the capital, which is exactly what the app did before
  /// this feature existed, so no failure here can damage text that was already
  /// correct.
  func mayLower(
    word: String, left: String, payload: String
  ) -> CursorInsertionRepair.CaseSkipReason? {
    if let unavailableReason { return unavailableReason }
    let lower = word.lowercased()
    guard !isLearnedWord(lower) else { return .learnedWord }
    guard isOrdinaryWord(lower) else { return .notOrdinaryWord }
    if Self.compatibilityExceptions.contains(lower) { return nil }
    guard wordClassIsSafe(left, payload) else { return .wordClassNotSafe }
    return nil
  }
}
