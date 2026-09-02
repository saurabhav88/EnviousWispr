import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #628 — the snippet matcher.
///
/// When this fails the user gets the wrong text pasted into their document, so the class is
/// `.productOutcome`. The three cases that carry the most weight are the two NEGATIVE ones —
/// a trigger spoken without the keyword, and the keyword spoken with nothing matching after it
/// — because those are what the keyword rule exists for, and a matcher that fires too eagerly
/// looks like a working feature right up until it rewrites a sentence the user meant.
@Suite("Snippet expansion (#628)", .tags(.productOutcome))
struct SnippetExpanderTests {

  private func vocabulary(
    _ pairs: [(String, String)], keyword: String = SnippetVocabulary.defaultKeyword
  ) -> SnippetVocabulary {
    SnippetVocabulary(
      snippets: pairs.map { Snippet(trigger: $0.0, expansion: $0.1) },
      keyword: keyword,
      generation: 1)
  }

  /// A predictable sentinel source so assertions can name the token. Real runs use random hex.
  private func fixedExpander(_ values: [String]) -> SnippetExpander {
    let box = Box(values)
    return SnippetExpander(candidateSource: { box.next() })
  }

  private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]
    private var index = 0
    init(_ values: [String]) { self.values = values }
    func next() -> String {
      lock.lock()
      defer { lock.unlock() }
      let value = values[min(index, values.count - 1)]
      index += 1
      return value
    }
  }

  // MARK: - The keyword rule

  @Test("A trigger after the keyword expands in place, mid-sentence")
  func expandsAfterKeyword() {
    let expander = fixedExpander(["EWSNIPaaaa"])
    let out = expander.expand(
      "feel free to email me at backslash my email address any time",
      using: vocabulary([("my email address", "sam@example.com")]))

    #expect(out.text == "feel free to email me at EWSNIPaaaa any time")
    #expect(
      out.records == [SnippetExpansionRecord(sentinel: "EWSNIPaaaa", expansion: "sam@example.com")])
  }

  @Test("The same words WITHOUT the keyword are left completely alone")
  func triggerWithoutKeywordDoesNothing() {
    let input = "can you send me my email address from that form"
    let out = SnippetExpander().expand(
      input, using: vocabulary([("my email address", "sam@example.com")]))

    #expect(out.text == input)
    #expect(out.records.isEmpty)
    #expect(out.didFire == false)
  }

  @Test("The keyword with nothing matching after it is left in place")
  func keywordWithoutMatchIsPreserved() {
    let input = "the path is backslash users backslash shared"
    let out = SnippetExpander().expand(
      input, using: vocabulary([("my email address", "sam@example.com")]))

    #expect(out.text == input)
    #expect(out.records.isEmpty)
  }

  // MARK: - Matching semantics carried from the approved design

  @Test("The LONGEST trigger wins when two match at the same position")
  func longestMatchWins() {
    let expander = fixedExpander(["EWSNIPlong"])
    let out = expander.expand(
      "backslash my email address please",
      using: vocabulary([
        ("my email", "SHORT"),
        ("my email address", "LONG"),
      ]))

    #expect(out.text == "EWSNIPlong please")
    #expect(out.records.first?.expansion == "LONG")
  }

  @Test("Punctuation clinging to the last trigger word survives the substitution")
  func trailingPunctuationSurvives() {
    let expander = fixedExpander(["EWSNIPdot"])
    let out = expander.expand(
      "email me at backslash my email address.",
      using: vocabulary([("my email address", "sam@example.com")]))

    #expect(out.text == "email me at EWSNIPdot.")
  }

  @Test("Matching is case-insensitive, because speech is transcribed with sentence casing")
  func matchIsCaseInsensitive() {
    let expander = fixedExpander(["EWSNIPcase"])
    let out = expander.expand(
      "Backslash My Email Address",
      using: vocabulary([("my email address", "sam@example.com")]))

    #expect(out.text == "EWSNIPcase")
  }

  @Test("Two snippets in one utterance each fire, with distinct sentinels")
  func twoSnippetsInOneUtterance() {
    let expander = fixedExpander(["EWSNIPone", "EWSNIPtwo"])
    let out = expander.expand(
      "backslash my email or backslash support address",
      using: vocabulary([
        ("my email", "sam@example.com"),
        ("support address", "help@example.com"),
      ]))

    #expect(out.text == "EWSNIPone or EWSNIPtwo")
    #expect(out.records.count == 2)
    #expect(Set(out.records.map(\.sentinel)).count == 2)
  }

  @Test("Original spacing and line breaks are preserved around an expansion")
  func spacingIsPreserved() {
    let expander = fixedExpander(["EWSNIPgap"])
    let out = expander.expand(
      "first line\n\nbackslash my email  trailing",
      using: vocabulary([("my email", "sam@example.com")]))

    #expect(out.text == "first line\n\nEWSNIPgap  trailing")
  }

  @Test("A trigger at the very end of the utterance still fires")
  func triggerAtEndOfUtterance() {
    let expander = fixedExpander(["EWSNIPend"])
    let out = expander.expand(
      "email me at backslash my email address",
      using: vocabulary([("my email address", "sam@example.com")]))

    #expect(out.text == "email me at EWSNIPend")
    #expect(out.records.count == 1)
  }

  /// Leading whitespace belongs to no word, and the reconstruction walks words. It was dropped
  /// on EVERY dictation once the step was armed — match or no match — and no fixture caught it
  /// because every one of them started with a letter.
  @Test("Whitespace before the first word survives, with and without a match")
  func leadingWhitespaceIsPreserved() {
    let vocab = vocabulary([("my email", "sam@example.com")])
    let expander = fixedExpander(["EWSNIPlead"])

    #expect(expander.expand("\n  hello there", using: vocab).text == "\n  hello there")
    #expect(
      fixedExpander(["EWSNIPlead"]).expand("  backslash my email", using: vocab).text
        == "  EWSNIPlead")
  }

  /// Both ends of a quoted phrase. The opening mark is stripped from the KEYWORD so the match
  /// can happen, the closing one from the last trigger word; restoring only the tail leaves an
  /// orphan closing quote in the user's sentence.
  @Test("A quoted trigger keeps BOTH quotes around the pasted text")
  func quotesSurviveOnBothSides() {
    let expander = fixedExpander(["EWSNIPq"])
    let out = expander.expand(
      "he said \u{201C}backslash my email\u{201D} and left",
      using: vocabulary([("my email", "sam@example.com")]))

    #expect(out.text == "he said \u{201C}EWSNIPq\u{201D} and left")
  }

  /// The OTHER arrangement. The user can attach the opening mark to the keyword or to the first
  /// trigger word, and a fix covering one looks identical to a fix covering both.
  @Test("An opening mark on the first trigger word is kept too")
  func openingMarkOnTriggerSurvives() {
    let expander = fixedExpander(["EWSNIPt"])
    let out = expander.expand(
      "he said backslash \u{201C}my email\u{201D} and left",
      using: vocabulary([("my email", "sam@example.com")]))

    #expect(out.text == "he said \u{201C}EWSNIPt\u{201D} and left")
  }

  @Test("A trigger in brackets keeps both brackets")
  func bracketsSurviveOnBothSides() {
    let expander = fixedExpander(["EWSNIPb"])
    let out = expander.expand(
      "(backslash my email)",
      using: vocabulary([("my email", "sam@example.com")]))

    #expect(out.text == "(EWSNIPb)")
  }

  /// A full stop INSIDE the phrase means the user said two sentences, not one trigger.
  /// Normalisation strips it so the words still compare equal, which is exactly why this needs
  /// its own guard rather than falling out of the comparison.
  @Test("A trigger does not match across a sentence boundary")
  func triggerDoesNotSpanASentenceBoundary() {
    let input = "send me backslash my. Email address is below"
    let out = SnippetExpander().expand(
      input, using: vocabulary([("my email address", "sam@example.com")]))

    #expect(out.text == input)
    #expect(out.records.isEmpty)
  }

  /// The KEYWORD is consumed too, and it was the token the first boundary guard could not see.
  @Test("A sentence boundary on the KEYWORD blocks the match")
  func keywordBoundaryBlocksTheMatch() {
    let input = "send me backslash. My email address is below"
    let out = SnippetExpander().expand(
      input, using: vocabulary([("my email address", "sam@example.com")]))

    #expect(out.text == input)
    #expect(out.records.isEmpty)
  }

  /// The other side of the same rule: punctuation on the LAST trigger word is the sentence the
  /// trigger legitimately ends, and it is re-attached after the expansion rather than blocking.
  @Test("A full stop on the last trigger word still matches, and survives")
  func sentenceEndingOnLastTokenStillMatches() {
    let expander = fixedExpander(["EWSNIPend2"])
    let out = expander.expand(
      "write to backslash my email address. Thanks.",
      using: vocabulary([("my email address", "sam@example.com")]))

    #expect(out.text == "write to EWSNIPend2. Thanks.")
  }

  /// Punctuation strictly INSIDE the phrase is dropped with the words it sat between, and that
  /// is correct rather than a gap: the phrase is REPLACED, so an interior comma has no
  /// destination in the pasted text. Frozen here so nobody "fixes" it back.
  @Test("A comma inside the phrase is consumed with the phrase")
  func interiorCommaIsConsumed() {
    let expander = fixedExpander(["EWSNIPcomma"])
    let out = expander.expand(
      "email me at backslash my, email today",
      using: vocabulary([("my email", "sam@example.com")]))

    #expect(out.text == "email me at EWSNIPcomma today")
  }

  // MARK: - The disabled path, which is what an ordinary user takes

  @Test("An empty store returns the input unchanged and identical")
  func emptyStoreIsIdentity() {
    let input = "backslash my email address"
    let out = SnippetExpander().expand(input, using: .empty)

    #expect(out.text == input)
    #expect(out.records.isEmpty)
  }

  @Test("A blank keyword cannot fire, even with snippets saved")
  func blankKeywordCannotFire() {
    let input = "backslash my email address"
    let vocab = SnippetVocabulary(
      snippets: [Snippet(trigger: "my email address", expansion: "sam@example.com")],
      keyword: "   ",
      generation: 1)

    #expect(vocab.canFire == false)
    #expect(SnippetExpander().expand(input, using: vocab).text == input)
  }

  // MARK: - Sentinel uniqueness, all three domains

  @Test("A sentinel already present in the dictated text is rejected")
  func sentinelCollidingWithInputIsRejected() {
    let expander = fixedExpander(["EWSNIPdupe", "EWSNIPfresh"])
    let out = expander.expand(
      "the code is EWSNIPdupe and backslash my email",
      using: vocabulary([("my email", "sam@example.com")]))

    #expect(out.records.first?.sentinel == "EWSNIPfresh")
    #expect(out.text.contains("EWSNIPfresh"))
  }

  /// The domain that is easiest to miss: restoration substitutes expansions back INTO the text,
  /// so a sentinel living inside an expansion would reappear after the finalizer had already
  /// checked that none remained.
  @Test("A sentinel that appears inside a saved expansion is rejected")
  func sentinelCollidingWithAnExpansionIsRejected() {
    let expander = fixedExpander(["EWSNIPinside", "EWSNIPclean"])
    let out = expander.expand(
      "backslash my email",
      using: vocabulary([
        ("my email", "sam@example.com"),
        ("my note", "reference EWSNIPinside for details"),
      ]))

    #expect(out.records.first?.sentinel == "EWSNIPclean")
  }

  @Test("A degenerate source that always returns one value still yields distinct sentinels")
  func exhaustedSourceStillYieldsDistinctSentinels() {
    let expander = fixedExpander(["EWSNIPsame"])
    let out = expander.expand(
      "backslash my email or backslash support address",
      using: vocabulary([
        ("my email", "sam@example.com"),
        ("support address", "help@example.com"),
      ]))

    #expect(out.records.count == 2)
    #expect(out.records[0].sentinel != out.records[1].sentinel)
  }

  // MARK: - The duplicate rule, stated once on the type

  @Test("Two triggers differing only by case and punctuation are the same trigger")
  func duplicateTriggersCollide() {
    let a = Snippet(trigger: "my email address", expansion: "one")
    let b = Snippet(trigger: "My Email Address.", expansion: "two")
    let c = Snippet(trigger: "my email", expansion: "three")

    #expect(a.collidesWith(b))
    #expect(!a.collidesWith(c))
  }

  @Test("An all-punctuation trigger collides with nothing, including itself")
  func emptyTriggerTokensNeverCollide() {
    let blank = Snippet(trigger: "...", expansion: "x")

    #expect(blank.triggerTokens.isEmpty)
    #expect(!blank.collidesWith(blank))
  }
}
