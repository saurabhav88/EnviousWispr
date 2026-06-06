import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprPostProcessing

/// #992 — vocabulary-pack two-tier fuzzy matching.
///
/// Pack-sourced terms now participate in the matcher's fuzzy passes, but in a
/// SECOND tier that runs only after every non-pack (user/builtin) fuzzy pass
/// misses (structural "user/builtin always wins"), only for single-word terms
/// whose scored surface is >= `packFuzzyMinLength`, with a stricter score bar
/// and a casing guard. Short pack terms stay exact-only. Supersedes the
/// exact-only safety suite (the parked design that almost never fired).
@Suite("Vocabulary Pack — two-tier fuzzy (length-gated, user-precedence)")
struct VocabularyPackTests {

  private func packWord(_ canonical: String, _ aliases: [String]) -> CustomWord {
    CustomWord(canonical: canonical, aliases: aliases, source: .pack)
  }
  private func userWord(_ canonical: String, _ aliases: [String]) -> CustomWord {
    CustomWord(canonical: canonical, aliases: aliases, source: .user)
  }

  // MARK: - Freeze: which pools a pack term enters

  @Test("long pack term enters the PACK fuzzy pools, never the non-pack pools")
  func longPackTermInPackPoolsOnly() {
    let lookups = WordCorrector.buildLookups(words: [packWord("Kubernetes", ["coobernetties"])])
    // Exact maps still carry the pack alias (Pass 1/3 exact).
    #expect(lookups.singleAliasMap["coobernetties"] == "Kubernetes")
    // #992: pack canonical self-entry is DROPPED (was the casing-harm source).
    #expect(lookups.singleAliasMap["kubernetes"] == nil)
    // Pack term is in the PACK fuzzy pools (>= 7 chars).
    #expect(lookups.packSingleFuzzyCandidates.contains { $0.surface == "coobernetties" })
    #expect(lookups.packCanonicals.contains("Kubernetes"))
    // ...and NOT in the non-pack fuzzy pools (no user/builtin terms here).
    #expect(lookups.singleFuzzyCandidates.isEmpty)
    #expect(lookups.canonicals.isEmpty)
    #expect(lookups.nospaceCanonicalMap.isEmpty)
  }

  @Test("short pack term stays exact-only — absent from ALL fuzzy pools")
  func shortPackTermExactOnly() {
    // canonical "Go" (2), alias "goh" (3): both below packFuzzyMinLength (7).
    let lookups = WordCorrector.buildLookups(words: [packWord("Go", ["goh"])])
    #expect(lookups.singleAliasMap["goh"] == "Go")  // exact still works
    #expect(lookups.packSingleFuzzyCandidates.isEmpty)
    #expect(lookups.packCanonicals.isEmpty)
  }

  @Test("non-pack terms still populate the NON-pack fuzzy pools, not the pack ones")
  func nonPackTermsPopulateNonPackPools() {
    let lookups = WordCorrector.buildLookups(words: [userWord("Kubernetes", ["coobernetties"])])
    #expect(!lookups.singleFuzzyCandidates.isEmpty)
    #expect(!lookups.canonicals.isEmpty)
    #expect(lookups.packSingleFuzzyCandidates.isEmpty)
    #expect(lookups.packCanonicals.isEmpty)
  }

  @Test("normalization parity: the length gate counts the lowercased scored surface")
  func lengthGateNormalizationParity() {
    // 7-char alias once lowercased -> included; 6-char alias -> excluded.
    let lookups = WordCorrector.buildLookups(
      words: [packWord("Canonicalterm", ["ABCDEFG", "ABCDEF"])])
    #expect(lookups.packSingleFuzzyCandidates.contains { $0.surface == "abcdefg" })
    #expect(!lookups.packSingleFuzzyCandidates.contains { $0.surface == "abcdef" })
  }

  // MARK: - Two-tier behaviour

  @Test("long pack ALIAS near-miss now corrects (pack Pass 4 fuzzy)")
  func longPackAliasNearMissCorrects() {
    // "coobernetties" (alias, 13) -> near-miss "coobernettie" (12): now fuzzy-fires.
    let r = WordCorrector().correct(
      "coobernettie", against: [packWord("Kubernetes", ["coobernetties"])])
    #expect(r.corrected == "Kubernetes")
  }

  @Test("long pack CANONICAL near-miss now corrects (pack Pass 5 fuzzy)")
  func longPackCanonicalNearMissCorrects() {
    // No alias matches; canonical "Kubernetes" (10) reached via pack Pass 5.
    let r = WordCorrector().correct(
      "kubernetis", against: [packWord("Kubernetes", ["zzzzzzz"])])
    #expect(r.corrected == "Kubernetes")
  }

  @Test("SHORT pack term near-miss does NOT correct (still exact-only)")
  func shortPackTermNearMissDoesNotCorrect() {
    // "goh" alias, "gow" near-miss — short term, never enters the fuzzy tier.
    let r = WordCorrector().correct("gow", against: [packWord("Go", ["goh"])])
    #expect(r.corrected == "gow")
  }

