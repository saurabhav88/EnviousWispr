import Foundation

// MARK: - The phone-prefix pass (#1677, PR 2 chunk 4)
//
// ONE pure pass: where a spoken country-prefix word (German `plus`) stands before an
// already-written telephone digit run, propose an edit that replaces ONLY that word and the
// horizontal separator after it with the replacement sign. Every digit, comma, space and
// surrounding byte stays as written. The pass proposes edits against one immutable snapshot; the
// shared editor applies them (and independently refuses anything that touches protected text).
// Nothing registers or calls this pass yet.
//
// ADMISSION (all must hold, otherwise no edit and a named refusal):
//  1. a complete standalone trigger word: a whole whitespace-delimited chunk with optional opening
//     punctuation before it. A trigger-like word inside an address, identifier or path is part of
//     a longer chunk and never matches, so the pass cannot start inside a protected span;
//  2. horizontal whitespace, then ONE maximal ASCII digit group of 1 to 3 digits with no leading
//     zero (parsed by the shared parser as a country-prefix digit group);
//  3. at least ONE more written digit group, joined by horizontal whitespace or by a comma with
//     optional surrounding horizontal whitespace; no line break, letter, slash, colon, hyphen or
//     decimal point inside the run; at most 8 groups and 128 UTF-16 units, else the WHOLE
//     candidate is refused (a truncated prefix is never converted);
//  4. none of the reviewed refusal shapes applies, and no unit or currency word (as protection
//     reads them) follows the run: a competing quantity or price, not a reviewed shape.
//
// The reviewed shapes are enforced two ways, and the result says which:
//  - explicit predicates: `plus_between_operands` (a written or spoken number directly before the
//    trigger) and `plus_before_temperature_or_percent` (a temperature or percentage unit after
//    the digit run);
//  - admission failure: `plus_joining_nouns` (a word follows the trigger) and
//    `plus_not_followed_by_digit` (no digit group follows) are negative structural conditions;
//    the dispatch evaluates them as conditions and names them, but they are no word list.
//
// LIMITS (declared syntax limits, not telephone-length correctness): this is not a telephone
// parser and not a German part-of-speech classifier. It does not check that a country code is
// assigned, does not regroup digits, and does not convert spoken digits, `00` prefixes or
// national prefixes. A refused candidate is reported and left exactly as written.

struct LanguagePhonePrefixPass: Sendable {

  let grammar: LanguageNumberGrammar
  let rules: LanguagePhonePrefixRules

  init(grammar: LanguageNumberGrammar, rules: LanguagePhonePrefixRules) {
    self.grammar = grammar
    self.rules = rules
  }

  /// Why one candidate produced no edit.
  enum Refusal: Sendable, Equatable {
    /// Shape `plus_between_operands`: a number stands directly before the trigger.
    case arithmeticOperandBefore
    /// Shape `plus_joining_nouns`: a word follows the trigger.
    case wordFollowsTrigger
    /// Shape `plus_not_followed_by_digit`: no ASCII digit group follows the trigger.
    case notFollowedByDigit
    /// Shape `plus_before_temperature_or_percent`: a temperature or percentage unit follows.
    case temperatureOrPercentTail
    /// A competing written structure: a unit or currency follows the digit run, so it is a
    /// quantity or a price, not a telephone number. Not a reviewed shape (that is the
    /// temperature-or-percentage predicate); an admission exclusion.
    case measurementOrCurrencyTail
    case countryGroupInvalid(LanguageNumberRefusal)
    case leadingZeroCountryGroup
    case malformedContinuation
    case overLimit
    case tooFewDigitGroups
    case editRefused(LanguageEditRefusal)
  }

  enum Decision: Sendable, Equatable {
    case proposed(LanguageTextEdit)
    case refused(Refusal)
  }

  struct Candidate: Sendable, Equatable {
    /// The trigger word's UTF-16 range in the original text.
    let trigger: Range<Int>
    let decision: Decision
  }

  struct Run: Sendable, Equatable {
    /// Every proposed edit, minted against the supplied snapshot.
    let edits: [LanguageTextEdit]
    /// The first `Run.diagnosticLimit` candidates, in text order.
    let candidates: [Candidate]
    let candidatesTruncated: Bool

    static let diagnosticLimit = 64
  }

  enum Outcome: Sendable, Equatable {
    case ran(Run)
    /// The rules cannot be interpreted safely: no pass ran and nothing was proposed.
    case unavailable(String)
  }

