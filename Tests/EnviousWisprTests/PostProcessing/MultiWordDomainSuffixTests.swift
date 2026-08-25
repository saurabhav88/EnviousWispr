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
