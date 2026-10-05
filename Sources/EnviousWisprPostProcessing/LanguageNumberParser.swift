import Foundation

// MARK: - Complete-span number parsing (#1677, PR 2 chunk 3)
//
// The parser answers ONE question about a candidate span the caller chose: "is this exact span
// one number the grammar admits, and what is it?". It returns a value with the original range, or
// a refusal. It rewrites no text, and a parsed number is NOT permission to convert it: whether a
// following word makes an ordinal safe, or whether `halb` and an hour form a clock time, belongs
// to the pass that calls this.
//
// Contract:
//  - The WHOLE candidate must be consumed. Anything left over, any unknown word, any ambiguity
//    refuses the whole candidate; a valid prefix is never returned.
//  - Limits are checked before any word is read: at most `candidateUTF16Max` UTF-16 units and
//    `candidateTokenMax` whitespace-separated tokens, and never across a line break.
//  - Lookups fold each token (lower-case, NFC) but every returned range is a range of the
//    ORIGINAL text, so NFD input produces correct original coordinates.
//  - Values are small integers built with checked arithmetic. Unknown input never becomes zero.

enum LanguageNumberKind: Sendable, Equatable {
  case cardinal
  case ordinal
  case clockHour
  case phonePrefixDigits
}

enum LanguageNumberRefusal: Error, Sendable, Equatable {
  case outOfBounds
  /// An endpoint falls inside an extended grapheme cluster of the original text.
  case splitsCharacter
  case emptyCandidate
  case exceedsUTF16Limit
  case exceedsTokenLimit
  case crossesLineBreak
  /// The candidate starts or ends with whitespace, so it is not one tight span.
  case notTight
  /// A word or a combination the grammar does not admit (including digits, English words,
  /// scale words, negative and decimal forms, and the `-s`/`-m` ordinal forms).
  case notAdmitted
  /// A bare article form (`ein`, `eine`): a determiner here, not a number.
  case articleForm
  case ambiguous
  case outOfRange
  case invalidDigits
  /// More ASCII digits than a telephone country-prefix group may hold.
  case exceedsDigitLimit
}

struct LanguageNumber: Sendable, Equatable {
  let kind: LanguageNumberKind
  let value: Int
  /// The whole candidate, as a UTF-16 range of the original text.
  let range: Range<Int>
  /// Each token's UTF-16 range in the original text.
  let tokenRanges: [Range<Int>]
  /// The candidate exactly as written, byte for byte (a digit group keeps leading zeros).
  let source: String
}

enum LanguageNumberResult: Sendable, Equatable {
  case parsed(LanguageNumber)
  case refused(LanguageNumberRefusal)
}

struct LanguageNumberParser: Sendable {
  let grammar: LanguageNumberGrammar

  init(grammar: LanguageNumberGrammar) {
    self.grammar = grammar
  }

  func parse(_ kind: LanguageNumberKind, in snapshot: LanguageTextSnapshot, range: Range<Int>)
    -> LanguageNumberResult
  {
    guard snapshot.contains(range) else { return .refused(.outOfBounds) }
    guard snapshot.isCharacterBoundary(range.lowerBound),
      snapshot.isCharacterBoundary(range.upperBound),
      let source = snapshot.substring(range)
    else { return .refused(.splitsCharacter) }
    guard !range.isEmpty else { return .refused(.emptyCandidate) }
    guard range.count <= grammar.limits.candidateUTF16Max else {
      return .refused(.exceedsUTF16Limit)
    }

    if kind == .phonePrefixDigits {
      return parseDigits(source: source, range: range)
    }

    let tokens: [Token]
    switch tokenize(source, base: range.lowerBound) {
    case .failure(let refusal): return .refused(refusal)
    case .success(let found): tokens = found
    }
    guard tokens.count <= grammar.limits.candidateTokenMax else {
      return .refused(.exceedsTokenLimit)
    }

    func make(_ value: Int) -> LanguageNumberResult {
      .parsed(
        LanguageNumber(
          kind: kind, value: value, range: range, tokenRanges: tokens.map(\.range),
          source: source))
    }

    switch kind {
    case .cardinal:
      switch cardinal(tokens) {
      case .success(let value): return make(value)
      case .failure(let refusal): return .refused(refusal)
      }
    case .clockHour:
      guard tokens.count == 1 else { return .refused(.notAdmitted) }
      switch cardinal(tokens) {
      case .failure(let refusal): return .refused(refusal)
      case .success(let value):
        guard grammar.limits.clockHourRange.contains(value) else { return .refused(.outOfRange) }
        return make(value)
      }
    case .ordinal:
      switch ordinal(tokens) {
      case .success(let value): return make(value)
      case .failure(let refusal): return .refused(refusal)
      }
    case .phonePrefixDigits:
      return .refused(.notAdmitted)
    }
  }

  // MARK: Tokens

  private struct Token {
    let range: Range<Int>
    let folded: [Unicode.Scalar]
  }

  private static let lineBreaks: Set<UInt32> = [0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029]

