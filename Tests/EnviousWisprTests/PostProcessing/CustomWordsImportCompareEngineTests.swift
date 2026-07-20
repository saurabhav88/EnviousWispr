import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #1661 (PR-F2a) — compare/dedup engine. Pure classification coverage: the
/// engine takes the library as a value snapshot, so every test is hermetic.
/// The adversarial fuzzy pairs (Saurabh/Sarah, OpenAI/OpenAPI, C++/C#) are
/// the acceptance bar for the founder's pending threshold decision (bible §8
/// risk register): the mock-up's unvalidated placeholder (length ≥5,
/// distance ≤3) FAILS that bar, which is frozen below as documentation.
@Suite("CustomWordsImportCompareEngine")
struct CustomWordsImportCompareEngineTests {

  // MARK: - Helpers

  private func word(
    _ canonical: String, aliases: [String] = [], id: UUID = UUID()
  ) -> CustomWord {
    CustomWord(id: id, canonical: canonical, aliases: aliases)
  }

  private func candidate(
    _ canonical: String,
    aliases: CustomWordsImportField<[String]> = .unspecified,
    id: UUID = UUID()
  ) -> CustomWordsImportCandidate {
    CustomWordsImportCandidate(id: id, canonical: canonical, aliases: aliases)
  }

  private func compare(
    _ candidates: [CustomWordsImportCandidate],
    against existing: [CustomWord],
    policy: CustomWordsImportFuzzyPolicy = .disabled
  ) async throws -> [CustomWordsImportComparison] {
    try await CustomWordsImportCompareEngine().compare(
      candidates: candidates, against: existing, fuzzyPolicy: policy)
  }

  /// A conservative candidate policy that PASSES the adversarial bar:
  /// length ≥7 excludes OpenAI (6) and Sarah (5); distance ≤1 excludes
  /// Saurabh→Sarah (2) independently.
  private static let conservativeCandidatePolicy = CustomWordsImportFuzzyPolicy(
    minimumLength: 7, maximumEditDistance: 1)

  /// The mock-up's unvalidated placeholder (bible §5.3). Ships nowhere as-is.
  private static let mockupPlaceholderPolicy = CustomWordsImportFuzzyPolicy(
    minimumLength: 5, maximumEditDistance: 3)

  // MARK: - Classification basics

  @Test("unknown canonical classifies new")
  func newCanonicalClassifiesNew() async throws {
    let results = try await compare(
      [candidate("Qualtrics")], against: [word("Claude Code")])
    #expect(results.count == 1)
    #expect(results[0].classification == .new)
    #expect(results[0].collidingAliases.isEmpty)
  }

  @Test("case and whitespace variations classify exact")
  func caseAndWhitespaceCanonicalClassifiesExact() async throws {
    let existing = word("Claude Code")
    let results = try await compare(
      [candidate("  claude   CODE ")], against: [existing])
    #expect(results[0].classification == .exact(existing: existing))
  }

