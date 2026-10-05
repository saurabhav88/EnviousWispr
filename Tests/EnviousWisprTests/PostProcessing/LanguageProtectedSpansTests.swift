import Foundation
import Testing

@testable import EnviousWisprPostProcessing

// MARK: - Protected spans and validated edits (#1677, PR 2 chunk 3)
//
// A language pass must never rewrite text that is already written. These tests propose edits that
// cross spans a person or an earlier pass already wrote, and prove the editor refuses them and
// leaves the original bytes untouched. Every rejection is paired with a disjoint or merely
// touching edit that SUCCEEDS, so a guard that refuses everything cannot pass.
//
// Expected spans are located with `NSString` and literal substrings, never read from the
// collector under test. The neutral-subset cases feed the REAL output of
// `normalizeLanguageNeutral`.
//
// When this fails, a later pass would rewrite a digit, an address or a unit that was already
// written, or would hand back a half-edited text.

@Suite("Protected spans and text edits (#1677)", .tags(.driftGuard))
struct LanguageProtectedSpansTests {

  // MARK: Helpers

  /// The UTF-16 range of a literal substring, located independently of the collector.
  private func locate(_ needle: String, in text: String, occurrence: Int = 0) -> Range<Int>? {
    var found: Range<Int>?
    var from = 0
    for _ in 0...occurrence {
      guard
        let next = ITNFixtureRanges.range(
          of: needle, in: text, within: from..<(text as NSString).length)
      else { return nil }
      found = next
      from = next.upperBound
    }
    return found
  }

  private func spans(_ text: String) -> [(text: String, kind: LanguageProtectedSpan.Kind)] {
    let snapshot = LanguageTextSnapshot(text)
    return LanguageProtectedSpans.collect(in: snapshot).map {
      (snapshot.substring($0.range) ?? "<invalid>", $0.kind)
    }
  }

  private func apply(_ text: String, _ proposals: [(Range<Int>, String)]) -> LanguageEditOutcome {
    let snapshot = LanguageTextSnapshot(text)
    var edits: [LanguageTextEdit] = []
    for (range, replacement) in proposals {
      switch snapshot.edit(replacing: range, with: replacement) {
      case .success(let edit): edits.append(edit)
      case .failure(let refusal): return .refused(refusal)
      }
    }
    return LanguageTextEditor.apply(edits, to: snapshot)
  }

  // MARK: What counts as a written span

  struct Expectation: Sendable, CustomTestStringConvertible {
    let text: String
    let expected: [String]
    var testDescription: String { text }
  }

  /// Sentences with independently known written spans (chunk text, in reading order).
  static let numbers: [Expectation] = [
    Expectation(text: "Der Zug kommt um 12:30 an.", expected: ["12:30"]),
    Expectation(text: "Am 05.05.2024 war es heiß.", expected: ["05.05.2024"]),
    Expectation(text: "Das Datum ist 2026-09-26.", expected: ["2026-09-26."]),
    Expectation(text: "Version 2.5.0 ist da.", expected: ["2.5.0"]),
    Expectation(text: "Frage B-2, bitte", expected: ["B-2,"]),
    Expectation(text: "Läuft auf localhost:3000, ok", expected: ["localhost:3000,"]),
    Expectation(text: "Ruf +49 171 2345678 an", expected: ["+49", "171", "2345678"]),
    Expectation(text: "Es sind 3,5 mehr", expected: ["3,5"]),
    Expectation(text: "Im 17. Jahrhundert", expected: ["17."]),
    Expectation(text: "Nummer 00 49 40 1357", expected: ["00", "49", "40", "1357"]),
    Expectation(text: "Er ist Jahrgang ١٩٩٠ geboren", expected: ["١٩٩٠"]),
  ]

  @Test("chunks holding a written digit are protected as numbers", arguments: numbers)
  func numberSpans(_ item: Expectation) {
    let found = spans(item.text)
    #expect(found.map(\.text) == item.expected, "\(item.text)")
    #expect(found.allSatisfy { $0.kind == .number }, "\(item.text)")
  }

