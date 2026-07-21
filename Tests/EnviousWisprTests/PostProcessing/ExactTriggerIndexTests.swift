import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #1667 — the exact-trigger authority.
///
/// The headline pair is `indexMatchesAnIndependentlyEnumeratedOracle` and
/// `buildLookupsProjectsTheAuthorityFaithfully`. Both check against maps
/// written out by hand, NOT against each other: `buildLookups` now projects
/// from the index, so comparing the two would compare the index to itself and
/// pass regardless. The literal oracle is what makes it safe to project the
/// correction maps instead of re-deriving them, which is the point of this
/// change.
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

  /// Hand-enumerated expected ownership for `vocabulary()`, written out rather
  /// than derived.
  ///
  /// This started as a comparison between the index and `buildLookups`, which
  /// was a real proof while the two were independently constructed. It stopped
  /// being one the moment `buildLookups` began PROJECTING from the index: it
  /// then compared the index to itself and would have passed no matter what
  /// either did. Grounded review caught it, and it had already let an
  /// empty-key regression through unnoticed.
  ///
  /// So the oracle is literal. It fails if the authority drifts, if the
  /// projection drifts, or if they drift together — which the previous version
  /// could not detect.
  private let expectedSingle = [
    "kubernetties": "Kubernetes", "koobernetes": "Kubernetes",
    "kwaltrics": "Qualtrics", "reactnative": "React Native",
    // Canonical self-entries, space-free canonicals only.
    "kubernetes": "Kubernetes", "qualtrics": "Qualtrics",
    "enviouswispr": "EnviousWispr", "postgres": "Postgres",
    // Pack gap-fill. `kubernetes` is NOT here from the pack: a non-pack
    // canonical already owns that key, so the pack term is refused.
    "bazel": "Bazel",
  ]

  private let expectedMulti = [
    "clawed code": "Claude Code", "cloud code": "Claude Code",
    "envious whisper": "EnviousWispr", "post gres": "Postgres",
  ]

  private let expectedNospace = [
    "claudecode": "Claude Code", "clawedcode": "Claude Code",
    "cloudcode": "Claude Code",
    "kubernetes": "Kubernetes", "kubernetties": "Kubernetes",
    "koobernetes": "Kubernetes",
    "qualtrics": "Qualtrics", "kwaltrics": "Qualtrics",
    "enviouswispr": "EnviousWispr", "enviouswhisper": "EnviousWispr",
    // "post gres" strips to the same key its own canonical already took.
    "postgres": "Postgres",
    "reactnative": "React Native",
      // No pack term appears at all: packs never enter this namespace.
  ]

  @Test("the authority resolves the hand-enumerated owner for every surface")
  func indexMatchesAnIndependentlyEnumeratedOracle() {
    let index = WordCorrector.buildExactTriggerIndex(words: vocabulary())

    #expect(index.single.mapValues(\.canonical) == expectedSingle)
    #expect(index.multi.mapValues(\.canonical) == expectedMulti)
    #expect(index.nospace.mapValues(\.canonical) == expectedNospace)
  }

  @Test("the projected correction maps are the authority's resolution, unchanged")
  func buildLookupsProjectsTheAuthorityFaithfully() {
    // Against the same literal oracle, not against the index — otherwise this
    // is the tautology described above.
    let lookups = WordCorrector.buildLookups(words: vocabulary())

    #expect(lookups.singleAliasMap == expectedSingle)
    #expect(lookups.multiAliasMap == expectedMulti)
    #expect(lookups.nospaceCanonicalMap == expectedNospace)
  }

  @Test("empty keys are preserved exactly as the pre-refactor construction left them")
  func projectionPreservesLegacyEmptyKeyBehaviour() {
    // Inert at runtime, but a refactor that silently drops map entries is not a
    // refactor. Filtering them also changed DEBUG collision numbering
    // (grounded review, #1667).
    let emptyAlias = WordCorrector.buildLookups(words: [
      CustomWord(canonical: "Alpha", aliases: [""])
    ])
    #expect(emptyAlias.singleAliasMap[""] == "Alpha")
    #expect(emptyAlias.nospaceCanonicalMap[""] == "Alpha")

    let emptyCanonical = WordCorrector.buildLookups(words: [CustomWord(canonical: "")])
    #expect(emptyCanonical.singleAliasMap[""] == "")
    #expect(emptyCanonical.nospaceCanonicalMap[""] == "")
  }

  @Test("a multi-word canonical claims its space-stripped form")
  func multiWordCanonicalClaimsNospaceKey() {
    // The defect #1667 was filed for: `Claude Code` already owns `claudecode`,
    // so an imported alias of that spelling could never have triggered.
    let index = WordCorrector.buildExactTriggerIndex(words: vocabulary())
    #expect(index.nospace["claudecode"]?.canonical == "Claude Code")
    #expect(index.single["claudecode"] == nil, "it is a no-space claim, not an ordinary one")
  }

  @Test("a no-space owner only counts when Pass 0 could actually consume the surface")
  func nospaceInterceptionMatchesPassZeroEligibility() {
    // Holding a key is not intercepting it. A first cut modelled only the
    // "already correct" short-circuit and treated every other no-space holder
    // as a blocker, which let surfaces Pass 0 can never even look at outrank
    // real ordinary claims (grounded review, #1667).
    func intercepts(_ key: String, _ surface: String, _ canonical: String) -> Bool {
      WordCorrector.ownerIntercepts(
        claim: .init(key: key, namespace: .nospace),
        rawSurface: surface,
        owner: .init(wordID: UUID(), canonical: canonical, isPack: false))
    }

    // "Already correct" is judged CASE-SENSITIVELY, exactly as Pass 0 judges
    // it — so an exact spelling declines, but a lowercase one does not, because
    // Pass 0 would substitute to fix the casing.
    #expect(intercepts("annie", "Annie", "Annie") == false, "already spells its canonical")
    #expect(intercepts("annie", "annie", "Annie"), "casing differs, Pass 0 still corrects it")
    #expect(intercepts("annie", "annie", "Anika"), "different word, Pass 0 substitutes")

    // Punctuation is stripped before the comparison, so this is still "already
    // correct" and still declines.
    #expect(intercepts("annie", "\"Annie\"", "Annie") == false)

    // Pass 0 never looks up fewer than three characters.
    #expect(intercepts("ny", "ny", "Elsewhere") == false)

    // Pass 0 concatenates at most three tokens.
    #expect(intercepts("onetwothreefour", "one two three four", "Elsewhere") == false)

    // Surrounding whitespace is not part of that window, but interior doubled
    // spaces are: the tokenizer really does see an extra empty token there.
    #expect(intercepts("onetwo", " one two ", "Elsewhere"))
    #expect(intercepts("onetwo", "one   two", "Elsewhere") == false)

    // Reserved trigger words are skipped wholesale.
    #expect(intercepts("oneemoji", "one emoji", "Elsewhere") == false)

    // The ordinary namespaces have no such gate: holding is intercepting.
    #expect(
      WordCorrector.ownerIntercepts(
        claim: .init(key: "annie", namespace: .single),
        rawSurface: "Annie",
        owner: .init(wordID: UUID(), canonical: "Annie", isPack: false)))
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
    #expect(
      WordCorrector.ExactTriggerNamespace.nospace.passPriority
        < WordCorrector.ExactTriggerNamespace.multi.passPriority)
    #expect(
      WordCorrector.ExactTriggerNamespace.multi.passPriority
        < WordCorrector.ExactTriggerNamespace.single.passPriority)
  }

  // MARK: - resolveAliasOwnership (#1672)
  //
  // The shared decision both `CustomWordsImportCompareEngine` and
  // `CustomWordsManager` call instead of each hand-rolling their own blocker
  // detection and decisive-owner selection.

  @Test("resolveAliasOwnership returns blocked when a single alias-holder intercepts")
  func resolveAliasOwnershipBlockedBySingleHolder() {
    let owner = CustomWord(canonical: "Anika", aliases: ["annie"])
    let index = WordCorrector.buildExactTriggerIndex(words: [owner])
    let ownerID = try! #require(index.single["annie"]?.wordID)

    let resolution = index.resolveAliasOwnership(for: "Annie", excludingOwnerID: UUID())
    #expect(resolution == .blocked(by: .init(wordID: ownerID, canonical: "Anika", isPack: false)))
  }

  @Test("resolveAliasOwnership returns available when nobody holds the key")
  func resolveAliasOwnershipAvailableWhenUnclaimed() {
    let index = WordCorrector.buildExactTriggerIndex(words: [CustomWord(canonical: "Anika")])
    let resolution = index.resolveAliasOwnership(for: "Zed", excludingOwnerID: UUID())
    guard case .available(let claims) = resolution else {
      Issue.record("expected .available, got \(resolution)")
      return
    }
    #expect(!claims.isEmpty)
  }

  @Test("resolveAliasOwnership excludes the given owner id from counting as a blocker")
  func resolveAliasOwnershipExcludesOwnOwner() {
    let owner = CustomWord(canonical: "Anika", aliases: ["annie"])
    let index = WordCorrector.buildExactTriggerIndex(words: [owner])
    let ownerID = try! #require(index.single["annie"]?.wordID)

    let resolution = index.resolveAliasOwnership(for: "Annie", excludingOwnerID: ownerID)
    guard case .available = resolution else {
      Issue.record("expected .available when excluding the key's own holder, got \(resolution)")
      return
    }
  }

  @Test("resolveAliasOwnership returns noClaims for an empty alias")
  func resolveAliasOwnershipNoClaimsForEmptyAlias() {
    // `exactClaims(forAlias:)` lowercases but does NOT trim whitespace — a
    // whitespace-only alias like "   " is NOT empty after lowercasing and
    // yields a real `.multi` claim, not `.noClaims`. Only the literal empty
    // string produces zero claims.
    let index = WordCorrector.ExactTriggerIndex()
    #expect(index.resolveAliasOwnership(for: "", excludingOwnerID: UUID()) == .noClaims)
  }

  @Test("resolveAliasOwnership names the earliest-intercepting namespace's owner")
  func resolveAliasOwnershipPrefersEarliestNamespace() {
    // "New York" claims both the .multi surface ("new york") and the .nospace
    // surface ("newyork"). Register two DIFFERENT owners on those two keys, so
    // whichever one the resolution names proves which namespace actually wins.
    let multiOwner = WordCorrector.TriggerOwner(
      wordID: UUID(), canonical: "Multi Owner", isPack: false)
    let nospaceOwner = WordCorrector.TriggerOwner(
      wordID: UUID(), canonical: "Nospace Owner", isPack: false)

    var index = WordCorrector.ExactTriggerIndex()
    index.register(.init(key: "new york", namespace: .multi), to: multiOwner)
    index.register(.init(key: "newyork", namespace: .nospace), to: nospaceOwner)

    let resolution = index.resolveAliasOwnership(for: "New York", excludingOwnerID: UUID())
    #expect(resolution == .blocked(by: nospaceOwner), "nospace runs Pass 0, before multi's Pass 1")
  }

  @Test("resolveAliasOwnership skips a non-intercepting holder and finds the real blocker")
  func resolveAliasOwnershipSkipsNonInterceptingHolder() {
    // The no-space owner's OWN canonical already spells the surface, so Pass 0
    // declines to substitute (`ownerIntercepts`) — the real blocker is the
    // .multi owner, which DOES intercept.
    let nospaceOwner = WordCorrector.TriggerOwner(
      wordID: UUID(), canonical: "New York", isPack: false)
    let multiOwner = WordCorrector.TriggerOwner(
      wordID: UUID(), canonical: "Other Word", isPack: false)

    var index = WordCorrector.ExactTriggerIndex()
    index.register(.init(key: "newyork", namespace: .nospace), to: nospaceOwner)
    index.register(.init(key: "new york", namespace: .multi), to: multiOwner)

    let resolution = index.resolveAliasOwnership(for: "New York", excludingOwnerID: UUID())
    #expect(
      resolution == .blocked(by: multiOwner),
      "the declining no-space holder must not shadow the real, intercepting blocker")
  }
}
