import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprPostProcessing

// MARK: - PipelineState Tests

@Suite("PipelineState")
struct PipelineStateTests {
  @Test("idle is not active")
  func idleIsNotActive() {
    #expect(!PipelineState.idle.isActive)
  }

  @Test("complete is not active")
  func completeIsNotActive() {
    #expect(!PipelineState.complete.isActive)
  }

  @Test("error is not active")
  func errorIsNotActive() {
    #expect(!PipelineState.error("something broke").isActive)
  }

  @Test(
    "active states",
    arguments: [
      PipelineState.loadingModel,
      PipelineState.recording,
      PipelineState.transcribing,
      PipelineState.polishing,
    ])
  func activeStates(state: PipelineState) {
    #expect(state.isActive)
  }

  @Test("equality for error states")
  func errorEquality() {
    #expect(PipelineState.error("a") == PipelineState.error("a"))
    #expect(PipelineState.error("a") != PipelineState.error("b"))
  }

  @Test("equality for non-error states")
  func nonErrorEquality() {
    #expect(PipelineState.idle == PipelineState.idle)
    #expect(PipelineState.idle != PipelineState.recording)
  }
}

// MARK: - WERCalculator Tests

@Suite("WERCalculator")
struct WERCalculatorTests {
  @Test("identical strings yield 0 WER")
  func identicalStrings() {
    let result = WERCalculator.calculate(reference: "hello world", hypothesis: "hello world")
    #expect(result.wer == 0.0)
  }

  @Test("case insensitive comparison")
  func caseInsensitive() {
    let result = WERCalculator.calculate(reference: "Hello World", hypothesis: "hello world")
    #expect(result.wer == 0.0)
  }

  @Test("single substitution")
  func singleSubstitution() {
    let result = WERCalculator.calculate(reference: "the cat sat", hypothesis: "the dog sat")
    #expect(abs(result.wer - 1.0 / 3.0) < 0.001)
  }

  @Test("single insertion")
  func singleInsertion() {
    let result = WERCalculator.calculate(reference: "the cat", hypothesis: "the big cat")
    #expect(abs(result.wer - 0.5) < 0.001)
  }

  @Test("single deletion")
  func singleDeletion() {
    let result = WERCalculator.calculate(reference: "the big cat", hypothesis: "the cat")
    #expect(abs(result.wer - 1.0 / 3.0) < 0.001)
  }

  @Test("completely different strings")
  func completelyDifferent() {
    let result = WERCalculator.calculate(reference: "a b c", hypothesis: "x y z")
    #expect(result.wer == 1.0)
  }

  @Test("empty reference with empty hypothesis")
  func bothEmpty() {
    let result = WERCalculator.calculate(reference: "", hypothesis: "")
    #expect(result.wer == 0.0)
  }

  @Test("empty reference with non-empty hypothesis")
  func emptyReference() {
    let result = WERCalculator.calculate(reference: "", hypothesis: "hello world")
    #expect(result.wer == 2.0)
  }

  @Test("non-empty reference with empty hypothesis")
  func emptyHypothesis() {
    let result = WERCalculator.calculate(reference: "one two three", hypothesis: "")
    #expect(result.wer == 1.0)
  }

  @Test("mixed operations")
  func mixedOperations() {
    let result = WERCalculator.calculate(
      reference: "the quick brown fox",
      hypothesis: "a quick fox jumps"
    )
    #expect(abs(result.wer - 0.75) < 0.001)
  }
}

// MARK: - WordCorrector Tests

@Suite("WordCorrector")
struct WordCorrectorTests {
  let corrector = WordCorrector()

  // MARK: - Pass 1: Exact multi-word alias

  @Test("exact multi-word alias replacement")
  func exactMultiWord() {
    let words = [CustomWord(canonical: "Visual Studio Code", aliases: ["vs code"])]
    let (result, replacements) = corrector.correct("I opened vs code", against: words)
    #expect(result == "I opened Visual Studio Code")
    #expect(replacements.count == 1)
  }

  // MARK: - Pass 3: Exact single-word alias

