import Foundation
import Testing

@testable import EnviousWisprPostProcessing

// MARK: - The clock-idiom pass (#1677, PR 2 chunk 6)
//
// These tests drive the real pass and the real shared editor (the German language route runs the
// pass in production); nothing here certifies the German clock cell. Expected outputs are
// independent literals or the frozen rows' accepted written variants, compared as UTF-8 bytes.
// Every refusal is paired with the near-identical input that converts.
//
// The four noon/midnight controls are kept by a STRUCTURAL exclusion (`ambiguousClockFace`), not
// by executing the pending noon/midnight refusal entry; the ledger names them as such.
//
// When this fails, a clock idiom is left unconverted, or a duration, a fraction, a quantity or a
// noon/midnight choice is rewritten as a time.

@Suite("German clock-idiom pass (#1677)", .tags(.driftGuard))
struct LanguageClockIdiomPassTests {

  let grammar: LanguageNumberGrammar
  let pass: LanguageClockIdiomPass

  init() throws {
    grammar = try LanguageNumberGrammar.german()
    pass = LanguageClockIdiomPass(grammar: grammar, rules: try LanguageClockIdiomRules.german())
  }

  // MARK: Helpers

  private func run(_ text: String) throws -> (LanguageTextSnapshot, LanguageClockIdiomPass.Run) {
    let snapshot = LanguageTextSnapshot(text)
    guard case .ran(let result) = pass.propose(in: snapshot) else {
      Issue.record("the pass reported itself unavailable")
      throw CancellationError()
    }
    return (snapshot, result)
  }

  private func converted(_ text: String) throws -> String {
    let (snapshot, result) = try run(text)
    switch LanguageTextEditor.apply(result.edits, to: snapshot) {
    case .applied(let output): return output
    case .refused(let refusal):
      Issue.record("the editor refused the pass's own edits: \(refusal)")
      return text
    }
  }

  private func dispositions(_ text: String) throws -> [LanguageClockIdiomPass.Disposition] {
    try run(text).1.candidates.map(\.disposition)
  }

  private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

  // MARK: The rules

