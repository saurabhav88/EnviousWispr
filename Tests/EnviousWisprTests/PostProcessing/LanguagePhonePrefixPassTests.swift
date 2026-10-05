import Foundation
import Testing

@testable import EnviousWisprPostProcessing

// MARK: - The phone-prefix pass (#1677, PR 2 chunk 4)
//
// These tests drive the real pass and the real shared editor. The pass is not registered or called
// by any production code, and nothing here says a German sentence is converted correctly in the
// product: a pass count is not an engine result.
//
// Expected outputs are independent literals or the frozen rows' accepted written variants, compared
// as UTF-8 bytes. Every refusal control is paired with the near-identical input that converts, so
// a pass that refuses everything cannot satisfy them.
//
// When this fails, a spoken telephone prefix is left unconverted, or a sum, a price, a temperature
// or a bare word is rewritten as a telephone number.

@Suite("German phone-prefix pass (#1677)", .tags(.driftGuard))
struct LanguagePhonePrefixPassTests {

  let pass: LanguagePhonePrefixPass

  init() throws {
    pass = LanguagePhonePrefixPass(
      grammar: try LanguageNumberGrammar.german(), rules: try LanguagePhonePrefixRules.german())
  }

  // MARK: Helpers

  private func run(_ text: String) throws -> (LanguageTextSnapshot, LanguagePhonePrefixPass.Run) {
    let snapshot = LanguageTextSnapshot(text)
    guard case .ran(let result) = pass.propose(in: snapshot) else {
      Issue.record("the pass reported itself unavailable")
      throw CancellationError()
    }
    return (snapshot, result)
  }

  /// The text after the pass proposed and the SHARED editor applied (or refused).
  private func converted(_ text: String) throws -> String {
    let (snapshot, result) = try run(text)
    switch LanguageTextEditor.apply(result.edits, to: snapshot) {
    case .applied(let output): return output
    case .refused(let refusal):
      Issue.record("the editor refused the pass's own edits: \(refusal)")
      return text
    }
  }

  private func refusals(_ text: String) throws -> [LanguagePhonePrefixPass.Refusal] {
    try run(text).1.candidates.compactMap {
      if case .refused(let reason) = $0.decision { return reason }
      return nil
    }
  }

  private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

  // MARK: The reviewed rules

