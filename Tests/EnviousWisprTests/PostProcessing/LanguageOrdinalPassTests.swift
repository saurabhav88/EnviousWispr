import Foundation
import Testing

@testable import EnviousWisprPostProcessing

// MARK: - The ordinal pass (#1677, PR 2 chunk 5)
//
// These tests drive the real pass and the real shared editor. Nothing registers or calls the pass
// from production, and nothing here certifies the German ordinal cell: with the German data today
// NO ordinal followed by a word can be converted, because the reviewed entries name no months, no
// fixed expressions and no way to rule out a name. Those rows are reported UNAVAILABLE, not as
// conversions and not as correct refusals.
//
// Two kinds of evidence are kept apart on purpose:
//  - FROZEN GERMAN RESULTS: the 79 ordinal rows through the pass built from the generated German
//    data, with a per-row disposition ledger written from reading each sentence.
//  - MECHANISM EVIDENCE: small literal sentences run against rules that carry a SYNTHETIC context
//    authority, to prove the conversion branch, the edit boundaries and the reviewed matchers
//    work when an authority exists. They never waive an unknown German predicate.
//
// When this fails, an ordinal is converted next to a date, a fixed expression, a fraction or a
// name, or a convertible one is left untouched with no named reason.

@Suite("German ordinal pass (#1677)", .tags(.driftGuard))
struct LanguageOrdinalPassTests {

  let grammar: LanguageNumberGrammar
  /// The pass built from the generated German data: no context authority.
  let german: LanguageOrdinalPass

  init() throws {
    grammar = try LanguageNumberGrammar.german()
    german = LanguageOrdinalPass(grammar: grammar, rules: try LanguageOrdinalRules.german())
  }

  // MARK: Helpers

  /// SYNTHETIC authority for mechanism tests only. It is not German data.
  private static let syntheticEvidence = LanguageOrdinalContextEvidence(
    calendarWords: ["mai", "april", "oktober"], fixedPhraseNouns: ["hilfe", "wahl", "hand"],
    properNameClearance: .lowercaseAdjectiveOrthography)

  private func mechanism(_ evidence: LanguageOrdinalContextEvidence = syntheticEvidence) throws
    -> LanguageOrdinalPass
  {
    let rules = try LanguageOrdinalRules.german()
    return LanguageOrdinalPass(
      grammar: grammar,
      rules: LanguageOrdinalRules(
        writtenSuffix: rules.writtenSuffix, refusals: rules.refusals, evidence: evidence))
  }

  private func run(_ text: String, using pass: LanguageOrdinalPass? = nil) throws
    -> (LanguageTextSnapshot, LanguageOrdinalPass.Run)
  {
    let snapshot = LanguageTextSnapshot(text)
    guard case .ran(let result) = (pass ?? german).propose(in: snapshot) else {
      Issue.record("the pass reported itself unavailable")
      throw CancellationError()
    }
    return (snapshot, result)
  }

  private func converted(_ text: String, using pass: LanguageOrdinalPass? = nil) throws -> String {
    let (snapshot, result) = try run(text, using: pass)
    switch LanguageTextEditor.apply(result.edits, to: snapshot) {
    case .applied(let output): return output
    case .refused(let refusal):
      Issue.record("the editor refused the pass's own edits: \(refusal)")
      return text
    }
  }

  private func dispositions(_ text: String, using pass: LanguageOrdinalPass? = nil) throws
    -> [LanguageOrdinalPass.Disposition]
  {
    try run(text, using: pass).1.candidates.map(\.disposition)
  }

  private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

  // MARK: The reviewed rules

