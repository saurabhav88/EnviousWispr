import Foundation
import Testing

@testable import EnviousWisprPostProcessing

// MARK: - The international phone pass (#1677)
//
// These tests drive the real pass, the real phone metadata and the real shared editor. The pass is
// not registered or called by any production code, and nothing here says a German sentence is
// converted correctly in the product: a pass count is not an engine result.
//
// Expected outputs are literals compared as UTF-8 bytes; the grouping inside a converted number is
// the metadata's (see LanguagePhoneMetadataTests). Frozen rows are compared by their target digits
// and surrounding text, because their accepted variants fix one grouping. Every refusal control is
// paired with the near-identical input that converts, so a pass that refuses everything cannot
// satisfy them.
//
// When this fails, an explicitly international number is left unconverted or regrouped wrongly, a
// digit is changed, or a sum, a price, a temperature, a bare word or a number without a plus is
// rewritten as a telephone number.

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
    let snapshot = LanguageTextSnapshot("Ruf plus 49 176 9087654 an")
    guard case .unavailable(let reason) = broken.propose(in: snapshot) else {
      Issue.record("a pass with a missing shape must be unavailable")
      return
    }
    #expect(reason.contains("plus_not_followed_by_digit"))
    // Control: the complete rules convert the same text.
    #expect(try converted("Ruf plus 49 176 9087654 an") == "Ruf +49 176 9087654 an")
  }

  // MARK: Conversion: one edit over the whole number, digits kept

  @Test("a spoken number becomes one edit over trigger and run, regrouped by the metadata")
  func spokenNumber() throws {
    let text = "Notiere plus 49, 1, 7, 6, 9, 0, 8, 7, 6, 5, 4 bitte."
    let (snapshot, result) = try run(text)
    #expect(result.edits.count == 1)
    let edit = try #require(result.edits.first)
    #expect(snapshot.substring(edit.range) == "plus 49, 1, 7, 6, 9, 0, 8, 7, 6, 5, 4")
    #expect(edit.replacement == "+49 176 9087654")
    #expect(edit.regroupsDigits)
    #expect(bytes(try converted(text)) == bytes("Notiere +49 176 9087654 bitte."))
  }

  @Test(
    "engine shapes the old pass refused now convert, every digit kept",
    arguments: [
      ("Ruf plus 49176 90876 54 an", "Ruf +49 176 9087654 an"),
      ("Ruf plus 43.664 9.081.122 an", "Ruf +43 664 9081122 an"),
      ("Ruf plus 431 7.894.321 an", "Ruf +43 1 7894321 an"),
      ("Ruf plus46319876543 an", "Ruf +46 31 987 65 43 an"),
      ("Ruf plus91-11-4567-8901 an", "Ruf +91 11 4567 8901 an"),
      ("Ruf plus 4144683 2190 an", "Ruf +41 44 683 21 90 an"),
      ("Ruf plus 27214449087 an", "Ruf +27 21 444 9087 an"),
      ("Ruf plus 3 2 2 6 0 1 7 7 4 4 an", "Ruf +32 2 601 77 44 an"),
      ("Ruf +81/3/4567/8901 an", "Ruf +81 3 4567 8901 an"),
      ("Ruf +32/26017744 an", "Ruf +32 2 601 77 44 an"),
      ("Ruf +43.664.9081122 an", "Ruf +43 664 9081122 an"),
      ("Ruf +49 30 / 1234 5678 an", "Ruf +49 30 12345678 an"),
    ])
  func engineShapes(input: String, expected: String) throws {
    #expect(bytes(try converted(input)) == bytes(expected))
    let (snapshot, result) = try run(input)
    for edit in result.edits {
      let original = try #require(snapshot.substring(edit.range))
      #expect(original.filter(\.isNumber) == edit.replacement.filter(\.isNumber))
    }
  }

  @Test("trigger case, brackets, tabs, no-break and double spaces, sentence punctuation")
  func triggerVariants() throws {
    let cases: [(String, String)] = [
      ("Plus 49 176 9087654", "+49 176 9087654"),
      ("PLUS 49 176 9087654", "+49 176 9087654"),
      ("Ruf (plus 49 176 9087654) an", "Ruf (+49 176 9087654) an"),
      ("Ruf plus\t49 176 9087654 an", "Ruf +49 176 9087654 an"),
      ("Ruf plus\u{00A0}49 176 9087654 an", "Ruf +49 176 9087654 an"),
      ("Ruf plus  49 176 9087654 an", "Ruf +49 176 9087654 an"),
      ("Ruf plus 49 176 9087654. Danke", "Ruf +49 176 9087654. Danke"),
      ("Ruf plus 49 176 9087654, und", "Ruf +49 176 9087654, und"),
      ("Ruf plus 49 176 9087654? Ja", "Ruf +49 176 9087654? Ja"),
      ("Ruf (plus491769087654) an", "Ruf (+49 176 9087654) an"),
    ]
    for (input, expected) in cases {
      #expect(bytes(try converted(input)) == bytes(expected), "\(input.debugDescription)")
    }
  }

  @Test("only a complete trigger word, alone or glued to digits, is a spoken anchor")
  func triggerBoundaries() throws {
    for text in [
      "Ruf surplus 49 176 9087654 an", "Ruf plusquamperfekt 49 176 9087654 an",
      "Ruf plus, 49 176 9087654 an", "Ruf plus-Konto 49 176 9087654 an",
      "Ruf plus/minus 49 176 9087654 an",
      "Siehe https://beispiel.de/plus 49 176 9087654 jetzt",
      "Mail plus@beispiel.de 49 176 9087654 jetzt",
    ] {
      let (_, result) = try run(text)
      #expect(result.candidates.isEmpty, "\(text)")
      #expect(bytes(try converted(text)) == bytes(text), "\(text)")
    }
    #expect(try converted("Siehe plus 49 176 9087654 jetzt") == "Siehe +49 176 9087654 jetzt")
  }

  // MARK: What is never converted

  @Test("a written number grouped by spaces, or not at all, is already well formed")
  func alreadyWellFormed() throws {
    for text in ["Ruf +49 176 9087654 an", "Ruf +491769087654 an", "Ruf +49 176 90876 54 an"] {
      #expect(try refusals(text) == [.alreadyWellFormed], "\(text)")
      #expect(bytes(try converted(text)) == bytes(text), "\(text)")
    }
    // A slash makes the same written number a candidate.
    #expect(try converted("Ruf +49/176/9087654 an") == "Ruf +49 176 9087654 an")
  }

  @Test("a number without an explicit plus is never a candidate")
  func noPlusNoCandidate() throws {
    for text in [
      "Ruf 00 49 30 12345678 an", "Ruf 0049 30 12345678 an", "Ruf 33 5 6789 0123 an",
      "Ruf 030 12345678 an", "Ruf 49 176 9087654 an",
    ] {
      let (_, result) = try run(text)
      #expect(result.candidates.isEmpty, "\(text)")
      #expect(bytes(try converted(text)) == bytes(text), "\(text)")
    }
  }

  @Test("digits that form no documented number and fail the fallback are refused as written")
  func invalidNumbers() throws {
    for text in [
      "Ruf plus 49 30 12 an", "Ruf plus 999 1234 5678 an", "Mehl plus 10 Milliliter Wasser",
      "Ruf plus 2 345 6789 an", "Ruf plus4420731608 an", "Ruf +44/20/731/6085 an",
    ] {
      guard case .refused(.notAValidNumber)? = try run(text).1.candidates.first?.decision else {
        Issue.record("\(text): expected notAValidNumber, got \(try run(text).1.candidates)")
        continue
      }
      #expect(bytes(try converted(text)) == bytes(text), "\(text)")
    }
  }

  @Test("the sign-only fallback: a standalone trigger, a real calling code, 7 to 15 digits")
  func signOnlyFallback() throws {
    let cases: [(String, String)] = [
      // A spoken trunk zero and an invalid London length: the sign is right, the digits stay.
      ("Ruf plus 41 0 22 700 45 61 an", "Ruf +41 0 22 700 45 61 an"),
      ("Ruf plus 44 20 731 6085 an", "Ruf +44 20 731 6085 an"),
      ("Ruf plus 44 020 7031 3000 an", "Ruf +44 020 7031 3000 an"),
      ("Ruf plus 39.08770899 an", "Ruf +39.08770899 an"),
    ]
    for (input, expected) in cases {
      #expect(bytes(try converted(input)) == bytes(expected), "\(input)")
      let (snapshot, result) = try run(input)
      let edit = try #require(result.edits.first, "\(input)")
      // Only the trigger word and its separator: no digit is inside the edit.
      #expect(try #require(snapshot.substring(edit.range)).allSatisfy { !$0.isNumber })
      #expect(edit.replacement == "+")
      #expect(!edit.regroupsDigits)
    }
    // Too few digits after a real calling code: a sum or a quantity, never a sign.
    #expect(try converted("Ruf plus 44 123 an") == "Ruf plus 44 123 an")
  }

  @Test("unavailable metadata refuses every candidate and changes nothing")
  func metadataUnavailable() throws {
    let broken = LanguagePhonePrefixPass(
      grammar: pass.grammar, rules: pass.rules,
      metadata: LanguagePhoneMetadata(loadMetadata: {
        throw LanguagePhoneMetadata.LoadError.missing
      }))
    let snapshot = LanguageTextSnapshot("Ruf plus 49 176 9087654 an")
    guard case .ran(let result) = broken.propose(in: snapshot) else {
      Issue.record("the pass itself must still run")
      return
    }
    #expect(result.edits.isEmpty)
    guard case .refused(.metadataUnavailable)? = result.candidates.first?.decision else {
      Issue.record("expected metadataUnavailable, got \(result.candidates)")
      return
    }
  }

  // MARK: Admission of the run

  @Test("a numeric continuation across a line break or sentence end refuses the whole candidate")
  func hiddenContinuations() throws {
    #expect(try refusals("Ruf plus\n49 176 9087654 an") == [.notFollowedByDigit])
    for text in [
      "Ruf plus 49 176\n9087654 an", "Ruf plus 49 176 9087654. 3 Leute",
      "Ruf plus 49 176 9087654, ٤ an",
    ] {
      #expect(try refusals(text) == [.malformedContinuation], "\(text.debugDescription)")
      #expect(bytes(try converted(text)) == bytes(text))
    }
    #expect(
      bytes(try converted("Ruf plus 49 176 9087654\nDanke")) == bytes("Ruf +49 176 9087654\nDanke"))
  }

  @Test(
    "spaced punctuation cannot hide a numeric continuation; spaced punctuation before prose converts"
  )
  func spacedPunctuationContinuations() throws {
    for text in [
      "Ruf plus 49 176 9087654 . 99 an", "Ruf plus 49 176 9087654 ) 99 an",
      "Ruf plus 49 176 9087654 / \n99 an", "Ruf plus 49 176 9087654 -\n99 an",
      "Ruf plus 49 176 9087654.\n(99) an",
    ] {
      #expect(try refusals(text) == [.malformedContinuation], "\(text.debugDescription)")
      #expect(bytes(try converted(text)) == bytes(text), "\(text.debugDescription)")
    }
    let cases: [(String, String)] = [
      ("Ruf plus 49 176 9087654 . Danke", "Ruf +49 176 9087654 . Danke"),
      ("Ruf (plus 49 176 9087654 ) an", "Ruf (+49 176 9087654 ) an"),
      (
        "Ruf plus 49 176 9087654 - weitere Infos folgen",
        "Ruf +49 176 9087654 - weitere Infos folgen"
      ),
      ("Ruf plus 49 176 9087654.\nDanke", "Ruf +49 176 9087654.\nDanke"),
    ]
    for (input, expected) in cases {
      #expect(bytes(try converted(input)) == bytes(expected), "\(input.debugDescription)")
    }
  }

  @Test("a malformed tail refuses the whole candidate, never a prefix of it")
  func malformedContinuations() throws {
    for tail in [
      "9087654x", "9087654°", "9087654€", "9087654%", "9087654@x.de", "9087654٤",
      "9087654:12", "9087654..1", "9087654_1",
    ] {
      let text = "Ruf plus 49 176 \(tail) an"
      #expect(try refusals(text) == [.malformedContinuation], "\(text)")
      #expect(bytes(try converted(text)) == bytes(text), "\(text)")
    }
  }

  @Test("the run limits are exact: 15 digits and 128 units; more refuses the whole run")
  func runLimits() throws {
    // 15 digits that are not a number are refused by the metadata, 16 by the scanner.
    #expect(try refusals("Ruf plus 999 1234 5678 9012 an") == [.notAValidNumber(.notANumber)])
    #expect(try refusals("Ruf plus 999 1234 5678 90123 an") == [.overLimit])
    let wide = "Ruf plus 49" + String(repeating: " ", count: 130) + "176 9087654 an"
    #expect(try refusals(wide) == [.overLimit])
    #expect(try converted(wide) == wide)
  }

  // MARK: The reviewed refusal shapes, each paired with the input that converts

  @Test("plus_between_operands: a number directly before the trigger or sign refuses")
  func arithmetic() throws {
    #expect(try refusals("Rechne 7 plus 8 9 aus") == [.arithmeticOperandBefore])
    #expect(try refusals("Es ist zwölf plus 5 6 aus") == [.arithmeticOperandBefore])
    #expect(try refusals("Es ist drei und zwanzig plus 5 6 aus") == [.arithmeticOperandBefore])
    #expect(try refusals("Hotline 3, plus 49 176 9087654 an") == [.arithmeticOperandBefore])
    #expect(try refusals("Rechne 7 +49/176/9087654 aus") == [.arithmeticOperandBefore])
    #expect(try converted("Rechne 7 plus 8 9 aus") == "Rechne 7 plus 8 9 aus")
    #expect(
      try converted("Rechne bitte plus 41 44 683 21 90 aus") == "Rechne bitte +41 44 683 21 90 aus")
    #expect(try converted("Ein plus 41 44 683 21 90 aus") == "Ein +41 44 683 21 90 aus")
  }

  @Test("plus_joining_nouns and plus_not_followed_by_digit: no digit group follows the trigger")
  func noDigitGroupFollows() throws {
    #expect(try refusals("Der Preis gilt plus Versand und Verpackung.") == [.wordFollowsTrigger])
    #expect(
      try refusals("Wir liefern den Schrank plus Montage bis Freitag.") == [.wordFollowsTrigger])
    #expect(try refusals("Am Ende steht plus") == [.notFollowedByDigit])
    #expect(try refusals("Am Ende steht plus ") == [.notFollowedByDigit])
    #expect(try refusals("Am Ende steht plus … 49 176 9087654") == [.notFollowedByDigit])
    #expect(try converted("Am Ende steht plus 49 176 9087654") == "Am Ende steht +49 176 9087654")
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
    #expect(try converted("Es sind plus 49 176 9087654 heute") == "Es sind +49 176 9087654 heute")
  }

  @Test("closing punctuation cannot hide a competing unit")
  func bracketedUnitTail() throws {
    for text in ["Es sind (plus 3,5) Grad draußen", "Es sind (plus 3,5) Prozent mehr"] {
      #expect(try refusals(text) == [.temperatureOrPercentTail], "\(text)")
      #expect(bytes(try converted(text)) == bytes(text))
    }
    #expect(try refusals("Es sind (plus 3,5) Meter mehr") == [.measurementOrCurrencyTail])
    #expect(try refusals("Dazu plus 3,5 Meter Seil") == [.measurementOrCurrencyTail])
    #expect(try refusals("Das kostet plus 5 20 Euro") == [.measurementOrCurrencyTail])
    #expect(
      bytes(try converted("Ruf (plus 49 176 9087654) an")) == bytes("Ruf (+49 176 9087654) an"))
  }

  @Test("a separate closing mark cannot hide a unit or currency behind it")
  func spacedClosingMarkUnitTail() throws {
    for text in ["Es kostet (plus 49 176 9087654 ) Euro", "Es sind (plus 49 176 9087654 ) Liter"] {
      #expect(try refusals(text) == [.measurementOrCurrencyTail], "\(text)")
      #expect(bytes(try converted(text)) == bytes(text), "\(text)")
    }
    let degrees = "Es sind (plus 49 176 9087654 ) Grad"
    #expect(try refusals(degrees) == [.temperatureOrPercentTail])
    #expect(bytes(try converted(degrees)) == bytes(degrees))
    #expect(try converted("Ruf (plus 49 176 9087654 ) an") == "Ruf (+49 176 9087654 ) an")
  }

  // MARK: The editor's digit guarantee

  @Test("a regrouping edit that changes a digit is refused at minting and at applying")
  func editorRefusesChangedDigits() throws {
    let snapshot = LanguageTextSnapshot("Ruf plus 49 176 9087654 an")
    let range = 4..<23
    #expect(snapshot.substring(range) == "plus 49 176 9087654")
    guard
      case .failure(.changesDigits) = snapshot.edit(
        regroupingDigitsIn: range, with: "+49 176 9087653")
    else {
      Issue.record("a changed digit must not mint")
      return
    }
    // A forged edit carrying the flag is checked again by the editor.
    let forged = LanguageTextEdit(
      range: range, replacement: "+49 176 908765", snapshotIdentity: snapshot.identity,
      regroupsDigits: true)
    #expect(LanguageTextEditor.apply([forged], to: snapshot) == .refused(.changesDigits))
    // The honest edit applies.
    let honest = try snapshot.edit(regroupingDigitsIn: range, with: "+49 176 9087654").get()
    #expect(LanguageTextEditor.apply([honest], to: snapshot) == .applied("Ruf +49 176 9087654 an"))
  }

  @Test("a regrouping edit may not cover a number chunk in part, nor an address, money or unit")
  func editorLimitsRegrouping() throws {
    let snapshot = LanguageTextSnapshot("Ruf plus 49 176 9087654 an")
    // Ends inside the chunk "9087654".
    let partial = try snapshot.edit(regroupingDigitsIn: 4..<20, with: "+49 1769087").get()
    guard
      case .refused(.intersectsProtectedSpan) = LanguageTextEditor.apply([partial], to: snapshot)
    else {
      Issue.record("a partly covered number chunk must refuse")
      return
    }
    let money = LanguageTextSnapshot("Es kostet 5 20 Euro heute")
    let overMoney = try money.edit(regroupingDigitsIn: 10..<19, with: "520 Euro").get()
    guard case .refused(.intersectsProtectedSpan) = LanguageTextEditor.apply([overMoney], to: money)
    else {
      Issue.record("a money span must refuse")
      return
    }
    // A plain edit still may not cross any number chunk.
    let plain = try snapshot.edit(replacing: 4..<23, with: "+49 176 9087654").get()
    guard case .refused(.intersectsProtectedSpan) = LanguageTextEditor.apply([plain], to: snapshot)
    else {
      Issue.record("a plain edit over digits must refuse")
      return
    }
  }

  // MARK: Unicode, several candidates, the editor, idempotence

  @Test("surrounding Unicode keeps its bytes and its character boundaries")
  func unicodeSurroundings() throws {
    let nfd = "Für Zoe\u{0308} plus 49 176 9087654 an"
    #expect(bytes(try converted(nfd)) == bytes("Für Zoe\u{0308} +49 176 9087654 an"))
    let emoji = "📞 plus 49 176 9087654"
    #expect(bytes(try converted(emoji)) == bytes("📞 +49 176 9087654"))
    let (snapshot, result) = try run(emoji)
    let edit = try #require(result.edits.first)
    #expect(edit.range == 3..<22)
    #expect(snapshot.substring(edit.range) == "plus 49 176 9087654")
  }

  @Test("several safe candidates are all proposed against one snapshot and applied together")
  func severalCandidates() throws {
    let text = "Erst plus 49 176 9087654, dann plus 43 1 7894321 an"
    let (_, result) = try run(text)
    #expect(result.edits.count == 2)
    #expect(bytes(try converted(text)) == bytes("Erst +49 176 9087654, dann +43 1 7894321 an"))
  }

  @Test("a refused candidate leaves a separate safe candidate in place")
  func safeAndRefused() throws {
    let text = "Rechne 7 plus 8 9 und ruf plus 49 176 9087654 an"
    let (_, result) = try run(text)
    #expect(result.edits.count == 1)
    #expect(result.candidates.count == 2)
    #expect(result.candidates[0].decision == .refused(.arithmeticOperandBefore))
    #expect(bytes(try converted(text)) == bytes("Rechne 7 plus 8 9 und ruf +49 176 9087654 an"))
  }

  @Test("edits applied to another text are refused by the editor and leave that text alone")
  func editorFallback() throws {
    let (_, result) = try run("Ruf plus 49 176 9087654 an")
    let other = LanguageTextSnapshot("Ruf plus 49 176 9087655 an")
    #expect(LanguageTextEditor.apply(result.edits, to: other) == .refused(.staleSnapshot))
  }

  @Test("a second pass over the converted text proposes nothing and changes nothing")
  func idempotence() throws {
    for text in [
      "Notiere plus 49, 1, 7, 6, 9, 0, 8, 7, 6, 5, 4 bitte.", "Ruf plus 49 176 9087654 an",
      "Ruf (plus 49 176 9087654) an", "Ruf +81/3/4567/8901 an",
      "Erst plus 49 176 9087654, dann plus 43 1 7894321 an", "Ruf plus 41 0 22 700 45 61 an",
      "Ruf plus 39.08770899 an",
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
    let text = String(repeating: "Ruf plus 49 176 9087654 oder ", count: 70)
    let (_, result) = try run(text)
    #expect(result.edits.count == 70)
    #expect(result.candidates.count == LanguagePhonePrefixPass.Run.diagnosticLimit)
    #expect(result.candidatesTruncated)
    #expect(try converted(text) == String(repeating: "Ruf +49 176 9087654 oder ", count: 70))
  }

  // MARK: The frozen phone rows

  /// The text with every explicitly international number reduced to "+" and its digits, so two
  /// texts that differ only in digit grouping compare equal. Independent of the pass's scanner.
  private func canonical(_ text: String) -> String {
    var output = ""
    var index = text.startIndex
    while index < text.endIndex {
      if text[index] == "+", let next = text.index(index, offsetBy: 1, limitedBy: text.endIndex),
        next < text.endIndex, text[next].isASCII, text[next].isNumber
      {
        output.append("+")
        let separators: Set<Character> = [" ", "/", "-", ".", ","]
        var cursor = next
        while cursor < text.endIndex {
          let character = text[cursor]
          if character.isASCII && character.isNumber {
            output.append(character)
            cursor = text.index(after: cursor)
          } else if separators.contains(character) {
            // A run of separators belongs to the number only when a digit follows it.
            var after = cursor
            while after < text.endIndex, separators.contains(text[after]) {
              after = text.index(after: after)
            }
            guard after < text.endIndex, text[after].isASCII, text[after].isNumber else { break }
            cursor = after
          } else {
            break
          }
        }
        index = cursor
      } else {
        output.append(text[index])
        index = text.index(after: index)
      }
    }
    return output
  }

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
    var converted = 0
    var refusalReasons: [String: Int] = [:]

    for row in development {
      visited += 1
      let (snapshot, result) = try run(row.spokenInput)
      let output = try self.converted(row.spokenInput)
      let matches = row.acceptedWrittenVariants.contains { canonical($0) == canonical(output) }
      #expect(matches, "\(row.id): \(output.debugDescription) does not carry an accepted number")
      if output != row.spokenInput { converted += 1 }
      for edit in result.edits {
        let original = try #require(snapshot.substring(edit.range), "\(row.id)")
        #expect(original.filter(\.isNumber) == edit.replacement.filter(\.isNumber), "\(row.id)")
      }
      let (_, again) = try run(output)
      #expect(again.edits.isEmpty, "\(row.id): second pass proposed an edit")
    }

    for row in lexical + formatted {
      visited += 1
      let (_, result) = try run(row.spokenInput)
      #expect(result.edits.isEmpty, "\(row.id): proposed an edit")
      #expect(bytes(try self.converted(row.spokenInput)) == bytes(row.spokenInput), "\(row.id)")
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
          row.spokenInput.contains("Milliliter")
          ? .notAValidNumber(.notANumber) : .temperatureOrPercentTail
        #expect(result.candidates.map(\.decision) == [.refused(expected)], "\(row.id)")
      case "already_formatted":
        #expect(
          result.candidates.allSatisfy { $0.decision == .refused(.alreadyWellFormed) },
          "\(row.id): a written number is kept as written")
      default:
        Issue.record("\(row.id): unexpected reason \(row.refusalReason ?? "nil")")
      }
    }

    #expect(visited == 79)
    print(
      "ITN phone fixtures: visited=\(visited) development=\(development.count) converted=\(converted) "
        + "lexical=\(lexical.count) formatted=\(formatted.count) "
        + "refusals=\(refusalReasons.sorted { $0.key < $1.key })")
  }
}
