import Foundation

// MARK: - The international phone pass (#1677)
//
// ONE pure pass. It finds an EXPLICITLY international telephone number, validates its digits
// against numbering metadata (`LanguagePhoneMetadata`), and rewrites the whole number in the
// metadata's international grouping. Every digit is kept, in order: the edit is minted by
// `edit(regroupingDigitsIn:with:)`, so the snapshot and the shared editor both refuse any edit
// whose replacement changes a digit. The pass proposes edits against one immutable snapshot; the
// shared editor applies them. Nothing registers or calls this pass yet.
//
// CANDIDATES (the only two ways a number is explicitly international):
//  1. spoken: a standalone trigger word (German `plus`), then horizontal whitespace and a digit
//     run, OR the trigger word glued to the run in one chunk (`plus46319876543`, an engine shape);
//  2. written: a plus sign glued to a digit run whose groups use a separator other than spaces
//     (`+81/3/4567/8901`, `+43.664.9081122`, `+32-2-601`). A written number grouped only by
//     spaces, or not at all, is already well formed and is never touched.
// A number without an explicit plus (`33 5 6789 0123`, `00 49 ...`) is never a candidate: digits
// alone do not say a number is international, and the pass never guesses a country.
//
// THE DIGIT RUN is complete or refused as a whole: groups of ASCII digits joined by horizontal
// whitespace, a comma (with optional whitespace either side), or a dot, slash or hyphen. It ends
// at prose (whitespace then a non-digit), at sentence punctuation followed by whitespace or the
// end, or at a line break; a decimal digit after any of those ends is a hidden continuation and
// refuses the candidate. A letter, sign or other character glued to the run refuses it. At most
// 15 digits (E.164) and 128 UTF-16 units; anything longer is refused whole.
//
// ADMISSION (all must hold, otherwise no edit and a named refusal):
//  - none of the reviewed refusal shapes applies (spoken candidates: `plus_between_operands`,
//    `plus_joining_nouns`, `plus_before_temperature_or_percent`, `plus_not_followed_by_digit`;
//    written candidates: a number directly before the sign is arithmetic);
//  - no unit or currency follows the run (a quantity or a price, not a telephone number);
//  - the metadata accepts the digits: an assigned calling code and a national number matching a
//    documented pattern and type, read without changing a digit.
//
// THE EDIT covers the whole chunks the candidate touches, so it rewrites protected number chunks
// only completely: opening punctuation before the trigger or sign and closing punctuation after
// the last digit are carried into the replacement unchanged.
//
// FALLBACK (spoken anchors only): when the metadata rejects the digits but the trigger word
// stands alone, the run's first group is exactly an assigned calling code and the run has 7 to 15
// digits, the pass replaces only the trigger word and its separator with the sign and keeps every
// digit and separator as written. Engines mishear single digits and speakers say trunk zeros
// (`plus 41 0 22 ...`); the sign is still right where the regrouping is not.
//
// LIMITS: validity is a documented numbering range, not a reachable subscriber. Digits the
// engine misheard stay misheard; the pass can only refuse them when they form no valid number.

struct LanguagePhonePrefixPass: Sendable {

  let grammar: LanguageNumberGrammar
  let rules: LanguagePhonePrefixRules
  let metadata: LanguagePhoneMetadata

  init(
    grammar: LanguageNumberGrammar, rules: LanguagePhonePrefixRules,
    metadata: LanguagePhoneMetadata = .shared
  ) {
    self.grammar = grammar
    self.rules = rules
    self.metadata = metadata
  }

  /// Why one candidate produced no edit.
  enum Refusal: Sendable, Equatable {
    /// Shape `plus_between_operands`: a number stands directly before the trigger or sign.
    case arithmeticOperandBefore
    /// Shape `plus_joining_nouns`: a word follows the trigger.
    case wordFollowsTrigger
    /// Shape `plus_not_followed_by_digit`: no ASCII digit group follows the trigger.
    case notFollowedByDigit
    /// Shape `plus_before_temperature_or_percent`: a temperature or percentage unit follows.
    case temperatureOrPercentTail
    /// A unit or currency follows the run: a quantity or a price, not a telephone number. Not a
    /// reviewed shape (that is the temperature-or-percentage predicate); an admission exclusion.
    case measurementOrCurrencyTail
    case malformedContinuation
    case overLimit
    /// A written number grouped by spaces only, or not at all: already well formed, kept as is.
    case alreadyWellFormed
    /// The metadata rejects the digits.
    case notAValidNumber(LanguagePhoneMetadata.Invalid)
    /// The metadata could not be loaded; no number is validated.
    case metadataUnavailable(String)
    case editRefused(LanguageEditRefusal)
  }