  static let addresses: [Expectation] = [
    Expectation(
      text: "Schreib an max.mustermann@gmail.com bitte", expected: ["max.mustermann@gmail.com"]),
    Expectation(
      text: "Siehe https://beispiel.de/hilfe jetzt", expected: ["https://beispiel.de/hilfe"]),
    Expectation(text: "Auf www.beispiel.de, steht es", expected: ["www.beispiel.de,"]),
    Expectation(text: "Öffne beispiel.de/aide und lies", expected: ["beispiel.de/aide"]),
    Expectation(text: "Mail an mailto:info@beispiel.de.", expected: ["mailto:info@beispiel.de."]),
    Expectation(text: "Folge @beispiel heute", expected: ["@beispiel"]),
    Expectation(text: "Auf docs.beispiel.co.uk lesen", expected: ["docs.beispiel.co.uk"]),
  ]

  @Test("addresses and URLs are protected whole, punctuation included", arguments: addresses)
  func addressSpans(_ item: Expectation) {
    let found = spans(item.text)
    #expect(found.map(\.text) == item.expected, "\(item.text)")
    #expect(found.allSatisfy { $0.kind == .address }, "\(item.text)")
  }

  @Test("a long URL is protected to its last character: no unprotected suffix")
  func longURL() throws {
    let path = String(repeating: "abschnitt/", count: 40) + "ende"
    let url = "https://beispiel.de/" + path
    #expect(url.utf16.count > 128)
    let text = "Lies \(url) jetzt"
    let found = spans(text)
    #expect(found.map(\.text) == [url])
    // An edit that starts in the last few characters of the URL is refused.
    let tail = try #require(locate("ende", in: text))
    let outcome = apply(text, [(tail, "XXXX")])
    guard case .refused(.intersectsProtectedSpan(let span)) = outcome else {
      Issue.record("expected a refusal inside the long URL, got \(outcome)")
      return
    }
    #expect(span.kind == .address)
  }

  static let money: [Expectation] = [
    Expectation(text: "Es kostet 5 € heute", expected: ["5", "€"]),
    Expectation(text: "Es kostet € 5 heute", expected: ["€", "5"]),
    Expectation(text: "Zahle 20 Euro bar", expected: ["20", "Euro"]),
    Expectation(text: "Konto: USD 5", expected: ["USD", "5"]),
    Expectation(text: "Preis 5 CHF.", expected: ["5", "CHF."]),
  ]

  @Test("a currency beside a written number is protected with it", arguments: money)
  func moneySpans(_ item: Expectation) {
    let found = spans(item.text)
    #expect(found.map(\.text) == item.expected, "\(item.text)")
    #expect(found.contains { $0.kind == .money }, "\(item.text)")
  }

  static let measurements: [Expectation] = [
    Expectation(text: "Es sind 20 % mehr", expected: ["20", "%"]),
    Expectation(text: "Er wiegt 5 kg.", expected: ["5", "kg."]),
    Expectation(text: "Um 12 Uhr geht es los", expected: ["12", "Uhr"]),
    Expectation(text: "Es hat 5 Grad draußen", expected: ["5", "Grad"]),
    Expectation(text: "Bei 21 °C ist es warm", expected: ["21", "°C"]),
    Expectation(text: "Sie läuft 10 km", expected: ["10", "km"]),
  ]

  @Test("a unit after a written number is protected with it", arguments: measurements)
  func measurementSpans(_ item: Expectation) {
    let found = spans(item.text)
    #expect(found.map(\.text) == item.expected, "\(item.text)")
    #expect(found.contains { $0.kind == .measurement }, "\(item.text)")
  }

  @Test("prose with no written structure has no protected span")
  func proseHasNone() {
    for text in [
      "Wir treffen uns am Abend vor der Tür.",
      "Er kam um dreiundzwanzig Uhr nach Hause.",
      "Der Förster, z.B. in Bayern, wohnt dort.",
      "Das gilt usw. für alle.",
      "Halb eins ist keine Zeitangabe hier.",
      "Ruhe\u{0301} bitte, und und oder.",
      "",
    ] {
      #expect(spans(text).isEmpty, "\(text.debugDescription)")
    }
  }

  @Test("a unit or currency word separated by a line break is not part of the number")
  func lineBreakEndsAdjacency() {
    #expect(spans("5\nkg").map(\.text) == ["5"])
    #expect(spans("5 kg").map(\.text) == ["5", "kg"])
    #expect(spans("€\n5").map(\.text) == ["5"])
    // A word that merely follows a number is not a unit.
    #expect(spans("5 Katzen").map(\.text) == ["5"])
  }

  // MARK: Rejection paired with success

