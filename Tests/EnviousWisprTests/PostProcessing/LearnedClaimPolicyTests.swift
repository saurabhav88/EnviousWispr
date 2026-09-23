import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #3105: a learned word never swaps text by itself.
///
/// A learned sound-alike (`learnedAliases`) and every claim of a word the app
/// created from an edit (`learnedAt`) keep OWNING their keys, so learning and
/// import still refuse a collision against them, but they leave every
/// deterministic swap map. Manual aliases swap exactly as before. Expected
/// outcomes are written out by hand, never derived from the index.
@Suite("Learned claims own but never swap (#3105)", .tags(.productOutcome))
struct LearnedClaimPolicyTests {
  private let learnedAt = Date(timeIntervalSince1970: 1_790_000_000)

  private func correct(_ text: String, _ words: [CustomWord]) -> String {
    WordCorrector().correct(text, using: WordCorrector.buildLookups(words: words)).corrected
  }

  @Test("a born-learned word changes nothing: its alias, casing and fuzzy forms all stay")
  func bornLearnedWordNeverSwaps() {
    let tuist = CustomWord(
      canonical: "Tuist", aliases: ["toast"], learnedAliases: ["toast"], learnedAt: learnedAt)
    #expect(correct("the day toast regenerated", [tuist]) == "the day toast regenerated")
    #expect(correct("tuist regenerated it", [tuist]) == "tuist regenerated it")
    #expect(correct("tuistt regenerated it", [tuist]) == "tuistt regenerated it")
  }

  @Test("a manual word keeps swapping its alias and fixing its casing")
  func manualWordStillSwaps() {
    let tuist = CustomWord(canonical: "Tuist", aliases: ["toast"])
    #expect(correct("the day toast regenerated", [tuist]) == "the day Tuist regenerated")
    #expect(correct("tuist regenerated it", [tuist]) == "Tuist regenerated it")
  }

  @Test("a manual word's learned alias does not swap; its manual alias still does")
  func learnedAliasOnManualWordIsCheckerOnly() {
    let qwen = CustomWord(canonical: "Qwen", aliases: ["kwen", "queen"], learnedAliases: ["queen"])
    #expect(correct("ask kwen please", [qwen]) == "ask Qwen please")
    #expect(correct("the queen spoke", [qwen]) == "the queen spoke")
  }

  @Test("a learned alias still owns its key for learning and import")
  func learnedAliasStillOwnsItsKey() {
    let tuist = CustomWord(
      canonical: "Tuist", aliases: ["toast"], learnedAliases: ["toast"], learnedAt: learnedAt)
    let index = WordCorrector.buildExactTriggerIndex(words: [tuist])
    let owner = index.owner(of: WordCorrector.ExactTriggerClaim(key: "toast", namespace: .single))
    #expect(owner?.wordID == tuist.id)
    #expect(owner?.checkerOnly == true)
    guard case .blocked(let by) = index.resolveAliasOwnership(for: "toast", excludingOwnerID: nil)
    else {
      Issue.record("a learned alias must still block another word claiming it")
      return
    }
    #expect(by.wordID == tuist.id)
  }

  @Test("a learned claim that wins a key never swaps; the manual word keeps only its own claims")
  func learnedWinnerNeverSwaps() {
    // Both words claim "toast". In the ordinary single namespace the later
    // (learned) claim wins the key, and filtering happens after resolution, so
    // that key swaps to nothing: the learned word is never written. The manual
    // word keeps its OWN no-space claim on "toast" (first-wins there), which a
    // user-authored swap is entitled to (G1).
    let toaster = CustomWord(canonical: "Toastmasters", aliases: ["toast"])
    let tuist = CustomWord(
      canonical: "Tuist", aliases: ["toast"], learnedAliases: ["toast"], learnedAt: learnedAt)
    let lookups = WordCorrector.buildLookups(words: [toaster, tuist])
    #expect(lookups.singleAliasMap["toast"] == nil)
    #expect(lookups.nospaceCanonicalMap["toast"] == "Toastmasters")
    #expect(!correct("a toast to that", [toaster, tuist]).contains("Tuist"))
  }

  @Test("a learned key still shields its surface from the pack fuzzy tier")
  func learnedKeyShieldsPackFuzzy() {
    let tuist = CustomWord(
      canonical: "Tuist", aliases: ["toast"], learnedAliases: ["toast"], learnedAt: learnedAt)
    let lookups = WordCorrector.buildLookups(words: [tuist])
    #expect(lookups.nonPackExactKeys.contains("toast"))
    #expect(lookups.nonPackExactKeys.contains("tuist"))
  }

  @Test("a born-learned multi-word word leaves the compound pass")
  func bornLearnedCompoundDoesNotJoin() {
    let hackClub = CustomWord(canonical: "HackClub", aliases: [], learnedAt: learnedAt)
    #expect(correct("go to hack club now", [hackClub]) == "go to hack club now")
    let manual = CustomWord(canonical: "HackClub")
    #expect(correct("go to hack club now", [manual]) == "go to HackClub now")
  }
}
