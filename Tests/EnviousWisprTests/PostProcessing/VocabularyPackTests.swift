import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprPostProcessing

/// #633 Phase 9 — vocabulary-pack runtime safety guarantees.
///
/// The load-bearing invariant: pack-sourced terms are EXACT-MATCH ONLY. A pack
/// alias/canonical may correct only on an exact hit; a near-miss must never
/// trigger a fuzzy correction (which would silently rewrite legitimate text).
@Suite("Vocabulary Pack — exact-only safety")
struct VocabularyPackTests {

  private func packWord(_ canonical: String, _ aliases: [String]) -> CustomWord {
    CustomWord(canonical: canonical, aliases: aliases, source: .pack)
  }
  private func userWord(_ canonical: String, _ aliases: [String]) -> CustomWord {
    CustomWord(canonical: canonical, aliases: aliases, source: .user)
  }

  // MARK: - Freeze: pack terms never enter any fuzzy/compound pool

  @Test("pack alias and canonical are absent from every fuzzy/compound pool")
  func packTermsExcludedFromFuzzyPools() {
    let lookups = WordCorrector.buildLookups(words: [packWord("Kubernetes", ["coobernetties"])])
    // Exact maps DO carry the pack term.
    #expect(lookups.singleAliasMap["coobernetties"] == "Kubernetes")
    #expect(lookups.singleAliasMap["kubernetes"] == "Kubernetes")  // canonical self-entry (casing)
    // Fuzzy / compound / Pass-5 canonical pools are empty (no non-pack terms).
    #expect(lookups.singleFuzzyCandidates.isEmpty)
    #expect(lookups.multiAliasByCount.isEmpty)
    #expect(lookups.nospaceCanonicalMap.isEmpty)
    #expect(lookups.canonicals.isEmpty)
    #expect(lookups.lowercasedCanonicals.isEmpty)
  }

  @Test("non-pack terms still populate the fuzzy pools")
  func nonPackTermsPopulateFuzzyPools() {
    let lookups = WordCorrector.buildLookups(words: [userWord("Kubernetes", ["coobernetties"])])
    #expect(!lookups.singleFuzzyCandidates.isEmpty)
    #expect(!lookups.canonicals.isEmpty)
  }

  // MARK: - Exact-only matching behaviour

  @Test("pack alias corrects on exact hit")
  func packAliasExactHit() {
    let r = WordCorrector().correct(
      "coobernetties", against: [packWord("Kubernetes", ["coobernetties"])])
    #expect(r.corrected == "Kubernetes")
  }

  @Test("pack alias does NOT correct on a near-miss (no fuzzy leak)")
  func packAliasNearMissDoesNotCorrect() {
    // One char dropped — would fuzzy-match if pack terms were in the fuzzy pool.
    let r = WordCorrector().correct(
      "coobernettie", against: [packWord("Kubernetes", ["coobernetties"])])
    #expect(r.corrected == "coobernettie")
  }

  @Test("pack canonical does NOT correct on a near-miss (no Pass-5 leak)")
  func packCanonicalNearMissDoesNotCorrect() {
    let r = WordCorrector().correct(
      "kubernete", against: [packWord("Kubernetes", ["coobernetties"])])
    #expect(r.corrected == "kubernete")
  }

  @Test("same near-miss DOES correct for a user term (proves the difference)")
  func userTermNearMissStillCorrects() {
    let r = WordCorrector().correct(
      "coobernettie", against: [userWord("Kubernetes", ["coobernetties"])])
    #expect(r.corrected == "Kubernetes")
  }

  // MARK: - Precedence: non-pack always wins on key clash

  @Test("user alias wins over pack alias (same alias key)")
  func userAliasOverPackAlias() {
    let words = [packWord("PackWord", ["foo"]), userWord("UserWord", ["foo"])]
    let r = WordCorrector().correct("foo", against: words)
    #expect(r.corrected == "UserWord")
  }

  @Test("user canonical wins over pack alias (pack alias == user canonical)")
  func userCanonicalOverPackAlias() {
    // Pack wants "elixir" -> "PackTarget"; user has canonical "elixir".
    let words = [packWord("PackTarget", ["elixir"]), userWord("elixir", [])]
    let r = WordCorrector().correct("elixir", against: words)
    #expect(r.corrected == "elixir")  // user canonical not hijacked
  }

  @Test("user alias wins over pack canonical (user alias == pack canonical)")
  func userAliasOverPackCanonical() {
    // User maps "redis" -> "Redux"; pack canonical is "redis".
    let words = [packWord("redis", []), userWord("Redux", ["redis"])]
    let r = WordCorrector().correct("redis", against: words)
    #expect(r.corrected == "Redux")
  }

  @Test("multi-word user canonical is NOT hijacked by a pack multi-word alias")
  func multiWordUserCanonicalWins() {
    // User has the multi-word canonical "machine learning" (no alias); a pack
    // multi-word alias "machine learning" -> "MachineLearning" must not claim
    // it. (Codex precedence edge — multi-word user canonicals get no exact-map
    // self-entry, so the nonPackCanonicalKeys guard is what protects them.)
    let words = [
      packWord("MachineLearning", ["machine learning"]), userWord("machine learning", []),
    ]
    let r = WordCorrector().correct("machine learning", against: words)
    #expect(r.corrected == "machine learning")
  }

