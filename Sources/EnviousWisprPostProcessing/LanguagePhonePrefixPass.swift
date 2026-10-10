import Foundation

// MARK: - The international phone pass (#1677)
//
// ONE pure pass. It finds an EXPLICITLY international telephone number, validates its digits
// against numbering metadata (`LanguagePhoneMetadata`), and rewrites the whole number in the
// metadata's international grouping. Every digit is kept, in order: the edit is minted by
// `edit(regroupingDigitsIn:with:)`, so the snapshot and the shared editor both refuse any edit
// whose replacement changes a digit. The pass proposes edits against one immutable snapshot; the
// shared editor applies them. The German language route runs it (`InverseTextNormalizer+Language`).
//
// CANDIDATES (the only two ways a number is explicitly international):
//  1. spoken: a standalone trigger word (German `plus`), then horizontal whitespace and a digit
//     run, OR the trigger word glued to the run in one chunk (`plus46319876543`, an engine shape);
//  2. written: a plus sign glued to a digit run whose groups use a separator other than spaces
//     (`+81/3/4567/8901`, `+43.664.9081122`, `+32-2-601`). A written number grouped only by
//     spaces, or not at all, is already well formed and is never touched.
//  3. unsigned (founder direction 2026-10-06, "phone number by default"): a run with no sign that
//     STARTS with an assigned calling code (`49 176 9087654`, an engine that dropped the spoken
//     plus) is read as international; a run that starts with a trunk zero (`030 86 0800`) is read
//     as a domestic number of the caller's home region, when the caller names one. Unsigned runs
//     need 8 to 15 digits; international ones also need two or more groups. They are refused only
//     when the number belongs to something else (see UNSIGNED GATES). A run starting with `00`,
//     and every other unsigned run, is not a candidate.
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
// UNSIGNED GATES (word classes from `LanguagePhonePrefixRules.Unsigned`, logic shared):
//  - a number, sign or trigger word directly before the run, or a unit or currency after it;
//  - ATTACHED: the nearest word before the run (skipping linker words such as "ist") is a value
//    verb ("kostet") or a capitalised noun that is not a phone word ("Projekt", "Rechnung"),
//    unless it is the possessor of a phone word ("Nummer der Praxis"); a bare "Nummer" right
//    after such a noun ("Projekt Nummer") but not after a possessive name ("Lisas Nummer"); or a
//    capitalised noun right after the run ("358 ... Besucher");
//  - a number-field word ("Kundennummer") anywhere in the sentence;
//  - international reading only: an explicit local or national qualifier in the sentence.
// Policy (declared inference, not proof): a calling-code first group is read as international;
// a local or prefix-omitted national number can be misread. No digit is ever added or removed.
// A domestic number already written in its region's grouping is left as it is.
//
// LIMITS: validity is a documented numbering range, not a reachable subscriber. Digits the
// engine misheard stay misheard; the pass can only refuse them when they form no valid number.

struct LanguagePhonePrefixPass: Sendable {

  /// The language's number grammar, for spoken operands before a trigger ("sieben plus ...");
  /// nil for a language without generated number data (written operands are still refused).
  let grammar: LanguageNumberGrammar?
  let rules: LanguagePhonePrefixRules
  let metadata: LanguagePhoneMetadata

  init(
    grammar: LanguageNumberGrammar?, rules: LanguagePhonePrefixRules,
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
    /// The metadata rejects the digits and they are grouped in thousands (`1.000.000`,
    /// `2 500 000`): an amount, so the sign-only fallback does not apply.
    case thousandsGroupedAmount
    /// The metadata could not be loaded; no number is validated.
    case metadataUnavailable(String)
    /// Unsigned: the number belongs to another field, a label, a quantity or an amount.
    case attachedToAnotherField
    /// Unsigned international reading: the sentence names the number local or national.
    case localOrNationalQualifier
    case editRefused(LanguageEditRefusal)
  }

  enum Decision: Sendable, Equatable {
    case proposed(LanguageTextEdit)
    case refused(Refusal)
  }