  // MARK: Limits

  static let maxGroups = 8
  static let maxRunUTF16 = 128

  // MARK: Entry

  func propose(in snapshot: LanguageTextSnapshot) -> Outcome {
    for shape in LanguagePhonePrefixRules.Shape.allCases where rules.refusal(for: shape) == nil {
      return .unavailable("reviewed shape \(shape.rawValue) is missing")
    }
    guard !rules.triggers.isEmpty, !rules.replacement.isEmpty else {
      return .unavailable("no trigger or replacement")
    }
    let chunks = LanguageProtectedSpans.chunks(of: snapshot.text)
    let protected = LanguageProtectedSpans.collect(in: snapshot)
    let parser = LanguageNumberParser(grammar: grammar)
    var edits: [LanguageTextEdit] = []
    var candidates: [Candidate] = []
    var truncated = false
    for index in chunks.indices {
      guard let trigger = triggerRange(of: chunks[index]) else { continue }
      let decision = decide(
        trigger: trigger, chunkIndex: index, chunks: chunks, snapshot: snapshot,
        protected: protected, parser: parser)
      if case .proposed(let edit) = decision { edits.append(edit) }
      if candidates.count < Run.diagnosticLimit {
        candidates.append(Candidate(trigger: trigger, decision: decision))
      } else {
        truncated = true
      }
    }
    return .ran(Run(edits: edits, candidates: candidates, candidatesTruncated: truncated))
  }

  // MARK: Trigger

  private static let openingPunctuation = CharacterSet(charactersIn: "([{\"'«„“‘")

  /// The trigger word's range when the chunk is exactly one trigger word (after optional opening
  /// punctuation), compared by lookup-only folding.
  private func triggerRange(of chunk: LanguageProtectedSpans.Chunk) -> Range<Int>? {
    var leading = 0
    var rest = String.UnicodeScalarView()
    var skipping = true
    for scalar in chunk.text.unicodeScalars {
      if skipping, Self.openingPunctuation.contains(scalar) {
        leading += scalar.value > 0xFFFF ? 2 : 1
        continue
      }
      skipping = false
      rest.append(scalar)
    }
    guard rules.triggers.contains(LanguageNumberGrammar.fold(String(rest))) else { return nil }
    return (chunk.range.lowerBound + leading)..<chunk.range.upperBound
  }

  // MARK: Decision

  private func decide(
    trigger: Range<Int>, chunkIndex: Int, chunks: [LanguageProtectedSpans.Chunk],
    snapshot: LanguageTextSnapshot, protected: [LanguageProtectedSpan],
    parser: LanguageNumberParser
  ) -> Decision {
    let units = snapshot.units
    let scanner = UnitScanner(units: units)

    // Separator after the trigger, then the start of whatever follows.
    var cursor = trigger.upperBound
    while cursor < units.count, scanner.isHorizontalWhitespace(at: cursor) {
      cursor += scanner.width(at: cursor)
    }
    let separatorEnd = cursor
    let startsWithDigit =
      separatorEnd > trigger.upperBound && scanner.isASCIIDigit(at: separatorEnd)
    let wordFollows = separatorEnd > trigger.upperBound && scanner.isLetter(at: separatorEnd)

    let scan = startsWithDigit ? scanner.scanRun(from: separatorEnd) : nil
    var tail = UnitTail.none
    if case .run(_, let runEnd)? = scan {
      tail = unitTail(after: runEnd, chunks: chunks, protected: protected, scanner: scanner)
    }
    let operandBefore = numberPrecedes(
      chunkIndex: chunkIndex, chunks: chunks, snapshot: snapshot, parser: parser)

    // Exhaustive dispatch over the reviewed shapes, in reviewed order. Each shape is a predicate
    // over the context above; the first one that applies names the refusal.
    for shape in LanguagePhonePrefixRules.Shape.allCases {
      let refusal: Refusal?
      switch shape {
      case .plusBetweenOperands:
        refusal = startsWithDigit && operandBefore ? .arithmeticOperandBefore : nil
      case .plusJoiningNouns: refusal = wordFollows ? .wordFollowsTrigger : nil
      case .plusBeforeTemperatureOrPercent:
        refusal = tail == .temperatureOrPercent ? .temperatureOrPercentTail : nil
      case .plusNotFollowedByDigit: refusal = startsWithDigit ? nil : .notFollowedByDigit
      }
      if let refusal { return .refused(refusal) }
    }

    // Admission of the numeric run. A competing quantity or price is not a telephone number.
    if tail == .otherUnitOrCurrency { return .refused(.measurementOrCurrencyTail) }
    guard case .run(let groups, _)? = scan else {
      switch scan {
      case .overLimit?: return .refused(.overLimit)
      default: return .refused(.malformedContinuation)
      }
    }
    guard let country = groups.first else { return .refused(.notFollowedByDigit) }
    switch parser.parse(.phonePrefixDigits, in: snapshot, range: country) {
    case .refused(let reason): return .refused(.countryGroupInvalid(reason))
    case .parsed(let number):
      if number.source.hasPrefix("0") { return .refused(.leadingZeroCountryGroup) }
    }
    guard groups.count >= 2 else { return .refused(.tooFewDigitGroups) }

    // The minimal edit: the trigger word and its separator, never a digit.
    let range = trigger.lowerBound..<separatorEnd
    switch snapshot.edit(replacing: range, with: rules.replacement) {
    case .success(let edit): return .proposed(edit)
    case .failure(let refusal): return .refused(.editRefused(refusal))
    }
  }

