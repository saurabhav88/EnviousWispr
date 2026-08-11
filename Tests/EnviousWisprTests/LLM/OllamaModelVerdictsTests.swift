import Testing

@testable import EnviousWisprLLM

/// #1950: the measured-verdict authority.
///
/// These freeze the two defects the change exists to remove, so each has a mutation control noted
/// in its comment: revert the production change and the test must fail. A test that passes against
/// the old code would be proving nothing.
@Suite("Ollama model verdicts (#1950)")
struct OllamaModelVerdictsTests {

  // MARK: - The six verdicts and their words

  @Test("every verdict has its approved label")
  func labels() {
    #expect(OllamaModelVerdict.recommended.label == "Recommended")
    #expect(OllamaModelVerdict.mixed.label == "Mixed results")
    #expect(OllamaModelVerdict.unreliable.label == "Unreliable")
    #expect(OllamaModelVerdict.notRecommended.label == "Not recommended")
    #expect(OllamaModelVerdict.notTested.label == "Not tested by us")
    #expect(OllamaModelVerdict.firstParty.label == "Our own model")
  }

  @Test("no label uses the old euphemism vocabulary")
  func noOldVocabulary() {
    // "Fast" was the old `.worst` label, so a model that failed all twenty cases read as a speed
    // choice. "Best" was assigned to a 6% model. Neither word may come back.
    let labels = [
      OllamaModelVerdict.recommended, .mixed, .unreliable, .notRecommended, .notTested,
      .firstParty,
    ].map(\.label)
    #expect(labels.contains("Fast") == false)
    #expect(labels.contains("Best") == false)
    #expect(labels.contains("Medium") == false)
  }

  @Test("no user-facing string carries an em dash or en dash")
  func noDashes() {
    var strings = [
      OllamaModelVerdict.recommended, .mixed, .unreliable, .notRecommended, .notTested,
      .firstParty,
    ].map(\.label)
    strings.append(OllamaModelVerdicts.nonEnglishCaveat)
    strings += OllamaModelVerdicts.measuredModelIDs.map { OllamaModelVerdicts.entry(for: $0).note }
    for string in strings {
      #expect(string.contains("\u{2014}") == false, "em dash in \(string)")
      #expect(string.contains("\u{2013}") == false, "en dash in \(string)")
    }
  }

  // MARK: - Bucket membership, from the 2026-08-11 receipts

  @Test("the measured set is exactly the twelve local arms we judged")
  func measuredSet() {
    let expected: Set<String> = [
      "qwen2.5:3b", "qwen3:0.6b", "qwen2.5:7b",
      "gemma2:2b", "gemma2", "gemma3n:e4b",
      "llama3.2", "mistral", "deepseek-r1:1.5b",
      "phi3", "llama3.2:1b", "tinyllama",
    ]
    #expect(OllamaModelVerdicts.measuredModelIDs == expected)
    // `eg-1` carries a verdict but is NOT a measured id: it was scored on a different corpus, and
    // the generated-fixture test asserts set equality against this, so including it would fail there.
    #expect(OllamaModelVerdicts.measuredModelIDs.contains("eg-1") == false)
  }

  @Test(
    "each model's verdict matches its measured pass rate",
    arguments: [
      ("qwen2.5:3b", OllamaModelVerdict.recommended),
      ("qwen3:0.6b", .recommended),
      ("qwen2.5:7b", .recommended),
      ("gemma2:2b", .mixed),
      ("gemma2", .mixed),
      ("gemma3n:e4b", .mixed),
      ("llama3.2", .unreliable),
      ("mistral", .unreliable),
      ("deepseek-r1:1.5b", .unreliable),
      ("phi3", .notRecommended),
      ("llama3.2:1b", .notRecommended),
      ("tinyllama", .notRecommended),
    ])
  func verdictPerModel(modelID: String, expected: OllamaModelVerdict) {
    #expect(OllamaModelVerdicts.verdict(for: modelID) == expected)
  }

  @Test("the shipped default candidates are both recommended")
  func bothQwenRecommended() {
    // The founder's decision was to recommend BOTH, so neither may quietly drop out.
    #expect(OllamaModelVerdicts.verdict(for: "qwen2.5:3b") == .recommended)
    #expect(OllamaModelVerdicts.verdict(for: "qwen2.5:7b") == .recommended)
  }

  @Test("the old default is no longer presented as a good choice")
  func oldDefaultIsUnreliable() {
    // 1 pass in 20 with 11 trust-breaking failures, and it was labelled "Best".
    #expect(OllamaModelVerdicts.verdict(for: "llama3.2") == .unreliable)
  }

  // MARK: - The size heuristic is gone