  @Test("pack alias still corrects on an exact hit")
  func packAliasExactHit() {
    let r = WordCorrector().correct(
      "coobernetties", against: [packWord("Kubernetes", ["coobernetties"])])
    #expect(r.corrected == "Kubernetes")
  }

  @Test("duplicate pack canonicals across packs do NOT self-compete (Pass 5)")
  func duplicatePackCanonicalStillCorrects() {
    // The same canonical can ship in two enabled packs (real case: "miralax" in
    // medical+brands). Without de-dup the duplicate is its own runner-up, the
    // best-vs-second margin collapses to 0, and a valid canonical fuzzy match is
    // wrongly rejected. Two identical pack canonicals, no aliases -> near-miss
    // must still correct.
    let words = [packWord("Kubernetes", []), packWord("Kubernetes", [])]
    let r = WordCorrector().correct("kubernetis", against: words)
    #expect(r.corrected == "Kubernetes")
  }

  @Test("6-char pack term is gated out of the fuzzy pools (length gate isolated)")
  func sixCharPackBoundaryGatedOut() {
    // canonical "docker" (6) + alias "dokker" (6): both below packFuzzyMinLength
    // (7). Isolate the GATE (not the score) by asserting they never enter the
    // pack fuzzy pools at build time — pool emptiness IS the gate's effect. The
    // runtime no-fire is then a corollary, not the proof. (A pure runtime check
    // can't isolate the gate: a 6-char near-miss fails the score bar anyway.)
    let lookups = WordCorrector.buildLookups(words: [packWord("docker", ["dokker"])])
    #expect(lookups.packCanonicals.isEmpty)
    #expect(lookups.packSingleFuzzyCandidates.isEmpty)
    #expect(WordCorrector().correct("dockor", using: lookups).corrected == "dockor")
  }

  // MARK: - Casing guard

  @Test("correctly-cased input matching a (lowercase) pack canonical is NOT downcased")
  func casingGuardSuppressesCaseOnlyChange() {
    // Pack canonicals ship lowercase; a correctly-typed "Ameritrade" must survive.
    let r = WordCorrector().correct(
      "Ameritrade", against: [packWord("ameritrade", ["meritrayed"])])
    #expect(r.corrected == "Ameritrade")
  }

  @Test("a genuine alias mishear still corrects to the (lowercase) canonical")
  func genuineAliasStillCorrectsDespiteCasingGuard() {
    // "meritrad" (8) is a fuzzy near-miss of alias "meritrayed"? Use canonical path:
    // input near the canonical but differing by more than case -> corrects.
    let r = WordCorrector().correct(
      "ameritrad", against: [packWord("ameritrade", ["meritrayed"])])
    #expect(r.corrected == "ameritrade")
  }

  // MARK: - Precedence: user/builtin always wins (exact AND fuzzy)

  @Test("user alias wins over pack alias (same alias key)")
  func userAliasOverPackAlias() {
    let words = [packWord("PackWord", ["foobarbaz"]), userWord("UserWord", ["foobarbaz"])]
    let r = WordCorrector().correct("foobarbaz", against: words)
    #expect(r.corrected == "UserWord")
  }

  @Test("user canonical wins over pack alias (pack alias == user canonical)")
  func userCanonicalOverPackAlias() {
    let words = [packWord("PackTarget", ["elixirlang"]), userWord("elixirlang", [])]
    let r = WordCorrector().correct("elixirlang", against: words)
    #expect(r.corrected == "elixirlang")  // user canonical not hijacked
  }

  @Test("user alias wins over pack canonical (user alias == pack canonical)")
  func userAliasOverPackCanonical() {
    let words = [packWord("rediscache", []), userWord("Redux", ["rediscache"])]
    let r = WordCorrector().correct("rediscache", against: words)
    #expect(r.corrected == "Redux")
  }

  @Test("user FUZZY match wins even when a pack term is the closer (exact) candidate")
  func userFuzzyBeatsCloserPack() {
    // Input "mixpanal" is EXACT to the pack canonical "Mixpanal" but a 1-edit
    // fuzzy of the user canonical "Mixpanel". The whole non-pack tier runs first,
    // so the user's fuzzy match fires and the pack term never gets a turn.
    let words = [packWord("Mixpanal", []), userWord("Mixpanel", [])]
    let r = WordCorrector().correct("mixpanal", against: words)
    #expect(r.corrected == "Mixpanel")
  }