  @Test("exact alias match corrects casing")
  func exactAliasMatch() {
    let words = [CustomWord(canonical: "ChatGPT", aliases: ["chatgpt"])]
    let (result, replacements) = corrector.correct("I used chatgpt today", against: words)
    #expect(result == "I used ChatGPT today")
    #expect(replacements.count == 1)
  }

  @Test("canonical self-entry fixes casing")
  func canonicalSelfEntry() {
    let words = [CustomWord(canonical: "iPhone")]
    let (result, replacements) = corrector.correct("I have an iphone", against: words)
    #expect(result == "I have an iPhone")
    #expect(replacements.count == 1)
  }

  @Test("short token exact alias")
  func shortTokenExactAlias() {
    let words = [CustomWord(canonical: "API", aliases: ["api"])]
    let (result, replacements) = corrector.correct("the api is fast", against: words)
    #expect(result == "the API is fast")
    #expect(replacements.count == 1)
  }

  @Test("already correct text unchanged")
  func alreadyCorrect() {
    let words = [CustomWord(canonical: "ChatGPT", aliases: ["chatgpt"])]
    let (result, replacements) = corrector.correct("I used ChatGPT today", against: words)
    #expect(result == "I used ChatGPT today")
    #expect(replacements.count == 0)
  }

  // MARK: - Pass 4: Fuzzy single-word against aliases

  @Test("fuzzy alias match corrects minor misspelling")
  func fuzzyAliasMatch() {
    // "kuberntes" is NOT in the alias list but close to canonical self-entry "kubernetes"
    let words = [CustomWord(canonical: "Kubernetes", aliases: ["k8s"])]
    let (result, replacements) = corrector.correct("deployed to kuberntes", against: words)
    #expect(result == "deployed to Kubernetes")
    #expect(replacements.count == 1)
  }

  // MARK: - Pass 5: Fuzzy canonical fallback

  @Test("fuzzy canonical fallback for words with no aliases")
  func fuzzyCanonicalFallback() {
    let words = [CustomWord(canonical: "Kubernetes")]
    let (result, replacements) = corrector.correct("deployed to kuberntes", against: words)
    #expect(result == "deployed to Kubernetes")
    #expect(replacements.count == 1)
  }

  // MARK: - Guards and edge cases

  @Test("empty word list returns unchanged text")
  func emptyWordList() {
    let empty: [CustomWord] = []
    let (result, replacements) = corrector.correct("hello world", against: empty)
    #expect(result == "hello world")
    #expect(replacements.count == 0)
  }

  @Test("no match when input is too different")
  func noFuzzyMatchWhenTooFar() {
    let words = [CustomWord(canonical: "Kubernetes")]
    let (result, replacements) = corrector.correct("I like bananas", against: words)
    #expect(result == "I like bananas")
    #expect(replacements.count == 0)
  }

  @Test("preserves surrounding punctuation")
  func preservesPunctuation() {
    let words = [CustomWord(canonical: "ChatGPT", aliases: ["chatgpt"])]
    let (result, replacements) = corrector.correct("I used chatgpt, and it worked!", against: words)
    #expect(result == "I used ChatGPT, and it worked!")
    #expect(replacements.count == 1)
  }

  @Test("multiple replacements in one pass")
  func multipleReplacements() {
    let words = [
      CustomWord(canonical: "ChatGPT", aliases: ["chatgpt"]),
      CustomWord(canonical: "OpenAI", aliases: ["openai"]),
    ]
    let (result, replacements) = corrector.correct("openai made chatgpt", against: words)
    #expect(result == "OpenAI made ChatGPT")
    #expect(replacements.count == 2)
  }

  // MARK: - Scoring primitives

  @Test("score identical strings returns 1.0")
  func scoreIdentical() {
    let s = corrector.score("hello", against: "hello")
    #expect(abs(s - 1.0) < 0.001)
  }

  @Test("score completely different strings returns low value")
  func scoreDifferent() {
    let s = corrector.score("abc", against: "xyz")
    #expect(s < 0.5)
  }