  @Test(
    "an unmeasured model is never given a verdict from its name or size",
    arguments: [
      "someones-finetune:7b",  // 7B: the old heuristic returned .best
      "someones-finetune:70b",  // large: still nothing
      "someones-tiny:1b",  // 1B: the old heuristic returned .worst
      "no-size-at-all",  // nil params: the old heuristic returned .medium
      "glm-5.2:cloud",  // a hosted id, which used to carry a .medium placeholder
      "phi",  // dropped from the catalog, never benchmarked
    ])
  func unmeasuredIsNotTested(modelID: String) {
    // MUTATION CONTROL: restore `inferQualityTier` and the 7B and 1B rows come back `.best` and
    // `.worst`, so this fails. That is the defect: a recommendation from a parameter count.
    #expect(OllamaModelVerdicts.verdict(for: modelID) == .notTested)
    #expect(OllamaModelVerdicts.entry(for: modelID).note.isEmpty)
  }

  @Test("a name that merely contains a cloud token is not recommended")
  func tokenBearingNameIsNotRecommended() {
    // The picker's old classifier recommended any id containing `mini`/`nano`/`flash`/`haiku`, so
    // an unmeasured `phi3-mini` was presented as recommended for cleanup on name alone.
    for modelID in ["phi3-mini", "acme-mini", "something-nano", "vendor-flash", "x-haiku"] {
      #expect(OllamaModelVerdicts.verdict(for: modelID) == .notTested, "\(modelID)")
    }
  }

  // MARK: - Notes

  @Test("every measured model has a non-empty note, and nothing else does")
  func notes() {
    for modelID in OllamaModelVerdicts.measuredModelIDs {
      #expect(
        OllamaModelVerdicts.entry(for: modelID).note.isEmpty == false,
        "measured model \(modelID) must say what goes wrong")
    }
    // EG-1 and unmeasured models say nothing rather than implying a reading we do not have.
    #expect(OllamaModelVerdicts.entry(for: "eg-1").note.isEmpty)
    #expect(OllamaModelVerdicts.entry(for: "who-knows").note.isEmpty)
  }

  @Test("models with identical measurements carry identical words")
  func identicalMeasurementsIdenticalWords() {
    // 5.0% each with 10 to 11 trust-breaking failures, 2.1pp apart on an instrument whose tail is
    // 5.0pp. Three different sentences would imply a distinction the data cannot support.
    let sameScore = ["llama3.2", "mistral", "deepseek-r1:1.5b"]
    let notes = Set(sameScore.map { OllamaModelVerdicts.entry(for: $0).note })
    #expect(notes.count == 1, "expected one shared phrase, got \(notes)")

    let gemmas = ["gemma2:2b", "gemma2", "gemma3n:e4b"]
    #expect(Set(gemmas.map { OllamaModelVerdicts.entry(for: $0).note }).count == 1)
  }

  // MARK: - Identity

  @Test("a tag of the same model resolves to the same verdict")
  func canonicalIdentity() {
    // `llama3.2` and `llama3.2:latest` are one model; `llama3.2:1b` is a different one, and they
    // land in different buckets, so getting this wrong would mislabel both.
    #expect(OllamaModelVerdicts.verdict(for: "llama3.2:latest") == .unreliable)
    #expect(OllamaModelVerdicts.verdict(for: "llama3.2") == .unreliable)
    #expect(OllamaModelVerdicts.verdict(for: "llama3.2:1b") == .notRecommended)
    #expect(OllamaModelVerdicts.verdict(for: "LLAMA3.2") == .unreliable)
  }

  @Test("first-party tags share the first-party verdict without admitting lookalikes")
  func firstPartyIdentity() {
    // `canonicalModelName` strips only `:latest`, so without routing through the first-party
    // identity authority a user running the already-supported `eg-1:q4` would be told
    // "Not tested by us" about our own model.
    for modelID in ["eg-1", "eg-1:latest", "eg-1:q4", "EG-1"] {
      #expect(OllamaModelVerdicts.verdict(for: modelID) == .firstParty, "\(modelID)")
    }
    // Lookalikes are somebody else's model and must stay unmeasured.
    for modelID in ["eg-10", "eg-1-q4", "eg-1-acme-client"] {
      #expect(OllamaModelVerdicts.verdict(for: modelID) == .notTested, "\(modelID)")
    }
  }

  @Test("the non-English caveat is stated once, as a general claim")
  func caveat() {
    // Best local result is 3 of 7 non-English cases; seven of twelve models pass zero of 7. It is a
    // property of local polish, not of one model, so it must not name a model.
    let caveat = OllamaModelVerdicts.nonEnglishCaveat
    #expect(caveat.isEmpty == false)
    for modelID in OllamaModelVerdicts.measuredModelIDs {
      #expect(caveat.contains(modelID) == false, "the shared caveat must not name \(modelID)")
    }
  }
}