  /// Splits on horizontal White_Space (never across a line break). The candidate must start and end
  /// with a word.
  private func tokenize(_ source: String, base: Int) -> Result<[Token], LanguageNumberRefusal> {
    var tokens: [Token] = []
    var offset = base
    var start: Int?
    var scalars = String.UnicodeScalarView()
    var sawEdgeSpace = false
    var lastWasSpace = true
    var first = true

    func close(at end: Int) {
      guard let begin = start else { return }
      let word = LanguageNumberGrammar.fold(String(scalars))
      tokens.append(Token(range: begin..<end, folded: Array(word.unicodeScalars)))
      start = nil
      scalars = String.UnicodeScalarView()
    }

    for scalar in source.unicodeScalars {
      if Self.lineBreaks.contains(scalar.value) { return .failure(.crossesLineBreak) }
      if scalar.properties.isWhitespace {
        if first { sawEdgeSpace = true }
        close(at: offset)
        lastWasSpace = true
      } else {
        if start == nil { start = offset }
        scalars.append(scalar)
        lastWasSpace = false
      }
      first = false
      offset += scalar.value > 0xFFFF ? 2 : 1
    }
    close(at: offset)
    if sawEdgeSpace || lastWasSpace { return .failure(.notTight) }
    return .success(tokens)
  }

  // MARK: Cardinals

  private func cardinal(_ tokens: [Token]) -> Result<Int, LanguageNumberRefusal> {
    guard !tokens.isEmpty else { return .failure(.emptyCandidate) }
    let joined = tokens.flatMap(\.folded)
    let word = String(String.UnicodeScalarView(joined))
    if tokens.count == 1 {
      if let value = grammar.standalone[word] { return check(value) }
      if grammar.nonStandalone.contains(word) { return .failure(.articleForm) }
    }
    var found: [(value: Int, cuts: [Int])] = []
    let connectorScalars = Array(grammar.connector.unicodeScalars)
    for (tensWord, tensValue) in grammar.tens {
      let tensScalars = Array(tensWord.unicodeScalars)
      guard joined.count > tensScalars.count + connectorScalars.count,
        Array(joined.suffix(tensScalars.count)) == tensScalars
      else { continue }
      let head = Array(joined.dropLast(tensScalars.count))
      guard Array(head.suffix(connectorScalars.count)) == connectorScalars else { continue }
      let unitScalars = Array(head.dropLast(connectorScalars.count))
      let unit = String(String.UnicodeScalarView(unitScalars))
      guard let unitValue = grammar.compoundUnits[unit] else { continue }
      let (sum, overflow) = tensValue.addingReportingOverflow(unitValue)
      guard !overflow else { return .failure(.outOfRange) }
      found.append((sum, [unitScalars.count, unitScalars.count + connectorScalars.count]))
    }
    guard found.count == 1, let compound = found.first else {
      return .failure(found.isEmpty ? .notAdmitted : .ambiguous)
    }
    guard jointsAllowTokens(tokens, allowed: compound.cuts) else { return .failure(.notAdmitted) }
    return check(compound.value)
  }

  private func check(_ value: Int) -> Result<Int, LanguageNumberRefusal> {
    value >= 0 && value <= grammar.limits.cardinalMax ? .success(value) : .failure(.outOfRange)
  }

  /// A spaced tokenization is admitted only where it splits the composition at one of its joints:
  /// every boundary between two tokens must fall on an allowed scalar offset of the joined word.
  private func jointsAllowTokens(_ tokens: [Token], allowed: [Int]) -> Bool {
    guard tokens.count > 1 else { return true }
    var consumed = 0
    for token in tokens.dropLast() {
      consumed += token.folded.count
      if !allowed.contains(consumed) { return false }
    }
    return true
  }

  // MARK: Ordinals

  private func ordinal(_ tokens: [Token]) -> Result<Int, LanguageNumberRefusal> {
    guard !tokens.isEmpty else { return .failure(.emptyCandidate) }
    let word = String(String.UnicodeScalarView(tokens.flatMap(\.folded)))
    guard let form = grammar.ordinalForms[word] else {
      return .failure(grammar.nonStandalone.contains(word) ? .articleForm : .notAdmitted)
    }
    guard jointsAllowTokens(tokens, allowed: form.joints) else { return .failure(.notAdmitted) }
    guard grammar.limits.ordinalRange.contains(form.value) else { return .failure(.outOfRange) }
    return .success(form.value)
  }

  // MARK: Telephone country-prefix digit groups

  /// One to three ASCII digits, numeric value at most the limit. Digit-group SYNTAX only: it does
  /// not check that a real country code was assigned, and it keeps the digits as written.
  private func parseDigits(source: String, range: Range<Int>) -> LanguageNumberResult {
    let scalars = Array(source.unicodeScalars)
    guard scalars.count <= grammar.limits.phoneDigitCountMax else {
      return .refused(.exceedsDigitLimit)
    }
    var value = 0
    for scalar in scalars {
      guard scalar.value >= 0x30, scalar.value <= 0x39 else { return .refused(.invalidDigits) }
      let (times, overflowA) = value.multipliedReportingOverflow(by: 10)
      let (sum, overflowB) = times.addingReportingOverflow(Int(scalar.value - 0x30))
      guard !overflowA, !overflowB else { return .refused(.outOfRange) }
      value = sum
    }
    guard value <= grammar.limits.phoneValueMax else { return .refused(.outOfRange) }
    return .parsed(
      LanguageNumber(
        kind: .phonePrefixDigits, value: value, range: range, tokenRanges: [range], source: source))
  }
}