  // MARK: Context

  /// True when a written number or a supported spoken number directly precedes the trigger across
  /// horizontal whitespace only (one to three words for a spoken compound).
  private func numberPrecedes(
    chunkIndex: Int, chunks: [LanguageProtectedSpans.Chunk], snapshot: LanguageTextSnapshot,
    parser: LanguageNumberParser
  ) -> Bool {
    guard chunkIndex > 0, chunks[chunkIndex - 1].gapAfterIsHorizontal else { return false }
    if chunks[chunkIndex - 1].hasDecimalDigit { return true }
    for width in 1...3 {
      let first = chunkIndex - width
      guard first >= 0 else { return false }
      if width > 1, !chunks[first].gapAfterIsHorizontal { return false }
      let range = chunks[first].range.lowerBound..<chunks[chunkIndex - 1].range.upperBound
      if case .parsed = parser.parse(.cardinal, in: snapshot, range: range) { return true }
    }
    return false
  }

  private enum UnitTail: Equatable {
    case none
    case temperatureOrPercent
    case otherUnitOrCurrency
  }

  /// What the first word after the digit run (across horizontal whitespace) is, read from the
  /// protection file's authority: the word is a unit or currency exactly when protection marks it
  /// as a measurement or money span beside the run's last number, and it is a temperature or
  /// percentage when that authority says so. No unit word is listed here.
  private func unitTail(
    after runEnd: Int, chunks: [LanguageProtectedSpans.Chunk], protected: [LanguageProtectedSpan],
    scanner: UnitScanner
  ) -> UnitTail {
    // The chunk that holds the run's last digit, closing punctuation included, so a bracket or a
    // sentence mark cannot hide the unit behind it.
    guard
      let numericChunk = chunks.first(where: {
        $0.range.lowerBound < runEnd && runEnd <= $0.range.upperBound
      })
    else { return .none }
    let chunkEnd = numericChunk.range.upperBound
    var cursor = chunkEnd
    while cursor < scanner.units.count, scanner.isHorizontalWhitespace(at: cursor) {
      cursor += scanner.width(at: cursor)
    }
    guard cursor > chunkEnd, cursor < scanner.units.count,
      let chunk = chunks.first(where: { $0.range.lowerBound == cursor }),
      protected.contains(where: {
        $0.range == chunk.range && ($0.kind == .measurement || $0.kind == .money)
      })
    else { return .none }
    return LanguageProtectedSpans.isTemperatureOrPercentUnit(chunk.text)
      ? .temperatureOrPercent : .otherUnitOrCurrency
  }
}

// MARK: - Scanning the original code units

/// Reads the original UTF-16 units. Every question is about ONE position; nothing here copies or
/// normalizes the text.
private struct UnitScanner {
  let units: [UInt16]

  private static let lineBreaks: Set<UInt32> = [0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029]
  /// Punctuation that may directly follow the last digit without belonging to the number.
  private static let endingPunctuation: Set<UInt32> = Set(
    ".!?;:)]}\"'»”’“‘".unicodeScalars.map(\.value))

  enum RunScan: Equatable {
    case run(groups: [Range<Int>], end: Int)
    case malformed
    case overLimit
  }

