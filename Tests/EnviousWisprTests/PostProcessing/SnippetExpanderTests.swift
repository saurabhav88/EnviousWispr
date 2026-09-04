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

  // MARK: - The snippet's own ending wins (#2637)

  /// Speaking ONLY the snippet is how a snippet is mostly used — into an empty field, a search
  /// box, a form. Parakeet punctuates a complete utterance, and a dictation that is nothing but
  /// the phrase IS one, so the recogniser writes `snippet.` and the reconstruction welded that
  /// stop onto an email address every single time. Measured on the founder's log, 2026-09-03
  /// 23:22, three consecutive takes.
  @Test("A snippet spoken on its own does not get a full stop welded on")
  func wholeDictationDropsTheRecognisersStop() {
    let expander = fixedExpander(["EWSNIPalone"])
    let out = expander.expand(
      "backslash my email address.",
      using: vocabulary([("my email address", "sam@example.com")]))

    #expect(out.text == "EWSNIPalone")
    #expect(out.records.count == 1)
    #expect(out.records[0].expansion == "sam@example.com")
    #expect(out.records[0].suppressFollowingSentenceEnding)
  }

  /// The two-way control on the test above: with no stop to suppress the output is unchanged,
  /// so a green there cannot come from the suppression firing on everything.
  @Test("A snippet spoken on its own with no stop is unchanged")
  func wholeDictationWithoutAStopIsUnchanged() {
    let expander = fixedExpander(["EWSNIPalone2"])
    let out = expander.expand(
      "backslash my email address",
      using: vocabulary([("my email address", "sam@example.com")]))

    #expect(out.text == "EWSNIPalone2")
    // The flag records the DECISION, not whether anything was removed here. A whole-dictation
    // snippet the recogniser left unpunctuated still owns its ending, and a model is the other
    // source of a terminator.
    #expect(out.records[0].suppressFollowingSentenceEnding)
  }

  /// Scoping control. Suppression is for the recogniser's TERMINATOR, not for punctuation in
  /// general, so a comma is re-attached exactly as before even in the whole-dictation case.
  /// Widening this to "strip whatever clings to the last token" is the change this row refuses.
  @Test("A comma on a snippet spoken on its own is still re-attached")
  func wholeDictationKeepsANonTerminator() {
    let expander = fixedExpander(["EWSNIPcomma2"])
    let out = expander.expand(
      "backslash my email address,",
      using: vocabulary([("my email address", "sam@example.com")]))

    #expect(out.text == "EWSNIPcomma2,")
  }

  /// The in-sentence case is the one the re-attachment exists for and it must not regress: this
  /// full stop is the USER'S sentence, not the trigger's.
  @Test("A snippet inside a sentence still keeps the sentence's full stop")
  func inSentenceKeepsTheStop() {
    let expander = fixedExpander(["EWSNIPmid"])
    let out = expander.expand(
      "please contact me at backslash my email address.",
      using: vocabulary([("my email address", "sam@example.com")]))

    #expect(out.text == "please contact me at EWSNIPmid.")
    #expect(!out.records[0].suppressFollowingSentenceEnding)
  }

  /// Founder, 2026-09-03: "People will add punctuation and formatting to their snippet. We
  /// would honor that." A canned reply that ends itself must not arrive with a second stop.
  @Test("A saved expansion that already ends a sentence does not get a second stop")
  func expansionEndingASentenceSuppressesTheStop() {
    let expander = fixedExpander(["EWSNIPsig"])
    let out = expander.expand(
      "tell them backslash my sign off. Then send it.",
      using: vocabulary([("my sign off", "Let me know if that works.")]))

    #expect(out.text == "tell them EWSNIPsig Then send it.")
    #expect(out.records[0].expansion == "Let me know if that works.")
  }

  /// A saved expansion is deliberately NOT trimmed on save, so a real multi-line snippet ends
  /// with the newline the user typed. Reading only the final character answers `newline`, which
  /// is why the whitespace hop is inside `endsSentence` rather than at this call site.
  @Test("A trailing newline does not hide the expansion's own full stop")
  func expansionEndingASentenceThenANewline() {
    let expander = fixedExpander(["EWSNIPnl"])
    let out = expander.expand(
      "tell them backslash my sign off. Then send it.",
      using: vocabulary([("my sign off", "Speak soon.\n")]))

    #expect(out.text == "tell them EWSNIPnl Then send it.")
  }

  /// An expansion that does NOT end a sentence is the other half of the pair, and without it a
  /// suppression that fired on every in-sentence expansion would still pass the row above.
  @Test("An expansion that ends mid-phrase still receives the sentence's stop")
  func expansionNotEndingASentenceKeepsTheStop() {
    let expander = fixedExpander(["EWSNIPmid2"])
    let out = expander.expand(
      "tell them backslash my sign off. Then send it.",
      using: vocabulary([("my sign off", "Best,\nSaurabh")]))

    #expect(out.text == "tell them EWSNIPmid2. Then send it.")
  }

  /// "Whole dictation" has to mean the WHOLE dictation. With two snippets neither one is, so
  /// both keep their marks — the guard cannot be reading "a snippet fired" and calling it whole.
  @Test("With two snippets in one utterance neither counts as the whole dictation")
  func twoSnippetsAreNeitherWhole() {
    let expander = fixedExpander(["EWSNIPa", "EWSNIPb"])
    let out = expander.expand(
      "backslash my email. backslash my cell.",
      using: vocabulary([("my email", "sam@example.com"), ("my cell", "555-0100")]))

    #expect(out.text == "EWSNIPa. EWSNIPb.")
    #expect(out.records.count == 2)
  }

  /// A terminator hidden inside a MIXED run. Testing the run wholesale ("is every character a
  /// terminator?") looked conservative and left this untouched, so a self-terminating expansion
  /// still arrived as `..\u{201D}` — the defect this exists to prevent, behind one closing mark.
  @Test("A full stop followed by a closing quote is suppressed, and the quote is kept")
  func mixedTrailingRunLosesOnlyTheTerminator() {
    let expander = fixedExpander(["EWSNIPmix"])
    let out = expander.expand(
      "he said \u{201C}backslash my sign off.\u{201D} Then he left.",
      using: vocabulary([("my sign off", "Let me know if that works.")]))

    #expect(out.text == "he said \u{201C}EWSNIPmix\u{201D} Then he left.")
    #expect(out.records[0].suppressFollowingSentenceEnding)
  }

  // MARK: - A sentence boundary hiding behind a closing mark (#2605)

  /// `endsSentence` read only a token's FINAL character, so a stop followed by a closing quote
  /// was invisible and a snippet could span a real sentence break, eating the first words of
  /// the next sentence. The quote is what makes this different from the plain boundary rows
  /// above, so those passing says nothing about this one.
  @Test("A sentence boundary hidden behind a closing quote blocks the match")
  func boundaryBehindAClosingQuoteBlocks() {
    let expander = fixedExpander(["EWSNIPquote"])
    let out = expander.expand(
      "he said backslash my.\u{201D} Email address is below",
      using: vocabulary([("my email address", "sam@example.com")]))

    #expect(out.text == "he said backslash my.\u{201D} Email address is below")
    #expect(out.records.isEmpty)
  }

  /// The same shape with a closing bracket, because the fix hops a SET and a row proving one
  /// member proves only that member.
  @Test("A sentence boundary hidden behind a closing bracket blocks the match")
  func boundaryBehindAClosingBracketBlocks() {
    let expander = fixedExpander(["EWSNIPparen"])
    let out = expander.expand(
      "he said (backslash my.) Email address is below",
      using: vocabulary([("my email address", "sam@example.com")]))

    #expect(out.records.isEmpty)
  }

  // MARK: - The punctuation sets themselves

  /// `trailing` is composed from the three roles rather than spelled out, so this pins the
  /// resulting MEMBERSHIP against a literal. Building the expectation from the same union would
  /// pass against any definition, including one that dropped a role entirely.
  @Test("The trailing set is exactly the thirteen marks normalisation strips")
  func trailingSetMembershipIsPinned() {
    #expect(
      SnippetText.trailing == Set<Character>([
        ".", ",", "!", "?", ";", ":", ")", "]", "}", "\"", "'", "\u{201D}", "\u{2019}",
      ]))
    #expect(SnippetText.sentenceEnding.isSubset(of: SnippetText.trailing))
    #expect(SnippetText.closing.isSubset(of: SnippetText.trailing))
    #expect(SnippetText.sentenceEnding.isDisjoint(with: SnippetText.closing))
  }

  @Test("endsSentence reads through trailing closing marks and whitespace")
  func endsSentenceReadsThroughClosersAndWhitespace() {
    #expect(SnippetText.endsSentence("done."))
    #expect(SnippetText.endsSentence("my.\u{201D}"))
    #expect(SnippetText.endsSentence("email.)"))
    #expect(SnippetText.endsSentence("done.\"'"))
    #expect(SnippetText.endsSentence("Speak soon.\n"))
    #expect(SnippetText.endsSentence("What?  "))

    #expect(!SnippetText.endsSentence("Saurabh"))
    #expect(!SnippetText.endsSentence("email,"))
    #expect(!SnippetText.endsSentence("\u{201D}"))
    #expect(!SnippetText.endsSentence(""))
    #expect(!SnippetText.endsSentence("   "))
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
