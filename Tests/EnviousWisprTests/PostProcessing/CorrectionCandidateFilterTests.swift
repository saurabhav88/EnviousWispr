import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprPostProcessing

/// #996 chunk 5b: the filter decides which runs reach the judge and which
/// Accept outcome a card would offer. Wrong here means a rejected pair asked
/// again, a stopword phrase judged, a sound-alike added to the wrong word, or
/// an existing word offered as new.
/// Class: `.productOutcome`.
@Suite(.tags(.productOutcome)) struct CorrectionCandidateFilterTests {

  private typealias F = CorrectionCandidateFilter

  private func run(_ original: String, _ replacement: String) -> EditAlignment.Run {
    EditAlignment.Run(
      original: original, replacement: replacement, originalRange: 0..<1, editedRange: 0..<1,
      labels: [.substitute])
  }

  private func inputs(
    userWords: [CustomWord] = [], packTerms: [CustomWord] = [], open: [String: UUID] = [:],
    rejected: Set<String> = [], language: String? = "en",
    supported: Set<String>? = ["en", "de", "es"]
  ) -> F.Inputs {
    F.Inputs(
      userWords: userWords, packTerms: packTerms, openProposals: open, rejectedPairKeys: rejected,
      dictationLanguage: language, supportedLanguages: supported)
  }

  private func disposition(_ r: EditAlignment.Run, _ inputs: F.Inputs) -> F.Disposition {
    F.filter(runs: [r], inputs: inputs)[0].disposition
  }

  private func key(_ o: String, _ c: String) -> String {
    CorrectionPairKey.make(original: o, corrected: c)
  }

  // MARK: - Ineligible reasons

  @Test("a phrase made only of stopwords is ineligible; one real word makes it eligible")
  func stopwordPhrase() {
    #expect(disposition(run("and we said", "and we"), inputs()) == .ineligible(.stopwordPhrase))
    #expect(disposition(run("At the", "at it"), inputs()) == .ineligible(.stopwordPhrase))
    #expect(disposition(run("and we said", "and Wade"), inputs()) == .candidate(.newWord))
  }

  @Test("a corrected run ending in a contraction is ineligible")
  func contractionEnding() {
    for corrected in [
      "it's", "don't", "we're", "they'll", "I've", "she'd", "I'm", "Sarah\u{2019}s",
    ] {
      #expect(
        disposition(run("its", corrected), inputs()) == .ineligible(.contractionEnding), "\(corrected)")
    }
    #expect(disposition(run("sarah", "Saira"), inputs()) == .candidate(.newWord))
    #expect(disposition(run("os", "O's"), inputs()) == .ineligible(.contractionEnding))
    // A bare apostrophe word ("'s") is too short to be a contraction ending of anything.
    #expect(disposition(run("x", "'s"), inputs()) == .candidate(.newWord))
  }

  @Test(
    "no dictation language, an unsupported one, or an arm with no language evidence grants nothing")
  func languageGate() {
    let r = run("Sarah", "Saira")
    #expect(disposition(r, inputs(language: nil)) == .ineligible(.languageUnsupported))
    #expect(disposition(r, inputs(language: "ja")) == .ineligible(.languageUnsupported))
    #expect(
      disposition(r, inputs(language: "en", supported: nil)) == .ineligible(.languageUnsupported))
    #expect(disposition(r, inputs(language: "de")) == .candidate(.newWord))
  }

  // MARK: - Target resolution and ownership

  @Test(
    "an existing user canonical resolves to .existingWord with its id; a pack term likewise, and user beats pack"
  )
  func existingWordAndPack() {
    let saira = CustomWord(canonical: "Saira", aliases: ["sara"])
    let packSaira = CustomWord(canonical: "saira", source: .pack)
    #expect(
      disposition(run("Sarah", "Saira"), inputs(userWords: [saira]))
        == .candidate(.existingWord(saira.id)))
    #expect(
      disposition(run("Sarah", "saira"), inputs(userWords: [saira]))
        == .candidate(.existingWord(saira.id)))
    #expect(
      disposition(run("Sarah", "Saira"), inputs(packTerms: [packSaira]))
        == .candidate(.existingWord(packSaira.id)))
    #expect(
      disposition(run("Sarah", "Saira"), inputs(userWords: [saira], packTerms: [packSaira]))
        == .candidate(.existingWord(saira.id)),
      "user word beats the pack term for the same canonical")
    #expect(disposition(run("Sarah", "Saira"), inputs()) == .candidate(.newWord))
  }

  @Test(
    "the target already carrying the original as its canonical or alias is alreadyCovered, not a conflict"
  )
  func alreadyCovered() {
    let saira = CustomWord(canonical: "Saira", aliases: ["Sarah"])
    #expect(disposition(run("sarah", "Saira"), inputs(userWords: [saira])) == .alreadyCovered)
    #expect(disposition(run("Saira", "saira"), inputs(userWords: [saira])) == .alreadyCovered)
    // The same alias on ANOTHER word is a conflict, not coverage.
    let other = CustomWord(canonical: "Sara", aliases: ["sarah"])
    #expect(
      disposition(
        run("sarah", "Saira"), inputs(userWords: [CustomWord(canonical: "Saira"), other]))
        == .ineligible(.aliasOwnedElsewhere))
  }

  @Test(
    "an original that is another word's trigger, or a corrected phrase that is another word's alias, is dropped as owned elsewhere"
  )
  func ownedElsewhere() {
    let anika = CustomWord(canonical: "Anika", aliases: ["annie"])
    // The original "annie" belongs to Anika; the user is fixing it to a new word Annie-Lou.
    #expect(
      disposition(run("annie", "Annalou"), inputs(userWords: [anika]))
        == .ineligible(.aliasOwnedElsewhere))
    // The corrected phrase is another word's alias.
    let kube = CustomWord(canonical: "Kubernetes", aliases: ["k8s"])
    #expect(
      disposition(run("kates", "k8s"), inputs(userWords: [kube]))
        == .ineligible(.aliasOwnedElsewhere))
    // Cross-namespace: a pack term owning the original blocks a new-word candidate too.
    let packWord = CustomWord(canonical: "Adyen", aliases: ["adiane"], source: .pack)
    #expect(
      disposition(run("adiane", "Adian"), inputs(packTerms: [packWord]))
        == .ineligible(.aliasOwnedElsewhere))
    // Same-target coverage is NOT a conflict: the resolved target holds the claim itself.
    #expect(disposition(run("annie", "Anika"), inputs(userWords: [anika])) == .alreadyCovered)
    // Unrelated words never block.
    #expect(disposition(run("annie", "Annalou"), inputs(userWords: [kube])) == .candidate(.newWord))
  }

  // MARK: - Ledger memory

  @Test(
    "a rejected pair is dropped and never becomes a candidate or a refresh, whatever else applies")
  func rejectedPair() {
    let r = run("Sarah", "Saira")
    let k = key("Sarah", "Saira")
    #expect(disposition(r, inputs(rejected: [k])) == .rejected)
    // Casing of the pair does not evade the tombstone.
    #expect(disposition(run("sarah", "SAIRA"), inputs(rejected: [k])) == .rejected)
    // Rejection outranks an open proposal, a covered target and the language gate.
    let open = UUID()
    #expect(disposition(r, inputs(open: [k: open], rejected: [k])) == .rejected)
    #expect(
      disposition(
        r, inputs(userWords: [CustomWord(canonical: "Saira", aliases: ["Sarah"])], rejected: [k]))
        == .rejected)
    #expect(disposition(r, inputs(rejected: [k], language: nil)) == .rejected)
    // The reversed pair is a different key.
    #expect(disposition(run("Saira", "Sarah"), inputs(rejected: [k])) == .candidate(.newWord))
  }

  @Test(
    "an open proposal for the pair is refreshed, not re-judged; coverage and conflicts still win over it"
  )
  func openPairRefreshed() {
    let r = run("Sarah", "Saira")
    let k = key("Sarah", "Saira")
    let open = UUID()
    #expect(disposition(r, inputs(open: [k: open])) == .refreshOpen(proposalID: open))
    #expect(
      disposition(run("sarah", "saira"), inputs(open: [k: open])) == .refreshOpen(proposalID: open))
    let covered = CustomWord(canonical: "Saira", aliases: ["Sarah"])
    #expect(disposition(r, inputs(userWords: [covered], open: [k: open])) == .alreadyCovered)
    let conflict = CustomWord(canonical: "Sara", aliases: ["sarah"])
    #expect(
      disposition(r, inputs(userWords: [conflict], open: [k: open]))
        == .ineligible(.aliasOwnedElsewhere))
    #expect(
      disposition(r, inputs(open: [k: open], language: nil)) == .ineligible(.languageUnsupported))
  }

  // MARK: - Evidence

  @Test(
    "similarity is advisory Latin-only evidence: a number for Latin runs, nil outside, never zero")
  func similarityEvidence() {
    let latin = F.filter(runs: [run("Sarah", "Saira")], inputs: inputs())[0]
    #expect((latin.similarity ?? -1) > 0.5)
    let cyrillic = F.filter(runs: [run("Саша", "Сашо")], inputs: inputs())[0]
    #expect(cyrillic.similarity == nil)
    #expect(cyrillic.disposition == .candidate(.newWord), "no evidence is not a veto")
    let mixed = F.filter(runs: [run("Sarah", "Сара")], inputs: inputs())[0]
    #expect(mixed.similarity == nil)
    let accented = F.filter(runs: [run("Jose", "José")], inputs: inputs())[0]
    #expect(accented.similarity != nil)
  }

  // MARK: - Request shape

  @Test(
    "eligible runs are ordered capitalised-first with source order for ties, capped at four, ids assigned after the cap, and the result builds a valid request"
  )
  func orderingAndCap() throws {
    let raw = [
      run("aa", "bb"), run("cc", "Dd"), run("ee", "ff"), run("gg", "Hh"), run("ii", "jj"),
      run("and we said", "and we"),  // ineligible, must not occupy a slot
      run("kk", "Ll"),
    ]
    let filtered = F.filter(runs: raw, inputs: inputs())
    let prepared = F.prepare(filtered)
    #expect(prepared.candidates.map(\.replacement) == ["Dd", "Hh", "Ll", "bb"])
    #expect(prepared.candidates.map(\.id) == [1, 2, 3, 4])
    #expect(prepared.overflow.map(\.run.replacement) == ["ff", "jj"])
    #expect(prepared.byID[1]?.run.original == "cc" && prepared.byID[4]?.run.original == "aa")
    let request = try CorrectionJudgeRequest(
      candidates: prepared.candidates, context: "aa cc ee gg ii kk", language: "en")
    #expect(request.candidates.count == 4)
    // Fewer than four: no padding, ids still 1...n.
    let two = F.prepare(F.filter(runs: [run("x", "y"), run("p", "q")], inputs: inputs()))
    #expect(two.candidates.map(\.id) == [1, 2] && two.overflow.isEmpty)
    // Nothing eligible: nothing prepared.
    let none = F.prepare(F.filter(runs: [run("and we said", "and we")], inputs: inputs()))
    #expect(none.candidates.isEmpty && none.byID.isEmpty)
  }

  @Test("similarity is computed only for candidates within the character budget; rejected and long runs get no evidence")
  func similarityBudget() {
    let k = key("Sarah", "Saira")
    let rejected = F.filter(runs: [run("Sarah", "Saira")], inputs: inputs(rejected: [k]))[0]
    #expect(rejected.disposition == .rejected && rejected.similarity == nil)
    let long = F.filter(runs: [run(String(repeating: "a", count: 300), String(repeating: "b", count: 300))], inputs: inputs())[0]
    #expect(long.disposition == .candidate(.newWord) && long.similarity == nil)
    let short = F.filter(runs: [run(String(repeating: "a", count: 200), String(repeating: "b", count: 200))], inputs: inputs())[0]
    #expect(short.similarity != nil)
  }

  @Test("alignment to filter end to end: sentence punctuation and quotes never hide an existing word, a pack term or a conflict")
  func punctuationEndToEnd() throws {
    let saira = CustomWord(canonical: "Saira")
    let packSaira = CustomWord(canonical: "saira", source: .pack)
    let conflict = CustomWord(canonical: "Sara", aliases: ["sarah"])
    for (pasted, edited) in [
      ("Ask Sarah.", "Ask Saira."), ("she said \"sarah\" today", "she said \"Saira\" today"),
      ("(Sarah)", "(Saira)"), ("Sarah?!", "Saira?!"),
      // Typographic delimiters: macOS smart quotes and guillemets.
      ("Ask \u{201C}Sarah\u{201D} today", "Ask \u{201C}Saira\u{201D} today"),
      ("Ask \u{2018}Sarah\u{2019} today", "Ask \u{2018}Saira\u{2019} today"),
      ("Ask \u{00AB}Sarah\u{00BB} today", "Ask \u{00AB}Saira\u{00BB} today"),
    ] {
      let runs = EditAlignment.align(pasted: pasted, edited: edited).runs
      #expect(runs.count == 1, "\(pasted)")
      #expect(F.filter(runs: runs, inputs: inputs(userWords: [saira]))[0].disposition == .candidate(.existingWord(saira.id)), "\(pasted)")
      #expect(F.filter(runs: runs, inputs: inputs(packTerms: [packSaira]))[0].disposition == .candidate(.existingWord(packSaira.id)), "\(pasted)")
      #expect(F.filter(runs: runs, inputs: inputs(userWords: [conflict]))[0].disposition == .ineligible(.aliasOwnedElsewhere), "\(pasted)")
      #expect(F.filter(runs: runs, inputs: inputs(rejected: [key("Sarah", "Saira")]))[0].disposition == .rejected, "\(pasted)")
      let prepared = F.prepare(F.filter(runs: runs, inputs: inputs()))
      // The judge sees the cores, never the decoration.
      #expect(prepared.candidates.map(\.replacement) == ["Saira"], "\(pasted)")
      #expect(prepared.candidates.first?.original == runs[0].coreOriginal, "\(pasted)")
    }
  }

  @Test("straight and typographic quoting give the same target, ownership and rejection key; internal curly apostrophes survive")
  func typographicQuotesMatchStraightOnes() throws {
    let saira = CustomWord(canonical: "Saira")
    let conflict = CustomWord(canonical: "Sara", aliases: ["sarah"])
    let straight = EditAlignment.align(pasted: "say \"Sarah\"", edited: "say \"Saira\"").runs
    let curly = EditAlignment.align(pasted: "say \u{201C}Sarah\u{201D}", edited: "say \u{201C}Saira\u{201D}").runs
    #expect(straight.count == 1 && curly.count == 1)
    let fs = F.filter(runs: straight, inputs: inputs(userWords: [saira]))[0]
    let fc = F.filter(runs: curly, inputs: inputs(userWords: [saira]))[0]
    #expect(fs.pairKey == fc.pairKey && fs.disposition == fc.disposition && fs.disposition == .candidate(.existingWord(saira.id)))
    #expect(F.filter(runs: curly, inputs: inputs(userWords: [conflict]))[0].disposition == .ineligible(.aliasOwnedElsewhere))
    #expect(F.filter(runs: curly, inputs: inputs(rejected: [fs.pairKey]))[0].disposition == .rejected)
    let oreilly = try #require(EditAlignment.align(pasted: "call oreily today", edited: "call O\u{2019}Reilly today").runs.first)
    #expect(oreilly.coreReplacement == "O\u{2019}Reilly")
  }

  @Test("a new-word candidate excludes no owner; an existing target excludes only itself")
  func exclusionIdentity() {
    let anika = CustomWord(canonical: "Anika", aliases: ["annie"])
    // New word: Anika's claim on the original blocks, because nobody is excluded.
    #expect(disposition(run("annie", "Annalou"), inputs(userWords: [anika])) == .ineligible(.aliasOwnedElsewhere))
    // Existing target: its own claim on the corrected canonical does not block itself.
    #expect(disposition(run("aneeka", "Anika"), inputs(userWords: [anika])) == .candidate(.existingWord(anika.id)))
    // Two runs of the same pair in one call get the same answer (no randomness).
    let twice = F.filter(runs: [run("annie", "Annalou"), run("annie", "Annalou")], inputs: inputs(userWords: [anika]))
    #expect(twice[0].disposition == twice[1].disposition)
  }

  @Test("inputs are never mutated by filtering")
  func inputsUntouched() {
    let word = CustomWord(canonical: "Saira", aliases: ["Sarah"])
    let open = [key("a", "b"): UUID()]
    let rejected: Set<String> = [key("c", "d")]
    let inp = inputs(userWords: [word], open: open, rejected: rejected)
    _ = F.filter(runs: [run("sarah", "Saira"), run("a", "b"), run("c", "d")], inputs: inp)
    #expect(
      inp.userWords == [word] && inp.openProposals == open && inp.rejectedPairKeys == rejected)
    #expect(word.aliases == ["Sarah"])
  }
}