  func scalar(at index: Int) -> Unicode.Scalar? {
    guard index >= 0, index < units.count else { return nil }
    let unit = units[index]
    if UTF16.isLeadSurrogate(unit) {
      guard index + 1 < units.count, UTF16.isTrailSurrogate(units[index + 1]) else { return nil }
      let high = UInt32(unit) - 0xD800
      let low = UInt32(units[index + 1]) - 0xDC00
      return Unicode.Scalar(0x10000 + (high << 10) + low)
    }
    return Unicode.Scalar(unit)
  }

  func width(at index: Int) -> Int {
    guard let scalar = scalar(at: index) else { return 1 }
    return scalar.value > 0xFFFF ? 2 : 1
  }

  func isASCIIDigit(at index: Int) -> Bool {
    index >= 0 && index < units.count && units[index] >= 0x30 && units[index] <= 0x39
  }

  func isHorizontalWhitespace(at index: Int) -> Bool {
    guard let scalar = scalar(at: index) else { return false }
    return scalar.properties.isWhitespace && !Self.lineBreaks.contains(scalar.value)
  }

  func isLetter(at index: Int) -> Bool {
    scalar(at: index)?.properties.isAlphabetic ?? false
  }

  /// Scans the supported numeric run starting at an ASCII digit. The run is COMPLETE or it is
  /// refused as a whole: a permitted separator (horizontal whitespace, or a comma with horizontal
  /// whitespace on either side) always continues it, glued or non-ASCII continuations are
  /// malformed, and a numeric continuation behind a line break or closing punctuation cannot turn
  /// an unsupported run into an admitted prefix.
  func scanRun(from start: Int) -> RunScan {
    guard isASCIIDigit(at: start) else { return .malformed }
    var groups: [Range<Int>] = []
    var position = start
    var end = start

    func completed() -> RunScan {
      .run(groups: groups, end: end)
    }

    func finishAtBoundary(from boundary: Int) -> RunScan {
      var cursor = boundary
      while let value = scalar(at: cursor), value.properties.isWhitespace {
        cursor += width(at: cursor)
      }
      if scalar(at: cursor)?.properties.numericType == .decimal {
        return .malformed
      }
      return completed()
    }

    while true {
      var groupEnd = position
      while isASCIIDigit(at: groupEnd) { groupEnd += 1 }
      groups.append(position..<groupEnd)
      end = groupEnd
      if groups.count > LanguagePhonePrefixPass.maxGroups
        || groupEnd - start > LanguagePhonePrefixPass.maxRunUTF16
      {
        return .overLimit
      }

      var nextPosition = groupEnd
      while isHorizontalWhitespace(at: nextPosition) {
        nextPosition += width(at: nextPosition)
      }
      guard let next = scalar(at: nextPosition) else { return completed() }
      let hadHorizontalGap = nextPosition > groupEnd

      // A decimal digit is a separator-joined group only when it is ASCII and a gap precedes it;
      // a non-ASCII digit is a different script or a malformed run.
      if next.properties.numericType == .decimal {
        guard hadHorizontalGap, isASCIIDigit(at: nextPosition) else { return .malformed }
        position = nextPosition
        continue
      }

      // A comma separator permits horizontal whitespace on BOTH sides.
      if next == "," {
        let commaEnd = nextPosition + 1
        var after = commaEnd
        while isHorizontalWhitespace(at: after) { after += width(at: after) }
        if isASCIIDigit(at: after) {
          position = after
          continue
        }
        guard let following = scalar(at: after) else { return completed() }
        if following.properties.numericType == .decimal { return .malformed }
        if Self.lineBreaks.contains(following.value) {
          return finishAtBoundary(from: after)
        }
        // A sentence comma may precede prose after a space; glued text is malformed.
        guard after > commaEnd, isLetter(at: after) else { return .malformed }
        return completed()
      }

      if Self.lineBreaks.contains(next.value) {
        return finishAtBoundary(from: nextPosition)
      }

      if Self.endingPunctuation.contains(next.value) {
        var after = nextPosition
        while let punctuation = scalar(at: after),
          Self.endingPunctuation.contains(punctuation.value) || punctuation == ","
        {
          after += width(at: after)
        }
        guard let following = scalar(at: after) else { return completed() }
        guard following.properties.isWhitespace else { return .malformed }
        return finishAtBoundary(from: after)
      }

      if hadHorizontalGap { return completed() }
      return .malformed
    }
  }
}
