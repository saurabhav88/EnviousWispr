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

  private func inputs(userWords: [CustomWord] = [], packTerms: [CustomWord] = []) -> F.Inputs {
    F.Inputs(userWords: userWords, packTerms: packTerms)
  }

  private func disposition(_ r: EditAlignment.Run, _ inputs: F.Inputs) -> F.Disposition {
    F.filter(runs: [r], inputs: inputs)[0].disposition
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

  @Test("no language gate: the ineligibility vocabulary has no language member (founder 2026-09-21)")
  func noLanguageGate() {
    #expect(
      F.IneligibleReason.allCases.map(\.rawValue) == [
        "stopwordPhrase", "contractionEnding", "unfinishedEdit", "aliasOwnedElsewhere",
      ])
    // A run in any script is judged on its own merits.
    #expect(disposition(run("さら", "サラ"), inputs()) == .candidate(.newWord))
    #expect(disposition(run("Sarah", "Saira"), inputs()) == .candidate(.newWord))
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

  // MARK: - No rejection memory (2026-09-21 plan)

  @Test(
    "the inputs are the live words only: a pair the user undid earlier is an ordinary candidate again, and the reversed pair is its own key"
  )
  func noRejectionMemory() {
    let r = run("Sarah", "Saira")
    #expect(disposition(r, inputs()) == .candidate(.newWord))
    #expect(disposition(run("sarah", "SAIRA"), inputs()) == .candidate(.newWord))
    #expect(disposition(run("Saira", "Sarah"), inputs()) == .candidate(.newWord))
    let covered = CustomWord(canonical: "Saira", aliases: ["Sarah"])
    #expect(disposition(r, inputs(userWords: [covered])) == .alreadyCovered)
    let conflict = CustomWord(canonical: "Sara", aliases: ["sarah"])
    #expect(disposition(r, inputs(userWords: [conflict])) == .ineligible(.aliasOwnedElsewhere))
    // The inputs carry the two word lists and nothing else.
    let mirror = Mirror(reflecting: inputs())
    #expect(mirror.children.map { $0.label ?? "" } == ["userWords", "packTerms"])
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

  @Test("similarity is computed only for candidates within the character budget; ineligible and long runs get no evidence")
  func similarityBudget() {
    let ineligible = F.filter(runs: [run("it", "it's")], inputs: inputs())[0]
    #expect(ineligible.disposition == .ineligible(.contractionEnding) && ineligible.similarity == nil)
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
      let prepared = F.prepare(F.filter(runs: runs, inputs: inputs()))
      // The judge sees the cores, never the decoration.
      #expect(prepared.candidates.map(\.replacement) == ["Saira"], "\(pasted)")
      #expect(prepared.candidates.first?.original == runs[0].coreOriginal, "\(pasted)")
    }
  }

  @Test("straight and typographic quoting give the same target, ownership and pair key; internal curly apostrophes survive")
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
    let inp = inputs(userWords: [word])
    _ = F.filter(runs: [run("sarah", "Saira"), run("a", "b"), run("c", "d")], inputs: inp)
    #expect(inp.userWords == [word] && inp.packTerms.isEmpty)
    #expect(word.aliases == ["Sarah"])
  }

  // MARK: - #996 baseline 2026-09-20, W1: a file-name-shaped canonical

  @Test(
    "the one word of 42 the baseline never judged: a fix that changes only casing and punctuation (ClaudeMD → CLAUDE.md) is dropped at alignment BY DESIGN, before the filter, and never reaches the judge"
  )
  func dottedCasingOnlyFixIsShapeDropped() {
    // Frozen convention (plan §3.1 step 5, `EditRunShape`): casing-only and
    // punctuation-only runs are not mishearings; the exam was built on that
    // rule, so the product path drops them before any judge is asked. This
    // binds the disclosure in the PR: such a word is added by hand in
    // Settings → Dictionary, not learned from an edit.
    let aligned = EditAlignment.align(
      pasted: "Please ask ClaudeMD about the invoices today.",
      edited: "Please ask CLAUDE.md about the invoices today.")
    #expect(aligned.limitExceeded == false)
    #expect(aligned.runs.isEmpty)
    #expect(aligned.dropped.map(\.reason) == [.casingOrPunctuationOnly])
    #expect(aligned.dropped.first?.run.coreReplacement == "CLAUDE.md")
    // A real respelling of the same shape IS a candidate: the dot is not the reason.
    let respelt = EditAlignment.align(
      pasted: "Please ask cloud md about the invoices today.",
      edited: "Please ask CLAUDE.md about the invoices today.")
    #expect(respelt.runs.map(\.coreReplacement) == ["CLAUDE.md"])
    let filtered = F.filter(runs: respelt.runs, inputs: inputs())
    #expect(filtered.map(\.disposition) == [.candidate(.newWord)])
    #expect(F.prepare(filtered).candidates.map(\.replacement) == ["CLAUDE.md"])
  }

  @Test("an edit that only deletes letters is unfinished; a padded name or a join still reaches the judge (#3105)")
  func deletionOnlyEditIsUnfinished() {
    for (original, corrected) in [
      ("do fewer words", "drds"), ("Sorat", "S"), ("test experience", "texperience"),
    ] {
      #expect(
        disposition(run(original, corrected), inputs()) == .ineligible(.unfinishedEdit),
        "\(original) -> \(corrected)")
    }
    #expect(disposition(run("adiane", "Adian"), inputs()) == .candidate(.newWord))
    #expect(disposition(run("Johnson's", "Johnson"), inputs()) == .candidate(.newWord))
    #expect(disposition(run("Pay Pal", "PayPal"), inputs()) == .candidate(.newWord))
    #expect(disposition(run("day toast", "Tuist"), inputs()) == .candidate(.newWord))
  }
}