  @Test("canonical matching an existing alias classifies variant with the matched alias")
  func canonicalMatchingExistingAliasClassifiesVariant() async throws {
    let existing = word("Parvati", aliases: ["Pavarthi", "Parvathi"])
    let results = try await compare([candidate("pavarthi")], against: [existing])
    #expect(
      results[0].classification == .variant(existing: existing, matchedAlias: "Pavarthi"))
  }

  @Test("composed and decomposed unicode forms classify exact")
  func unicodeComposedAndDecomposedFormsClassifyExact() async throws {
    let existing = word("caf\u{00E9}")  // é precomposed
    let results = try await compare(
      [candidate("cafe\u{0301}")], against: [existing])  // e + combining acute
    #expect(results[0].classification == .exact(existing: existing))
  }

  // MARK: - Fuzzy

  @Test("one-edit canonical classifies fuzzy when policy allows")
  func oneEditCanonicalClassifiesFuzzyWhenPolicyAllows() async throws {
    let existing = word("Kubernetes")
    let results = try await compare(
      [candidate("Kubernetez")], against: [existing],
      policy: CustomWordsImportFuzzyPolicy(minimumLength: 5, maximumEditDistance: 1))
    #expect(results[0].classification == .fuzzy(existing: existing, distance: 1))
  }

  @Test("a fuzzy match of different length is found across length buckets")
  func fuzzyMatchOfDifferentLengthIsFoundAcrossBuckets() async throws {
    // The library side is bucketed by length for speed. Every other fuzzy
    // test compares equal-length words, so all of them would still pass if
    // bucketing only ever looked at the candidate's own bucket — this one
    // fails in that case. Deletion (9 chars vs 10) and insertion (11 vs 10).
    let shorter = CustomWord(canonical: "Kubernete")
    let longer = CustomWord(canonical: "Kuberneteses")
    let policy = CustomWordsImportFuzzyPolicy(minimumLength: 5, maximumEditDistance: 1)

    let deletion = try await compare(
      [candidate("Kubernetes")], against: [shorter], policy: policy)
    #expect(deletion[0].classification == .fuzzy(existing: shorter, distance: 1))

    let insertion = try await compare(
      [candidate("Kubernetese")], against: [longer], policy: policy)
    #expect(insertion[0].classification == .fuzzy(existing: longer, distance: 1))
  }

  @Test("an extreme maximum distance does not trap")
  func extremeMaximumEditDistanceDoesNotTrap() async throws {
    // `.disabled` already uses `minimumLength: .max`, so extreme values are
    // in this type's vocabulary; the symmetric distance value must not crash.
    let policy = CustomWordsImportFuzzyPolicy(minimumLength: 1, maximumEditDistance: .max)
    let empty = try await compare([candidate("Kubernetes")], against: [], policy: policy)
    #expect(empty[0].classification == .new)

    let existing = CustomWord(canonical: "Kubernetez")
    let populated = try await compare(
      [candidate("Kubernetes")], against: [existing], policy: policy)
    #expect(populated[0].classification == .fuzzy(existing: existing, distance: 1))
  }

  @Test("a length gap wider than the maximum distance is never a fuzzy match")
  func lengthGapWiderThanMaximumDistanceNeverMatches() async throws {
    let results = try await compare(
      [candidate("Kubernetes")], against: [CustomWord(canonical: "Kubern")],
      policy: CustomWordsImportFuzzyPolicy(minimumLength: 5, maximumEditDistance: 2))
    #expect(results[0].classification == .new)
  }

  @Test("candidate below the minimum length never fuzzy-matches")
  func shortCandidateNeverFuzzyMatches() async throws {
    let results = try await compare(
      [candidate("Kube")], against: [word("Kubz")],
      policy: CustomWordsImportFuzzyPolicy(minimumLength: 5, maximumEditDistance: 2))
    #expect(results[0].classification == .new)
  }

  @Test("fuzzy boundary: exactly the maximum distance matches")
  func fuzzyBoundaryAtMaximumDistanceMatches() async throws {
    let existing = word("Kubernetes")
    // Kubernetes -> Kubernetiz: two substitutions.
    let results = try await compare(
      [candidate("Kubernetiz")], against: [existing],
      policy: CustomWordsImportFuzzyPolicy(minimumLength: 5, maximumEditDistance: 2))
    #expect(results[0].classification == .fuzzy(existing: existing, distance: 2))
  }

  @Test("fuzzy boundary: one past the maximum distance does not match")
  func fuzzyBoundaryBeyondMaximumDistanceDoesNotMatch() async throws {
    let results = try await compare(
      [candidate("Kubernetiz")], against: [word("Kubernetes")],
      policy: CustomWordsImportFuzzyPolicy(minimumLength: 5, maximumEditDistance: 1))
    #expect(results[0].classification == .new)
  }

  @Test("disabled policy never fuzzy-matches anything")
  func disabledPolicyNeverFuzzyMatches() async throws {
    let results = try await compare(
      [candidate("Kubernetez")], against: [word("Kubernetes")], policy: .disabled)
    #expect(results[0].classification == .new)
  }

  // MARK: - Punctuation and adversarial pairs

  @Test("technical punctuation stays distinct: no exact, variant, or fuzzy collapse")
  func technicalPunctuationRemainsDistinct() async throws {
    let library = [word("C"), word("C++"), word("C#"), word(".NET"), word("node.js")]
    // Even under a deliberately permissive policy, punctuation excludes the
    // fuzzy path (letters-only rule), and normalization never strips it.
    let permissive = CustomWordsImportFuzzyPolicy(minimumLength: 1, maximumEditDistance: 3)
    let results = try await compare(
      [candidate("C++"), candidate("C#"), candidate("nodejs")],
      against: library, policy: permissive)
    #expect(results[0].classification == .exact(existing: library[1]))  // C++ is itself,
    #expect(results[1].classification == .exact(existing: library[2]))  // never C#
    // "nodejs" is letters-only, but "node.js" is not, so fuzzy is excluded
    // from BOTH sides and no other stage matches.
    #expect(results[2].classification == .new)
  }

  @Test("adversarial brand pairs do not match under the conservative candidate policy")
  func adversarialBrandPairsDoNotMatchUnderConservativePolicy() async throws {
    let results = try await compare(
      [candidate("Saurabh"), candidate("OpenAI")],
      against: [word("Sarah"), word("OpenAPI")],
      policy: Self.conservativeCandidatePolicy)
    #expect(results[0].classification == .new)
    #expect(results[1].classification == .new)
  }

  @Test("documentation: the mock-up placeholder policy fails the adversarial bar")
  func mockupPlaceholderPolicyFailsTheAdversarialBar() async throws {
    // Frozen as evidence for the pending founder threshold decision: under
    // the demo's (≥5, ≤3) placeholder, both real-world distinct pairs are
    // flagged as fuzzy duplicates. This freezes WHY the placeholder cannot
    // ship uncalibrated; it does not bless the behavior.
    let sarah = word("Sarah")
    let openAPI = word("OpenAPI")
    let results = try await compare(
      [candidate("Saurabh"), candidate("OpenAI")],
      against: [sarah, openAPI],
      policy: Self.mockupPlaceholderPolicy)
    #expect(results[0].classification == .fuzzy(existing: sarah, distance: 2))
    #expect(results[1].classification == .fuzzy(existing: openAPI, distance: 1))
  }

  // MARK: - Ambiguity

  @Test("canonical matching an alias owned by two existing words classifies ambiguous with both")
  func canonicalMatchingAliasOwnedByTwoExistingWordsClassifiesAmbiguousWithBothMatches()
    async throws
  {
    let zeta = word("Zeta", aliases: ["annie"])
    let alpha = word("Alpha", aliases: ["Annie"])
    let results = try await compare([candidate("annie")], against: [zeta, alpha])
    guard case .ambiguous(let matches) = results[0].classification else {
      Issue.record("expected ambiguous, got \(results[0].classification)")
      return
    }
    #expect(matches.count == 2)
    #expect(matches[0].existing == alpha)  // ordered by normalized canonical
    #expect(matches[1].existing == zeta)
    #expect(matches[0].kind == .variant(matchedAlias: "Annie"))
  }

  @Test("canonicals distinct on disk but identical under the import key classify ambiguous")
  func canonicalsCollapsingUnderTheImportKeyClassifyAmbiguousNotArbitraryExact() async throws {
    // `CustomWordsManager` dedups on `trimmed.lowercased()`, so these two are
    // legitimately distinct in persisted data; this engine's key collapses
    // them. Electing either one as "the" exact match would let Review offer
    // to replace a word the user never meant.
    let singleSpace = CustomWord(canonical: "Claude Code")
    let doubleSpace = CustomWord(canonical: "Claude  Code")
    let results = try await compare(
      [candidate("claude code")], against: [singleSpace, doubleSpace])
    guard case .ambiguous(let matches) = results[0].classification else {
      Issue.record("expected ambiguous, got \(results[0].classification)")
      return
    }
    #expect(matches.count == 2)
    #expect(matches.allSatisfy { $0.kind == .exact })
    #expect(Set(matches.map(\.existing.id)) == Set([singleSpace.id, doubleSpace.id]))
  }

  @Test("decomposed and precomposed duplicates on disk also classify ambiguous")
  func unicodeDuplicatesOnDiskClassifyAmbiguous() async throws {
    let precomposed = CustomWord(canonical: "caf\u{00E9}")
    let decomposed = CustomWord(canonical: "cafe\u{0301}")
    let results = try await compare(
      [candidate("café")], against: [precomposed, decomposed])
    guard case .ambiguous(let matches) = results[0].classification else {
      Issue.record("expected ambiguous, got \(results[0].classification)")
      return
    }
    #expect(matches.count == 2)
  }

  @Test("a single canonical owner still classifies exact, not ambiguous")
  func singleCanonicalOwnerStaysExact() async throws {
    let only = CustomWord(canonical: "Claude Code")
    let results = try await compare(
      [candidate("claude code")], against: [only, CustomWord(canonical: "Qualtrics")])
    #expect(results[0].classification == .exact(existing: only))
  }

  @Test("single-owner alias match stays variant, not ambiguous")
  func singleOwnerAliasMatchStaysVariantNotAmbiguous() async throws {
    let owner = word("Parvati", aliases: ["annie"])
    let results = try await compare(
      [candidate("annie")], against: [owner, word("Zeta", aliases: ["zed"])])
    #expect(results[0].classification == .variant(existing: owner, matchedAlias: "annie"))
  }

  @Test("fuzzy tie at equal minimal distance classifies ambiguous")
  func fuzzyTieAtEqualMinimalDistanceClassifiesAmbiguous() async throws {
    let first = word("Clarab")
    let second = word("Clarac")
    let results = try await compare(
      [candidate("Claraz")], against: [second, first],
      policy: CustomWordsImportFuzzyPolicy(minimumLength: 5, maximumEditDistance: 1))
    guard case .ambiguous(let matches) = results[0].classification else {
      Issue.record("expected ambiguous, got \(results[0].classification)")
      return
    }
    #expect(matches.count == 2)
    #expect(matches[0].existing == first)  // deterministic order despite library order
    #expect(matches[1].existing == second)
    #expect(matches[0].kind == .fuzzy(distance: 1))
  }

  @Test("unique minimal fuzzy distance stays fuzzy even when farther matches exist")
  func uniqueMinimalFuzzyDistanceStaysFuzzyEvenWhenFartherMatchesExist() async throws {
    let close = word("Clarab")
    let farther = word("Clarxyz")
    let results = try await compare(
      [candidate("Claraz")], against: [farther, close],
      policy: CustomWordsImportFuzzyPolicy(minimumLength: 5, maximumEditDistance: 3))
    #expect(results[0].classification == .fuzzy(existing: close, distance: 1))
  }

  @Test("ambiguous match list order is deterministic regardless of library order")
  func ambiguousMatchListOrderIsDeterministic() async throws {
    let alpha = word("Alpha", aliases: ["shared"])
    let zeta = word("Zeta", aliases: ["shared"])
    for library in [[alpha, zeta], [zeta, alpha]] {
      let results = try await compare([candidate("shared")], against: library)
      guard case .ambiguous(let matches) = results[0].classification else {
        Issue.record("expected ambiguous, got \(results[0].classification)")
        return
      }
      #expect(matches.map(\.existing) == [alpha, zeta])
    }
  }

  // MARK: - Duplicate-candidate coalescing

  @Test("repeated incoming canonical coalesces to the first row, unioning supplied aliases")
  func repeatedIncomingCanonicalCoalescesAndMergesAliases() async throws {
    let first = candidate("Kubernetes", aliases: .supplied(["k8s"]))
    let second = candidate("kubernetes", aliases: .supplied(["kube", "K8S"]))
    let results = try await compare([first, second], against: [])
    #expect(results.count == 1)
    #expect(results[0].candidate.id == first.id)
    #expect(results[0].candidate.canonical == "Kubernetes")
    // K8S deduplicates against k8s via the normalization key; first spelling wins.
    #expect(results[0].candidate.aliases == .supplied(["k8s", "kube"]))
  }

  @Test("candidates the manager would store separately stay separate review rows")
  func candidatesDistinctUnderThePersistenceKeyAreNotCoalesced() async throws {
    // The backup round-trip regression: `CustomWordsManager` dedups on
    // `trimmed.lowercased()`, so a library can hold BOTH of these, and an
    // export of that library contains both. Coalescing on the stronger
    // matching key would merge them into one row and make the second word
    // impossible to restore.
    let first = candidate("Claude Code")
    let second = candidate("Claude  Code")
    let results = try await compare([first, second], against: [])
    #expect(results.count == 2)
    #expect(results.map(\.candidate.canonical) == ["Claude Code", "Claude  Code"])
    #expect(results.allSatisfy { $0.classification == .new })
  }

  @Test("coalescing keeps the first supplied value per field, independently")
  func coalescedDuplicatesKeepFirstSuppliedFieldPerFieldIndependently() async throws {
    var first = candidate("Kubernetes")
    first.priority = .supplied(5)
    var second = candidate("KUBERNETES")
    second.category = .supplied(.brand)
    second.priority = .supplied(9)
    second.caseSensitive = .supplied(true)
    let results = try await compare([first, second], against: [])
    #expect(results.count == 1)
    let merged = results[0].candidate
    #expect(merged.priority == .supplied(5))  // first row's supplied value wins
    #expect(merged.category == .supplied(.brand))  // first row had no opinion
    #expect(merged.caseSensitive == .supplied(true))
    #expect(merged.forceReplace == .unspecified)  // nobody supplied it
  }

  @Test("coalescing distinguishes unspecified from supplied-nil strictness override")
  func coalescingDistinguishesUnspecifiedFromSuppliedNilMinSimilarityOverride() async throws {
    var first = candidate("Kubernetes")
    first.minSimilarityOverride = .unspecified
    var second = candidate("kubernetes")
    second.minSimilarityOverride = .supplied(nil)  // authoritative "no override"
    let results = try await compare([first, second], against: [])
    #expect(results[0].candidate.minSimilarityOverride == .supplied(nil))
  }

  @Test("coalesced aliases stay unspecified only when every duplicate row was unspecified")
  func coalescedDuplicatesUnionSuppliedAliasesAndStayUnspecifiedWhenAllRowsAreUnspecified()
    async throws
  {
    let allUnspecified = try await compare(
      [candidate("Kubernetes"), candidate("kubernetes")], against: [])
    #expect(allUnspecified[0].candidate.aliases == .unspecified)

    let oneSupplied = try await compare(
      [candidate("Kubernetes"), candidate("kubernetes", aliases: .supplied(["k8s"]))],
      against: [])
    #expect(oneSupplied[0].candidate.aliases == .supplied(["k8s"]))
  }

  // MARK: - Alias-collision detection (disclosure only)

  @Test("candidate alias matching a different existing word's alias is flagged")
  func candidateAliasMatchingDifferentExistingWordIsFlaggedAsCollision() async throws {
    let incumbent = word("Anika", aliases: ["annie"])
    let results = try await compare(
      [candidate("Annabelle", aliases: .supplied(["Annie"]))], against: [incumbent])
    #expect(
      results[0].collidingAliases == [
        CustomWordsImportAliasCollision(alias: "Annie", heldBy: incumbent.id)
      ])
  }

  @Test("a variant match's own matched alias is the reason for the match, not a collision")
  func candidateAliasMatchingItsOwnClassifiedMatchIsNotFlagged() async throws {
    let existing = word("Parvati", aliases: ["Pavarthi"])
    let results = try await compare([candidate("pavarthi")], against: [existing])
    #expect(
      results[0].classification == .variant(existing: existing, matchedAlias: "Pavarthi"))
    #expect(results[0].collidingAliases.isEmpty)
  }

  @Test("new candidate with an alias matching any existing word is flagged")
  func newCandidateWithAliasMatchingAnyExistingWordIsFlagged() async throws {
    let incumbent = word("Anika", aliases: ["annie"])
    let results = try await compare(
      [candidate("Zed", aliases: .supplied(["annie", "zeddy"]))], against: [incumbent])
    #expect(results[0].classification == .new)
    #expect(
      results[0].collidingAliases == [
        CustomWordsImportAliasCollision(alias: "annie", heldBy: incumbent.id)
      ])
  }

  @Test("when two existing words share an alias, the collision names the runtime winner")
  func sharedIncumbentAliasReportsTheRuntimeWinningOwner() async throws {
    // This test used to expect the LATER word, reasoning that the alias map is
    // assigned unconditionally so the last writer wins. That reasoning reads
    // one surface and stops. Pass 0 runs FIRST and accepts single tokens
    // (`for n in (1...min(3, ...))`), and in the no-space namespace aliases are
    // FIRST-wins — so the earlier word holds "annie" there and intercepts
    // before the alias map is ever consulted.
    //
    // Corrected against the real corrector, which turns "Annie" into "Anika"
    // here (`aRuntimeOracleForEveryOwnerThisSuiteNames`). Naming Annabelle told
    // the user a word that never touches their text already uses the alias —
    // exactly the class of blindness #1667 exists to end.
    let earlier = CustomWord(canonical: "Anika", aliases: ["annie"])
    let later = CustomWord(canonical: "Annabelle", aliases: ["annie"])
    let results = try await compare(
      [candidate("Zed", aliases: .supplied(["Annie"]))], against: [earlier, later])
    #expect(
      results[0].collidingAliases == [
        CustomWordsImportAliasCollision(alias: "Annie", heldBy: earlier.id)
      ])
  }

  @Test("a key held by both an existing alias and an existing canonical names the alias owner")
  func keyHeldByBothAnExistingAliasAndCanonicalReportsTheAliasOwner() async throws {
    // The corrector builds every alias into the lookup FIRST, then skips any
    // canonical whose key an alias already owns (WordCorrector.swift:176-215,
    // "Canonical 'X' skipped: key already maps to..."). So when both kinds of
    // owner exist, the alias owner is the real holder — naming the canonical
    // owner would point at a word the corrector never reaches for that key.
    let canonicalHolder = CustomWord(canonical: "Annie")
    let aliasHolder = CustomWord(canonical: "Anika", aliases: ["annie"])
    let results = try await compare(
      [candidate("Zed", aliases: .supplied(["Annie"]))],
      against: [canonicalHolder, aliasHolder])
    #expect(
      results[0].collidingAliases == [
        CustomWordsImportAliasCollision(alias: "Annie", heldBy: aliasHolder.id)
      ])
  }

  @Test("an imported alias equal to a multi-word canonical's space-free form is disclosed")
  func aliasMatchingAnExistingMultiWordCanonicalsNoSpaceFormIsFlagged() async throws {
    // The defect #1667 was filed for. `Claude Code` claims "claudecode" in the
    // no-space namespace, and Pass 0 resolves that n-gram before any alias pass
    // runs — so this alias was reported collision-free, persisted, and then
    // never fired. It has no entry in either alias map, which is precisely why
    // a detector that mirrored only those maps could not see it.
    let existing = CustomWord(canonical: "Claude Code")
    let results = try await compare(
      [candidate("Zed", aliases: .supplied(["claudecode"]))], against: [existing])
    #expect(
      results[0].collidingAliases == [
        CustomWordsImportAliasCollision(alias: "claudecode", heldBy: existing.id)
      ])
  }

  @Test("a dropped alias's surviving claims never become a phantom owner")
  func blockedAliasRegistersNoneOfItsClaimsForLaterCandidates() async throws {
    // Atomicity (grounded review r4). The first candidate's alias is blocked on
    // its ordinary surface, so the whole alias will be dropped at commit — the
    // stored alias, not one trigger claim, is the unit that survives. If its
    // UNBLOCKED no-space claim were registered anyway, it would become an owner
    // that never exists in the library and would then falsely block the second
    // candidate, whose alias is in fact free.
    //
    // The fixture matters, and two earlier ones were useless. Both gave the two
    // candidates the SAME blocked claim, so both stayed blocked by the incumbent
    // whether or not the first leaked a registration — the test could not fail
    // for the reason it named (grounded review r1 and r2, #1667).
    //
    // This one can. A PACK incumbent enters the ordinary exact map but never the
    // no-space map, so the first alias is blocked on its ordinary claim while
    // its no-space claim is genuinely free. The second candidate's alias differs
    // only by an internal space, so its ordinary claim is a different key and is
    // free — but it strips to the SAME no-space key. It therefore stays clean
    // only if the first alias registered nothing.
    let incumbent = CustomWord(
      canonical: "Pack Holder", aliases: ["New York"], source: .pack)
    let first = candidate("Zed", aliases: .supplied(["New York"]))
    let second = candidate("Quinn", aliases: .supplied(["New  York"]))
    let results = try await compare([first, second], against: [incumbent])

    #expect(
      results[0].collidingAliases == [
        CustomWordsImportAliasCollision(alias: "New York", heldBy: incumbent.id)
      ])
    // Fails the moment registration stops being all-or-none.
    #expect(results[1].collidingAliases.isEmpty)
  }

  @Test("aliases that differ only by internal whitespace still collide, on the no-space surface")
  func aliasesDifferingOnlyByInternalWhitespaceCollideOnTheCompoundSurface() async throws {
    // Inverted deliberately (#1667). This test used to assert no collision, on
    // the reasoning that the two aliases occupy different slots in the alias
    // map and so "never actually collide at runtime". They do: both strip to
    // "newyork" in the no-space namespace, where the incumbent got there first.
    //
    // The real corrector turns "new york" into "Anika" with both words present
    // (`aRuntimeOracleForEveryOwnerThisSuiteNames`), so the imported alias is
    // inert on every surface — it can never win the compound form, and its own
    // double-spaced form is unreachable from speech, which normalises to one
    // space. Silently persisting a dead alias is the defect; disclosing it is
    // the fix.
    let incumbent = CustomWord(canonical: "Anika", aliases: ["New York"])
    let results = try await compare(
      [candidate("Zed", aliases: .supplied(["New  York"]))], against: [incumbent])
    #expect(
      results[0].collidingAliases == [
        CustomWordsImportAliasCollision(alias: "New  York", heldBy: incumbent.id)
      ])
  }

  /// The instrument that settled the two corrections above, kept rather than
  /// deleted (#1667).
  ///
  /// Every earlier attempt to state this file's precedence reasoned from the
  /// lookup maps and got it wrong, three times. These assertions ask the actual
  /// corrector what happens to actual text, so a future change to pass order or
  /// no-space precedence fails HERE, next to the collision tests that depend on
  /// it, rather than silently making their expectations lies again.
  @Test("the corrector itself confirms which word each named owner really is")
  func aRuntimeOracleForEveryOwnerThisSuiteNames() {
    func corrected(_ text: String, _ words: [CustomWord]) -> String {
      WordCorrector().correct(text, using: WordCorrector.buildLookups(words: words)).corrected
    }

    // Two existing words share an alias: the no-space FIRST-wins owner
    // intercepts in Pass 0, ahead of the alias map's last writer.
    let anika = CustomWord(canonical: "Anika", aliases: ["annie"])
    let annabelle = CustomWord(canonical: "Annabelle", aliases: ["annie"])
    #expect(corrected("Annie", [anika, annabelle]) == "Anika")

    // A no-space owner whose canonical the text already spells does NOT
    // intercept: Pass 0 sees "already correct" and the alias map decides.
    let annie = CustomWord(canonical: "Annie")
    #expect(corrected("Annie", [annie, anika]) == "Anika")

    // The compound surface is live for whitespace-only variants.
    let newYork = CustomWord(canonical: "Anika", aliases: ["New York"])
    let doubled = CustomWord(canonical: "Zed", aliases: ["New  York"])
    #expect(corrected("new york", [newYork, doubled]) == "Anika")
  }

  @Test("non-colliding aliases are not flagged")
  func nonCollidingAliasesAreNotFlagged() async throws {
    let results = try await compare(
      [candidate("Zed", aliases: .supplied(["zeddy", "zedster"]))],
      against: [word("Anika", aliases: ["annie"])])
    #expect(results[0].collidingAliases.isEmpty)
  }

  @Test("an alias owned by the candidate's own exact match remains disclosed")
  func aliasOwnedByTheCandidatesOwnExactMatchRemainsDisclosed() async throws {
    // DELIBERATE, per the adopted plan (PR-F2a §alias-collision detection):
    // this engine is decision-agnostic — it runs before any Review decision
    // exists — so it records the collision naming the matched word and the
    // Review screen owns display policy. Under the two-decision v1 scope
    // (Add/Skip; founder 2026-07-18) every non-empty collision is displayed:
    // the Replace-target suppression an earlier plan draft assigned to the
    // Review screen is unreachable, because Replace is not a v1 decision.
    // The commit step remains the persistence guarantee regardless, since it
    // evaluates the fully-applied result.
    let existing = CustomWord(canonical: "Parvati", aliases: ["Pavarthi"])
    let results = try await compare(
      [candidate("Parvati", aliases: .supplied(["Pavarthi"]))], against: [existing])
    #expect(results[0].classification == .exact(existing: existing))
    #expect(
      results[0].collidingAliases == [
        CustomWordsImportAliasCollision(alias: "Pavarthi", heldBy: existing.id)
      ])
  }

  @Test("a candidate's own duplicate alias spellings are not flagged against itself")
  func candidateOwnDuplicateAliasSpellingsAreNotFlaggedAgainstItself() async throws {
    let results = try await compare(
      [candidate("Annabelle", aliases: .supplied(["annie", "ANNIE", "Annie"]))],
      against: [])
    #expect(results[0].collidingAliases.isEmpty)
  }

  @Test("a candidate with no supplied aliases produces no collisions")
  func candidateWithUnspecifiedAliasesProducesNoCollisions() async throws {
    let results = try await compare(
      [candidate("Annabelle")], against: [word("Anika", aliases: ["annabelle"])])
    #expect(results[0].collidingAliases.isEmpty)
  }

  @Test("two incoming candidates sharing an alias flag only the later candidate")
  func twoIncomingCandidatesSharingAnAliasFlagsOnlyTheLaterCandidateAgainstTheEarlierOwner()
    async throws
  {
    let earlier = candidate("Anika", aliases: .supplied(["annie"]))
    let later = candidate("Annabelle", aliases: .supplied(["Annie"]))
    let results = try await compare([earlier, later], against: [])
    #expect(results[0].collidingAliases.isEmpty)  // the winner's alias is not at risk
    #expect(
      results[1].collidingAliases == [
        CustomWordsImportAliasCollision(alias: "Annie", heldBy: earlier.id)
      ])
  }

  @Test("candidate alias matching an existing canonical is flagged")
  func candidateAliasMatchingAnExistingCanonicalIsFlagged() async throws {
    let incumbent = word("Anika")
    let results = try await compare(
      [candidate("Annabelle", aliases: .supplied(["anika"]))], against: [incumbent])
    #expect(
      results[0].collidingAliases == [
        CustomWordsImportAliasCollision(alias: "anika", heldBy: incumbent.id)
      ])
  }

  @Test("candidate alias equal to its own canonical is normalized away, not flagged")
  func candidateAliasEqualToItsOwnCanonicalIsNormalizedAwayNotFlagged() async throws {
    let results = try await compare(
      [candidate("Anika", aliases: .supplied(["ANIKA", "annie"]))], against: [])
    #expect(results[0].collidingAliases.isEmpty)
  }

  @Test(
    "alias colliding with both a canonical and another candidate's alias reports the canonical owner"
  )
  func aliasCollidingWithBothACanonicalAndAnotherCandidateAliasReportsTheCanonicalOwner()
    async throws
  {
    // "anika" is simultaneously an existing CANONICAL and an earlier
    // candidate's alias; canonical ownership is checked first, so the
    // existing word wins, and the earlier candidate's identical alias was
    // itself flagged against that canonical rather than registered as an
    // alias owner.
    let incumbent = word("Anika")
    let earlier = candidate("Zed", aliases: .supplied(["anika"]))
    let later = candidate("Annabelle", aliases: .supplied(["Anika"]))
    let results = try await compare([earlier, later], against: [incumbent])
    #expect(
      results[0].collidingAliases == [
        CustomWordsImportAliasCollision(alias: "anika", heldBy: incumbent.id)
      ])
    #expect(
      results[1].collidingAliases == [
        CustomWordsImportAliasCollision(alias: "Anika", heldBy: incumbent.id)
      ])
  }

  @Test("earlier candidate's alias loses to a later candidate's canonical")
  func
    earlierCandidateAliasMatchingLaterCandidateCanonicalFlagsEarlierAliasAgainstLaterCanonicalOwner()
    async throws
  {
    // Every incoming canonical is registered before any imported alias is
    // checked, so plan order does not protect the earlier alias here.
    let earlier = candidate("Zed", aliases: .supplied(["annabelle"]))
    let later = candidate("Annabelle")
    let results = try await compare([earlier, later], against: [])
    #expect(
      results[0].collidingAliases == [
        CustomWordsImportAliasCollision(alias: "annabelle", heldBy: later.id)
      ])
    #expect(results[1].collidingAliases.isEmpty)
  }

  // MARK: - Cancellation

  @Test("cancelled compare throws and returns nothing")
  func cancelledCompareThrowsAndReturnsNothing() async throws {
    let engine = CustomWordsImportCompareEngine()
    let candidates = (0..<5).map { candidate("word\($0)") }
    // Cancel from INSIDE the task before compare runs — deterministic, no
    // race against task startup (a post-creation cancel() can lose to a
    // fast compare and flake).
    let task = Task { () -> [CustomWordsImportComparison] in
      withUnsafeCurrentTask { $0?.cancel() }
      return try await engine.compare(
        candidates: candidates, against: [], fuzzyPolicy: .disabled)
    }
    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }
  }

  // MARK: - Skip never rewrites an existing word

  @Test("re-importing a word you already have cannot touch its aliases")
  func skippingAnExistingWordPreservesItsAliases() async throws {
    // Founder's exact scenario (2026-07-19): GitHub ships with 3 aliases, the
    // user adds 3 more, exports, then re-imports the SAME file on the SAME
    // Mac. "Skip" has to mean nothing is written for that word — NOT that it
    // is rewritten with the importing file's shorter alias list. Their words
    // stay their words.
    let mine = word("GitHub", aliases: ["git hub", "get hub", "gh", "git-hub", "githib", "guthub"])
    let engine = CustomWordsImportCompareEngine()

    // A plain list carries no alias opinion at all — the strongest case,
    // because there is nothing for a Replace to even be built from.
    let comparisons = try await engine.compare(
      candidates: [candidate("GitHub")], against: [mine], fuzzyPolicy: .disabled)

    let row = try #require(comparisons.first)
    guard case .exact(let matched) = row.classification else {
      Issue.record("expected an exact match, got \(row.classification)")
      return
    }
    // The matched word is the user's, with all six alternates intact...
    #expect(matched.aliases.count == 6)
    #expect(matched.aliases.contains("gh"))
    // ...and the candidate carries no authority to overwrite them with.
    #expect(row.candidate.aliases == .unspecified)
  }

  @Test("even an exported file's aliases cannot overwrite the word you have")
  func exportedFileAliasesCannotOverwriteExistingWord() async throws {
    // An exported file DOES carry aliases, so this is the case where a Replace
    // would be constructible. It must still classify as already-present: v1
    // never modifies an existing word or its alternates.
    let mine = word("GitHub", aliases: ["git hub", "get hub", "gh"])
    let engine = CustomWordsImportCompareEngine()

    let fromExport = candidate("GitHub", aliases: .supplied(["totally", "different"]))
    let comparisons = try await engine.compare(
      candidates: [fromExport], against: [mine], fuzzyPolicy: .disabled)

    let row = try #require(comparisons.first)
    guard case .exact(let matched) = row.classification else {
      Issue.record("expected an exact match, got \(row.classification)")
      return
    }
    #expect(matched.aliases == ["git hub", "get hub", "gh"])
  }

}