  @Test("the rules adapt the six reviewed entries with their identity, kinds and enforcement")
  func rulesFacts() throws {
    let rules = try LanguageOrdinalRules.german()
    #expect(rules.writtenSuffix == ".")
    #expect(
      rules.refusals.map(\.id) == [
        "ref-ordinal-001", "ref-ordinal-002", "ref-ordinal-003", "ref-ordinal-004",
        "ref-ordinal-005", "ref-ordinal-006",
      ])
    #expect(rules.refusals.map(\.version) == [1, 1, 2, 2, 1, 2])
    #expect(rules.refusals.allSatisfy { $0.contentSHA256.count == 64 })
    #expect(rules.evidence == .none)
    #expect(rules.tokens(for: .ordinalAdverb) == ["erstens", "zweitens", "drittens", "viertens"])
    #expect(
      rules.literalPhrases == [
        ["ein", "drittel"], ["ein", "viertel"], ["ein", "fünftel"], ["ein", "zehntel"],
        ["ein", "achtel"],
      ])
    // The reviewed matchers split into explicit token matches, structure, authority and withholds.
    let byEnforcement = Dictionary(
      grouping: LanguageOrdinalRules.Shape.allCases, by: { $0.enforcement })
    #expect(byEnforcement[.reviewedTokenMatch] == [.ordinalAdverb])
    #expect(byEnforcement[.structuralAdmission] == [.withoutFollowingNoun])
    #expect(byEnforcement[.authorityDependent] == [.dateContext, .fixedExpression])
    #expect(byEnforcement[.conservativeWithhold] == [.properName])
  }

  @Test("the lowered rows equal the reviewed ordinal entries in the refusal file, read directly")
  func rulesMatchTheRefusalFile() throws {
    let url = RepoRoot.url.appending(path: "scripts/itn/refusals/de.json")
    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let reviewed = try #require(object["reviewed_entries"] as? [[String: Any]])
    let ordinal = reviewed.filter { $0["category"] as? String == "ordinal" }
      .sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
    let rules = try LanguageOrdinalRules.german()
    #expect(ordinal.count == 6)
    #expect(ordinal.compactMap { $0["id"] as? String } == rules.refusals.map(\.id))
    #expect(ordinal.compactMap { $0["version"] as? Int } == rules.refusals.map(\.version))
    #expect(
      ordinal.compactMap { $0["content_sha256"] as? String } == rules.refusals.map(\.contentSHA256))
    let kinds = ordinal.compactMap { ($0["match"] as? [String: Any])?["kind"] as? String }
    #expect(
      kinds == [
        "context_shape", "context_shape", "context_shape", "literal_phrase", "context_shape",
        "context_shape",
      ])
    // The vocabulary shape without a reviewed entry is not lowered; pending entries are not either.
    let shapes = ordinal.compactMap { ($0["match"] as? [String: Any])?["context_shape"] as? String }
    #expect(shapes.contains("ordinal_word_before_fraction_noun") == false)
    let pending = (object["pending_entries"] as? [[String: Any]] ?? []).compactMap {
      $0["id"] as? String
    }
    #expect(Set(pending).isDisjoint(with: rules.refusals.map(\.id)))
  }

  @Test("unsupported, missing, duplicate or malformed data fails the whole adaptation")
  func adaptationFailsClosed() {
    typealias Data = GermanOrdinalData
    let good = Data.refusals
    func row(
      _ index: Int, shape: String?? = nil, kind: Data.Refusal.Kind? = nil, tokens: [String]? = nil
    ) -> Data.Refusal {
      let base = good[index]
      return Data.Refusal(
        id: base.id, version: base.version, contentSHA256: base.contentSHA256,
        reasonCode: base.reasonCode, kind: kind ?? base.kind,
        contextShape: shape ?? base.contextShape, tokens: tokens ?? base.tokens,
        reviewRef: base.reviewRef)
    }
    func build(_ rows: [Data.Refusal], suffix: String = ".") -> LanguageOrdinalRules.BuildError? {
      do {
        _ = try LanguageOrdinalRules.build(rows: rows, writtenSuffix: suffix, evidence: .none)
        return nil
      } catch let error as LanguageOrdinalRules.BuildError {
        return error
      } catch {
        return nil
      }
    }
    #expect(build(good) == nil)
    var replaced = good
    replaced[4] = row(4, shape: .some("ordinal_word_before_fraction_noun"))
    #expect(build(replaced) == .unsupportedShape("ordinal_word_before_fraction_noun"))
    replaced[4] = row(4, shape: .some(nil))
    #expect(build(replaced) == .shapeWithoutEntryKind("ref-ordinal-005"))
    replaced = good
    replaced[3] = row(3, shape: .some("ordinal_adverb"))
    #expect(build(replaced) == .unknownKind("ref-ordinal-004"))
    #expect(build(Array(good[0..<3] + good[4...])) == .missingLiteralPhrases)
    #expect(build(Array(good[0..<2] + good[3...])) == .missingShape("ordinal_word_in_fixed_phrase"))
    #expect(build(good + [row(0)]) == .duplicateShape("ordinal_adverb"))
    replaced = good
    replaced[0] = row(0, tokens: [])
    #expect(build(replaced) == .emptyTokens("ref-ordinal-001"))
    replaced[0] = row(0, tokens: [""])
    #expect(build(replaced) == .emptyTokens("ref-ordinal-001"))
    #expect(build(good, suffix: "") == .emptySuffix)
  }

  @Test(
    "a pass whose rules lack a reviewed shape or phrase entry is unavailable and proposes nothing")
  func unavailableRules() throws {
    let full = try LanguageOrdinalRules.german()
    let noShape = LanguageOrdinalRules(
      writtenSuffix: full.writtenSuffix,
      refusals: full.refusals.filter { $0.id != "ref-ordinal-005" }, evidence: .none)
    let noPhrase = LanguageOrdinalRules(
      writtenSuffix: full.writtenSuffix,
      refusals: full.refusals.filter { $0.id != "ref-ordinal-004" }, evidence: .none)
    let snapshot = LanguageTextSnapshot("Das ist die dritte Ausgabe.")
    for broken in [noShape, noPhrase] {
      guard
        case .unavailable = LanguageOrdinalPass(grammar: grammar, rules: broken).propose(
          in: snapshot)
      else {
        Issue.record("incomplete rules must make the pass unavailable")
        continue
      }
    }
    // Control: complete rules run (and report the missing German context, see below).
    guard case .ran = german.propose(in: snapshot) else {
      Issue.record("complete rules must run")
      return
    }
  }

  // MARK: The frozen German rows: the disposition ledger

  /// The disposition each frozen control sentence must meet, written from reading the sentence and
  /// the reviewed rules (not read from the pass). Dependencies by row follow the chunk prompt.
  private enum Expected: Equatable {
    case unavailable
    case adverb
    case fraction
    case withoutNoun
    case capitalized
    case noCandidate
  }

  private static let controlLedger: [String: Expected] = {
    var ledger: [String: Expected] = [:]
    for number in [1, 7, 13, 19, 25] {
      ledger[String(format: "de-ordinal-ctl-%03d", number)] = .fraction
    }
    for number in [4, 10, 16, 22] {
      ledger[String(format: "de-ordinal-ctl-%03d", number)] = .adverb
    }
    // Fixed-expression controls: two are withheld by capitalization, three stay unavailable.
    for number in [2, 20] { ledger[String(format: "de-ordinal-ctl-%03d", number)] = .capitalized }
    for number in [8, 14, 26] {
      ledger[String(format: "de-ordinal-ctl-%03d", number)] = .unavailable
    }
    // Proper-name and title controls: one capitalized title, five terminal ordinals.
    ledger["de-ordinal-ctl-009"] = .capitalized
    for number in [3, 15, 21, 27, 30] {
      ledger[String(format: "de-ordinal-ctl-%03d", number)] = .withoutNoun
    }
    // No-following-noun controls.
    for number in [5, 11, 17, 23, 28] {
      ledger[String(format: "de-ordinal-ctl-%03d", number)] = .withoutNoun
    }
    // Date controls: the month is a capitalized word the data cannot rule out.
    for number in [6, 12, 18, 24, 29] {
      ledger[String(format: "de-ordinal-ctl-%03d", number)] = .unavailable
    }
    // Already-formatted controls.
    for number in 31...59 { ledger[String(format: "de-ordinal-ctl-%03d", number)] = .noCandidate }
    return ledger
  }()

  @Test("every frozen ordinal row goes through the real pass and the shared editor, row by row")
  func frozenOrdinalRows() throws {
    let development = try ITNDevelopmentFixtures.development().rows.filter {
      $0.category == "ordinal"
    }
    let controls = try ITNDevelopmentFixtures.controls().rows.filter { $0.category == "ordinal" }
    let lexical = controls.filter { $0.refusalReason != "already_formatted" }
    let formatted = controls.filter { $0.refusalReason == "already_formatted" }
    #expect(development.count == 20)
    #expect(lexical.count == 30)
    #expect(formatted.count == 29)

    var visited = 0
    var definiteAssertions = 0
    var unavailable = 0
    let conversions = 0
    var counts: [String: Int] = [:]
    let missingGerman: [LanguageOrdinalPass.MissingContext] = [
      .calendarAuthority, .fixedPhraseAuthority, .properNameClearance,
    ]

    for row in development {
      visited += 1
      let (_, result) = try run(row.spokenInput)
      #expect(result.edits.isEmpty, "\(row.id): the German data must not convert")
      #expect(bytes(try converted(row.spokenInput)) == bytes(row.spokenInput), "\(row.id)")
      #expect(result.candidates.count == 1, "\(row.id)")
      #expect(result.candidates.first?.disposition == .unavailable(missingGerman), "\(row.id)")
      // The row's accepted variant is a conversion; unchanged input is NOT a pass for it.
      #expect(
        row.acceptedWrittenVariants.contains { bytes($0) == bytes(row.spokenInput) } == false,
        "\(row.id)")
      unavailable += 1
      counts["development unavailable", default: 0] += 1
    }

    for row in lexical + formatted {
      visited += 1
      let expected = try #require(Self.controlLedger[row.id], "\(row.id) has no ledger entry")
      let (_, result) = try run(row.spokenInput)
      #expect(result.edits.isEmpty, "\(row.id): proposed an edit")
      #expect(bytes(try converted(row.spokenInput)) == bytes(row.spokenInput), "\(row.id)")
      #expect(
        row.acceptedWrittenVariants.contains { bytes($0) == bytes(row.spokenInput) }, "\(row.id)")
      let dispositions = result.candidates.map(\.disposition)
      switch expected {
      case .noCandidate:
        #expect(dispositions.isEmpty, "\(row.id)")
      case .adverb:
        #expect(dispositions == [.refused(.adverbToken(entry: "ref-ordinal-001"))], "\(row.id)")
      case .fraction:
        #expect(dispositions == [.refused(.literalPhrase(entry: "ref-ordinal-004"))], "\(row.id)")
      case .withoutNoun:
        #expect(dispositions == [.refused(.withoutFollowingNoun)], "\(row.id)")
      case .capitalized:
        #expect(dispositions == [.refused(.capitalizedOrdinal)], "\(row.id)")
      case .unavailable:
        #expect(dispositions == [.unavailable(missingGerman)], "\(row.id)")
      }
      if expected == .unavailable {
        unavailable += 1
        counts["control unavailable", default: 0] += 1
      } else {
        definiteAssertions += 1
        counts["control \(expected)", default: 0] += 1
      }
    }

    #expect(visited == 79)
    #expect(definiteAssertions + unavailable == visited)
    #expect(conversions == 0)
    #expect(unavailable == 28)
    #expect(definiteAssertions == 51)
    #expect(formatted.count == 29)
    print(
      "ITN ordinal fixtures: visited=\(visited) availableOutputAssertions=\(definiteAssertions) "
        + "unavailable=\(unavailable) conversions=\(conversions) formatted=\(formatted.count) "
        + "dispositions=\(counts.sorted { $0.key < $1.key })")
  }

  // MARK: Mechanism evidence (synthetic authority; not German results)

  @Test(
    "MECHANISM: with an authority the pass converts only the ordinal span and keeps its neighbours")
  func mechanismConversions() throws {
    let pass = try mechanism()
    let cases: [(String, String)] = [
      ("Das ist die dritte Ausgabe.", "Das ist die 3. Ausgabe."),
      ("Wir sitzen in der ersten Reihe.", "Wir sitzen in der 1. Reihe."),
      ("Im zwölften Kapitel", "Im 12. Kapitel"),
      ("Er wurde zweiter Sieger.", "Er wurde 2. Sieger."),
      ("Die einunddreißigste Runde läuft.", "Die 31. Runde läuft."),
      ("Die ein und zwanzigste Runde läuft.", "Die 21. Runde läuft."),
      ("Die einund zwanzigste Runde läuft.", "Die 21. Runde läuft."),
      ("(die dritte Ausgabe)", "(die 3. Ausgabe)"),
      ("Die dritte\tAusgabe", "Die 3.\tAusgabe"),
      ("Die dritte  Ausgabe", "Die 3.  Ausgabe"),
    ]
    for (input, expected) in cases {
      #expect(
        bytes(try converted(input, using: pass)) == bytes(expected), "\(input.debugDescription)")
    }
    // The edit covers exactly the ordinal span.
    let (snapshot, result) = try run("Das ist die dritte Ausgabe.", using: pass)
    let edit = try #require(result.edits.first)
    #expect(snapshot.substring(edit.range) == "dritte")
    #expect(edit.replacement == "3.")
  }

  @Test("MECHANISM: ordinals outside the grammar and look-alikes are not candidates")
  func mechanismOutsideTheGrammar() throws {
    let pass = try mechanism()
    for text in [
      "Die zweiunddreißigste Runde", "Die nullte Runde", "Das erstes Mal", "Dem erstem Mann",
      "Die vierzigste Runde", "Das dritteln wir", "Der erst Fall", "The third Ausgabe",
      "Die 3. Ausgabe", "Die 3 Ausgabe", "Am Abend um sieben",
    ] {
      let (_, result) = try run(text, using: pass)
      #expect(result.candidates.isEmpty, "\(text)")
      #expect(bytes(try converted(text, using: pass)) == bytes(text))
    }
  }

  @Test("MECHANISM: each reviewed matcher refuses, paired with the nearby input that converts")
  func mechanismMatchers() throws {
    let pass = try mechanism()
    // Adverb token.
    #expect(
      try dispositions("Erstens prüfen wir die Rechnung.", using: pass) == [
        .refused(.adverbToken(entry: "ref-ordinal-001"))
      ])
    #expect(
      try converted("Die erste Rechnung prüfen wir.", using: pass) == "Die 1. Rechnung prüfen wir.")
    // Literal fraction phrase, matched as a complete token sequence only.
    #expect(
      try dispositions("Ein Drittel der Kosten", using: pass) == [
        .refused(.literalPhrase(entry: "ref-ordinal-004"))
      ])
    #expect(
      try dispositions("Ein  Drittel der Kosten", using: pass) == [
        .refused(.literalPhrase(entry: "ref-ordinal-004"))
      ])
    #expect(try dispositions("Kein Drittel der Kosten", using: pass).isEmpty)
    #expect(try dispositions("Das dritte Drittel der Kosten", using: pass).count == 1)
    // A fraction elsewhere does not suppress an independent candidate.
    #expect(
      try converted("Ein Drittel zahlt die dritte Gruppe.", using: pass)
        == "Ein Drittel zahlt die 3. Gruppe.")
    // Date authority: a month is a date context, any other capitalized word is not.
    #expect(try dispositions("Am ersten Mai beginnt es.", using: pass) == [.refused(.dateContext)])
    #expect(try converted("Am ersten Tag beginnt es.", using: pass) == "Am 1. Tag beginnt es.")
    // Fixed-expression authority.
    #expect(
      try dispositions("Das war nur zweite Wahl.", using: pass) == [.refused(.fixedExpression)])
    #expect(try converted("Das war nur zweite Runde.", using: pass) == "Das war nur 2. Runde.")
    // Without a following capitalized word: structural refusal.
    for text in [
      "Sie wurde Zweite.", "Sie wurde zweite ins Ziel", "Sie kam als dritte", "Die dritte 5 Euro",
      "Die dritte\nAusgabe", "Die dritte, Ausgabe", "Die dritte) Ausgabe",
    ] {
      #expect(try dispositions(text, using: pass) == [.refused(.withoutFollowingNoun)], "\(text)")
      #expect(bytes(try converted(text, using: pass)) == bytes(text))
    }
    // Capitalized ordinal inside a sentence is withheld, at a sentence start it is not by itself.
    #expect(
      try dispositions("Der Zweite Weltkrieg endete.", using: pass) == [
        .refused(.capitalizedOrdinal)
      ])
    #expect(
      try dispositions("Dritte Ausgabe erscheint.", using: pass)
        == [.unavailable([.properNameClearance])])
    #expect(try converted("Dritte Ausgabe erscheint.", using: pass) == "Dritte Ausgabe erscheint.")
  }

  @Test("MECHANISM: failed compounds cannot admit a later ordinal suffix")
  func mechanismRejectsOrdinalSuffixes() throws {
    let pass = try mechanism()
    let inputs = [
      "Die ein und und zwanzigste Runde",
      "Die einund" + String(repeating: " ", count: 129) + "zwanzigste Runde",
      "Die ein" + String(repeating: " ", count: 129) + "und zwanzigste Runde",
      "Die ein und\nzwanzigste Runde",
      "Die ein und und und und und und und zwanzigste Runde",
    ]
    for input in inputs {
      let (_, result) = try run(input, using: pass)
      #expect(result.edits.isEmpty, "\(input.debugDescription)")
      #expect(
        result.candidates.map(\.disposition) == [.refused(.numberContinuationBefore)],
        "\(input.debugDescription)")
      #expect(bytes(try converted(input, using: pass)) == bytes(input))
    }
    // Controls: the licensed compounds and an article before an ordinal still convert.
    #expect(bytes(try converted("Die ein und zwanzigste Runde", using: pass)) == bytes("Die 21. Runde"))
    #expect(bytes(try converted("Die einund zwanzigste Runde", using: pass)) == bytes("Die 21. Runde"))
    #expect(
      bytes(try converted("Das ist eine dritte Ausgabe.", using: pass))
        == bytes("Das ist eine 3. Ausgabe."))
  }

  @Test(
    "MECHANISM: without clearance a lowercase ordinal stays unavailable even with the other authorities"
  )
  func mechanismNeedsEveryAuthority() throws {
    let noClearance = LanguageOrdinalContextEvidence(
      calendarWords: ["mai"], fixedPhraseNouns: ["hilfe"], properNameClearance: .none)
    #expect(
      try dispositions("Die dritte Ausgabe", using: try mechanism(noClearance)) == [
        .unavailable([.properNameClearance])
      ])
    let noCalendar = LanguageOrdinalContextEvidence(
      calendarWords: nil, fixedPhraseNouns: ["hilfe"],
      properNameClearance: .lowercaseAdjectiveOrthography)
    #expect(
      try dispositions("Die dritte Ausgabe", using: try mechanism(noCalendar)) == [
        .unavailable([.calendarAuthority])
      ])
    let noFixed = LanguageOrdinalContextEvidence(
      calendarWords: ["mai"], fixedPhraseNouns: nil,
      properNameClearance: .lowercaseAdjectiveOrthography)
    #expect(
      try dispositions("Die dritte Ausgabe", using: try mechanism(noFixed)) == [
        .unavailable([.fixedPhraseAuthority])
      ])
    // All three present: converts.
    #expect(try converted("Die dritte Ausgabe", using: try mechanism()) == "Die 3. Ausgabe")
    // The German rules (no authority) never convert the same sentence.
    #expect(try converted("Die dritte Ausgabe") == "Die dritte Ausgabe")
  }

  @Test("MECHANISM: surrounding Unicode, emoji, mixed language and articles survive byte for byte")
  func mechanismUnicode() throws {
    let pass = try mechanism()
    let cases: [(String, String)] = [
      ("Für Zoe\u{0308} die dritte Ausgabe", "Für Zoe\u{0308} die 3. Ausgabe"),
      ("📞 die dritte Ausgabe", "📞 die 3. Ausgabe"),
      ("Wir sagen the third and die dritte Ausgabe", "Wir sagen the third and die 3. Ausgabe"),
      ("Der Hund und die dritte Ausgabe der Zeitung", "Der Hund und die 3. Ausgabe der Zeitung"),
      ("Die dritte Ausgabe\r\nDie vierte Ausgabe", "Die 3. Ausgabe\r\nDie 4. Ausgabe"),
    ]
    for (input, expected) in cases {
      #expect(
        bytes(try converted(input, using: pass)) == bytes(expected), "\(input.debugDescription)")
    }
    // NFD spelling of the ordinal itself keeps its original range.
    let nfd = "Im zwo\u{0308}lften Kapitel"
    let (snapshot, result) = try run(nfd, using: pass)
    let edit = try #require(result.edits.first)
    #expect(snapshot.substring(edit.range) == "zwo\u{0308}lften")
    #expect(bytes(try converted(nfd, using: pass)) == bytes("Im 12. Kapitel"))
  }

  @Test(
    "MECHANISM: several candidates, protected neighbours, the editor, idempotence, bounded diagnostics"
  )
  func mechanismSystem() throws {
    let pass = try mechanism()
    let several = "Die erste Runde und die zweite Gruppe und die dritte Ausgabe"
    let (_, result) = try run(several, using: pass)
    #expect(result.edits.count == 3)
    #expect(
      try converted(several, using: pass) == "Die 1. Runde und die 2. Gruppe und die 3. Ausgabe")
    // A refused candidate leaves a separate safe candidate in place.
    #expect(
      try converted("Am ersten Mai war die dritte Ausgabe da", using: pass)
        == "Am ersten Mai war die 3. Ausgabe da")
    // Idempotence: a second pass over the output proposes nothing.
    let once = try converted(several, using: pass)
    #expect(try run(once, using: pass).1.edits.isEmpty)
    #expect(try converted(once, using: pass) == once)
    // Already-written ordinals, whatever their value, stay as written.
    for text in ["Die 3. Ausgabe", "Die 99. Ausgabe", "Der 31. Mai", "Die 3.. Ausgabe"] {
      #expect(try run(text, using: pass).1.candidates.isEmpty, "\(text)")
    }
    // Edits from another text are refused by the editor and leave that text alone.
    let other = LanguageTextSnapshot("Anderer Text")
    #expect(LanguageTextEditor.apply(result.edits, to: other) == .refused(.staleSnapshot))
    // Diagnostics are bounded but every safe candidate still gets its edit.
    let many = String(repeating: "die dritte Ausgabe und ", count: 70)
    let (_, bounded) = try run(many, using: pass)
    #expect(bounded.edits.count == 70)
    #expect(bounded.candidates.count == LanguageOrdinalPass.Run.diagnosticLimit)
    #expect(bounded.candidatesTruncated)
  }
}
