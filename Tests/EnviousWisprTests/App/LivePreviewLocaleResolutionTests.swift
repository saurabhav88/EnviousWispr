import Foundation
import Testing

@testable import EnviousWisprLivePreview

/// #2080 round 4 — which installed pack satisfies a language request.
///
/// **The regression this exists to prevent.** Apple's `supportedLocale(equivalentTo:)` returns a
/// DIFFERENT region each call for a bare code: `fr` measured as fr-CH, then fr-CA, then fr-BE
/// across three runs. Locked language mode sends a bare catalogue code, so it lotteries.
///
/// That used to cost quality only, because `prepare()` downloaded whichever variant the draw
/// named. Making installation the user's deliberate action turned it into a functional break: the
/// user downloads the French the pill asked for, the next recording draws a different French, and
/// the pill asks again. Nothing they can do short of installing all four variants fixes it.
///
/// Pure function on purpose — the regional behaviour is the part worth testing, and Apple's
/// inventory is not injectable.
struct LivePreviewLocaleResolutionTests {

  private func satisfying(_ code: String, _ resolved: String, _ installed: [String]) -> String? {
    ApplePreviewEngineResolver.satisfyingTag(
      requestedCode: code, resolvedTag: resolved, installedTags: installed)
  }

  @Test("A locked language is satisfied by any installed region of that language")
  func bareCodeAcceptsAnInstalledSibling() {
    // The exact reported shape: the draw named Swiss French, the user has French (France).
    #expect(satisfying("fr", "fr-CH", ["fr-FR"]) == "fr-FR")
    #expect(satisfying("fr", "fr-BE", ["fr-FR"]) == "fr-FR")
    #expect(satisfying("fr", "fr-CA", ["fr-FR"]) == "fr-FR")
  }

  /// The fix is worthless if the CHOICE among installed variants is itself a lottery: the engine
  /// cache is keyed on the chosen tag, so an unstable pick would rebuild the engine with a
  /// different regional model on random recordings — the same churn, one level further in.
  @Test("The choice among installed variants does not depend on their order")
  func bareCodeChoiceIsStable() {
    let a = satisfying("fr", "fr-CH", ["fr-FR", "fr-BE", "fr-CA"])
    let b = satisfying("fr", "fr-CH", ["fr-CA", "fr-FR", "fr-BE"])
    let c = satisfying("fr", "fr-BE", ["fr-BE", "fr-CA", "fr-FR"])
    #expect(a == b, "the same installed set must give the same answer in any order")
    #expect(a == c, "and must not depend on which region the draw happened to name")
    #expect(a == "fr-BE", "deterministic by sort, so the answer is stated not incidental")
  }

  @Test("A language with no installed region is still reported as missing")
  func bareCodeWithNothingInstalled() {
    #expect(satisfying("fr", "fr-CH", ["de-DE", "en-US"]) == nil)
    #expect(satisfying("fr", "fr-CH", []) == nil)
  }

  /// Auto sends the FULL system locale, where the region is the entire point: measured, a zh-TW
  /// Mac reduced to a bare code gets Simplified characters for a Traditional reader. So the
  /// leniency above must not leak into this path.
  @Test("A request carrying a region still requires that exact region")
  func fullLocaleRequiresItsExactRegion() {
    #expect(satisfying("en-US", "en-US", ["en-GB", "en-AU"]) == nil)
    #expect(satisfying("en-US", "en-US", ["en-US"]) == "en-US")
    #expect(satisfying("zh-TW", "zh-TW", ["zh-CN"]) == nil)
    #expect(satisfying("zh-TW", "zh-TW", ["zh-CN", "zh-TW"]) == "zh-TW")
  }

  /// Two-way control: the leniency is real and scoped, not a function that returns the first
  /// installed tag regardless of language.
  @Test("A different language never satisfies the request")
  func neverCrossesLanguages() {
    #expect(satisfying("fr", "fr-CH", ["de-DE", "de-AT"]) == nil)
    #expect(satisfying("de", "de-DE", ["fr-FR", "de-AT"]) == "de-AT")
  }
}