  enum Decision: Sendable, Equatable {
    case proposed(LanguageTextEdit)
    case refused(Refusal)
  }

  struct Candidate: Sendable, Equatable {
    /// The trigger word's (or the plus sign's) UTF-16 range in the original text.
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

  static let maxDigits = LanguagePhoneMetadata.maxDigits
  /// The fewest digits the sign-only fallback converts: shorter runs after `plus` are more often
  /// sums and quantities than telephone numbers.
  static let minFallbackDigits = 7
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
    var consumedUpTo = 0
    for index in chunks.indices where chunks[index].range.lowerBound >= consumedUpTo {
      guard let anchor = anchor(in: chunks[index], snapshot: snapshot) else { continue }
      let (decision, end) = decide(
        anchor: anchor, chunkIndex: index, chunks: chunks, snapshot: snapshot,
        protected: protected, parser: parser)
      if case .proposed(let edit) = decision {
        edits.append(edit)
        consumedUpTo = end
      }
      if candidates.count < Run.diagnosticLimit {
        candidates.append(Candidate(trigger: anchor.marker, decision: decision))
      } else {
        truncated = true
      }
    }
    return .ran(Run(edits: edits, candidates: candidates, candidatesTruncated: truncated))
  }

  // MARK: Anchors

  private enum AnchorKind: Equatable {
    /// The trigger word stands alone in its chunk; the run starts after whitespace.
    case spoken
    /// The trigger word is glued to the run inside one chunk.
    case spokenGlued
    /// A written plus sign glued to the run.
    case written
  }

  private struct Anchor {
    let kind: AnchorKind
    /// The trigger word or the plus sign.
    let marker: Range<Int>
    /// Where the edit starts: the anchor chunk's first unit, so opening punctuation is carried.
    let chunkStart: Int
  }

  private static let openingPunctuation = CharacterSet(charactersIn: "([{\"'«„“‘")

  /// The anchor this chunk starts, if any: opening punctuation, then the trigger word alone, the
  /// trigger word glued to an ASCII digit, or a plus sign glued to an ASCII digit.
  private func anchor(
    in chunk: LanguageProtectedSpans.Chunk, snapshot: LanguageTextSnapshot
  ) -> Anchor? {
    let scanner = UnitScanner(units: snapshot.units)
    var cursor = chunk.range.lowerBound
    while cursor < chunk.range.upperBound, let scalar = scanner.scalar(at: cursor),
      Self.openingPunctuation.contains(scalar)
    {
      cursor += scanner.width(at: cursor)
    }
    let start = cursor
    if scanner.units[safe: start] == 0x2B {  // "+"
      guard scanner.isASCIIDigit(at: start + 1) else { return nil }
      return Anchor(kind: .written, marker: start..<(start + 1), chunkStart: chunk.range.lowerBound)
    }
    // The trigger word: letters up to the chunk end or the first ASCII digit.
    var wordEnd = start
    while wordEnd < chunk.range.upperBound, scanner.isLetter(at: wordEnd) {
      wordEnd += scanner.width(at: wordEnd)
    }
    guard wordEnd > start, let word = snapshot.substring(start..<wordEnd),
      rules.triggers.contains(LanguageNumberGrammar.fold(word))
    else { return nil }
    if wordEnd == chunk.range.upperBound {
      return Anchor(kind: .spoken, marker: start..<wordEnd, chunkStart: chunk.range.lowerBound)
    }
    guard scanner.isASCIIDigit(at: wordEnd) else { return nil }
    return Anchor(kind: .spokenGlued, marker: start..<wordEnd, chunkStart: chunk.range.lowerBound)
  }

  // MARK: Decision

  /// The decision for one anchor, and the UTF-16 offset the proposed edit ends at (0 when refused).
  private func decide(
    anchor: Anchor, chunkIndex: Int, chunks: [LanguageProtectedSpans.Chunk],
    snapshot: LanguageTextSnapshot, protected: [LanguageProtectedSpan],
    parser: LanguageNumberParser
  ) -> (Decision, Int) {
    let units = snapshot.units
    let scanner = UnitScanner(units: units)

    // Where the digit run starts.
    var runStart = anchor.marker.upperBound
    var wordFollows = false
    if anchor.kind == .spoken {
      while runStart < units.count, scanner.isHorizontalWhitespace(at: runStart) {
        runStart += scanner.width(at: runStart)
      }
      if runStart == anchor.marker.upperBound || !scanner.isASCIIDigit(at: runStart) {
        wordFollows = runStart > anchor.marker.upperBound && scanner.isLetter(at: runStart)
        runStart = -1
      }
    }
    let startsWithDigit = runStart >= 0
    let scan = startsWithDigit ? scanner.scanRun(from: runStart) : nil
    var tail = UnitTail.none
    if case .run(_, _, _, let runEnd)? = scan {
      tail = unitTail(after: runEnd, chunks: chunks, protected: protected, scanner: scanner)
    }
    let operandBefore = numberPrecedes(
      chunkIndex: chunkIndex, chunks: chunks, snapshot: snapshot, parser: parser)

    // Exhaustive dispatch over the reviewed shapes, in reviewed order. Each shape is a predicate
    // over the context above; the first one that applies names the refusal. A written sign has
    // no trigger word, so only the arithmetic shape can apply to it.
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
      if let refusal { return (.refused(refusal), 0) }
    }

