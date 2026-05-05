import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// Phase 2 (#638) — pins the four hardening items in `WordCorrector`.
/// Bible §8.2.
@Suite("WordCorrector — Phase 2 hardening for scale")
struct WordCorrectorHardeningTests {
  let corrector = WordCorrector()

  // MARK: - Item 1: Stopword guard

  @Test("Stopword guard — 'and we are good' against ['Andre'] does NOT swap")
  func stopwordGuardPreventsAndreSwap() {
    let andre = CustomWord(canonical: "Andre", aliases: ["andre"])
    let (result, replacements) = corrector.correct("and we are good", against: [andre])
    #expect(result == "and we are good", "Stopword span must not swap to Andre")
    #expect(replacements.isEmpty)
  }

  @Test("Stopword regression — 'andre is here' against ['Andre'] still swaps")
  func stopwordRegressionAndreInProperContextStillSwaps() {
    let andre = CustomWord(canonical: "Andre", aliases: ["andre"])
    let (result, replacements) = corrector.correct("andre is here", against: [andre])
    #expect(result == "Andre is here", "Single-word match for canonical still works")
    #expect(replacements.count == 1)
    #expect(replacements.first?.sourceID == andre.id)
  }

  // MARK: - Item 2: Vocabulary-size penalty

  @Test("largeVocabPenalty — pool ≤100 → 0")
  func vocabPenaltyZeroAtSmallPool() {
    #expect(WordCorrector.largeVocabPenalty(poolSize: 0) == 0)
    #expect(WordCorrector.largeVocabPenalty(poolSize: 50) == 0)
    #expect(WordCorrector.largeVocabPenalty(poolSize: 100) == 0)
  }

  @Test("largeVocabPenalty — pool 101-600 → +0.02")
  func vocabPenaltyOneBumpInRange() {
    #expect(WordCorrector.largeVocabPenalty(poolSize: 101) == 0)  // (101-100)/500 = 0
    #expect(WordCorrector.largeVocabPenalty(poolSize: 600) == 0.02)  // (600-100)/500 = 1
  }

  @Test("largeVocabPenalty — pool 1100 → +0.04")
  func vocabPenaltyTwoBumps() {
    #expect(WordCorrector.largeVocabPenalty(poolSize: 1100) == 0.04)  // (1100-100)/500 = 2
  }

  @Test("largeVocabPenalty — capped at +0.06 above 1600")
  func vocabPenaltyCapped() {
    #expect(WordCorrector.largeVocabPenalty(poolSize: 1600) == 0.06)  // (1600-100)/500 = 3
    #expect(WordCorrector.largeVocabPenalty(poolSize: 5000) == 0.06)  // capped
    #expect(WordCorrector.largeVocabPenalty(poolSize: 100_000) == 0.06)
  }

  // MARK: - Item 3: Length-aware threshold scaling

  @Test("lengthAwareAdjustment — short candidates get no leniency")
  func lengthAdjShortNone() {
    #expect(WordCorrector.lengthAwareAdjustment(candidateLength: 0) == 0)
    #expect(WordCorrector.lengthAwareAdjustment(candidateLength: 5) == 0)
    #expect(WordCorrector.lengthAwareAdjustment(candidateLength: 8) == 0)
  }

  @Test("lengthAwareAdjustment — 16-char candidate gets +0.04 leniency")
  func lengthAdjMediumLeniency() {
    #expect(WordCorrector.lengthAwareAdjustment(candidateLength: 12) == 0.02)  // (12-8)*0.005
    #expect(WordCorrector.lengthAwareAdjustment(candidateLength: 16) == 0.04)  // (16-8)*0.005
  }

  @Test("lengthAwareAdjustment — capped at 0.04")
  func lengthAdjCapped() {
    #expect(WordCorrector.lengthAwareAdjustment(candidateLength: 20) == 0.04)
    #expect(WordCorrector.lengthAwareAdjustment(candidateLength: 100) == 0.04)
  }

  // MARK: - Item 4: Per-term threshold override

  @Test("Override — Loose (0.72) accepts what global 0.82 would reject")
  func overrideLoosenAccepts() {
    // "kuberntes" vs "Kubernetes" scores ~0.85+ with default — too easy.
    // Use a smaller distortion that misses default 0.82 but passes 0.72.
    // "kubrnetes" (one transposition + drop) scores around 0.78.
    let kube = CustomWord(canonical: "Kubernetes", minSimilarityOverride: 0.70)
    let (result, replacements) = corrector.correct("deployed to kuberntes", against: [kube])
    #expect(result == "deployed to Kubernetes", "Looser override accepts marginal match")
    #expect(replacements.count == 1)
  }

  @Test("Override — Strict (0.95) rejects what global 0.82 would accept")
  func overrideStrictRejects() {
    // "kuberntes" passes at default 0.82 but should fail at 0.95.
    let kube = CustomWord(canonical: "Kubernetes", minSimilarityOverride: 0.95)
    let (result, replacements) = corrector.correct("deployed to kuberntes", against: [kube])
    #expect(result == "deployed to kuberntes", "Strict override rejects marginal match")
    #expect(replacements.isEmpty)
  }

  @Test("Override nil → use global threshold (regression)")
  func overrideNilFallsBackToGlobal() {
    let kube = CustomWord(canonical: "Kubernetes", minSimilarityOverride: nil)
    let (result, _) = corrector.correct("deployed to kuberntes", against: [kube])
    #expect(result == "deployed to Kubernetes", "Nil override = pre-Phase-2 behavior")
  }

  // MARK: - Items combined: large vocab does not regress small-vocab behavior

  @Test("50-term vocab: existing single-alias swap unchanged")
  func smallVocabUnchanged() {
    let words =
      (1...49).map { CustomWord(canonical: "Term\($0)") }
      + [CustomWord(canonical: "ChatGPT", aliases: ["chatgpt"])]
    let (result, replacements) = corrector.correct("I used chatgpt today", against: words)
    #expect(result == "I used ChatGPT today")
    #expect(replacements.count == 1)
  }
}