  struct Candidate: Sendable, Equatable {
    /// The trigger word's (or the plus sign's) UTF-16 range in the original text; for an unsigned
    /// run, its first digit.
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

  /// `homeRegion` (ISO 3166, e.g. "DE") enables domestic numbers for that region only; nil leaves
  /// every trunk-prefixed number as written.
  func propose(in snapshot: LanguageTextSnapshot, homeRegion: String? = nil) -> Outcome {
    for shape in LanguagePhonePrefixRules.Shape.allCases where rules.refusal(for: shape) == nil {
      return .unavailable("reviewed shape \(shape.rawValue) is missing")
    }
    guard !rules.triggers.isEmpty, !rules.replacement.isEmpty else {
      return .unavailable("no trigger or replacement")
    }
    let chunks = LanguageProtectedSpans.chunks(of: snapshot.text)
    let parser = grammar.map { LanguageNumberParser(grammar: $0) }
    var edits: [LanguageTextEdit] = []
    var candidates: [Candidate] = []
    var truncated = false
    var consumedUpTo = 0
    let words = Self.words(of: chunks, snapshot: snapshot)
    for index in chunks.indices where chunks[index].range.lowerBound >= consumedUpTo {
      guard let anchor = anchor(in: chunks[index], snapshot: snapshot) else {
        if let (marker, decision, end) = decideUnsigned(
          chunkIndex: index, chunks: chunks, words: words, snapshot: snapshot, parser: parser,
          homeRegion: homeRegion)
        {
          if case .proposed(let edit) = decision {
            edits.append(edit)
            consumedUpTo = end
          }
          if candidates.count < Run.diagnosticLimit {
            candidates.append(Candidate(trigger: marker, decision: decision))
          } else {
            truncated = true
          }
        }
        continue
      }
      let (decision, end) = decide(
        anchor: anchor, chunkIndex: index, chunks: chunks, snapshot: snapshot,
        parser: parser)
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

  // MARK: Unsigned numbers

  /// One chunk reduced to its word, for the unsigned gates: the text without opening or closing
  /// punctuation, its fold, whether it is capitalised, and whether a sentence ends after it.
  private struct Word {
    let core: String
    let folded: String
    let capitalised: Bool
    let endsSentence: Bool
  }

  private static let closingPunctuation = CharacterSet(charactersIn: ".,;:!?)]}\"'»”’“‘")
  private static let sentenceEnders: Set<Character> = [".", "!", "?", ";"]

  private static func words(
    of chunks: [LanguageProtectedSpans.Chunk], snapshot: LanguageTextSnapshot
  ) -> [Word] {
    chunks.map { chunk in
      var scalars = Array(chunk.text.unicodeScalars)
      while let first = scalars.first, openingPunctuation.contains(first) { scalars.removeFirst() }
      var trailing = ""
      while let last = scalars.last, closingPunctuation.contains(last) {
        trailing.unicodeScalars.insert(last, at: trailing.unicodeScalars.startIndex)
        scalars.removeLast()
      }
      var view = String.UnicodeScalarView()
      view.append(contentsOf: scalars)
      let core = String(view)
      return Word(
        core: core, folded: LanguageNumberGrammar.fold(core),
        capitalised: core.first?.isUppercase ?? false,
        endsSentence: trailing.contains(where: { sentenceEnders.contains($0) })
          || !chunk.gapAfterIsHorizontal)
    }
  }

  /// The decision for an unsigned run starting in this chunk, its first digit, and the edit end;
  /// nil when the chunk does not start a structurally possible unsigned number.
  private func decideUnsigned(
    chunkIndex: Int, chunks: [LanguageProtectedSpans.Chunk], words: [Word],
    snapshot: LanguageTextSnapshot, parser: LanguageNumberParser?, homeRegion: String?
  ) -> (Range<Int>, Decision, Int)? {
    // A language without unsigned word classes runs the signed path only.
    guard let classes = rules.unsigned else { return nil }
    let units = snapshot.units
    let scanner = UnitScanner(units: units)
    let chunk = chunks[chunkIndex]
    var runStart = chunk.range.lowerBound
    while runStart < chunk.range.upperBound, let scalar = scanner.scalar(at: runStart),
      Self.openingPunctuation.contains(scalar)
    {
      runStart += scanner.width(at: runStart)
    }
    guard scanner.isASCIIDigit(at: runStart) else { return nil }
    // Inside a longer run, or right after a sign or trigger word: not an unsigned start.
    if chunkIndex > 0, !words[chunkIndex - 1].endsSentence {
      let previous = chunks[chunkIndex - 1]
      if let last = scanner.scalar(at: previous.range.upperBound - 1),
        last.properties.numericType != nil || "+-−".unicodeScalars.contains(last)
      {
        return nil
      }
      if rules.triggers.contains(words[chunkIndex - 1].folded) { return nil }
    }
    guard
      case .run(let digits, let separators, let firstGroup, let runEnd) = scanner.scanRun(
        from: runStart),
      (8...Self.maxDigits).contains(digits.utf8.count), !digits.hasPrefix("00")
    else { return nil }
    // Dates and other dotted numbers are never unsigned telephone numbers: a dot separator, or
    // three groups shaped like a day, a month and a year ("05.05.2024", "05-05-2024").
    if separators.contains(.dot) { return nil }
    if let written = snapshot.substring(runStart..<runEnd) {
      let groups = written.split(whereSeparator: { !$0.isASCII || !$0.isNumber }).map(\.count)
      if groups.count == 3, groups[0] <= 2, groups[1] <= 2, groups[2] == 2 || groups[2] == 4 {
        return nil
      }
    }
    let marker = runStart..<(runStart + 1)
    let domestic = digits.hasPrefix("0")

    let formatted: String
    if domestic {
      guard let homeRegion else { return nil }
      switch metadata.national(digits: digits, region: homeRegion) {
      case .valid(let national): formatted = national
      case .invalid: return nil
      case .unavailable(let reason): return (marker, .refused(.metadataUnavailable(reason)), 0)
      }
      // Already written in the region's grouping: nothing to do.
      if snapshot.substring(runStart..<runEnd) == formatted { return nil }
    } else {
      guard !separators.isEmpty else { return nil }
      switch metadata.international(digits: digits) {
      case .valid(let number) where number.countryCode == String(digits.prefix(firstGroup)):
        formatted = number.formatted
      case .unavailable(let reason): return (marker, .refused(.metadataUnavailable(reason)), 0)
      default: return nil
      }
    }

    if numberPrecedes(chunkIndex: chunkIndex, chunks: chunks, snapshot: snapshot, parser: parser) {
      return (marker, .refused(.arithmeticOperandBefore), 0)
    }
    switch unitTail(after: runEnd, chunks: chunks, scanner: scanner) {
    case .temperatureOrPercent: return (marker, .refused(.temperatureOrPercentTail), 0)
    case .otherUnitOrCurrency: return (marker, .refused(.measurementOrCurrencyTail), 0)
    case .none: break
    }
    guard
      let lastIndex = chunks.firstIndex(where: {
        $0.range.lowerBound < runEnd && runEnd <= $0.range.upperBound
      })
    else { return (marker, .refused(.malformedContinuation), 0) }
    let sentence = sentenceWords(around: chunkIndex, through: lastIndex, words: words)
    if attached(before: sentence.before, after: sentence.after, classes: classes)
      || sentence.all.contains(where: { isNumberField($0, classes: classes) })
    {
      return (marker, .refused(.attachedToAnotherField), 0)
    }
    if !domestic, sentence.all.contains(where: { classes.localQualifiers.contains($0.folded) }) {
      return (marker, .refused(.localOrNationalQualifier), 0)
    }

    guard let leading = snapshot.substring(chunk.range.lowerBound..<runStart),
      let trailing = snapshot.substring(runEnd..<chunks[lastIndex].range.upperBound)
    else { return (marker, .refused(.malformedContinuation), 0) }
    let range = chunk.range.lowerBound..<chunks[lastIndex].range.upperBound
    switch snapshot.edit(regroupingDigitsIn: range, with: leading + formatted + trailing) {
    case .success(let edit): return (marker, .proposed(edit), range.upperBound)
    case .failure(let refusal): return (marker, .refused(.editRefused(refusal)), 0)
    }
  }

  /// The sentence's words before the run (nearest first) and after it (nearest first), and all.
  private func sentenceWords(around first: Int, through last: Int, words: [Word])
    -> (before: [Word], after: [Word], all: [Word])
  {
    var before: [Word] = []
    var index = first - 1
    while index >= 0, !words[index].endsSentence {
      if !words[index].core.isEmpty { before.append(words[index]) }
      index -= 1
    }
    var after: [Word] = []
    if !words[last].endsSentence {
      index = last + 1
      while index < words.count {
        if !words[index].core.isEmpty { after.append(words[index]) }
        if words[index].endsSentence { break }
        index += 1
      }
    }
    return (before, after, before + after)
  }

  private func isNoun(_ word: Word, classes: LanguagePhonePrefixRules.Unsigned) -> Bool {
    return word.capitalised && word.core.first?.isLetter == true
      && !classes.phoneWords.contains(word.folded) && !classes.nonNounWords.contains(word.folded)
  }

  private func isNumberField(_ word: Word, classes: LanguagePhonePrefixRules.Unsigned) -> Bool {
    return !classes.phoneWords.contains(word.folded)
      && classes.fieldSuffixes.contains(where: { word.folded.hasSuffix($0) && word.folded != $0 })
  }

  /// The number belongs to a label, a quantity or an amount (see UNSIGNED GATES).
  private func attached(
    before: [Word], after: [Word], classes: LanguagePhonePrefixRules.Unsigned
  ) -> Bool {
    var i = 0
    while i < before.count, classes.linkersBefore.contains(before[i].folded) { i += 1 }
    if i < before.count {
      let word = before[i]
      if classes.valueVerbs.contains(word.folded) { return true }
      let bareFieldWord = classes.fieldSuffixes.contains(word.folded)
      if bareFieldWord, i + 1 < before.count, isNoun(before[i + 1], classes: classes),
        !before[i + 1].folded.hasSuffix(classes.possessiveSuffix)
      {
        return true
      }
      if isNoun(word, classes: classes) {
        let possessorOfPhoneWord =
          i + 2 < before.count && classes.possessorArticles.contains(before[i + 1].folded)
          && classes.phoneWords.contains(before[i + 2].folded)
        if !possessorOfPhoneWord { return true }
      }
    }
    if let next = after.first, isNoun(next, classes: classes) { return true }
    return false
  }

  // MARK: Decision

  /// The decision for one anchor, and the UTF-16 offset the proposed edit ends at (0 when refused).
  private func decide(
    anchor: Anchor, chunkIndex: Int, chunks: [LanguageProtectedSpans.Chunk],
    snapshot: LanguageTextSnapshot, parser: LanguageNumberParser?
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
    // A standalone spoken trigger may carry an engine's period after the calling code
    // ("plus 44. 0, 1, 2 ..."); no other anchor and no later group gets that boundary.
    let dotAfterCallingCode: ((String) -> Bool)? =
      anchor.kind == .spoken ? { self.metadata.isAssignedCallingCode($0) == true } : nil
    let scan =
      startsWithDigit
      ? scanner.scanRun(from: runStart, dotAfterFirstGroup: dotAfterCallingCode) : nil
    var tail = UnitTail.none
    if case .run(_, _, _, let runEnd)? = scan {
      tail = unitTail(after: runEnd, chunks: chunks, scanner: scanner)
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
      if Self.isThousandsGrouped(snapshot.substring(runStart..<runEnd)) {
        return (.refused(.thousandsGroupedAmount), 0)
      }
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

  /// True when a run is written as a thousands-grouped amount: one to three digits, then two or
  /// more groups of exactly three (`1.000.000`, `2 500 000`, `12,345,678`). Numbers dictated as
  /// telephone numbers are grouped by the engine in pairs or calling-code-first and carry a
  /// shorter or longer group; an invalid number in this shape is a quantity or a price.
  static func isThousandsGrouped(_ run: String?) -> Bool {
    guard let run else { return false }
    let groups = run.split(whereSeparator: { !("0"..."9").contains($0) }).map(\.count)
    guard groups.count >= 3, let first = groups.first, (1...3).contains(first) else {
      return false
    }
    return groups.dropFirst().allSatisfy { $0 == 3 }
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
    parser: LanguageNumberParser?
  ) -> Bool {
    guard chunkIndex > 0, chunks[chunkIndex - 1].gapAfterIsHorizontal else { return false }
    if chunks[chunkIndex - 1].hasDecimalDigit { return true }
    guard let parser else { return false }
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

  /// What the first word after the digit run (across horizontal whitespace and closing marks) is,
  /// read from the protection file's unit and currency authority, which also says whether it is a
  /// temperature or percentage. No unit word is listed here.
  private func unitTail(
    after runEnd: Int, chunks: [LanguageProtectedSpans.Chunk], scanner: UnitScanner
  ) -> UnitTail {
    // The chunk that holds the run's last digit, closing punctuation included, so a bracket or a
    // sentence mark cannot hide the unit behind it.
    guard
      let numericChunk = chunks.first(where: {
        $0.range.lowerBound < runEnd && runEnd <= $0.range.upperBound
      })
    else { return .none }
    // A separate closing mark (`) Euro`) hides the unit from protection's neighbour check, so the
    // word itself is asked of protection's unit and currency authority.
    var cursor = numericChunk.range.upperBound
    while cursor < scanner.units.count,
      scanner.isHorizontalWhitespace(at: cursor) || scanner.isEndingPunctuation(at: cursor)
    {
      cursor += scanner.width(at: cursor)
    }
    guard cursor < scanner.units.count,
      let chunk = chunks.first(where: { $0.range.lowerBound == cursor }),
      LanguageProtectedSpans.isMeasurementOrCurrencyUnit(chunk.text)
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

  func isEndingPunctuation(at index: Int) -> Bool {
    guard let value = scalar(at: index) else { return false }
    return Self.endingPunctuation.contains(value.value)
  }

  func isLetter(at index: Int) -> Bool {
    scalar(at: index)?.properties.isAlphabetic ?? false
  }

  /// Scans the supported numeric run starting at an ASCII digit. The run is COMPLETE or refused as
  /// a whole: a permitted separator always continues it, glued or non-ASCII continuations are
  /// malformed, and a numeric continuation behind a line break or sentence punctuation cannot
  /// turn part of a longer run into a number.
  func scanRun(from start: Int, dotAfterFirstGroup: ((String) -> Bool)? = nil) -> RunScan {
    guard isASCIIDigit(at: start) else { return .malformed }
    var digits = ""
    var separators: [Separator] = []
    var firstGroup = 0
    var position = start
    var end = start

    func completed() -> RunScan {
      .run(digits: digits, separators: separators, firstGroup: firstGroup, end: end)
    }

    // The run ends here only if the next letter-or-number after whitespace and punctuation is not
    // a number: `9087654 . 99`, `9087654 ) 99` and `9087654 /` + line break + `99` hide a
    // continuation and refuse the whole candidate.
    func finishAtBoundary(from boundary: Int) -> RunScan {
      var cursor = boundary
      while let value = scalar(at: cursor), !value.properties.isAlphabetic,
        value.properties.numericType == nil
      {
        cursor += width(at: cursor)
      }
      if scalar(at: cursor)?.properties.numericType != nil {
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

      // The first group only: a period, horizontal whitespace and an ASCII digit continue the run
      // when the caller says the group is exactly an assigned calling code.
      if separators.isEmpty, let dotAfterFirstGroup, units[groupEnd] == 0x2E {
        var after = groupEnd + 1
        while isHorizontalWhitespace(at: after) { after += width(at: after) }
        if after > groupEnd + 1, isASCIIDigit(at: after), dotAfterFirstGroup(digits) {
          separators.append(.dot)
          position = after
          continue
        }
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
        // Prose or spaced punctuation follows the run; a number behind that punctuation refuses.
        return finishAtBoundary(from: nextPosition)
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