    if tail == .otherUnitOrCurrency { return (.refused(.measurementOrCurrencyTail), 0) }
    guard case .run(let digits, let separators, let firstGroup, let runEnd)? = scan else {
      switch scan {
      case .overLimit?: return (.refused(.overLimit), 0)
      default: return (.refused(.malformedContinuation), 0)
      }
    }
    // A written number grouped by spaces only (or not at all) is already well formed.
    if anchor.kind == .written && !separators.contains(where: { $0 != .space }) {
      return (.refused(.alreadyWellFormed), 0)
    }

    let formatted: String
    switch metadata.international(digits: digits) {
    case .valid(let number): formatted = number.formatted
    case .unavailable(let reason): return (.refused(.metadataUnavailable(reason)), 0)
    case .invalid(let reason):
      return fallback(
        anchor: anchor, digits: digits, firstGroup: firstGroup, reason: reason, snapshot: snapshot)
    }

    // The whole chunks the candidate touches: opening punctuation before the anchor and closing
    // punctuation after the last digit are carried over unchanged.
    guard
      let lastChunk = chunks.first(where: {
        $0.range.lowerBound < runEnd && runEnd <= $0.range.upperBound
      }),
      let leading = snapshot.substring(anchor.chunkStart..<anchor.marker.lowerBound),
      let trailing = snapshot.substring(runEnd..<lastChunk.range.upperBound)
    else { return (.refused(.malformedContinuation), 0) }
    let range = anchor.chunkStart..<lastChunk.range.upperBound
    switch snapshot.edit(regroupingDigitsIn: range, with: leading + formatted + trailing) {
    case .success(let edit): return (.proposed(edit), range.upperBound)
    case .failure(let refusal): return (.refused(.editRefused(refusal)), 0)
    }
  }

  /// The sign-only edit for a spoken number the metadata does not accept (a misheard digit, a
  /// spoken trunk zero `plus 41 0 22 ...`, or a number outside documented ranges). It converts
  /// ONLY when the trigger word stands alone, the run's first group is exactly an assigned calling
  /// code, and the run carries 7 to 15 digits; it then replaces the trigger word and its separator
  /// with the sign and keeps every digit and separator as written. Glued and written anchors, and
  /// every other case, refuse with the metadata's reason.
  private func fallback(
    anchor: Anchor, digits: String, firstGroup: Int, reason: LanguagePhoneMetadata.Invalid,
    snapshot: LanguageTextSnapshot
  ) -> (Decision, Int) {
    let refusal = Decision.refused(.notAValidNumber(reason))
    guard anchor.kind == .spoken,
      (Self.minFallbackDigits...Self.maxDigits).contains(digits.utf8.count)
    else { return (refusal, 0) }
    switch metadata.isAssignedCallingCode(String(digits.prefix(firstGroup))) {
    case true?: break
    case false?: return (refusal, 0)
    case nil: return (.refused(.metadataUnavailable("calling codes unavailable")), 0)
    }
    let scanner = UnitScanner(units: snapshot.units)
    var separatorEnd = anchor.marker.upperBound
    while scanner.isHorizontalWhitespace(at: separatorEnd) {
      separatorEnd += scanner.width(at: separatorEnd)
    }
    let range = anchor.marker.lowerBound..<separatorEnd
    switch snapshot.edit(replacing: range, with: rules.replacement) {
    case .success(let edit): return (.proposed(edit), range.upperBound)
    case .failure(let refusal): return (.refused(.editRefused(refusal)), 0)
    }
  }

  // MARK: Context

  /// True when a written number or a supported spoken number directly precedes the anchor chunk
  /// across horizontal whitespace only (one to three words for a spoken compound).
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

extension Array {
  fileprivate subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}

/// Reads the original UTF-16 units. Every question is about ONE position; nothing here copies or
/// normalizes the text.
private struct UnitScanner {
  let units: [UInt16]

