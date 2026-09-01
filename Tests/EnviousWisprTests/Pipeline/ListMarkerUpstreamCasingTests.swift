import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline
@testable import EnviousWisprPostProcessing

/// #2496 — the composed `WordCorrection -> InverseTextNormalization` path.
///
/// **Product Outcome.** The list-marker rule reads the CASE the speech engine wrote, because
/// that case is the engine's own article-versus-tag decision. Word correction runs BEFORE it
/// and can rewrite a phrase with the registered term's own casing. So the rule's safety claim
/// is about the case that REACHES normalization, not the case the speech engine produced, and
/// that distinction is only observable when both steps run in one chain. When these fail, a
/// user with a custom words entry gets a tag glued that should not have been, or loses one
/// that should have been.
///
/// The single-step suites cannot reach this: `InverseTextNormalizerParityTests` feeds the
/// normalizer directly, so nothing upstream can have changed the casing first.
@Suite("List markers — upstream casing through word correction (#2496)", .tags(.productOutcome))
@MainActor
struct ListMarkerUpstreamCasingTests {

  /// Runs the two deterministic steps in their shipped order against one input.
  private func corrected(_ input: String, vocabulary terms: [CustomWord]) async throws -> String {
    let correction = WordCorrectionStep()
    correction.correctorVocabulary = CorrectorVocabulary(terms: terms, generation: 1)
    let itn = InverseTextNormalizationStep()
    var context = TextProcessingContext(text: input, language: "en")
    context = try await correction.process(context)
    context = try await itn.process(context)
    return context.text
  }

  /// A standalone one-character entry cannot recase a marker, because the single-word
  /// correction passes skip cores shorter than two characters. This is the half of §14
  /// question 2 that says the obvious attack does not work; without it, the next reader has
  /// to re-derive the length floor from `WordCorrector` to know the path is closed.
  @Test("a one-character custom word does not recase a marker letter")
  func oneCharacterEntryDoesNotRecase() async throws {
    let vocabulary = [CustomWord(canonical: "A", aliases: ["a"])]
    let out = try await corrected("this is a one time thing", vocabulary: vocabulary)
    #expect(out == "this is a one time thing")
  }

  /// The half that DOES work, and the reason the safety claim is scoped to the normalization
  /// boundary rather than to the speech engine's output: a multi-word entry emits its own
  /// canonical casing, and normalization then reads that.
  @Test("an uppercase multi-word canonical reaches normalization and glues")
  func uppercaseCanonicalGlues() async throws {
    let vocabulary = [CustomWord(canonical: "Section A one", aliases: ["section a one"])]
    let out = try await corrected("section a one is complete", vocabulary: vocabulary)
    #expect(out == "Section A1 is complete")
  }

  /// The same mechanism in the safe direction: a lowercase canonical stays unglued. Written
  /// as the PAIR of the row above on identical surrounding text, so neither row can pass
  /// against an implementation that ignores case.
  @Test("a lowercase multi-word canonical reaches normalization and does not glue")
  func lowercaseCanonicalDoesNotGlue() async throws {
    let vocabulary = [CustomWord(canonical: "section a one", aliases: ["Section A one"])]
    let out = try await corrected("Section A one is complete", vocabulary: vocabulary)
    #expect(out == "section a one is complete")
  }

  /// With no custom words at all, the chain must behave exactly as the normalizer alone does.
  /// This is the control: without it, a correction step that silently mangled every input
  /// would still let the three rows above pass for the wrong reason.
  @Test("with an empty vocabulary the chain matches the normalizer's own behaviour")
  func emptyVocabularyControl() async throws {
    #expect(try await corrected("the tag is A one", vocabulary: []) == "the tag is A1")
    #expect(try await corrected("the tag is a one", vocabulary: []) == "the tag is a one")
  }
  /// The run-walk ceiling, bound so it cannot rot into a comment.
  ///
  /// **Product Outcome.** The run walk is O(run length) and runs once per match, so an
  /// uninterrupted alternating run is quadratic. On real speech it costs a median 0.015 ms, but
  /// 1,000 synthetic markers cost 1.26 seconds before the cap, and this step has a wall-clock
  /// deadline — past it the user gets their text back with nothing converted at all.
  ///
  /// Both directions of the assertion matter: a run past the ceiling must REFUSE (never
  /// classify what a truncated walk happened to see), and a run inside it must still convert.
  /// Without the second row a cap of zero would pass.
  @Test("the walk ceiling is probed AT its boundary, and never rewrites a run in part")
  func runWalkCeilingFailsSafe() async throws {
    // 64 units is the ceiling, and one marker is two units, so 32 markers is the last run that
    // converts and 33 is the first that must refuse. The earlier version of this test used 100
    // markers — far past the boundary, where both walks are individually over the cap — and so
    // could not see that 33 came back MIXED: 31 converted, 2 left spoken (Codex r8).
    func run(_ n: Int) async throws -> String {
      try await corrected(Array(repeating: "P one", count: n).joined(separator: " "), vocabulary: [])
    }

    let atCeiling = try await run(32)
    #expect(!atCeiling.contains("P one"), "32 markers is AT the ceiling and must convert whole")

    for n in [33, 40, 100] {
      let out = try await run(n)
      let converted = out.components(separatedBy: "P1").count - 1
      let spoken = out.components(separatedBy: "P one").count - 1
      #expect(converted == 0, "\(n) markers is past the ceiling; it rewrote \(converted) of them")
      #expect(spoken == n, "\(n) markers must all be left spoken, saw \(spoken)")
    }

    // An ordinary run still converts, so the ceiling cannot pass by refusing everything.
    #expect(try await run(4) == "P1 P1 P1 P1")
  }