  @Test("an edit that crosses a written number is refused; the touching and disjoint edits apply")
  func numberEditsPaired() throws {
    let text = "Er kam um 12:30 Uhr heim."
    let number = try #require(locate("12:30", in: text))
    let word = try #require(locate("heim", in: text))
    let before = try #require(locate("kam", in: text))
    // Crossing: the whole span, part of it, and a range that merely overlaps its first unit.
    for crossing in [
      number, number.lowerBound..<(number.lowerBound + 1),
      (number.lowerBound - 2)..<(number.lowerBound + 1),
      (number.upperBound - 1)..<(number.upperBound + 2),
    ] {
      guard case .refused(.intersectsProtectedSpan) = apply(text, [(crossing, "X")]) else {
        Issue.record("expected a refusal for \(crossing)")
        continue
      }
    }
    // Disjoint and merely touching edits succeed.
    #expect(apply(text, [(word, "zurück")]) == .applied("Er kam um 12:30 Uhr zurück."))
    #expect(apply(text, [(before, "kehrte")]) == .applied("Er kehrte um 12:30 Uhr heim."))
    let space = (number.lowerBound - 1)..<number.lowerBound
    #expect(apply(text, [(space, "\u{00A0}")]) == .applied("Er kam um\u{00A0}12:30 Uhr heim."))
  }

  @Test("replacing the spoken prefix before a written digit group keeps the digits")
  func prefixBeforeDigits() throws {
    let text = "Ruf plus 49 171 2345678 an"
    let prefix = try #require(locate("plus ", in: text))
    #expect(apply(text, [(prefix, "+")]) == .applied("Ruf +49 171 2345678 an"))
    // Taking the first digit with it is refused.
    let reaching = prefix.lowerBound..<(prefix.upperBound + 1)
    guard case .refused(.intersectsProtectedSpan) = apply(text, [(reaching, "+4")]) else {
      Issue.record("an edit reaching the digit group must be refused")
      return
    }
  }

  @Test("edits keep a written address whole: one refusal, one success")
  func addressEditsPaired() throws {
    let text = "Schreib an max@beispiel.de oder ruf an"
    let address = try #require(locate("max@beispiel.de", in: text))
    let word = try #require(locate("oder", in: text))
    guard case .refused(.intersectsProtectedSpan(let span)) = apply(text, [(address, "x")]) else {
      Issue.record("expected a refusal")
      return
    }
    #expect(span.range == address)
    #expect(apply(text, [(word, "und")]) == .applied("Schreib an max@beispiel.de und ruf an"))
  }

  @Test("the editor protects written digits on its own: no caller-supplied spans exist to omit")
  func editorProtectsByItself() throws {
    let text = "Ruf 49 an"
    let digits = try #require(locate("49", in: text))
    let word = try #require(locate("an", in: text))
    guard case .refused(.intersectsProtectedSpan(let span)) = apply(text, [(digits, "50")]) else {
      Issue.record("the written digits must not be editable")
      return
    }
    #expect(span.range == digits)
    #expect(apply(text, [(word, "ab")]) == .applied("Ruf 49 ab"))
  }

  @Test("an encoded internationalized host protects its whole path")
  func encodedHostProtection() throws {
    let url = "bank.xn--vermgensberater-ctb/dritten"
    let text = "Lies \(url) jetzt"
    #expect(spans(text).map(\.text) == [url])
    let inside = try #require(locate("dritten", in: text))
    guard case .refused(.intersectsProtectedSpan) = apply(text, [(inside, "3.")]) else {
      Issue.record("the written URL path must not be editable")
      return
    }
    let outside = try #require(locate("jetzt", in: text))
    #expect(apply(text, [(outside, "morgen")]) == .applied("Lies \(url) morgen"))
    // Control: an `xn--` label with a non-ASCII character is not an encoded label.
    #expect(spans("Lies bank.xn--ü/dritten jetzt").isEmpty)
  }

