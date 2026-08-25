import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #2312 — the MULTI-WORD fuzzy pass (Pass 2) must not swallow a glued domain
/// suffix.
///
/// **Product Outcome.** When these fail the user dictates `platforn.com`, gets a
/// spelling correction, and their `.com` is silently gone.
///
/// The existing glued-suffix suite covers the SINGLE-word path that #2281 built.
/// Pass 2 runs first and consumed the tokens before that path could see them, so
/// none of it was binding here — which is why the defect survived 20 review
/// rounds one pass over.
@Suite("WordCorrector — multi-word glued domain suffix (#2312)", .tags(.productOutcome))
struct MultiWordDomainSuffixTests {
  let corrector = WordCorrector()

  /// The reported defect.
  ///
  /// **Reaches Pass 2's fuzzy branch by construction, which is what stops this
  /// being vacuous:** `international platforn.com` is not the exact spaced alias
  /// (so Pass 1 misses) and not its space-free form (so Pass 0 misses), and the
  /// last token ends in a letter so the suffix survives `stripPunctuation` into
  /// the scorer. A single-word-only implementation cannot produce this result,
  /// because Pass 2 replaces the whole two-token span before Pass 4 runs.
  @Test("a near-miss with a glued suffix keeps the suffix")
  func multiWordFuzzyKeepsGluedSuffix() {
    let word = CustomWord(canonical: "International Platform", aliases: ["international platform"])
    let (result, replacements) = corrector.correct(
      "visit international platforn.com today", against: [word])
    #expect(
      result == "visit International Platform.com today",
      "the spelling is corrected and the dictated .com survives; got: \(result)")
    #expect(replacements.count == 1)
    #expect(replacements.first?.sourceID == word.id)
  }

  /// Reattachment lands BEFORE the token's ordinary punctuation, mirroring the
  /// single-word path's `prefix + canonical + reattach + suffix` order.
  @Test("the peeled suffix is reattached before trailing punctuation")
  func suffixPrecedesTrailingPunctuation() {
    let word = CustomWord(canonical: "International Platform", aliases: ["international platform"])
    let (result, _) = corrector.correct("go to international platforn.com!", against: [word])
    #expect(
      result == "go to International Platform.com!",
      "expected canonical + .com + !; got: \(result)")
  }

  /// The other direction, and it is load-bearing: a multi-word near-miss with NO
  /// glued suffix must still correct exactly as before. Alone, the case above is
  /// satisfiable by an implementation that broke ordinary matching.
  @Test("a near-miss with no glued suffix still corrects")
  func multiWordFuzzyStillCorrectsWithoutSuffix() {
    let word = CustomWord(canonical: "International Platform", aliases: ["international platform"])
    let (result, replacements) = corrector.correct(
      "visit international platforn today", against: [word])
    #expect(result == "visit International Platform today")
    #expect(replacements.count == 1)
  }

  /// Text that is ALREADY correct must survive a competing distractor (#2406).
  ///
  /// With `International Platform.com` dictated, the PEELED attempt matches its
  /// canonical perfectly — nothing to do — while an unrelated domain-shaped
  /// distractor can clear the threshold on the UNPEELED attempt. Treating
  /// "already correct" as "found nothing" handed the span to the distractor and
  /// replaced correct text.
  ///
  /// This hazard is specific to the two-attempt design: the single-attempt
  /// version had no other branch to hand the span to.
  @Test("already-correct text is not replaced by a competing distractor")
  func alreadyCorrectTextSurvivesADistractor() {
    let real = CustomWord(
      canonical: "International Platform", aliases: ["international platform"])
    let distractor = CustomWord(
      canonical: "Unrelated Thing", aliases: ["international plxxform.com"])
    let (result, replacements) = corrector.correct(
      "visit International Platform.com today", against: [real, distractor])
    #expect(
      result == "visit International Platform.com today",
      "already-correct text must be left alone, not replaced; got: \(result)")
    #expect(replacements.isEmpty, "nothing should have been replaced")
  }

  /// An already-correct span must be RESERVED, not merely skipped (#2406 r2).
  ///
  /// `continue` only tried a shorter span, and the outer loop then advanced one
  /// token — back INSIDE the protected text — where a shorter overlapping alias
  /// rewrote it. A matched span collapses to one token so `i += 1` steps past it;
  /// an already-correct span keeps all N.
  @Test("an already-correct span is not rewritten by a shorter overlapping alias")
  func alreadyCorrectSpanIsReservedFromOverlappingAliases() {
    let full = CustomWord(canonical: "Alpha Beta Gamma", aliases: ["alpha beta gamma"])
    let overlapping = CustomWord(canonical: "Wrong", aliases: ["beta gamma"])
    let (result, _) = corrector.correct(
      "see Alpha Beta Gamma.com now", against: [full, overlapping])
    #expect(
      result == "see Alpha Beta Gamma.com now",
      "the whole already-correct span must be reserved; got: \(result)")
  }

  /// Already-correct text survives even when a NEAR-TWIN alias exists (#2406 r3).
  ///
  /// Self-identity is a fact about the input; threshold and margin are about a
  /// competition between candidates, and a competition cannot make correct text
  /// incorrect. Checked last, the margin gate reached it first and returned
  /// `.ambiguous` — which does not reserve the span, so an overlapping alias
  /// rewrote text that was already right.
  @Test("already-correct text survives a near-twin distractor and an overlapping alias")
  func alreadyCorrectSurvivesNearTwinAndOverlap() {
    let full = CustomWord(canonical: "Alpha Beta Gamma", aliases: ["alpha beta gamma"])
    let nearTwin = CustomWord(canonical: "Alpha Beta Gammaa", aliases: ["alpha beta gammaa"])
    let overlapping = CustomWord(canonical: "Wrong", aliases: ["beta gamma"])
    let (result, _) = corrector.correct(
      "see Alpha Beta Gamma.com now", against: [full, nearTwin, overlapping])
    #expect(
      result == "see Alpha Beta Gamma.com now",
      "a near-twin must not turn already-correct text into an ambiguous span; got: \(result)")
  }

  /// An EXACT peeled alias is a certainty, not a competitor (#2406 r5).
  ///
  /// Pass 1 gives the unpeeled phrase an exact lookup and misses here, because
  /// the dictated token still carries `.com`. The peeled phrase then had no
  /// exact lookup at all, so a score of 1.0 was put in a competition against a
  /// distractor at ~0.972 and lost on the ambiguity margin — a correction the
  /// vocabulary defines EXACTLY, refused because something else looked similar.
  @Test("an exact peeled alias wins over a near-twin distractor")
  func exactPeeledAliasOutranksFuzzyDistractor() {
    let intended = CustomWord(canonical: "Acme Suite", aliases: ["international platform"])
    let distractor = CustomWord(canonical: "Other Thing", aliases: ["international platforma"])
    let (result, replacements) = corrector.correct(
      "visit international platform.com today", against: [intended, distractor])
    #expect(
      result == "visit Acme Suite.com today",
      "an exact alias for the peeled phrase is the answer, not a candidate; got: \(result)")
    #expect(replacements.first?.sourceID == intended.id)
  }

  /// The other direction for the exact-peeled path, and it is what stops the
  /// case above being satisfiable by "always take the first exact-ish hit": an
  /// exact peeled alias must still respect the domain-shaped reattachment rule.
  @Test("an exact peeled alias to a domain-shaped canonical does not double the suffix")
  func exactPeeledAliasRespectsDomainShapedCanonical() {
    let word = CustomWord(canonical: "Acme Suite.com", aliases: ["international platform"])
    let (result, _) = corrector.correct(
      "visit international platform.com today", against: [word])
    #expect(
      result == "visit Acme Suite.com today",
      "the canonical already carries its own domain; got: \(result)")
  }

  /// The user's own word outranks a pack term ACROSS the peel boundary
  /// (#2406 r6, P1).
  ///
  /// A pack alias carrying its own domain suffix matches the UNPEELED phrase in
  /// Pass 1, which reads the wide map and accepts immediately — before Pass 2
  /// can offer the user's own alias, which matches the same span once the suffix
  /// comes off. The result is the user's vocabulary losing to a pack term, which
  /// inverts this repo's precedence.
  ///
  /// This is the slot-2-over-slot-3 rule the single-word path settled at round 7
  /// of #2281, reached in the multi-word passes only because this PR made a
  /// peeled exact match possible at all.
  @Test("a user's peeled exact outranks a pack term's unpeeled exact")
  func nonPackPeeledExactOutranksPackUnpeeledExact() {
    let packWord = CustomWord(
      canonical: "Pack Choice", aliases: ["international platform.com"], source: .pack)
    let userWord = CustomWord(canonical: "User Choice", aliases: ["international platform"])
    let (result, replacements) = corrector.correct(
      "visit international platform.com today", against: [packWord, userWord])
    #expect(
      result == "visit User Choice.com today",
      "the user's own word must outrank a pack term across the peel; got: \(result)")
    #expect(replacements.first?.sourceID == userWord.id)
  }

  /// The other direction, and it is what stops the case above being satisfiable
  /// by "always defer to Pass 2": with NO user word competing, the pack term's
  /// unpeeled exact must still win. Slot 3 is a real slot, not a disabled one.
  @Test("a pack term's unpeeled exact still wins when no user word competes")
  func packUnpeeledExactStillWinsUncontested() {
    let packWord = CustomWord(
      canonical: "Pack Choice", aliases: ["international platform.com"], source: .pack)
    let (result, _) = corrector.correct(
      "visit international platform.com today", against: [packWord])
    #expect(
      result == "visit Pack Choice today",
      "an uncontested pack exact must still be applied; got: \(result)")
  }

  /// A canonical that already specifies its own domain does NOT get the dictated
  /// suffix reattached — otherwise the user sees it twice. Same rule the
  /// single-word path applies.
  @Test("a domain-shaped canonical does not get the suffix reattached")
  func domainShapedCanonicalDoesNotDoubleSuffix() {
    let word = CustomWord(
      canonical: "Example Site.com", aliases: ["example site"])
    let (result, _) = corrector.correct("open example sight.com now", against: [word])
    #expect(
      !result.contains(".com.com"),
      "a domain-shaped canonical already carries its suffix; got: \(result)")
  }
}