  /// Spoken-punctuation commands are PENDING delimiters, and only a Swift test can reach this.
  ///
  /// **Product Outcome.** `listMarkers` runs at `:345` and `applyPunct` at `:569`, so the marker
  /// pass always sees the spoken word. With the setting on, "Note colon A one time fee applies."
  /// became "Note: A1 time fee applies." — the article glued into a tag because the capital
  /// looked semantic while the delimiter that makes it positional had not materialised yet.
  ///
  /// The Python oracle cannot express this: it has no `spokenPunctuation` parameter, so the
  /// parity fixture only ever exercises one side of the flag. Both sides are asserted here, and
  /// the rule is deliberately unconditional so the two implementations do not diverge.
  @Test("a spoken punctuation command before an article refuses, with the setting on or off")
  func punctuationCommandIsAPendingDelimiter() {
    let itn = InverseTextNormalizer()
    for spoken in [true, false] {
      let out = itn.normalize("Note colon A one time fee applies.", spokenPunctuation: spoken)
      #expect(!out.contains("A1"), "spokenPunctuation: \(spoken) glued the article: \(out)")
    }
    // The control: a real tag after an ordinary word still converts, so the rule above cannot
    // pass by refusing everything.
    #expect(InverseTextNormalizer().normalize("the tag is A one").contains("A1"))
  }

  /// A run whose cardinal group does not PARSE must refuse whole, not convert its second half.
  ///
  /// **Product Outcome.** "P one two Q three" became "P one two Q3": "one two" is not a number,
  /// so "P one two" cannot be a marker, yet the run still read letter-number-letter-number and
  /// converted the pair it could. The user gets half a sentence rewritten.
  @Test("a run containing an unparsable number refuses whole")
  func unparsableCardinalGroupRefusesTheWholeRun() {
    let itn = InverseTextNormalizer()
    #expect(itn.normalize("P one two Q three") == "P one two Q three")
    #expect(itn.normalize("P one twenty Q two") == "P one twenty Q two")
    // Control: the same shape with a parsable group still converts.
    #expect(itn.normalize("P one Q three") == "P1 Q3")
  }
  /// Punctuation attached to a title word must not hide its capital.
  ///
  /// **Product Outcome.** The title-case guard asked the run-classification helper, which
  /// rejects any token that is not pure letters. "Day's", "Day." and "Day," all came back empty,
  /// so the guard saw no next word and glued the article: "I take One A Day's vitamins" became
  /// "I take 1A Day's vitamins", while the unpunctuated form was correctly preserved.
  @Test("a capitalised title word still blocks the marker when punctuation is attached")
  func titleCaseGuardSeesPunctuatedWords() {
    let itn = InverseTextNormalizer()
    for input in [
      "I take One A Day's vitamins", "I take One A Day.", "One A Day, every day",
      "I take One A Day vitamins",
    ] {
      #expect(itn.normalize(input) == input, "title case was glued: \(itn.normalize(input))")
    }
    // Control: a real list whose letter is followed by punctuation still converts, so the guard
    // above cannot pass by refusing everything with a comma in it.
    #expect(itn.normalize("One A, two B, three C.") == "1A, 2B, 3C.")
  }

  /// The magnitude guard must protect a letter TOUCHING the number, not one separated by "$".
  ///
  /// **Product Outcome.** `keepMagnitude` gained a `(?<![A-Za-z])` so a compact tag is never
  /// split ("P1,000,000" must not become "P1 million"). A letter-prefixed currency is the case
  /// where that guard could over-reach — nothing in either parity fixture covers "US$", so this
  /// surface was untested in both implementations until now.
  @Test("a letter-prefixed currency still gets house-style magnitude")
  func letterPrefixedCurrencyKeepsMagnitude() {
    let itn = InverseTextNormalizer()
    #expect(itn.normalize("US$1,000,000") == "US$1 million")
    #expect(itn.normalize("US$5,200,000") == "US$5.2 million")
    #expect(itn.normalize("$1,000,000") == "$1 million")
    // The tag this guard exists for, asserted beside it so neither can drift alone.
    #expect(itn.normalize("P one million") == "P1,000,000")
  }
}