  @Test(
    "the rules carry the seven templates, five anchors, the marker and the three reviewed entries")
  func rulesFacts() throws {
    let rules = try LanguageClockIdiomRules.german()
    #expect(
      rules.templates.map(\.id) == [
        "half", "quarterAfter", "quarterTo", "minutesAfter", "minutesBefore", "minutesAfterHalf",
        "minutesBeforeHalf",
      ])
    #expect(rules.templates[0].minuteSlot == nil && rules.templates[2].minuteSlot == nil)
    #expect(rules.templates[2].tokens == ["viertel", "vor"])
    #expect(rules.templates[2].inputHours == 2...12)
    #expect(rules.templates[3].minuteSlot?.sign == 1 && rules.templates[3].minuteSlot?.minutes == 1...29)
    #expect(rules.templates[4].minuteSlot?.sign == -1 && rules.templates[4].minute == 60)
    #expect(rules.templates[6].minuteSlot?.minutes == 1...14)
    #expect(rules.templates[0].tokens == ["halb"])
    #expect(rules.templates[0].hourOffset == -1)
    #expect(rules.templates[0].minute == 30)
    #expect(rules.templates[0].inputHours == 2...12)
    #expect(rules.templates[1].tokens == ["viertel", "nach"])
    #expect(rules.templates[1].hourOffset == 0)
    #expect(rules.templates[1].minute == 15)
    #expect(rules.templates[1].inputHours == 1...11)
    #expect(rules.anchors == ["um", "gegen", "bis", "ab", "für"])
    #expect(rules.trailingMarker == "uhr")
    #expect(rules.outputSeparator == ":")
    #expect(rules.refusals.map(\.id) == ["ref-clock-002", "ref-clock-003", "ref-clock-004"])
    #expect(rules.refusals.map(\.version) == [3, 2, 2])
    #expect(rules.refusals.allSatisfy { $0.kind == .literalPhrase && $0.contentSHA256.count == 64 })
    #expect(
      rules.refusals[0].phrases == [
        ["halbe", "stunde"], ["halben", "stunde"], ["viertelstunde"], ["dreiviertelstunde"],
      ])
    #expect(
      rules.refusals[1].phrases == [
        ["ein", "viertel", "der"], ["drei", "viertel", "eines", "liters"],
        ["ein", "halbes", "kilogramm"],
      ])
    #expect(rules.refusals[2].phrases == [["halb", "voll"], ["halb", "leer"]])
    // Every reviewed kind is enforced as a complete literal-phrase match, nothing broader.
    for kind in LanguageClockIdiomRules.RefusalKind.allCases {
      #expect(kind.enforcement == .completeLiteralPhraseMatch)
    }
    // The syntax data is implementation data, labelled as not a reviewed refusal.
    #expect(GermanClockIdiomData.syntaxProvenance.contains("not a reviewed refusal"))
  }

  @Test("the lowered refusals equal the reviewed clock entries in the refusal file, read directly")
  func rulesMatchTheRefusalFile() throws {
    let url = RepoRoot.url.appending(path: "scripts/itn/refusals/de.json")
    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let reviewed = try #require(object["reviewed_entries"] as? [[String: Any]])
    let clock = reviewed.filter { $0["category"] as? String == "clock_idiom" }
      .sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
    let rules = try LanguageClockIdiomRules.german()
    #expect(clock.count == 3)
    #expect(clock.compactMap { $0["id"] as? String } == rules.refusals.map(\.id))
    #expect(clock.compactMap { $0["version"] as? Int } == rules.refusals.map(\.version))
    #expect(
      clock.compactMap { $0["content_sha256"] as? String } == rules.refusals.map(\.contentSHA256))
    let kinds = clock.compactMap { ($0["match"] as? [String: Any])?["kind"] as? String }
    #expect(kinds == ["literal_phrase", "literal_phrase", "literal_phrase"])
    // Pending entries (the regional forms and the noon/midnight entry) are never lowered.
    let pending = (object["pending_entries"] as? [[String: Any]] ?? []).compactMap {
      $0["id"] as? String
    }
    #expect(pending.isEmpty == false)
    #expect(Set(pending).isDisjoint(with: rules.refusals.map(\.id)))
  }

  @Test("unsupported, empty or duplicate data fails the whole adaptation")
  func adaptationFailsClosed() {
    typealias Data = GermanClockIdiomData
    let good = (
      templates: Data.templates, anchors: Data.anchors, marker: Data.trailingMarker,
      separator: Data.outputSeparator, refusals: Data.refusals
    )
    func build(
      templates: [Data.Template]? = nil, anchors: [String]? = nil, marker: String? = nil,
      separator: String? = nil, refusals: [Data.Refusal]? = nil
    ) -> LanguageClockIdiomRules.BuildError? {
      do {
        _ = try LanguageClockIdiomRules.build(
          templates: templates ?? good.templates, anchors: anchors ?? good.anchors,
          trailingMarker: marker ?? good.marker, outputSeparator: separator ?? good.separator,
          refusals: refusals ?? good.refusals)
        return nil
      } catch let error as LanguageClockIdiomRules.BuildError {
        return error
      } catch {
        return nil
      }
    }
    func template(
      _ id: String = "t", tokens: [String] = ["halb"], offset: Int = -1, minute: Int = 30,
      low: Int = 2, high: Int = 12, sign: Int = 0, most: Int = 0
    ) -> Data.Template {
      Data.Template(
        id: id, tokens: tokens, hourOffset: offset, minute: minute, inputHourLow: low,
        inputHourHigh: high, minuteSign: sign, minuteMax: most)
    }
    #expect(build() == nil)
    #expect(build(templates: []) == .noTemplates)
    #expect(build(templates: [template("a"), template("a")]) == .duplicateTemplate("a"))
    #expect(build(templates: [template(tokens: [])]) == .invalidTemplate("t"))
    #expect(build(templates: [template(low: 1, high: 12)]) == .invalidTemplate("t"))
    #expect(build(templates: [template(low: 7, high: 3)]) == .invalidTemplate("t"))
    #expect(build(templates: [template(minute: 60)]) == .invalidTemplate("t"))
    #expect(build(templates: [template(offset: 1, low: 2, high: 12)]) == .invalidTemplate("t"))
    // Minute slots: a sign of 1 or -1, at least one minute, every written minute inside 0...59.
    #expect(build(templates: [template(minute: 60, sign: -1, most: 29)]) == nil)
    #expect(build(templates: [template(minute: 0, sign: 2, most: 5)]) == .invalidTemplate("t"))
    #expect(build(templates: [template(minute: 0, sign: 1, most: 0)]) == .invalidTemplate("t"))
    #expect(build(templates: [template(minute: 50, sign: 1, most: 29)]) == .invalidTemplate("t"))
    #expect(build(templates: [template(minute: 10, sign: -1, most: 14)]) == .invalidTemplate("t"))
    #expect(build(anchors: []) == .noAnchors)
    #expect(build(anchors: ["um", "UM"]) == .invalidAnchor("um,UM"))
    #expect(build(anchors: [""]) == .invalidAnchor(""))
    #expect(build(marker: "") == .emptyMarker)
    #expect(build(separator: "") == .invalidSeparator)
    #expect(build(separator: "::") == .invalidSeparator)
    #expect(build(refusals: []) == .noRefusals)
    let empty = Data.Refusal(
      id: "r", version: 1, contentSHA256: "x", reasonCode: "c", phrases: [""], reviewRef: "r")
    #expect(build(refusals: [empty]) == .emptyPhrase("r"))
    #expect(
      build(refusals: good.refusals + [good.refusals[0]])
        == .duplicatePhrase("halbe stunde"))
  }

  @Test("a pass without templates, anchors or refusals is unavailable and proposes nothing")
  func unavailableRules() throws {
    let full = try LanguageClockIdiomRules.german()
    func rules(
      templates: [LanguageClockIdiomRules.Template]? = nil, anchors: Set<String>? = nil,
      refusals: [LanguageClockIdiomRules.Refusal]? = nil
    ) -> LanguageClockIdiomRules {
      LanguageClockIdiomRules(
        templates: templates ?? full.templates, anchors: anchors ?? full.anchors,
        trailingMarker: full.trailingMarker, outputSeparator: full.outputSeparator,
        refusals: refusals ?? full.refusals)
    }
    let snapshot = LanguageTextSnapshot("Wir kommen um halb sieben.")
    for broken in [rules(templates: []), rules(anchors: []), rules(refusals: [])] {
      guard
        case .unavailable = LanguageClockIdiomPass(grammar: grammar, rules: broken).propose(
          in: snapshot)
      else {
        Issue.record("incomplete rules must make the pass unavailable")
        continue
      }
    }
    #expect(try converted("Wir kommen um halb sieben.") == "Wir kommen um 6:30.")
  }

  // MARK: Both templates, boundaries, anchors

  @Test("halb H and viertel nach H convert only the idiom span, with an unpadded hour")
  func templates() throws {
    let cases: [(String, String)] = [
      ("Wir kommen um halb sieben.", "Wir kommen um 6:30."),
      ("Wir kommen um viertel nach vier.", "Wir kommen um 4:15."),
      ("Der Zug fährt gegen halb zwei ab.", "Der Zug fährt gegen 1:30 ab."),
      ("Der Zug fährt gegen halb zwölf ab.", "Der Zug fährt gegen 11:30 ab."),
      ("Die Tür öffnet um viertel nach eins.", "Die Tür öffnet um 1:15."),
      ("Die Tür öffnet um viertel nach elf.", "Die Tür öffnet um 11:15."),
      ("Wir bleiben bis halb zehn hier.", "Wir bleiben bis 9:30 hier."),
      ("Ab halb drei schließt es.", "Ab 2:30 schließt es."),
      ("Er kommt für halb acht", "Er kommt für 7:30"),
      ("Er kommt UM HALB ACHT", "Er kommt UM 7:30"),
      ("Er kommt um halb  acht", "Er kommt um 7:30"),
      ("Er kommt um halb\tacht", "Er kommt um 7:30"),
      ("Er kommt um viertel  nach\tacht", "Er kommt um 8:15"),
    ]
    for (input, expected) in cases {
      #expect(bytes(try converted(input)) == bytes(expected), "\(input.debugDescription)")
    }
    // The edit covers exactly the idiom, not the anchor.
    let (snapshot, result) = try run("Wir kommen um halb sieben.")
    let edit = try #require(result.edits.first)
    #expect(snapshot.substring(edit.range) == "halb sieben")
    #expect(edit.replacement == "6:30")
  }

  @Test("the clock marker Uhr, day-part words, articles and punctuation stay where they are")
  func neighboursSurvive() throws {
    let cases: [(String, String)] = [
      ("Wir kommen um halb sieben Uhr an.", "Wir kommen um 6:30 Uhr an."),
      ("Wir kommen um halb sieben abends.", "Wir kommen um 6:30 abends."),
      ("Wir kommen um halb sieben am Abend.", "Wir kommen um 6:30 am Abend."),
      ("Wir kommen (um halb sieben), ja.", "Wir kommen (um 6:30), ja."),
      ("Wir kommen um halb sieben, ja.", "Wir kommen um 6:30, ja."),
      ("Wir kommen um halb sieben. Danke", "Wir kommen um 6:30. Danke"),
      ("Wir kommen um halb sieben!", "Wir kommen um 6:30!"),
      ("Die Zeit: um halb sieben\nDanach", "Die Zeit: um 6:30\nDanach"),
    ]
    for (input, expected) in cases {
      #expect(bytes(try converted(input)) == bytes(expected), "\(input.debugDescription)")
    }
  }

  @Test(
    "the hours that need a clock-face choice are withheld, paired with the neighbours that convert")
  func clockFaceExclusion() throws {
    #expect(try dispositions("Wir treffen uns um halb eins.") == [.refused(.ambiguousClockFace)])
    #expect(
      try dispositions("Der Anruf kam um viertel nach zwölf.") == [.refused(.ambiguousClockFace)])
    #expect(try converted("Wir treffen uns um halb eins.") == "Wir treffen uns um halb eins.")
    #expect(
      try converted("Der Anruf kam um viertel nach zwölf.")
        == "Der Anruf kam um viertel nach zwölf.")
    // Controls one hour away convert, with no modulo arithmetic.
    #expect(try converted("Wir treffen uns um halb zwölf.") == "Wir treffen uns um 11:30.")
    #expect(try converted("Wir treffen uns um halb zwei.") == "Wir treffen uns um 1:30.")
    #expect(try converted("Der Anruf kam um viertel nach eins.") == "Der Anruf kam um 1:15.")
    #expect(try converted("Der Anruf kam um viertel nach elf.") == "Der Anruf kam um 11:15.")
  }

  @Test("an anchor is required, whole, directly before the idiom, and never inferred")
  func anchors() throws {
    for anchor in ["um", "Um", "gegen", "bis", "ab", "für"] {
      #expect(
        try converted("Es ist \(anchor) halb sieben so") == "Es ist \(anchor) 6:30 so", "\(anchor)")
    }
    for text in [
      "Es ist halb sieben so", "Es ist so halb sieben", "Es ist um, halb sieben so",
      "Es ist um\nhalb sieben so", "Es ist um (halb sieben) so",
      "Es ist zu halb sieben so", "halb sieben",
    ] {
      let found = try dispositions(text)
      #expect(found == [.refused(.noAnchor)], "\(text.debugDescription)")
      #expect(bytes(try converted(text)) == bytes(text))
    }
  }

  @Test("viertel vor H and a spoken minute before nach, vor and halb become written times")
  func quarterToAndMinutes() throws {
    // Engine output measured 2026-10-06 (docs/audits/2026-10-06-1677-de-clock-minutes-shapes,
    // Azure TTS, Parakeet and WhisperKit).
    let cases: [(String, String)] = [
      ("Wir treffen uns um viertel vor acht am Bahnhof.", "Wir treffen uns um 7:45 am Bahnhof."),
      ("Der Zug fährt um Viertel vor 12 ab.", "Der Zug fährt um 11:45 ab."),
      ("Komm bitte gegen Viertel vor sieben vorbei.", "Komm bitte gegen 6:45 vorbei."),
      ("Wir essen um 5 nach 2 zu Mittag.", "Wir essen um 2:05 zu Mittag."),
      ("Der Bus kommt um 10 nach 7.", "Der Bus kommt um 7:10."),
      ("Treffen wir uns um 20 nach 3?", "Treffen wir uns um 3:20?"),
      ("Das Kino fängt um 5 vor 8 an.", "Das Kino fängt um 7:55 an."),
      ("Das Kino fängt um fünf vor acht an.", "Das Kino fängt um 7:55 an."),
      ("Die Sitzung endet um 20 vor 5.", "Die Sitzung endet um 4:40."),
      ("Wir kommen um 5 vor halb neun.", "Wir kommen um 8:25."),
      ("Wir kommen um fünf vor halb neun.", "Wir kommen um 8:25."),
      ("Wir kommen um 5 nach halb 9.", "Wir kommen um 8:35."),
      ("Der Flieger landet um 25 nach 11.", "Der Flieger landet um 11:25."),
      ("Das Spiel beginnt um 10 nach halb 8.", "Das Spiel beginnt um 7:40."),
      ("Um sieben nach acht klingelte es.", "Um 8:07 klingelte es."),
      ("Wir kommen um 5 nach 2 Uhr.", "Wir kommen um 2:05 Uhr."),
      ("Wir kommen um 5 nach 2. Danach Kaffee.", "Wir kommen um 2:05. Danach Kaffee."),
    ]
    for (input, expected) in cases {
      #expect(bytes(try converted(input)) == bytes(expected), "\(input)")
    }
    // No anchor, not an hour, a clock-face hour, a minute out of range, a unit after the hour.
    for text in [
      "Die Zahl war 20 nach Abzug der Kosten.", "Ich habe noch 10 vor mir.",
      "Er kam um 10 nach Hause.", "Der Termin ist um viertel vor eins.",
      "Wir essen um 5 nach 12.", "Wir kommen um 5 vor 1.", "Wir kommen um 30 nach 2.",
      "Wir kommen um 20 vor halb 9.", "Wir warten um 5 nach 3 Minuten.",
      "Treffpunkt ist Viertel vor 9 Uhr am Eingang.", "Bitte sei um kurz nach drei da.",
      // A capitalized noun right after a minute idiom makes it a quantity.
      "Die Punktzahl steigt um fünf nach drei Treffern.", "Der Wert sinkt um 5 nach 3 Runden.",
    ] {
      #expect(bytes(try converted(text)) == bytes(text), "\(text)")
    }
  }

  @Test("pending regional forms and unsupported shapes are not candidates and stay as written")
  func pendingAndUnsupportedForms() throws {
    for text in [
      "Wir kommen um viertel drei.",
      "Wir kommen um dreiviertel vier.",
      "Wir kommen um drei viertel vier.", "Wir kommen um halb so spät.", "Wir kommen um halb.",
      "Wir kommen um halb zwanzig.", "Wir kommen um halb ein.", "Wir kommen um sieben am Abend.",
      "Wir kommen um viertel nach.", "Wir kommen um viertel nach dreizehn.", "Wir kommen um 6:30.",
      "Wir kommen at half past six.", "Wir kommen um halb ٧.",
    ] {
      let (_, result) = try run(text)
      #expect(result.candidates.isEmpty, "\(text)")
      #expect(bytes(try converted(text)) == bytes(text))
    }
  }

  // MARK: Reviewed literal refusals

  @Test(
    "each reviewed phrase refuses as a complete token sequence, beside the nearby input that is no match"
  )
  func reviewedPhrases() throws {
    let matches: [(String, String)] = [
      ("Das dauert eine halbe Stunde.", "ref-clock-002"),
      ("Nach einer halben Stunde ging es los.", "ref-clock-002"),
      ("Wir warten eine Viertelstunde.", "ref-clock-002"),
      ("Fast eine Dreiviertelstunde lang.", "ref-clock-002"),
      ("Ein Viertel der Leute kam.", "ref-clock-003"),
      ("Wir nehmen drei Viertel eines Liters.", "ref-clock-003"),
      ("Wir nehmen ein halbes Kilogramm.", "ref-clock-003"),
      ("Die Flasche ist halb voll.", "ref-clock-004"),
      ("Das Glas ist halb leer, wirklich.", "ref-clock-004"),
      ("Ein  Viertel  der Leute kam.", "ref-clock-003"),
    ]
    for (text, entry) in matches {
      #expect(try dispositions(text) == [.refused(.literalPhrase(entry: entry))], "\(text)")
      #expect(bytes(try converted(text)) == bytes(text))
    }
    // Near misses are NOT executions of a reviewed phrase: no candidate at all.
    for text in [
      "In einer viertel Stunde beginnt es.", "Ein Viertel und drei Stücke.",
      "Ein Viertel unserer Ersparnisse.",
      "Wir nehmen ein halbes Brot.", "Die Flasche ist halb.", "Kein Viertel der Leute kam.",
      "Das Glas ist halb leerer.", "Wir nehmen drei Viertel eines Kuchens.",
    ] {
      #expect(try run(text).1.candidates.isEmpty, "\(text)")
    }
    // A reviewed phrase elsewhere never suppresses an independent valid candidate.
    #expect(
      try converted("Das Glas ist halb voll und wir kommen um halb sieben.")
        == "Das Glas ist halb voll und wir kommen um 6:30.")
    #expect(
      try converted("Nach einer halben Stunde, um viertel nach vier, gingen wir.")
        == "Nach einer halben Stunde, um 4:15, gingen wir.")
  }

  // MARK: Continuation, units, limits

  @Test("number material after the hour word refuses, whatever stands between")
  func numberContinuation() throws {
    for text in [
      "Wir kommen um halb sieben und zwanzig an.", "Wir kommen um halb sieben 5 Leute.",
      "Wir kommen (um halb sieben) 5 Leute.", "Wir kommen um halb sieben\n5 Leute.",
      "Wir kommen um halb sieben, 20 Leute.", "Wir kommen um halb sieben drei Leute.",
      "Wir kommen um halb sieben dritte.", "Wir kommen um viertel nach vier 30 Leute.",
    ] {
      #expect(
        try dispositions(text) == [.refused(.numberContinuationAfter)], "\(text.debugDescription)")
      #expect(bytes(try converted(text)) == bytes(text))
    }
    // Controls: ordinary words after the hour convert.
    #expect(try converted("Wir kommen um halb sieben Leute.") == "Wir kommen um 6:30 Leute.")
    #expect(
      try converted("Wir kommen um halb sieben morgens an.") == "Wir kommen um 6:30 morgens an.")
  }

  @Test("punctuation, clock markers and compound pieces cannot hide number material")
  func completeNumberTail() throws {
    for text in [
      "Wir kommen um halb sieben ) 30 Leute.", "Wir kommen um halb sieben . ٣ Leute.",
      "Wir kommen um halb sieben Uhr dreißig.", "Wir kommen um halb sieben Uhr\n30 Leute.",
      "Wir kommen um halb sieben ein und dreißig Leute.",
      "Wir kommen um halb sieben einund zwanzig Leute.",
      "Wir kommen um halb sieben ein undzwanzig Leute.", "Wir kommen um halb sieben .5 Leute.",
    ] {
      #expect(try dispositions(text) == [.refused(.numberContinuationAfter)], "\(text)")
      #expect(bytes(try converted(text)) == bytes(text), "\(text)")
    }
    #expect(
      bytes(try converted("Wir kommen um halb sieben Uhr morgens."))
        == bytes("Wir kommen um 6:30 Uhr morgens."))
    #expect(
      bytes(try converted("Wir kommen um halb sieben eine Gruppe abholen."))
        == bytes("Wir kommen um 6:30 eine Gruppe abholen."))
  }

  @Test("standalone punctuation and the clock marker cannot hide a competing unit")
  func completeUnitTail() throws {
    for text in [
      "Wir füllen um halb sieben ) Liter ein.", "Wir füllen um halb sieben . Liter ein.",
      "Wir füllen um halb sieben Uhr Euro ein.",
    ] {
      #expect(try dispositions(text) == [.refused(.measurementOrCurrencyTail)], "\(text)")
      #expect(bytes(try converted(text)) == bytes(text), "\(text)")
    }
    #expect(
      bytes(try converted("Wir kommen (um halb sieben) Uhr an."))
        == bytes("Wir kommen (um 6:30) Uhr an."))
    // Controls: a line break between the tail and the unit keeps them apart.
    #expect(
      bytes(try converted("Wir füllen um halb sieben Uhr\nLiter ein."))
        == bytes("Wir füllen um 6:30 Uhr\nLiter ein."))
    #expect(
      bytes(try converted("Wir füllen um halb sieben\nLiter ein."))
        == bytes("Wir füllen um 6:30\nLiter ein."))
  }

  @Test("a competing unit or currency after the hour chunk refuses; the clock marker does not")
  func competingUnits() throws {
    for text in [
      "Wir füllen um halb sieben Liter ein.", "Das kostet um halb sieben Euro.",
      "Wir füllen (um halb sieben) Liter ein.", "Wir füllen um halb sieben, Liter ein.",
      "Wir füllen um viertel nach vier kg ein.",
    ] {
      #expect(try dispositions(text) == [.refused(.measurementOrCurrencyTail)], "\(text)")
      #expect(bytes(try converted(text)) == bytes(text))
    }
    #expect(try converted("Wir füllen um halb sieben Uhr ein.") == "Wir füllen um 6:30 Uhr ein.")
    #expect(try converted("Wir füllen um halb sieben UHR ein.") == "Wir füllen um 6:30 UHR ein.")
  }

  @Test(
    "the idiom span is bounded at 128 UTF-16 units; a longer one is refused whole, not shortened")
  func spanLimit() throws {
    func idiom(units: Int) -> String {
      // "halb" + n spaces + "sieben" spans 10 + n units.
      "Wir kommen um halb" + String(repeating: " ", count: units - 10) + "sieben an."
    }
    #expect(try converted(idiom(units: 128)) == "Wir kommen um 6:30 an.")
    #expect(try dispositions(idiom(units: 129)) == [.refused(.exceedsLimit)])
    #expect(bytes(try converted(idiom(units: 129))) == bytes(idiom(units: 129)))
    // Line breaks never sit inside an idiom.
    #expect(try run("Wir kommen um halb\nsieben an.").1.candidates.isEmpty)
    #expect(try run("Wir kommen um viertel\nnach vier an.").1.candidates.isEmpty)
  }

  // MARK: Unicode, system behavior

  @Test("NFD hour words, emoji, mixed language and articles survive byte for byte")
  func unicodeAndMixedText() throws {
    let cases: [(String, String)] = [
      ("Für Zoe\u{0308} um halb zwo\u{0308}lf", "Für Zoe\u{0308} um 11:30"),
      ("📞 um halb sieben", "📞 um 6:30"),
      ("The meeting is um halb sieben okay", "The meeting is um 6:30 okay"),
      ("Wir sehen den Film um viertel nach acht heute", "Wir sehen den Film um 8:15 heute"),
      ("Um halb sieben\r\nUm halb acht", "Um 6:30\r\nUm 7:30"),
    ]
    for (input, expected) in cases {
      #expect(bytes(try converted(input)) == bytes(expected), "\(input.debugDescription)")
    }
  }

  @Test(
    "several candidates, a refused one beside a safe one, the editor, idempotence, bounded diagnostics"
  )
  func systemBehavior() throws {
    let several =
      "Um halb sieben essen wir, gegen viertel nach acht gehen wir, ab halb zehn schlafen wir."
    let (_, result) = try run(several)
    #expect(result.edits.count == 3)
    #expect(
      try converted(several) == "Um 6:30 essen wir, gegen 8:15 gehen wir, ab 9:30 schlafen wir.")
    let mixed = "Um halb eins essen wir, ab halb zehn schlafen wir."
    #expect(try converted(mixed) == "Um halb eins essen wir, ab 9:30 schlafen wir.")
    #expect(try run(mixed).1.candidates.count == 2)
    // A second pass over the output proposes nothing.
    let once = try converted(several)
    #expect(try run(once).1.edits.isEmpty)
    #expect(try converted(once) == once)
    // Edits from another text are refused by the editor and leave that text alone.
    let other = LanguageTextSnapshot("Anderer Text")
    #expect(LanguageTextEditor.apply(result.edits, to: other) == .refused(.staleSnapshot))
    // Diagnostics are bounded but every safe candidate still gets its edit.
    let many = String(repeating: "Wir kommen um halb sieben oder ", count: 70)
    let (_, bounded) = try run(many)
    #expect(bounded.edits.count == 70)
    #expect(bounded.candidates.count == LanguageClockIdiomPass.Run.diagnosticLimit)
    #expect(bounded.candidatesTruncated)
  }

  // MARK: An anchor the engine glued to halb

  @Test("an exact anchor-plus-halb word reads as anchor and template; the anchor keeps its bytes")
  func gluedAnchor() throws {
    let cases: [(String, String)] = [
      ("Wir sollten bishalb sechs fertig sein.", "Wir sollten bis 5:30 fertig sein."),
      ("Wir kommen umhalb sieben.", "Wir kommen um 6:30."),
      ("Wir kommen Umhalb sieben.", "Wir kommen Um 6:30."),
      ("Wir kommen gegenhalb 8, ja.", "Wir kommen gegen 7:30, ja."),
      ("Der Tisch ist fu\u{0308}rhalb acht reserviert.", "Der Tisch ist fu\u{0308}r 7:30 reserviert."),
      ("Wir kommen abhalb zwölf Uhr.", "Wir kommen ab 11:30 Uhr."),
    ]
    for (input, expected) in cases {
      #expect(bytes(try converted(input)) == bytes(expected), "\(input.debugDescription)")
    }
    // Every existing restriction still applies to the glued form.
    #expect(try dispositions("Wir kommen umhalb eins.") == [.refused(.ambiguousClockFace)])
    #expect(try dispositions("Wir kommen umhalb sieben 5 Leute.") == [.refused(.numberContinuationAfter)])
    #expect(try dispositions("Wir füllen umhalb sieben Liter ein.") == [.refused(.measurementOrCurrencyTail)])
    // Words that merely end in halb, or glue something else, are no candidates.
    for text in [
      "Deshalb sieben Leute.", "Innerhalb acht Tagen.", "Anderthalb sieben.", "Weshalb acht?",
      "Wir kommen zuhalb sieben.", "Wir kommen umhalbe sieben.", "Wir kommen bishalbsieben.",
      "Wir kommen (umhalb sieben).",
    ] {
      #expect(try run(text).1.edits.isEmpty, "\(text)")
    }
    // A second pass over the output proposes nothing.
    #expect(try run("Wir sollten bis 5:30 fertig sein.").1.candidates.isEmpty)
  }

  // MARK: Digit hours the engine already wrote

  @Test("a digit hour converts like a spelled one, over the whole chunk, punctuation carried")
  func digitHours() throws {
    let cases: [(String, String)] = [
      ("Wir kommen um halb 8", "Wir kommen um 7:30"),
      ("Wir kommen um halb 08 an", "Wir kommen um 7:30 an"),
      ("Wir kommen um viertel nach 1 an", "Wir kommen um 1:15 an"),
      ("Wir kommen gegen halb 12.", "Wir kommen gegen 11:30."),
      ("Wir kommen (um halb 8), ja.", "Wir kommen (um 7:30), ja."),
      ("Wir kommen um halb 8 Uhr an.", "Wir kommen um 7:30 Uhr an."),
      ("Wir kommen um halb 8!", "Wir kommen um 7:30!"),
      ("Wir kommen um halb 8.) Danke", "Wir kommen um 7:30.) Danke"),
      ("Die Zeit: um halb 8\nDanach", "Die Zeit: um 7:30\nDanach"),
      ("Um halb 7 essen wir, ab halb zehn schlafen wir.", "Um 6:30 essen wir, ab 9:30 schlafen wir."),
    ]
    for (input, expected) in cases {
      #expect(bytes(try converted(input)) == bytes(expected), "\(input.debugDescription)")
    }
    let (snapshot, result) = try run("Wir kommen gegen halb 12.")
    let edit = try #require(result.edits.first)
    #expect(snapshot.substring(edit.range) == "halb 12.")
    #expect(edit.replacement == "11:30.")
    // A second pass over the output proposes nothing.
    #expect(try run("Wir kommen um 7:30 Uhr an.").1.candidates.isEmpty)
  }

  @Test("a sentence end after a digit hour converts, like a spelled hour before a new sentence")
  func digitHourSentenceEnd() throws {
    // `halb` and `viertel nach` never take an ordinal, so a period after the digit is read as the
    // sentence end, exactly as `um halb acht. Danach` is today.
    #expect(
      try converted("Wir treffen uns um halb 8. Danach essen wir.")
        == "Wir treffen uns um 7:30. Danach essen wir.")
    #expect(
      try converted("Wir treffen uns um halb acht. Danach essen wir.")
        == "Wir treffen uns um 7:30. Danach essen wir.")
  }

  @Test("digit hours outside 1 to 12, clock-face hours and other written forms never convert")
  func digitHourExclusions() throws {
    #expect(try dispositions("Wir treffen uns um halb 1.") == [.refused(.ambiguousClockFace)])
    #expect(try dispositions("Der Anruf kam um viertel nach 12.") == [.refused(.ambiguousClockFace)])
    for text in [
      "Wir kommen um halb 0.", "Wir kommen um halb 00.", "Wir kommen um halb 13.",
      "Wir kommen um halb 20.", "Wir kommen um halb 008.", "Wir kommen um halb 8:30.",
      "Wir kommen um halb 8%.", "Wir kommen um halb \u{FF18}.", "Wir kommen um halb 8er.",
      "Wir kommen um halb (8).",
    ] {
      #expect(try run(text).1.candidates.isEmpty, "\(text)")
      #expect(bytes(try converted(text)) == bytes(text), "\(text)")
    }
    for text in ["Wir treffen uns um halb 1.", "Der Anruf kam um viertel nach 12."] {
      #expect(bytes(try converted(text)) == bytes(text), "\(text)")
    }
  }

  @Test("a digit hour keeps every refusal a spelled hour has")
  func digitHourRefusals() throws {
    #expect(try dispositions("Es ist halb 8 so") == [.refused(.noAnchor)])
    #expect(try dispositions("Wir kommen um halb 8 5 Leute.") == [.refused(.numberContinuationAfter)])
    #expect(try dispositions("Wir kommen um halb 8, 20 Leute.") == [.refused(.numberContinuationAfter)])
    #expect(try dispositions("Wir füllen um halb 8 Liter ein.") == [.refused(.measurementOrCurrencyTail)])
    #expect(try dispositions("Das kostet um halb 8 Euro.") == [.refused(.measurementOrCurrencyTail)])
    for text in [
      "Es ist halb 8 so", "Wir kommen um halb 8 5 Leute.", "Wir füllen um halb 8 Liter ein.",
      "Das kostet um halb 8 Euro.",
    ] {
      #expect(bytes(try converted(text)) == bytes(text), "\(text)")
    }
  }

  @Test("the editor rechecks every clock chunk's shape and span; clock meaning stays the pass's")
  func clockChunkPermission() throws {
    let snapshot = LanguageTextSnapshot("um halb 8. dann 9 Leute")
    // "halb 8." is 3..<10; the chunk "8." is 8..<10; "9" is 16..<17.
    let honest = try snapshot.edit(
      replacing: 3..<10, consumingClockChunks: [8..<10], with: "7:30.").get()
    #expect(LanguageTextEditor.apply([honest], to: snapshot) == .applied("um 7:30. dann 9 Leute"))
    // Minting refuses a dropped mark, a chunk outside the edit, overlapping or unordered chunks,
    // and no chunk at all.
    for (range, chunks, replacement) in [
      (3..<10, [8..<10], "7:30"), (3..<9, [8..<10], "7:30."),
      (3..<17, [8..<10, 8..<10], "x"), (3..<17, [16..<17, 8..<10], "x"), (3..<10, [], "7:30."),
    ] {
      guard case .failure(.notAClockChunk) = snapshot.edit(
        replacing: range, consumingClockChunks: chunks, with: replacement)
      else {
        Issue.record("\(range) \(chunks) \(replacement) must not mint")
        continue
      }
    }
    // A chunk naming only part of the number "8." mints (its shape is fine) and is refused on apply.
    let partial = try snapshot.edit(replacing: 3..<10, consumingClockChunks: [8..<9], with: "7:30.").get()
    guard case .refused = LanguageTextEditor.apply([partial], to: snapshot) else {
      Issue.record("a chunk that is part of a number must be refused on apply")
      return
    }
    let long = LanguageTextSnapshot("um halb 123")
    guard case .failure(.notAClockChunk) = long.edit(
      replacing: 3..<11, consumingClockChunks: [8..<11], with: "1:30")
    else {
      Issue.record("three digits must not mint")
      return
    }
    // Two chunks, the digits changed, the mark carried: "a las 10 menos 20." to "a las 9:40.".
    let minus = LanguageTextSnapshot("a las 10 menos 20.")
    let both = try minus.edit(
      replacing: 6..<18, consumingClockChunks: [6..<8, 15..<18], with: "9:40.").get()
    #expect(LanguageTextEditor.apply([both], to: minus) == .applied("a las 9:40."))
    // Naming only one of the two number chunks the edit covers is refused.
    let half = try minus.edit(replacing: 6..<18, consumingClockChunks: [15..<18], with: "9:40.").get()
    guard case .refused(.intersectsProtectedSpan(let skipped)) = LanguageTextEditor.apply([half], to: minus)
    else {
      Issue.record("an edit covering an unnamed number chunk must be refused")
      return
    }
    #expect(skipped.range == 6..<8)
    // A named chunk that is only part of a number span is refused.
    let part = try minus.edit(replacing: 6..<18, consumingClockChunks: [6..<7, 15..<18], with: "9:40.").get()
    guard case .refused = LanguageTextEditor.apply([part], to: minus) else {
      Issue.record("a chunk that splits a number must be refused")
      return
    }
    // Forged values: a dropped mark, and a permission naming one chunk while covering another.
    let dropped = LanguageTextEdit(
      range: 3..<10, replacement: "7:30", snapshotIdentity: snapshot.identity,
      permission: .replacesClockChunks([8..<10]))
    #expect(LanguageTextEditor.apply([dropped], to: snapshot) == .refused(.notAClockChunk))
    let wide = LanguageTextEdit(
      range: 3..<17, replacement: "7:30. dann 9", snapshotIdentity: snapshot.identity,
      permission: .replacesClockChunks([16..<17]))
    guard case .refused(.intersectsProtectedSpan(let span)) = LanguageTextEditor.apply([wide], to: snapshot)
    else {
      Issue.record("an edit covering a second number chunk must be refused")
      return
    }
    #expect(span.range == 8..<10)
    // A plain edit over the digit chunk is refused as before.
    let plain = try snapshot.edit(replacing: 3..<10, with: "7:30.").get()
    guard case .refused(.intersectsProtectedSpan) = LanguageTextEditor.apply([plain], to: snapshot)
    else {
      Issue.record("a plain edit must not cover a number chunk")
      return
    }
  }

  // MARK: The frozen clock rows: the disposition ledger

  private enum Expected: Equatable {
    case duration
    case fraction
    case nonClock
    case clockFace
    case noCandidate
  }

  /// The disposition each frozen control must meet, from the chunk prompt's contract and a reading
  /// of each sentence (not read from the pass).
  private static let controlLedger: [String: Expected] = {
    var ledger: [String: Expected] = [:]
    func mark(_ numbers: [Int], _ expected: Expected) {
      for number in numbers { ledger[String(format: "de-clock-ctl-%03d", number)] = expected }
    }
    mark([1, 8, 22, 28, 61, 63, 64], .duration)
    mark([9, 29, 60, 65], .fraction)
    mark([4, 11, 18, 66], .nonClock)
    mark([5, 12, 19, 25], .clockFace)
    mark([2, 6, 13, 15, 16, 20, 23, 26, 30, 62, 67], .noCandidate)
    mark(Array(31...59), .noCandidate)
    return ledger
  }()

  @Test("every frozen clock row goes through the real pass and the shared editor, row by row")
  func frozenClockRows() throws {
    let development = try ITNDevelopmentFixtures.development().rows.filter {
      $0.category == "clock_idiom"
    }
    let controlFile = try ITNDevelopmentFixtures.controls()
    let controls = controlFile.rows.filter { $0.category == "clock_idiom" }
    let lexical = controls.filter { $0.refusalReason != "already_formatted" }
    let formatted = controls.filter { $0.refusalReason == "already_formatted" }
    #expect(development.count == 20)
    #expect(lexical.count == 30)
    #expect(formatted.count == 29)
    #expect(controlFile.pendingExcluded > 0, "pending regional controls are present and excluded")

    var visited = 0
    var definite = 0
    let unavailable = 0
    var conversions = 0
    var secondPassChecks = 0
    var counts: [String: Int] = [:]

    for row in development {
      visited += 1
      let (snapshot, result) = try run(row.spokenInput)
      #expect(result.edits.count == 1, "\(row.id): no edit plan")
      #expect(result.candidates.count == 1, "\(row.id)")
      let output = try converted(row.spokenInput)
      #expect(output != row.spokenInput, "\(row.id): unchanged")
      #expect(
        row.acceptedWrittenVariants.contains { bytes($0) == bytes(output) },
        "\(row.id): \(output.debugDescription) is not an accepted variant")
      for edit in result.edits {
        let removed = try #require(snapshot.substring(edit.range), "\(row.id)").lowercased()
        #expect(
          removed.hasPrefix("halb ") || removed.hasPrefix("viertel nach "), "\(row.id): \(removed)")
        #expect(edit.replacement.hasSuffix(":30") || edit.replacement.hasSuffix(":15"), "\(row.id)")
      }
      let (_, again) = try run(output)
      #expect(again.edits.isEmpty, "\(row.id): second pass proposed an edit")
      #expect(bytes(try converted(output)) == bytes(output), "\(row.id)")
      secondPassChecks += 1
      conversions += 1
      definite += 1
    }

    for row in lexical + formatted {
      visited += 1
      let expected = try #require(Self.controlLedger[row.id], "\(row.id) has no ledger entry")
      let (_, result) = try run(row.spokenInput)
      #expect(result.edits.isEmpty, "\(row.id): proposed an edit")
      #expect(bytes(try converted(row.spokenInput)) == bytes(row.spokenInput), "\(row.id)")
      #expect(
        row.acceptedWrittenVariants.contains { bytes($0) == bytes(row.spokenInput) }, "\(row.id)")
      let found = result.candidates.map(\.disposition)
      switch expected {
      case .duration:
        #expect(found == [.refused(.literalPhrase(entry: "ref-clock-002"))], "\(row.id)")
      case .fraction:
        #expect(found == [.refused(.literalPhrase(entry: "ref-clock-003"))], "\(row.id)")
      case .nonClock:
        #expect(found == [.refused(.literalPhrase(entry: "ref-clock-004"))], "\(row.id)")
      case .clockFace:
        #expect(found == [.refused(.ambiguousClockFace)], "\(row.id)")
      case .noCandidate:
        #expect(found.isEmpty, "\(row.id)")
      }
      counts["control \(expected)", default: 0] += 1
      definite += 1
    }

    #expect(visited == 79)
    #expect(definite + unavailable == visited)
    #expect(conversions == 20)
    #expect(unavailable == 0)
    #expect(secondPassChecks == 20)
    #expect(counts["control clockFace"] == 4)
    print(
      "ITN clock fixtures: visited=\(visited) definite=\(definite) unavailable=\(unavailable) "
        + "conversions=\(conversions) secondPass=\(secondPassChecks) "
        + "pendingExcluded=\(controlFile.pendingExcluded) "
        + "controls=\(counts.sorted { $0.key < $1.key })")
  }
}