  private static let lineBreaks: Set<UInt32> = [0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029]
  /// Punctuation that may directly follow the last digit without belonging to the number.
  private static let endingPunctuation: Set<UInt32> = Set(
    ".!?;:)]}\"'»”’“‘".unicodeScalars.map(\.value))
  /// Separators that may join two digit groups with no whitespace around them.
  private static let gluedSeparators: [UInt16: Separator] = [
    0x2E: .dot, 0x2F: .slash, 0x2D: .hyphen,
  ]

  enum Separator: Equatable {
    case space
    case comma
    case dot
    case slash
    case hyphen
  }

  enum RunScan: Equatable {
    /// The run's ASCII digits, the separators between its groups, the digit count of its first
    /// group, and its end offset.
    case run(digits: String, separators: [Separator], firstGroup: Int, end: Int)
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

  /// Scans the supported numeric run starting at an ASCII digit. The run is COMPLETE or refused as
  /// a whole: a permitted separator always continues it, glued or non-ASCII continuations are
  /// malformed, and a numeric continuation behind a line break or sentence punctuation cannot
  /// turn part of a longer run into a number.
  func scanRun(from start: Int) -> RunScan {
    guard isASCIIDigit(at: start) else { return .malformed }
    var digits = ""
    var separators: [Separator] = []
    var firstGroup = 0
    var position = start
    var end = start

    func completed() -> RunScan {
      .run(digits: digits, separators: separators, firstGroup: firstGroup, end: end)
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
      while isASCIIDigit(at: groupEnd) {
        digits.unicodeScalars.append(Unicode.Scalar(UInt8(units[groupEnd])))
        groupEnd += 1
      }
      end = groupEnd
      if firstGroup == 0 { firstGroup = groupEnd - position }
      if digits.utf8.count > LanguagePhonePrefixPass.maxDigits
        || groupEnd - start > LanguagePhonePrefixPass.maxRunUTF16
      {
        return .overLimit
      }

      guard scalar(at: groupEnd) != nil else { return completed() }

      // A dot, slash or hyphen glued between two ASCII digit groups.
      if let separator = Self.gluedSeparators[units[groupEnd]], isASCIIDigit(at: groupEnd + 1) {
        separators.append(separator)
        position = groupEnd + 1
        continue
      }

      var nextPosition = groupEnd
      while isHorizontalWhitespace(at: nextPosition) {
        nextPosition += width(at: nextPosition)
      }
      let hadHorizontalGap = nextPosition > groupEnd
      guard let following = scalar(at: nextPosition) else { return completed() }

      if following.properties.numericType == .decimal {
        // A decimal digit continues the run only when it is ASCII and a gap precedes it.
        guard hadHorizontalGap, isASCIIDigit(at: nextPosition) else { return .malformed }
        separators.append(.space)
        position = nextPosition
        continue
      }

      // A spaced slash or hyphen between groups ("030 / 1234").
      if hadHorizontalGap, let separator = Self.gluedSeparators[units[nextPosition]],
        separator != .dot
      {
        var after = nextPosition + 1
        while isHorizontalWhitespace(at: after) { after += width(at: after) }
        if isASCIIDigit(at: after) {
          separators.append(separator)
          position = after
          continue
        }
      }

      // A comma separator permits horizontal whitespace on BOTH sides.
      if following == "," {
        let commaEnd = nextPosition + 1
        var after = commaEnd
        while isHorizontalWhitespace(at: after) { after += width(at: after) }
        if isASCIIDigit(at: after) {
          separators.append(.comma)
          position = after
          continue
        }
        guard let afterComma = scalar(at: after) else { return completed() }
        if afterComma.properties.numericType == .decimal { return .malformed }
        if Self.lineBreaks.contains(afterComma.value) {
          return finishAtBoundary(from: after)
        }
        // A sentence comma may precede prose after a space; glued text is malformed.
        guard after > commaEnd, isLetter(at: after) else { return .malformed }
        return completed()
      }

      if Self.lineBreaks.contains(following.value) {
        return finishAtBoundary(from: nextPosition)
      }

      if hadHorizontalGap {
        // Prose follows the run; sentence punctuation after a gap is not part of the number.
        return completed()
      }

      if Self.endingPunctuation.contains(following.value) {
        var after = nextPosition
        while let punctuation = scalar(at: after),
          Self.endingPunctuation.contains(punctuation.value) || punctuation == ","
        {
          after += width(at: after)
        }
        guard let afterPunctuation = scalar(at: after) else { return completed() }
        guard afterPunctuation.properties.isWhitespace else { return .malformed }
        return finishAtBoundary(from: after)
      }
      return .malformed
    }
  }
}