  @Test("a set with one crossing edit applies nothing, even when another edit is fine")
  func allOrNothing() throws {
    let text = "Er kam um 12:30 Uhr heim."
    let number = try #require(locate("12:30", in: text))
    let word = try #require(locate("heim", in: text))
    let outcome = apply(text, [(word, "zurück"), (number, "halb eins")])
    guard case .refused(.intersectsProtectedSpan) = outcome else {
      Issue.record("expected the whole set to be refused, got \(outcome)")
      return
    }
    // The control: the same two edits without the crossing one apply.
    let other = try #require(locate("kam", in: text))
    #expect(
      apply(text, [(word, "zurück"), (other, "kehrte")])
        == .applied("Er kehrte um 12:30 Uhr zurück."))
  }

  // MARK: The neutral subset's real output

  struct NeutralRow: Sendable, CustomTestStringConvertible {
    let dictated: String
    let written: String
    let span: String
    let kind: LanguageProtectedSpan.Kind
    var testDescription: String { written }
  }

  static let neutralRows: [NeutralRow] = [
    NeutralRow(
      dictated: "Schreib an max.mustermann at gmail punkt com",
      written: "Schreib an max.mustermann@gmail.com", span: "max.mustermann@gmail.com",
      kind: .address),
    NeutralRow(
      dictated: "Das Datum ist 2026-9-26.", written: "Das Datum ist 2026-09-26.",
      span: "2026-09-26.", kind: .number),
    NeutralRow(
      dictated: "Frage B Bindestrich 2.", written: "Frage B-2.", span: "B-2.", kind: .number),
    NeutralRow(
      dictated: "Version 2 Punkt 5 Punkt 0.", written: "Version 2.5.0.", span: "2.5.0.",
      kind: .number),
    NeutralRow(
      dictated: "ouvre la page exemple point fr barre oblique aide et suis",
      written: "ouvre la page exemple.fr/aide et suis", span: "exemple.fr/aide", kind: .address),
    NeutralRow(
      dictated: "le lien https deux points barre oblique barre oblique exemple point fr, pour",
      written: "le lien https://exemple.fr, pour", span: "https://exemple.fr,", kind: .address),
    NeutralRow(
      dictated: "il tourne sur localhost deux points 3000, et",
      written: "il tourne sur localhost:3000, et", span: "localhost:3000,", kind: .number),
    NeutralRow(
      dictated: "adres 192 kropka 168 kropka 1 kropka 1 i", written: "adres 192.168.1.1 i",
      span: "192.168.1.1", kind: .number),
    NeutralRow(
      dictated: "sur le site www point exemple point fr, y compris",
      written: "sur le site www.exemple.fr, y compris", span: "www.exemple.fr,", kind: .address),
    NeutralRow(
      dictated: "escribe a maría punto lópez arroba gmail punto com y",
      written: "escribe a maría.lópez@gmail.com y", span: "maría.lópez@gmail.com",
      kind: .address),
  ]

  @Test("what the language-neutral subset wrote survives attempted edits", arguments: neutralRows)
  func neutralOutputSurvives(_ row: NeutralRow) throws {
    let output = InverseTextNormalizer().normalizeLanguageNeutral(row.dictated)
    #expect(output == row.written, "the row must be a real neutral output")
    let expected = try #require(locate(row.span, in: output))
    let snapshot = LanguageTextSnapshot(output)
    let found = LanguageProtectedSpans.collect(in: snapshot)
    let match = try #require(found.first { $0.range == expected }, "\(row.span)")
    #expect(match.kind == row.kind)
    // Crossing edits are refused with the original bytes intact.
    for crossing in [
      expected, expected.lowerBound..<(expected.lowerBound + 1),
      (expected.upperBound - 1)..<expected.upperBound,
    ] {
      guard case .refused(.intersectsProtectedSpan) = apply(output, [(crossing, "X")]) else {
        Issue.record("\(row.span): expected a refusal for \(crossing)")
        continue
      }
    }
    // The disjoint positive control: the first word of the sentence.
    let first = try #require(output.split(separator: " ").first.map(String.init))
    let firstRange = try #require(locate(first, in: output))
    let replaced = apply(output, [(firstRange, "Neu")])
    #expect(replaced == .applied("Neu" + String(output.dropFirst(first.count))))
  }

  // MARK: Editor mechanics

  @Test("edits are validated: empty, out of bounds, splitting a character, stale, overlapping")
  func editValidation() throws {
    let text = "Ab\u{0301}c 𝟘 x\r\ny"
    let snapshot = LanguageTextSnapshot(text)
    // "b" + combining acute is one character: the boundary between them is not an edit endpoint.
    #expect(snapshot.edit(replacing: 1..<2, with: "X").failureReason == .splitsCharacter)
    #expect(snapshot.edit(replacing: 2..<3, with: "X").failureReason == .splitsCharacter)
    #expect(snapshot.edit(replacing: 1..<3, with: "X").isSuccess)
    // A surrogate pair is one character, and so is CR LF.
    let astral = try #require(ITNFixtureRanges.range(of: "𝟘", in: text))
    #expect(astral.count == 2)
    #expect(
      snapshot.edit(replacing: astral.lowerBound..<(astral.lowerBound + 1), with: "X").failureReason
        == .splitsCharacter)
    #expect(snapshot.edit(replacing: astral, with: "X").isSuccess)
    let crlf = try #require(ITNFixtureRanges.range(of: "\r\n", in: text))
    #expect(
      snapshot.edit(replacing: crlf.lowerBound..<(crlf.lowerBound + 1), with: "X").failureReason
        == .splitsCharacter)
    #expect(snapshot.edit(replacing: crlf, with: " ").isSuccess)
    #expect(snapshot.edit(replacing: 3..<3, with: "X").failureReason == .emptyRange)
    #expect(
      snapshot.edit(replacing: 0..<(snapshot.utf16Count + 1), with: "X").failureReason
        == .outOfBounds)
    // Stale: an edit minted against another text.
    let other = LanguageTextSnapshot("Ab\u{0301}c 𝟘 x\r\nz")
    let stale = try other.edit(replacing: 0..<1, with: "X").get()
    #expect(
      LanguageTextEditor.apply([stale], to: snapshot) == .refused(.staleSnapshot))
  }

  @Test("overlapping edits refuse; touching edits and any input order compose the same text")
  func overlapAndOrder() throws {
    let text = "eins zwei drei vier"
    let one = try #require(locate("eins", in: text))
    let two = try #require(locate("zwei", in: text))
    let four = try #require(locate("vier", in: text))
    #expect(
      apply(text, [(one, "1"), (two, "2"), (four, "4")]) == .applied("1 2 drei 4"))
    #expect(
      apply(text, [(four, "4"), (one, "1"), (two, "2")]) == .applied("1 2 drei 4"))
    // Two edits that touch (one ends where the next starts) are allowed.
    let joined = (one.lowerBound)..<(one.upperBound + 1)
    let next = (one.upperBound + 1)..<two.upperBound
    #expect(apply(text, [(joined, "a "), (next, "b")]) == .applied("a b drei vier"))
    // Overlap refuses, in either order.
    #expect(
      apply(text, [(one.lowerBound..<(two.lowerBound + 2), "x"), (two, "y")])
        == .refused(.overlappingEdits))
    #expect(
      apply(text, [(two, "y"), (one.lowerBound..<(two.lowerBound + 2), "x")])
        == .refused(.overlappingEdits))
    // No edits, no change; a deletion is allowed.
    #expect(apply(text, []) == .applied(text))
    #expect(
      apply(text, [(two.lowerBound..<(two.upperBound + 1), "")]) == .applied("eins drei vier"))
  }

  @Test("untouched input comes back byte for byte: whitespace, line breaks, decomposed Unicode")
  func bytesSurvive() throws {
    let text = "  Ruhe\u{0301} bitte,\r\num sieben am 12:30 Abend.\n  "
    let snapshot = LanguageTextSnapshot(text)
    #expect(snapshot.text.utf8.elementsEqual(text.utf8))
    guard case .applied(let unchanged) = apply(text, []) else {
      Issue.record("an empty edit set must apply")
      return
    }
    #expect(Array(unchanged.utf8) == Array(text.utf8))
    // A refused edit leaves the snapshot's bytes as they were.
    let number = try #require(locate("12:30", in: text))
    guard case .refused(.intersectsProtectedSpan) = apply(text, [(number, "halb eins")]) else {
      Issue.record("the written time must not be editable")
      return
    }
    // An applied edit changes only its own range, and the result is compared byte for byte.
    let word = try #require(locate("sieben", in: text))
    guard case .applied(let edited) = apply(text, [(word, "7")]) else {
      Issue.record("the disjoint edit must apply")
      return
    }
    let expected = "  Ruhe\u{0301} bitte,\r\num 7 am 12:30 Abend.\n  "
    #expect(Array(edited.utf8) == Array(expected.utf8))
  }

  @Test("the snapshot answers boundary questions the editor relies on")
  func snapshotBoundaries() {
    let snapshot = LanguageTextSnapshot("a𝟘e\u{0301}\r\nz")
    // a(0) 𝟘(1,2) e+◌́(3,4) CR LF(5,6) z(7)
    #expect(snapshot.utf16Count == 8)
    let expectedCharacterBoundaries: Set<Int> = [0, 1, 3, 5, 7, 8]
    for offset in 0...8 {
      #expect(
        snapshot.isCharacterBoundary(offset) == expectedCharacterBoundaries.contains(offset),
        "offset \(offset)")
    }
    #expect(snapshot.isScalarBoundary(2) == false)
    #expect(snapshot.isScalarBoundary(4) == true)
    #expect(snapshot.substring(1..<3) == "𝟘")
    #expect(snapshot.substring(1..<2) == nil)
    #expect(snapshot.substring(0..<99) == nil)
  }

  // MARK: Frozen control rows: written digits survive

  @Test("every written digit chunk in the frozen control rows survives an attempted edit")
  func controlRowsKeepTheirDigits() throws {
    let loaded = try ITNDevelopmentFixtures.controls()
    #expect(loaded.rows.count == 177)
    var visited = 0
    var rowsWithDigits = 0
    var protectionAssertions = 0
    var pairedSuccesses = 0
    var noDisjointCandidate = 0
    for row in loaded.rows {
      visited += 1
      // An independent tokenization: split on ASCII space, digit-bearing means an ASCII digit.
      let units = Array(row.spokenInput.utf16)
      var tokens: [Range<Int>] = []
      var start: Int?
      for (offset, unit) in units.enumerated() {
        if unit == 0x20 {
          if let begin = start { tokens.append(begin..<offset) }
          start = nil
        } else if start == nil {
          start = offset
        }
      }
      if let begin = start { tokens.append(begin..<units.count) }
      let digitTokens = tokens.indices.filter { index in
        units[tokens[index]].contains { $0 >= 0x30 && $0 <= 0x39 }
      }
      guard !digitTokens.isEmpty else { continue }
      rowsWithDigits += 1
      for index in digitTokens {
        let token = tokens[index]
        // The whole token and its first unit alone cannot be edited.
        for crossing in [token, token.lowerBound..<(token.lowerBound + 1)] {
          guard case .refused(.intersectsProtectedSpan) = apply(row.spokenInput, [(crossing, "X")])
          else {
            Issue.record("\(row.id): an edit over \(crossing) was not refused")
            continue
          }
          protectionAssertions += 1
        }
        // The space just before the token (or after it, for a first token) is not protected.
        let space: Range<Int> =
          token.lowerBound > 0
          ? (token.lowerBound - 1)..<token.lowerBound : token.upperBound..<(token.upperBound + 1)
        if space.upperBound <= units.count {
          let outcome = apply(row.spokenInput, [(space, "\u{00A0}")])
          if case .applied = outcome {
            pairedSuccesses += 1
          } else {
            Issue.record("\(row.id): the touching space edit was refused: \(outcome)")
          }
        }
      }
      // A disjoint word far from every digit token is replaceable.
      let candidate = tokens.indices.first { index in
        !digitTokens.contains { abs($0 - index) < 2 }
          && units[tokens[index]].allSatisfy { unit in
            CharacterSet.letters.contains(Unicode.Scalar(unit) ?? "0")
          }
      }
      if let candidate {
        let outcome = apply(row.spokenInput, [(tokens[candidate], "NEU")])
        if case .applied(let text) = outcome {
          #expect(text.contains("NEU"), "\(row.id)")
          pairedSuccesses += 1
        } else {
          Issue.record("\(row.id): the disjoint word edit was refused: \(outcome)")
        }
      } else {
        noDisjointCandidate += 1
      }
    }
    #expect(visited == 177)
    #expect(rowsWithDigits > 80, "most controls carry written digits (read \(rowsWithDigits))")
    #expect(protectionAssertions >= 2 * rowsWithDigits)
    #expect(pairedSuccesses >= rowsWithDigits)
    print(
      "ITN control fixtures: visited=\(visited) rowsWithDigits=\(rowsWithDigits) "
        + "protectionAssertions=\(protectionAssertions) pairedSuccesses=\(pairedSuccesses) "
        + "noDisjointCandidate=\(noDisjointCandidate) "
        + "futurePassAssertionsUnavailable=\(visited - rowsWithDigits)")
  }
}

extension Result {
  fileprivate var failureReason: Failure? {
    if case .failure(let error) = self { return error }
    return nil
  }

  fileprivate var isSuccess: Bool {
    if case .success = self { return true }
    return false
  }
}