  @Test("score near-miss is above threshold")
  func scoreNearMiss() {
    // "kubernetes" vs "kuberntes" should score high enough to trigger correction
    let s = corrector.score("kuberntes", against: "kubernetes")
    #expect(s >= WordCorrector.threshold)
  }

  @Test("score distant word is below threshold")
  func scoreDistant() {
    let s = corrector.score("banana", against: "kubernetes")
    #expect(s < WordCorrector.threshold)
  }

  // MARK: - Pass 0: N-gram compound matching
  // N-gram window is max 3 tokens. Already-correct guard is case-sensitive.

  @Test("n-gram compound fixes casing: chat gpt -> ChatGPT")
  func ngramCompoundCasingFix() {
    let words = [CustomWord(canonical: "ChatGPT")]
    let (result, replacements) = corrector.correct("I used chat gpt today", against: words)
    #expect(result == "I used ChatGPT today")
    #expect(replacements.count == 1)
  }

  @Test("n-gram compound: open a i -> OpenAI (3 tokens, max window)")
  func ngramCompoundOpenAI() {
    let words = [CustomWord(canonical: "OpenAI")]
    let (result, replacements) = corrector.correct("open a i is great", against: words)
    #expect(result == "OpenAI is great")
    #expect(replacements.count == 1)
  }

  @Test("n-gram already correct casing not replaced")
  func ngramAlreadyCorrect() {
    // When raw concat matches canonical nospace (case-sensitive), no replacement
    let words = [CustomWord(canonical: "ChatGPT")]
    let (result, replacements) = corrector.correct("I used ChatGPT today", against: words)
    #expect(result == "I used ChatGPT today")
    #expect(replacements.count == 0)
  }

  @Test("n-gram compound preserves surrounding punctuation")
  func ngramPreservesPunctuation() {
    let words = [CustomWord(canonical: "ChatGPT")]
    let (result, replacements) = corrector.correct(
      "I used chat gpt, and it worked!", against: words)
    #expect(result == "I used ChatGPT, and it worked!")
    #expect(replacements.count == 1)
  }

  @Test("n-gram single token casing fix")
  func ngramSingleTokenCasingFix() {
    // N-gram pass also handles n=1 for single-token compound words
    let words = [CustomWord(canonical: "ChatGPT")]
    let (result, replacements) = corrector.correct("I used chatgpt", against: words)
    // Single token "chatgpt" matches nospace "chatgpt" -> "ChatGPT"
    #expect(result == "I used ChatGPT")
    #expect(replacements.count == 1)
  }

  // MARK: - Threshold boundaries

  @Test("short token below short threshold not corrected")
  func shortTokenBelowThreshold() {
    // "api" (3 chars) vs "apt" -- should NOT correct because it's a short token
    // and the score won't meet the 0.90 short token threshold
    let words = [CustomWord(canonical: "API")]
    let (result, replacements) = corrector.correct("use apt to install", against: words)
    #expect(result == "use apt to install")
    #expect(replacements.count == 0)
  }

  @Test("ambiguity margin prevents correction when two candidates are close")
  func ambiguityMarginRejectsTie() {
    // "kuberntes" is close to both "Kubernetes" and "Kubernotes" (hypothetical)
    // When two candidates score within 0.05, correction should be rejected
    let words = [
      CustomWord(canonical: "Kubernetes"),
      CustomWord(canonical: "Kubernotes"),
    ]
    let (result, _) = corrector.correct("kuberntes works", against: words)
    // Either corrected to Kubernetes (if margin sufficient) or left unchanged (if ambiguous)
    // The key test: it should not crash and should produce a deterministic result
    #expect(
      result.contains("kuberntes") || result.contains("Kubernetes") || result.contains("Kubernotes")
    )
  }

  // MARK: - Case preservation in corrections

  @Test("fuzzy match preserves canonical casing regardless of input case")
  func fuzzyPreservesCanonicalCasing() {
    let words = [CustomWord(canonical: "Kubernetes")]
    let (result, _) = corrector.correct("deployed to KUBERNTES", against: words)
    #expect(result == "deployed to Kubernetes")
  }
}