  // MARK: - Deterministic identity

  @Test("deterministic pack UUID is stable and distinct per canonical")
  func deterministicPackID() {
    let a = VocabularyPackStore.deterministicID(packID: .tech, canonical: "kubernetes")
    let b = VocabularyPackStore.deterministicID(packID: .tech, canonical: "kubernetes")
    let c = VocabularyPackStore.deterministicID(packID: .tech, canonical: "postgres")
    let d = VocabularyPackStore.deterministicID(packID: .medical, canonical: "kubernetes")
    #expect(a == b)
    #expect(a != c)
    #expect(a != d)  // pack id participates in the seed
  }

  // MARK: - Lane split: pack terms never reach the polish lane

  @MainActor
  @Test("pack terms are in the corrector lane but absent from the polish lane")
  func packTermsCorrectorOnly() {
    let words = [userWord("Redux", ["redex"]), packWord("Kubernetes", ["coobernetties"])]
    let lanes = LanePartitioner.split(words, generation: 1)
    #expect(lanes.corrector.terms.count == 2)
    #expect(lanes.polish.terms.count == 1)
    #expect(lanes.polish.terms.allSatisfy { $0.source != .pack })
    #expect(lanes.corrector.terms.contains { $0.source == .pack })
  }
}

/// #633 Phase 9 — proves the ACTUAL shipped pack JSON files load from the
/// module bundle and correct end-to-end through the real `WordCorrector`.
///
/// This is the regression guard for the failure that killed the prior pack
/// attempt (#653/#654): the matcher logic passed its fixture tests, but the
/// pack files never made it into the bundle, so nothing fired at runtime. The
/// fixture suite above uses hand-built `CustomWord`s and cannot see that gap.
/// This suite uses the production `VocabularyPackStore()` (Bundle.module) so a
/// missing-resource regression fails the test target, not the user.
@Suite("Vocabulary Pack — real bundled data")
struct BundledVocabularyPackTests {

  @Test("all five packs resolve in the module bundle")
  func allPacksResolve() {
    let store = VocabularyPackStore()
    let available = Set(store.availablePackIDs())
    for id in VocabularyPackID.allCases {
      #expect(available.contains(id), "pack '\(id.rawValue)' missing from bundle")
    }
  }

  @Test("every bundled pack loads non-empty terms with aliases")
  func packsLoadNonEmpty() {
    let store = VocabularyPackStore()
    for id in VocabularyPackID.allCases {
      guard let pack = store.load(id) else {
        Issue.record("pack '\(id.rawValue)' failed to load from bundle")
        continue
      }
      #expect(!pack.terms.isEmpty, "pack '\(id.rawValue)' has no terms")
      #expect(pack.terms.allSatisfy { $0.source == .pack })
      #expect(
        pack.terms.contains { !$0.aliases.isEmpty },
        "pack '\(id.rawValue)' has no aliases to correct against")
    }
  }

  /// The load-bearing end-to-end assertion: a real mined alias from each
  /// shipped pack, fed through the real corrector, produces the canonical.
  /// Data-change resilient — it pulls the first real (canonical, alias) pair
  /// from each pack rather than hardcoding strings.
  @Test("a real alias from each pack corrects to its canonical")
  func realAliasCorrectsEndToEnd() {
    let store = VocabularyPackStore()
    for id in VocabularyPackID.allCases {
      guard let pack = store.load(id),
        let sample = pack.terms.first(where: { !$0.aliases.isEmpty }),
        let alias = sample.aliases.first
      else {
        Issue.record("pack '\(id.rawValue)' produced no usable (canonical, alias) sample")
        continue
      }
      let result = WordCorrector().correct(alias, against: pack.terms)
      #expect(
        result.corrected == sample.canonical,
        "pack '\(id.rawValue)': '\(alias)' should correct to '\(sample.canonical)', got '\(result.corrected)'"
      )
    }
  }

  /// Exact-only safety on REAL data: drop the last character of a real alias;
  /// the near-miss must NOT correct (no fuzzy leak from bundled pack terms).
  @Test("a near-miss of a real pack alias does not correct")
  func realAliasNearMissDoesNotCorrect() {
    let store = VocabularyPackStore()
    guard let pack = store.load(.tech),
      let sample = pack.terms.first(where: { ($0.aliases.first?.count ?? 0) >= 5 }),
      let alias = sample.aliases.first
    else {
      Issue.record("tech pack produced no alias long enough for a near-miss probe")
      return
    }
    let nearMiss = String(alias.dropLast())
    let result = WordCorrector().correct(nearMiss, against: pack.terms)
    #expect(
      result.corrected == nearMiss,
      "near-miss '\(nearMiss)' must not correct, but got '\(result.corrected)'")
  }
}
