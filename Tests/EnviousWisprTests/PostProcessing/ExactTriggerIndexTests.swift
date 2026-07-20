import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #1667 — the exact-trigger authority.
///
/// The headline test is `indexAgreesWithBuildLookupsAcrossEverySurface`: it
/// proves the authority resolves ownership exactly as the shipped
/// `buildLookups` does, for a vocabulary built to exercise every rule. That is
/// what makes it safe to project the correction maps from the index instead of
/// re-deriving them, which is the whole point of this change.
@Suite("ExactTriggerIndex")
struct ExactTriggerIndexTests {

  /// One vocabulary hitting every rule the two constructions must agree on:
  /// multi-word canonicals, multi-token aliases, no-space overlaps, an alias
  /// that shadows another word's canonical, and pack terms that must lose.
  private func vocabulary() -> [CustomWord] {
    [
      CustomWord(canonical: "Claude Code", aliases: ["clawed code", "cloud code"]),
      CustomWord(canonical: "Kubernetes", aliases: ["kubernetties", "koobernetes"]),
      CustomWord(canonical: "Qualtrics", aliases: ["kwaltrics"]),
      CustomWord(canonical: "EnviousWispr", aliases: ["envious whisper"]),
      CustomWord(canonical: "Postgres", aliases: ["post gres"]),
      CustomWord(canonical: "React Native", aliases: ["reactnative"]),
      CustomWord(canonical: "Bazel", aliases: ["bazel"], source: .pack),
      CustomWord(canonical: "Kubernetes", aliases: ["kubernetes"], source: .pack),
    ]
  }

  @Test("the index resolves the same owners buildLookups resolves, on every surface")
  func indexAgreesWithBuildLookupsAcrossEverySurface() {
    let words = vocabulary()
    let lookups = WordCorrector.buildLookups(words: words)
    let index = WordCorrector.buildExactTriggerIndex(words: words)

    // Same key sets, so neither side claims a surface the other missed.
    #expect(Set(index.single.keys) == Set(lookups.singleAliasMap.keys))
    #expect(Set(index.multi.keys) == Set(lookups.multiAliasMap.keys))
    #expect(Set(index.nospace.keys) == Set(lookups.nospaceCanonicalMap.keys))

    // Same WINNER per key. Key-set equality alone would pass while precedence
    // disagreed, which is the defect class this whole change exists to end.
    for (key, canonical) in lookups.singleAliasMap {
      #expect(index.single[key]?.canonical == canonical, "single '\(key)'")
    }
    for (key, canonical) in lookups.multiAliasMap {
      #expect(index.multi[key]?.canonical == canonical, "multi '\(key)'")
    }
    for (key, canonical) in lookups.nospaceCanonicalMap {
      #expect(index.nospace[key]?.canonical == canonical, "nospace '\(key)'")
    }
  }

  @Test("a multi-word canonical claims its space-stripped form")
  func multiWordCanonicalClaimsNospaceKey() {
    // The defect #1667 was filed for: `Claude Code` already owns `claudecode`,
    // so an imported alias of that spelling could never have triggered.
    let index = WordCorrector.buildExactTriggerIndex(words: vocabulary())
    #expect(index.nospace["claudecode"]?.canonical == "Claude Code")
    #expect(index.single["claudecode"] == nil, "it is a no-space claim, not an ordinary one")
  }

  @Test("no-space aliases fill gaps but a canonical overwrites them")
  func nospacePrecedenceIsThreeRulesNotOne() {
    let first = CustomWord(canonical: "Alpha", aliases: ["react native"])
    let second = CustomWord(canonical: "Beta", aliases: ["react native"])
    // alias vs alias in the no-space namespace: FIRST wins (gap-fill only).
    let aliasOnly = WordCorrector.buildExactTriggerIndex(words: [first, second])
    #expect(aliasOnly.nospace["reactnative"]?.canonical == "Alpha")

    // canonical vs alias: the canonical overwrites, whichever order.
    let withCanonical = WordCorrector.buildExactTriggerIndex(
      words: [first, CustomWord(canonical: "React Native")])
    #expect(withCanonical.nospace["reactnative"]?.canonical == "React Native")
  }

  @Test("a canonical self-entry yields to an alias that already owns the key")
  func canonicalSelfEntryYieldsToAlias() {
    let owner = CustomWord(canonical: "Alpha", aliases: ["beta"])
    let shadowed = CustomWord(canonical: "Beta")
    let index = WordCorrector.buildExactTriggerIndex(words: [owner, shadowed])
    #expect(index.single["beta"]?.canonical == "Alpha")
  }

  @Test("pack terms never claim a key a non-pack term owns, and never enter no-space")
  func packTermsLoseAndStayOutOfNospace() {
    let index = WordCorrector.buildExactTriggerIndex(words: vocabulary())
    // The pack Kubernetes alias must not displace the user word.
    #expect(index.single["kubernetes"]?.canonical == "Kubernetes")
    // No pack canonical reaches the no-space namespace at all.
    #expect(index.nospace["bazel"] == nil)
  }

  @Test("claim construction covers ordinary and no-space surfaces without duplicates")
  func claimConstructionIsDeduplicatedAndNamespaced() {
    let multi = WordCorrector.exactClaims(forAlias: "clawed code")
    #expect(multi.map(\.namespace) == [.multi, .nospace])
    #expect(multi.map(\.key) == ["clawed code", "clawedcode"])

    let single = WordCorrector.exactClaims(forAlias: "kubernetties")
    #expect(single.map(\.namespace) == [.single, .nospace])

    // A multi-word canonical gets no ordinary self-entry, only the no-space one.
    let canonical = WordCorrector.exactClaims(forCanonical: "Claude Code")
    #expect(canonical.map(\.namespace) == [.nospace])
    #expect(canonical.map(\.key) == ["claudecode"])

    #expect(WordCorrector.exactClaims(forAlias: "").isEmpty)
  }

  @Test("no-space outranks the ordinary passes when one alias collides on both")
  func passPriorityPrefersNospace() {
    // Pass 0 runs before the ordinary exact passes, so a receipt naming the
    // ordinary owner would name a word the corrector never actually reaches.
    #expect(WordCorrector.ExactTriggerNamespace.nospace.passPriority < WordCorrector.ExactTriggerNamespace.multi.passPriority)
    #expect(WordCorrector.ExactTriggerNamespace.multi.passPriority < WordCorrector.ExactTriggerNamespace.single.passPriority)
  }
}