  @Test("multi-word user canonical is NOT hijacked by a pack multi-word alias")
  func multiWordUserCanonicalWins() {
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
    #expect(a != d)
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

/// #992 — real bundled pack data: proves the shipped JSON loads and that the
/// two-tier fuzzy tier (a) fires on real mined data and (b) does NOT rewrite
/// everyday or multilingual dictation. The negative-corpus test is the primary
/// safety proof and the constant-tuning target (NOT the dogfood set — avoids
/// overfitting). Everyday/multilingual inputs are drawn from the polish eval
/// corpus `scripts/eval/corpus/ci_corpus.jsonl` (clean-noop / language-
/// preservation / named-entity categories).
@Suite("Vocabulary Pack — real bundled data")
struct BundledVocabularyPackTests {

  /// All 5 packs flattened (no user/builtin terms), so ANY correction is
  /// pack-sourced and `corrected != input` means a pack rewrite fired.
  private func allPackTerms() -> [CustomWord] {
    let store = VocabularyPackStore()
    return VocabularyPackID.allCases.compactMap { store.load($0) }.flatMap(\.terms)
  }

  @Test("all five packs resolve in the module bundle")
  func allPacksResolve() {
    let available = Set(VocabularyPackStore().availablePackIDs())
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
    }
  }

  @Test("a real alias from each pack corrects to its canonical (exact)")
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

  /// Two-tier fuzzy fires on REAL data: a 1-char near-miss of a long (>=8) real
  /// alias corrects to its canonical through the pack fuzzy tier.
  @Test("a near-miss of a long real pack alias corrects via the fuzzy tier")
  func realAliasNearMissNowCorrects() {
    let store = VocabularyPackStore()
    guard let pack = store.load(.tech),
      let sample = pack.terms.first(where: {
        ($0.aliases.first(where: { $0.count >= 8 && !$0.contains(" ") }) != nil)
      }),
      let alias = sample.aliases.first(where: { $0.count >= 8 && !$0.contains(" ") })
    else {
      Issue.record("tech pack produced no single-word alias >= 8 chars for a near-miss probe")
      return
    }
    let nearMiss = String(alias.dropLast())
    let result = WordCorrector().correct(nearMiss, against: pack.terms)
    #expect(
      result.corrected == sample.canonical,
      "near-miss '\(nearMiss)' should fuzzy-correct to '\(sample.canonical)', got '\(result.corrected)'"
    )
  }

  /// Sampled false-positive regression guard + cross-language measurement
  /// (measure-first decision). Everyday English + multilingual + named-entity
  /// dictation, run against ALL five real packs, must produce ZERO rewrites.
  /// This is a sampled guard, not exhaustive — duplicate-canonical, real-word
  /// pack-canonical, and length-boundary cases are covered by the synthetic
  /// suite above. Source: scripts/eval/corpus/ci_corpus.jsonl.
  @Test("everyday + multilingual dictation gets ZERO pack rewrites")
  func negativeCorpusNoFalsePositives() {
    let terms = allPackTerms()
    #expect(!terms.isEmpty, "no pack terms loaded — bundle problem")
    let corrector = WordCorrector()
    let lookups = WordCorrector.buildLookups(words: terms)

    // Everyday + multilingual + named-entity sentences (ci_corpus.jsonl).
    let negatives = [
      "Let's sync tomorrow at ten to review the API changes.",
      "The roadmap review is pushed to Thursday.",
      "Patient denies chest pain but reports mild shortness of breath.",
      "The second chapter needs another pass before the deadline on Friday.",
      "The sample size for cohort B was smaller than the pre-registered power analysis required.",
      "The CI runner finished in under three minutes.",
      "Marketing wants the demo video before end of quarter.",
      "Follow-up in six weeks or sooner if symptoms worsen.",
      "Her voice carried across the empty room like a held breath.",
      "The effect size held up under the robustness checks we added in revision two.",
      "So um the migration script you know it failed on row like forty two thousand I think",
      "okay so basically the auth token was expired which is why like every request was four oh one",
      "Let's deploy to staging actually let's deploy to prod directly since staging is broken",
      "The team in Madrid said the feature is listo for launch but quieren more time on QA",
      "I was talking to Rahul and he said the build pipeline theek hai now but we should double check",
      "The protagonist says wabi sabi to describe the cracked bowl she keeps on her desk",
      "Saurabh asked me to deploy EnviousWispr to the new mac mini for testing",
      "The Figma file lives in our Notion workspace under the Q3 roadmap page",
      "Dr. Patel prescribed metformin five hundred milligrams twice daily for the patient",
      "The dataset from Stanford HAI combined with the MIT Technology Review study",
      "were you able to push the fix i'm blocked on the ci passing",
      "the api returns json but the client expects xml we need to add a transformer",
      "participants were randomized into three arms placebo low dose and high dose",
      "Neither of the characters are truly sympathetic at the start",
    ]

    var rewrites: [(input: String, output: String)] = []
    for sentence in negatives {
      let out = corrector.correct(sentence, using: lookups).corrected
      // Normalize whitespace the way the corrector does before comparing.
      let inNorm = sentence.components(separatedBy: .whitespaces).joined(separator: " ")
      if out != inNorm { rewrites.append((sentence, out)) }
    }
    let detail = rewrites.map { "[\($0.input)] -> [\($0.output)]" }.joined(separator: " | ")
    #expect(
      rewrites.isEmpty,
      "pack fuzzy rewrote everyday/multilingual text (false positives): \(detail)")
  }
}