  @Test("the rules adapt the four reviewed entries, each with its identity, and nothing else")
  func rulesFacts() throws {
    let rules = try LanguagePhonePrefixRules.german()
    #expect(rules.triggers == ["plus"])
    #expect(rules.replacement == "+")
    #expect(
      rules.refusals.map(\.id) == [
        "ref-phone-001", "ref-phone-002", "ref-phone-003", "ref-phone-004",
      ])
    #expect(rules.refusals.map(\.version) == [2, 1, 2, 1])
    #expect(
      rules.refusals.map(\.shape) == [
        .plusBetweenOperands, .plusJoiningNouns, .plusBeforeTemperatureOrPercent,
        .plusNotFollowedByDigit,
      ])
    #expect(rules.refusals.allSatisfy { $0.contentSHA256.count == 64 })
    // Which refusals are explicit predicates and which are enforced by admission failure.
    let predicates = LanguagePhonePrefixRules.Shape.allCases.filter {
      $0.enforcement == .explicitPredicate
    }
    let admission = LanguagePhonePrefixRules.Shape.allCases.filter {
      $0.enforcement == .admissionFailure
    }
    #expect(predicates == [.plusBetweenOperands, .plusBeforeTemperatureOrPercent])
    #expect(admission == [.plusJoiningNouns, .plusNotFollowedByDigit])
  }

  @Test("the lowered rows equal the reviewed phone entries in the refusal file, read directly")
  func rulesMatchTheRefusalFile() throws {
    let url = RepoRoot.url.appending(path: "scripts/itn/refusals/de.json")
    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let reviewed = try #require(object["reviewed_entries"] as? [[String: Any]])
    let phone = reviewed.filter { $0["category"] as? String == "phone_country_prefix" }
      .sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
    let rules = try LanguagePhonePrefixRules.german()
    #expect(phone.count == 4)
    #expect(phone.compactMap { $0["id"] as? String } == rules.refusals.map(\.id))
    #expect(phone.compactMap { $0["version"] as? Int } == rules.refusals.map(\.version))
    #expect(
      phone.compactMap { $0["content_sha256"] as? String } == rules.refusals.map(\.contentSHA256))
    let shapes = phone.compactMap { entry -> String? in
      (entry["match"] as? [String: Any])?["context_shape"] as? String
    }
    #expect(shapes == rules.refusals.map(\.shape.rawValue))
    // Pending entries are not lowered: every lowered id is a reviewed one.
    let pending = (object["pending_entries"] as? [[String: Any]] ?? []).compactMap {
      $0["id"] as? String
    }
    #expect(Set(pending).isDisjoint(with: rules.refusals.map(\.id)))
  }

  @Test("unsupported, missing, duplicate or trigger-less data fails the whole adaptation")
  func adaptationFailsClosed() {
    typealias Data = GermanPhonePrefixData
    let good = Data.refusals
    func row(_ index: Int, shape: String? = nil) -> Data.Refusal {
      let base = good[index]
      return Data.Refusal(
        id: base.id, version: base.version, contentSHA256: base.contentSHA256,
        reasonCode: base.reasonCode, contextShape: shape ?? base.contextShape,
        reviewRef: base.reviewRef)
    }
    func build(_ rows: [Data.Refusal], triggers: [String] = ["plus"], replacement: String = "+")
      -> LanguagePhonePrefixRules.BuildError?
    {
      do {
        _ = try LanguagePhonePrefixRules.build(
          rows: rows, triggerTokens: triggers, replacement: replacement)
        return nil
      } catch let error as LanguagePhonePrefixRules.BuildError {
        return error
      } catch {
        return nil
      }
    }
    #expect(build(good) == nil)
    #expect(
      build([row(0), row(1), row(2), row(3, shape: "ordinal_adverb")])
        == .unsupportedShape("ordinal_adverb"))
    #expect(build([row(0), row(1), row(2)]) == .missingShape("plus_not_followed_by_digit"))
    #expect(
      build([row(0), row(1), row(2), row(2)])
        == .duplicateShape("plus_before_temperature_or_percent"))
    #expect(build(good, triggers: []) == .noTriggerToken)
    #expect(build(good, triggers: [""]) == .noTriggerToken)
    #expect(build(good, replacement: "") == .emptyReplacement)
  }

  @Test("a pass whose rules lack a reviewed shape is unavailable and proposes nothing")
  func unavailableWithoutAShape() throws {
    let full = try LanguagePhonePrefixRules.german()
    let partial = LanguagePhonePrefixRules(
      triggers: full.triggers, replacement: full.replacement,
      refusals: Array(full.refusals.dropLast()))
    let broken = LanguagePhonePrefixPass(grammar: pass.grammar, rules: partial)
    let snapshot = LanguageTextSnapshot("Ruf plus 49 30 12 an")
    guard case .unavailable(let reason) = broken.propose(in: snapshot) else {
      Issue.record("a pass with a missing shape must be unavailable")
      return
    }
    #expect(reason.contains("plus_not_followed_by_digit"))
    // Control: the complete rules convert the same text.
    #expect(try converted("Ruf plus 49 30 12 an") == "Ruf +49 30 12 an")
  }

  // MARK: The minimal edit

  @Test("the Phase 0 shape replaces only the word and its separator and keeps every digit")
  func phaseZeroShape() throws {
    let text = "Notiere plus 49, 3, 0, 12, 34, 55 bitte."
    let (snapshot, result) = try run(text)
    #expect(result.edits.count == 1)
    let edit = try #require(result.edits.first)
    #expect(edit.range == 8..<13)
    #expect(snapshot.substring(edit.range) == "plus ")
    #expect(edit.replacement == "+")
    #expect(bytes(try converted(text)) == bytes("Notiere +49, 3, 0, 12, 34, 55 bitte."))
  }

  @Test("trigger case, brackets, tabs, no-break and double spaces: only word and separator go")
  func triggerVariants() throws {
    let cases: [(String, String)] = [
      ("Plus 49 30 12", "+49 30 12"),
      ("PLUS 49 30 12", "+49 30 12"),
      ("Ruf (plus 49 30 12) an", "Ruf (+49 30 12) an"),
      ("Ruf plus\t49 30 12 an", "Ruf +49 30 12 an"),
      ("Ruf plus\u{00A0}49 30 12 an", "Ruf +49 30 12 an"),
      ("Ruf plus  49 30 12 an", "Ruf +49 30 12 an"),
      ("Ruf plus 49 30 12. Danke", "Ruf +49 30 12. Danke"),
      ("Ruf plus 49 30 12, und", "Ruf +49 30 12, und"),
      ("Ruf plus 49 30 12? Ja", "Ruf +49 30 12? Ja"),
    ]
    for (input, expected) in cases {
      #expect(bytes(try converted(input)) == bytes(expected), "\(input.debugDescription)")
    }
  }

  @Test("only a complete standalone trigger word matches")
  func triggerBoundaries() throws {
    for text in [
      "Ruf surplus 49 30 12 an", "Ruf plusquamperfekt 49 30 12 an", "Ruf plus49 30 12 an",
      "Ruf plus, 49 30 12 an", "Ruf plus-Konto 49 30 12 an", "Ruf plus/minus 49 30 12 an",
      "Siehe https://beispiel.de/plus 49 30 12 jetzt", "Mail plus@beispiel.de 49 30 12 jetzt",
    ] {
      let (_, result) = try run(text)
      #expect(result.candidates.isEmpty, "\(text)")
      #expect(bytes(try converted(text)) == bytes(text), "\(text)")
    }
    // Control: the same sentence with a standalone trigger converts.
    #expect(try converted("Siehe plus 49 30 12 jetzt") == "Siehe +49 30 12 jetzt")
  }

  // MARK: Admission

  @Test("a numeric continuation across a line break refuses the whole candidate")
  func lineBreaks() throws {
    #expect(try refusals("Ruf plus\n49 30 12 an") == [.notFollowedByDigit])
    for text in ["Ruf plus 49\n30 12 an", "Ruf plus 49 30\n12 an"] {
      #expect(try refusals(text) == [.malformedContinuation], "\(text.debugDescription)")
      #expect(bytes(try converted(text)) == bytes(text))
    }
    // Control: a line break followed by prose ends the run and the two groups convert.
    #expect(bytes(try converted("Ruf plus 49 30\nDanke")) == bytes("Ruf +49 30\nDanke"))
  }

  @Test("spaced commas are consumed and malformed tails never admit a prefix")
  func completeRunScanning() throws {
    #expect(bytes(try converted("Ruf plus 49 , 30 an")) == bytes("Ruf +49 , 30 an"))

    let nine = "Ruf plus 49 30 , 1 , 2 , 3 , 4 , 5 , 6 , 7 an"
    #expect(try refusals(nine) == [.overLimit])
    #expect(bytes(try converted(nine)) == bytes(nine))

    let long = "Ruf plus 49 30 , " + String(repeating: "1", count: 125) + " an"
    #expect(try refusals(long) == [.overLimit])
    #expect(bytes(try converted(long)) == bytes(long))

    for text in [
      "Ruf plus 49 30,٤ an", "Ruf plus 49 30 ٤ an", "Ruf plus 49 30,foo an", "Ruf plus 49 30..12 an",
      "Ruf plus 49 30. 12 an", "Ruf plus 49 30.x an",
    ] {
      #expect(try refusals(text) == [.malformedContinuation], "\(text)")
      #expect(bytes(try converted(text)) == bytes(text), "\(text)")
    }
  }

  @Test("a malformed continuation refuses the whole candidate, never a prefix of it")
  func malformedContinuations() throws {
    for tail in ["12x", "30-12", "30/12", "30:12", "30.12", "12°", "1€", "12%", "12@x.de", "12٤"] {
      let text = "Ruf plus 49 \(tail) an"
      #expect(try refusals(text) == [.malformedContinuation], "\(text)")
      #expect(bytes(try converted(text)) == bytes(text), "\(text)")
    }
  }

  @Test("the run limits are exact: 8 groups and 128 units convert, one more refuses the whole run")
  func runLimits() throws {
    let eight = "Ruf plus 1 2 3 4 5 6 7 8 an"
    let nine = "Ruf plus 1 2 3 4 5 6 7 8 9 an"
    #expect(try converted(eight) == "Ruf +1 2 3 4 5 6 7 8 an")
    #expect(try refusals(nine) == [.overLimit])
    #expect(try converted(nine) == nine)
    // "49 " plus N digits spans N + 3 units from the first digit to the last.
    let atLimit = "Ruf plus 49 " + String(repeating: "1", count: 125) + " an"
    let overLimit = "Ruf plus 49 " + String(repeating: "1", count: 126) + " an"
    #expect(try converted(atLimit) == atLimit.replacingOccurrences(of: "plus ", with: "+"))
    #expect(try refusals(overLimit) == [.overLimit])
    #expect(try converted(overLimit) == overLimit)
  }

  @Test("the country group is one to three ASCII digits without a leading zero, as written")
  func countryGroups() throws {
    #expect(try refusals("Ruf plus 049 30 12 an") == [.leadingZeroCountryGroup])
    #expect(try refusals("Ruf plus 0 30 12 an") == [.leadingZeroCountryGroup])
    #expect(try refusals("Ruf plus 00 49 30 an") == [.leadingZeroCountryGroup])
    #expect(try refusals("Ruf plus 4930 12 34 an") == [.countryGroupInvalid(.exceedsDigitLimit)])
    #expect(try refusals("Ruf plus ٤٩ 30 12 an") == [.notFollowedByDigit])
    #expect(try refusals("Ruf plus ４９ 30 12 an") == [.notFollowedByDigit])
    #expect(try converted("Ruf plus 420 224 301 875 an") == "Ruf +420 224 301 875 an")
    #expect(try converted("Ruf plus 1 416 555 0182 an") == "Ruf +1 416 555 0182 an")
  }

  // MARK: The reviewed refusal shapes, each paired with the input that converts

  @Test("plus_between_operands: a number directly before the trigger refuses")
  func arithmetic() throws {
    #expect(try refusals("Rechne 7 plus 8 9 aus") == [.arithmeticOperandBefore])
    #expect(try refusals("Es ist zwölf plus 5 6 aus") == [.arithmeticOperandBefore])
    #expect(try refusals("Es ist zwanzig plus 5 6 aus") == [.arithmeticOperandBefore])
    #expect(try refusals("Es ist drei und zwanzig plus 5 6 aus") == [.arithmeticOperandBefore])
    #expect(try refusals("Hotline 3, plus 49 30 12 an") == [.arithmeticOperandBefore])
    #expect(try converted("Rechne 7 plus 8 9 aus") == "Rechne 7 plus 8 9 aus")
    // Controls: no operand before, or an article that is not a number.
    #expect(try converted("Rechne bitte plus 8 9 aus") == "Rechne bitte +8 9 aus")
    #expect(try converted("Ein plus 5 6 aus") == "Ein +5 6 aus")
    #expect(try converted("Rechne hundert plus 5 6 aus") == "Rechne hundert +5 6 aus")
  }

  @Test("plus_joining_nouns and plus_not_followed_by_digit: no digit group follows the trigger")
  func noDigitGroupFollows() throws {
    #expect(try refusals("Der Preis gilt plus Versand und Verpackung.") == [.wordFollowsTrigger])
    #expect(
      try refusals("Wir liefern den Schrank plus Montage bis Freitag.") == [.wordFollowsTrigger])
    #expect(try refusals("Bitte lies plus deutlich vor.") == [.wordFollowsTrigger])
    #expect(try refusals("Am Ende steht plus") == [.notFollowedByDigit])
    #expect(try refusals("Am Ende steht plus ") == [.notFollowedByDigit])
    #expect(try refusals("Am Ende steht plus … 49 30") == [.notFollowedByDigit])
    #expect(try converted("Am Ende steht plus 49 30 12") == "Am Ende steht +49 30 12")
  }

  @Test("plus_before_temperature_or_percent: a temperature or percentage tail refuses")
  func temperatureAndPercent() throws {
    for text in [
      "Es sind plus 3,5 Grad draußen", "Es sind plus 3,5 Prozent mehr", "Es sind plus 3,5 % mehr",
      "Es sind plus 20 30 °C heute", "Heute plus 5 Grad am Morgen",
    ] {
      #expect(try refusals(text).contains(.temperatureOrPercentTail), "\(text)")
      #expect(bytes(try converted(text)) == bytes(text), "\(text)")
    }
    // Control: the same digits followed by an ordinary word convert.
    #expect(try converted("Es sind plus 20 30 heute") == "Es sind +20 30 heute")
  }

  @Test("closing punctuation cannot hide a competing unit")
  func bracketedUnitTail() throws {
    for text in ["Es sind (plus 3,5) Grad draußen", "Es sind (plus 3,5) Prozent mehr"] {
      #expect(try refusals(text) == [.temperatureOrPercentTail], "\(text)")
      #expect(bytes(try converted(text)) == bytes(text))
    }
    let quantity = "Es sind (plus 3,5) Meter mehr"
    #expect(try refusals(quantity) == [.measurementOrCurrencyTail])
    #expect(bytes(try converted(quantity)) == bytes(quantity))
    // Control: the same brackets around a plain telephone run convert.
    #expect(bytes(try converted("Ruf (plus 49 30) an")) == bytes("Ruf (+49 30) an"))
  }

  @Test("a quantity refuses through admission, not through the temperature shape")
  func quantityRefusesThroughAdmission() throws {
    // One digit group and a unit this authority does not list: too few groups.
    #expect(try refusals("Mehl plus 10 Milliliter Wasser") == [.tooFewDigitGroups])
    // Two groups and a listed unit: a competing structure, named as such and not as ref-phone-003.
    #expect(try refusals("Dazu plus 3,5 Meter Seil") == [.measurementOrCurrencyTail])
    #expect(try refusals("Das kostet plus 5 20 Euro") == [.measurementOrCurrencyTail])
    #expect(try converted("Dazu plus 3,5 Meter Seil") == "Dazu plus 3,5 Meter Seil")
  }

  @Test("already-written prefixes have no spoken trigger and are untouched")
  func alreadyWritten() throws {
    for text in ["Ruf +49 30 12 an", "Ruf 00 49 30 12 an", "Ruf +49 plus 30 12 an"] {
      let output = try converted(text)
      if text.contains("plus 30") {
        // A spoken trigger after a written prefix is a separate candidate: a number precedes it.
        #expect(try refusals(text) == [.arithmeticOperandBefore])
      }
      #expect(bytes(output) == bytes(text), "\(text)")
    }
  }

  // MARK: Unicode, several candidates, the editor, idempotence

  @Test("surrounding Unicode keeps its bytes and its character boundaries")
  func unicodeSurroundings() throws {
    let nfd = "Für Zoe\u{0308} plus 49 30 12 an"
    #expect(bytes(try converted(nfd)) == bytes("Für Zoe\u{0308} +49 30 12 an"))
    let emoji = "📞 plus 49 30 12"
    #expect(bytes(try converted(emoji)) == bytes("📞 +49 30 12"))
    let (snapshot, result) = try run(emoji)
    let edit = try #require(result.edits.first)
    #expect(edit.range == 3..<8)
    #expect(snapshot.substring(edit.range) == "plus ")
  }

  @Test("several safe candidates are all proposed against one snapshot and applied together")
  func severalCandidates() throws {
    let text = "Erst plus 49 30 12, dann plus 43 1 555 0199 an"
    let (_, result) = try run(text)
    #expect(result.edits.count == 2)
    #expect(bytes(try converted(text)) == bytes("Erst +49 30 12, dann +43 1 555 0199 an"))
  }

  @Test("a refused candidate leaves a separate safe candidate in place")
  func safeAndRefused() throws {
    let text = "Rechne 7 plus 8 9 und ruf plus 49 30 12 an"
    let (_, result) = try run(text)
    #expect(result.edits.count == 1)
    #expect(result.candidates.count == 2)
    #expect(result.candidates[0].decision == .refused(.arithmeticOperandBefore))
    #expect(bytes(try converted(text)) == bytes("Rechne 7 plus 8 9 und ruf +49 30 12 an"))
  }

  @Test("edits applied to another text are refused by the editor and leave that text alone")
  func editorFallback() throws {
    let (_, result) = try run("Ruf plus 49 30 12 an")
    let other = LanguageTextSnapshot("Ruf plus 49 30 13 an")
    let secondRun = LanguageTextSnapshot("Anderer Text")
    #expect(LanguageTextEditor.apply(result.edits, to: secondRun) == .refused(.staleSnapshot))
    #expect(Array(secondRun.text.utf8) == Array("Anderer Text".utf8))
    #expect(LanguageTextEditor.apply(result.edits, to: other) == .refused(.staleSnapshot))
  }

  @Test("a second pass over the converted text proposes nothing and changes nothing")
  func idempotence() throws {
    for text in [
      "Notiere plus 49, 3, 0, 12, 34, 55 bitte.", "Ruf plus 49 30 12 an", "Ruf (plus 49 30 12) an",
      "Erst plus 49 30 12, dann plus 43 1 555 0199 an",
    ] {
      let once = try converted(text)
      #expect(once != text)
      let (_, second) = try run(once)
      #expect(second.edits.isEmpty, "\(once)")
      #expect(bytes(try converted(once)) == bytes(once))
    }
  }

  @Test("diagnostics are bounded but every safe candidate still gets its edit")
  func diagnosticsBounded() throws {
    let text = String(repeating: "Ruf plus 49 30 12 oder ", count: 70)
    let (_, result) = try run(text)
    #expect(result.edits.count == 70)
    #expect(result.candidates.count == LanguagePhonePrefixPass.Run.diagnosticLimit)
    #expect(result.candidatesTruncated)
    let output = try converted(text)
    #expect(output == String(repeating: "Ruf +49 30 12 oder ", count: 70))
  }

  // MARK: The frozen phone rows

  @Test("every frozen phone row goes through the real pass and the shared editor")
  func frozenPhoneRows() throws {
    let development = try ITNDevelopmentFixtures.development().rows.filter {
      $0.category == "phone_country_prefix"
    }
    let controls = try ITNDevelopmentFixtures.controls().rows.filter {
      $0.category == "phone_country_prefix"
    }
    let lexical = controls.filter { $0.refusalReason != "already_formatted" }
    let formatted = controls.filter { $0.refusalReason == "already_formatted" }
    #expect(development.count == 20)
    #expect(lexical.count == 30)
    #expect(formatted.count == 29)

    var visited = 0
    var asserted = 0
    var idempotenceChecks = 0
    var refusalReasons: [String: Int] = [:]

    for row in development {
      visited += 1
      let (snapshot, result) = try run(row.spokenInput)
      #expect(result.edits.isEmpty == false, "\(row.id): no edit plan")
      let output = try converted(row.spokenInput)
      #expect(output != row.spokenInput, "\(row.id): unchanged")
      let matches = row.acceptedWrittenVariants.contains { bytes($0) == bytes(output) }
      #expect(matches, "\(row.id): \(output.debugDescription) is not an accepted variant")
      // The edit touches only the trigger word and its separator.
      for edit in result.edits {
        let removed = try #require(snapshot.substring(edit.range), "\(row.id)")
        #expect(removed.lowercased().hasPrefix("plus"), "\(row.id): \(removed.debugDescription)")
        #expect(
          removed.dropFirst(4).allSatisfy { $0 == " " || $0 == "\u{00A0}" || $0 == "\t" },
          "\(row.id): \(removed.debugDescription)")
        #expect(edit.replacement == "+", "\(row.id)")
      }
      let (_, again) = try run(output)
      #expect(again.edits.isEmpty, "\(row.id): second pass proposed an edit")
      #expect(bytes(try converted(output)) == bytes(output), "\(row.id)")
      idempotenceChecks += 1
      asserted += 1
    }

    for row in lexical + formatted {
      visited += 1
      let (_, result) = try run(row.spokenInput)
      #expect(result.edits.isEmpty, "\(row.id): proposed an edit")
      let output = try converted(row.spokenInput)
      #expect(bytes(output) == bytes(row.spokenInput), "\(row.id): changed")
      #expect(
        row.acceptedWrittenVariants.contains { bytes($0) == bytes(output) },
        "\(row.id): not an accepted variant")
      for candidate in result.candidates {
        guard case .refused(let reason) = candidate.decision else {
          Issue.record("\(row.id): a control candidate was proposed")
          continue
        }
        refusalReasons["\(reason)", default: 0] += 1
      }
      // The refusal each lexical trap should meet, written from the sentences, not from the pass.
      switch row.refusalReason {
      case "plus_arithmetic":
        #expect(
          result.candidates.map(\.decision) == [.refused(.arithmeticOperandBefore)], "\(row.id)")
      case "plus_conjunction_or_preposition":
        #expect(result.candidates.map(\.decision) == [.refused(.wordFollowsTrigger)], "\(row.id)")
      case "plus_without_digit_sequence":
        #expect(
          result.candidates.allSatisfy {
            $0.decision == .refused(.wordFollowsTrigger)
              || $0.decision == .refused(.notFollowedByDigit)
          }, "\(row.id)")
      case "plus_temperature_or_quantity":
        let expected: LanguagePhonePrefixPass.Refusal =
          row.spokenInput.contains("Milliliter") ? .tooFewDigitGroups : .temperatureOrPercentTail
        #expect(result.candidates.map(\.decision) == [.refused(expected)], "\(row.id)")
      case "already_formatted":
        #expect(result.candidates.isEmpty, "\(row.id): a written number has no trigger")
      default:
        Issue.record("\(row.id): unexpected reason \(row.refusalReason ?? "nil")")
      }
      asserted += 1
    }

    #expect(visited == 79)
    #expect(asserted == 79)
    #expect(idempotenceChecks == 20)
    print(
      "ITN phone fixtures: visited=\(visited) asserted=\(asserted) unavailable=\(visited - asserted) "
        + "development=\(development.count) lexical=\(lexical.count) formatted=\(formatted.count) "
        + "idempotence=\(idempotenceChecks) refusals=\(refusalReasons.sorted { $0.key < $1.key })")
  }
}
