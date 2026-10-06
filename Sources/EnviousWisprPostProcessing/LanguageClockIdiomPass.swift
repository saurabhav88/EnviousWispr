import Foundation

// MARK: - The clock-idiom pass (#1677, PR 2 chunk 6)
//
// ONE pure pass: where an anchored spoken clock idiom (German `um halb sieben`, `gegen viertel nach
// vier`) stands, propose an edit that replaces ONLY the idiom span with its written time (`6:30`,
// `4:15`): unpadded hour, a separator, two-digit minutes. The anchor, `Uhr`, day-part words,
// articles and punctuation stay as written. An hour the engine already wrote as digits (`um halb 8`)
// is an already-written number chunk: that edit runs to the end of the chunk through the editor's
// digit-hour permission and carries the chunk's closing punctuation (`halb 8.` to `7:30.`). The pass proposes edits against one immutable snapshot;
// the shared editor applies them. Nothing registers or calls this pass yet.
//
// SCOPE (founder option B): only the templates in the rules convert (`halb H` and `viertel nach H`
// for German). Regional forms (`viertel vor H`, bare `viertel H`, `dreiviertel H`) are neither
// converted nor refused: they are simply not candidates. No AM/PM or 24-hour inference ever happens:
// the written time is the idiom's own hour and minutes.
//
// ADMISSION (all must hold, otherwise no edit and a named refusal):
//  1. a complete template token sequence followed by ONE complete hour word that the shared parser
//     reads as a clock hour (1 to 12, spelled or as one or two ASCII digits); `halb so`, `halb`
//     alone, `halb 8:30`, `halb 20`, `um sieben am Abend` and unsupported forms are not candidates;
//  2. the idiom span fits 128 UTF-16 units and 8 tokens (whitespace counts);
//  3. an immediately preceding whole anchor word, across horizontal whitespace, with no punctuation
//     between: a CONSERVATIVE scope restriction, not proof that every phrase after an anchor is a
//     clock time;
//  4. the hour is inside the template's input range: the hours that need a clock-face choice
//     (`halb eins`, `viertel nach zwölf`) are a STRUCTURAL exclusion (`ambiguousClockFace`), named
//     distinctly and NOT the execution of the pending noon/midnight refusal entry;
//  5. no number material continues right after the hour word (a connector, a spoken number or
//     digits), whatever stands between: a failed longer numeric expression is not a clock time;
//  6. no competing unit or currency follows the hour chunk (the clock marker `Uhr` is the one
//     allowed neighbour).
// REVIEWED LITERAL REFUSALS (duration, fraction, `halb voll`/`halb leer`) are matched first, as
// complete token sequences, and consume their words; a refusal elsewhere never suppresses an
// independent valid candidate.
//
// An anchor glued to `halb` by the engine ("bishalb sechs") is read as the anchor and the template
// when the whole word is exactly an approved anchor plus the template's first word; the anchor
// keeps its bytes and the written time gets a space ("bis 5:30").
//
// Not a general time parser: no spoken minutes, no 24-hour digits, no restyling of written times.

struct LanguageClockIdiomPass: Sendable {

  let grammar: LanguageNumberGrammar
  let rules: LanguageClockIdiomRules

  init(grammar: LanguageNumberGrammar, rules: LanguageClockIdiomRules) {
    self.grammar = grammar
    self.rules = rules
  }

  enum Refusal: Sendable, Equatable {
    /// A reviewed literal phrase (duration, fraction, non-clock) matched; `entry` is its id.
    case literalPhrase(entry: String)
    /// No whole anchor word directly before the idiom.
    case noAnchor
    /// The hour needs a noon/midnight choice the written form cannot make.
    case ambiguousClockFace
    case exceedsLimit
    /// Number material follows the hour word: part of a longer numeric expression.
    case numberContinuationAfter
    /// A unit or currency other than the clock marker follows: a quantity or a price.
    case measurementOrCurrencyTail
    case editRefused(LanguageEditRefusal)
  }

  enum Disposition: Sendable, Equatable {
    case proposed(LanguageTextEdit)
    case refused(Refusal)
  }

  struct Candidate: Sendable, Equatable {
    /// The idiom's UTF-16 range in the original text (words only, no punctuation).
    let range: Range<Int>
    /// The hour word's value for a template candidate; nil for a literal phrase.
    let hour: Int?
    let disposition: Disposition
  }

  struct Run: Sendable, Equatable {
    let edits: [LanguageTextEdit]
    let candidates: [Candidate]
    let candidatesTruncated: Bool

    static let diagnosticLimit = 64
  }

  enum Outcome: Sendable, Equatable {
    case ran(Run)
    /// The rules cannot be interpreted safely: no pass ran and nothing was proposed.
    case unavailable(String)
  }

  static let maxSpanUTF16 = 128
  static let maxTokens = 8

  // MARK: Entry

  func propose(in snapshot: LanguageTextSnapshot) -> Outcome {
    guard !rules.templates.isEmpty, !rules.anchors.isEmpty, !rules.refusals.isEmpty,
      !rules.trailingMarker.isEmpty
    else { return .unavailable("incomplete clock-idiom rules") }
    for kind in LanguageClockIdiomRules.RefusalKind.allCases {
      switch kind.enforcement {
      case .completeLiteralPhraseMatch:
        guard rules.refusals.contains(where: { $0.kind == kind }) else {
          return .unavailable("no reviewed literal-phrase entry")
        }
      }
    }
    let words = Self.words(of: LanguageProtectedSpans.chunks(of: snapshot.text))
    let parser = LanguageNumberParser(grammar: grammar)
    let phrases = rules.phrases.sorted { $0.phrase.count > $1.phrase.count }
    let templates = rules.templates.sorted { $0.tokens.count > $1.tokens.count }

    var edits: [LanguageTextEdit] = []
    var candidates: [Candidate] = []
    var truncated = false
    var index = 0
    while index < words.count {
      var consumed = 0
      var candidate: Candidate?

      if let match = phrases.first(where: { matches(phrase: $0.phrase, at: index, in: words) }) {
        consumed = match.phrase.count
        candidate = Candidate(
          range: words[index].start..<words[index + consumed - 1].end, hour: nil,
          disposition: .refused(.literalPhrase(entry: match.entry)))
      } else {
        // An engine may glue the anchor to the template's first word ("bishalb sechs"): an exact
        // whole word equal to an approved anchor plus that word, read from the rules' own anchors.
        for template in templates where candidate == nil {
          guard let split = gluedAnchorSplit(words[index], firstToken: template.tokens[0]) else {
            continue
          }
          let width = template.tokens.count + 1
          guard windowIsContiguous(words, from: index, width: width),
            matches(phrase: Array(template.tokens.dropFirst()), at: index + 1, in: words)
              || template.tokens.count == 1
          else { continue }
          let hourWord = words[index + width - 1]
          guard
            case .parsed(let number) = parser.parse(
              .clockHour, in: snapshot, range: hourWord.start..<hourWord.end)
          else { continue }
          consumed = width
          candidate = decide(
            template: template, hour: number.value, first: index, hourIndex: index + width - 1,
            words: words, snapshot: snapshot, gluedAnchorUTF16: split)
        }
        for template in templates where candidate == nil {
          let width = template.tokens.count + 1
          guard windowIsContiguous(words, from: index, width: width),
            matches(phrase: template.tokens, at: index, in: words)
          else { continue }
          let hourWord = words[index + width - 1]
          let hourRange = hourWord.start..<hourWord.end
          guard case .parsed(let number) = parser.parse(.clockHour, in: snapshot, range: hourRange)
          else { continue }
          consumed = width
          candidate = decide(
            template: template, hour: number.value, first: index, hourIndex: index + width - 1,
            words: words, snapshot: snapshot)
          break
        }
      }

      guard let found = candidate, consumed > 0 else {
        index += 1
        continue
      }
      if case .proposed(let edit) = found.disposition { edits.append(edit) }
      if candidates.count < Run.diagnosticLimit {
        candidates.append(found)
      } else {
        truncated = true
      }
      index += consumed
    }
    return .ran(Run(edits: edits, candidates: candidates, candidatesTruncated: truncated))
  }

  // MARK: Words

  /// One chunk reduced to its word: the range and text without opening or closing punctuation.
  private struct Word {
    let start: Int
    let end: Int
    let text: String
    let folded: String
    let hasLeadingPunctuation: Bool
    let hasTrailingPunctuation: Bool
    let gapAfterIsHorizontal: Bool
    let chunkText: String
    /// The end of the whole chunk, closing punctuation included.
    let chunkEnd: Int
  }

  private static let openingPunctuation = CharacterSet(charactersIn: "([{\"'«„“‘")
  private static let closingPunctuation = CharacterSet(charactersIn: ".,;:!?)]}\"'»”’“‘")

  private static func words(of chunks: [LanguageProtectedSpans.Chunk]) -> [Word] {
    chunks.map { chunk in
      var scalars = Array(chunk.text.unicodeScalars)
      var lead = 0
      var trail = 0
      while let first = scalars.first, openingPunctuation.contains(first) {
        lead += first.value > 0xFFFF ? 2 : 1
        scalars.removeFirst()
      }
      while let last = scalars.last, closingPunctuation.contains(last) {
        trail += last.value > 0xFFFF ? 2 : 1
        scalars.removeLast()
      }
      var view = String.UnicodeScalarView()
      view.append(contentsOf: scalars)
      let text = String(view)
      return Word(
        start: chunk.range.lowerBound + lead, end: chunk.range.upperBound - trail, text: text,
        folded: LanguageNumberGrammar.fold(text), hasLeadingPunctuation: lead > 0,
        hasTrailingPunctuation: trail > 0, gapAfterIsHorizontal: chunk.gapAfterIsHorizontal,
        chunkText: chunk.text, chunkEnd: chunk.range.upperBound)
    }
  }

  /// Consecutive words joined by horizontal whitespace only, with punctuation only at the outer
  /// edges of the window.
  private func windowIsContiguous(_ words: [Word], from first: Int, width: Int) -> Bool {
    guard width > 0, first + width <= words.count else { return false }
    for offset in 0..<width {
      let word = words[first + offset]
      if word.text.isEmpty { return false }
      if offset > 0, word.hasLeadingPunctuation { return false }
      if offset < width - 1, word.hasTrailingPunctuation || !word.gapAfterIsHorizontal {
        return false
      }
    }
    return true
  }

  /// The UTF-16 length of the anchor inside a glued word ("bis" in "bishalb", "für" in an NFD
  /// "fu\u{308}rhalb"), when the whole word is exactly an approved anchor followed by `firstToken`;
  /// otherwise nil. Splits only at character boundaries of the original text.
  private func gluedAnchorSplit(_ word: Word, firstToken: String) -> Int? {
    guard !word.hasLeadingPunctuation, word.folded.hasSuffix(firstToken),
      word.folded.count > firstToken.count
    else { return nil }
    var prefix = ""
    var utf16 = 0
    for character in word.text {
      prefix.append(character)
      utf16 += character.utf16.count
      let folded = LanguageNumberGrammar.fold(prefix)
      guard rules.anchors.contains(folded) else { continue }
      let rest = String(decoding: Array(word.text.utf16.dropFirst(utf16)), as: UTF16.self)
      if LanguageNumberGrammar.fold(rest) == firstToken { return utf16 }
    }
    return nil
  }

  private func matches(phrase: [String], at index: Int, in words: [Word]) -> Bool {
    guard windowIsContiguous(words, from: index, width: phrase.count) else { return false }
    for (offset, token) in phrase.enumerated() where words[index + offset].folded != token {
      return false
    }
    return true
  }

  // MARK: Decision

  private func decide(
    template: LanguageClockIdiomRules.Template, hour: Int, first: Int, hourIndex: Int,
    words: [Word], snapshot: LanguageTextSnapshot, gluedAnchorUTF16: Int? = nil
  ) -> Candidate {
    // A glued anchor keeps its own bytes: the idiom starts after it, and the written time gets the
    // space the engine left out.
    let idiomStart = words[first].start + (gluedAnchorUTF16 ?? 0)
    let space = gluedAnchorUTF16 == nil ? "" : " "
    let range = idiomStart..<words[hourIndex].end
    func refuse(_ refusal: Refusal) -> Candidate {
      Candidate(range: range, hour: hour, disposition: .refused(refusal))
    }

    if hourIndex - first + 1 > Self.maxTokens || range.count > Self.maxSpanUTF16 {
      return refuse(.exceedsLimit)
    }
    guard gluedAnchorUTF16 != nil || hasAnchor(before: first, words: words) else {
      return refuse(.noAnchor)
    }
    guard template.inputHours.contains(hour) else { return refuse(.ambiguousClockFace) }
    if hasNumberContinuation(after: hourIndex, words: words, snapshot: snapshot) {
      return refuse(.numberContinuationAfter)
    }
    if hasCompetingUnit(after: hourIndex, words: words) {
      return refuse(.measurementOrCurrencyTail)
    }
    let minutes = template.minute < 10 ? "0\(template.minute)" : "\(template.minute)"
    let written = "\(hour + template.hourOffset)\(rules.outputSeparator)\(minutes)"
    let hourWord = words[hourIndex]
    let minted: Result<LanguageTextEdit, LanguageEditRefusal>
    if hourWord.chunkText.unicodeScalars.contains(where: { $0.properties.numericType != nil }) {
      // A digit hour is a protected number chunk: replace the whole chunk, punctuation carried.
      let chunk = hourWord.start..<hourWord.chunkEnd
      let closing = snapshot.substring(hourWord.end..<hourWord.chunkEnd) ?? ""
      minted = snapshot.edit(
        replacing: idiomStart..<hourWord.chunkEnd, consumingDigitHourChunk: chunk,
        with: space + written + closing)
    } else {
      minted = snapshot.edit(replacing: range, with: space + written)
    }
    switch minted {
    case .success(let edit):
      return Candidate(range: range, hour: hour, disposition: .proposed(edit))
    case .failure(let refusal): return refuse(.editRefused(refusal))
    }
  }

  /// A whole anchor word directly before the idiom, across horizontal whitespace, with no
  /// punctuation on the anchor and none before the idiom.
  private func hasAnchor(before first: Int, words: [Word]) -> Bool {
    guard first > 0, !words[first].hasLeadingPunctuation else { return false }
    let anchor = words[first - 1]
    return !anchor.hasTrailingPunctuation && anchor.gapAfterIsHorizontal
      && rules.anchors.contains(anchor.folded)
  }

  /// Read past standalone punctuation and the permitted clock marker. Keeps whether every
  /// intervening gap was horizontal, for the unit check.
  private func followingTail(after hourIndex: Int, words: [Word]) -> (index: Int, horizontal: Bool)? {
    var index = hourIndex + 1
    var horizontal = words[hourIndex].gapAfterIsHorizontal
    while index < words.count {
      let word = words[index]
      let punctuationOnly =
        !word.chunkText.isEmpty
        && word.chunkText.unicodeScalars.allSatisfy {
          switch $0.properties.generalCategory {
          case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
            .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return true
          default:
            return false
          }
        }
      if punctuationOnly || word.folded == rules.trailingMarker {
        horizontal = horizontal && word.gapAfterIsHorizontal
        index += 1
        continue
      }
      return (index, horizontal)
    }
    return nil
  }

  /// Number material after the hour word, past punctuation and the clock marker: a digit, a
  /// connector, a spoken number, an ordinal spelling, a licensed compound prefix, or an article
  /// that begins a complete licensed compound. Line breaks do not hide it.
  private func hasNumberContinuation(
    after hourIndex: Int, words: [Word], snapshot: LanguageTextSnapshot
  ) -> Bool {
    guard let tail = followingTail(after: hourIndex, words: words) else { return false }
    let index = tail.index
    let next = words[index]
    if next.chunkText.unicodeScalars.contains(where: { $0.properties.numericType == .decimal }) {
      return true
    }

    let key = next.folded
    if grammar.nonStandalone.contains(key) {
      // An article alone is not number evidence. A complete licensed compound beginning with it
      // is, and a connector must not hide one.
      let parser = LanguageNumberParser(grammar: grammar)
      for width in stride(from: min(3, words.count - index), through: 2, by: -1) {
        guard windowIsContiguous(words, from: index, width: width) else { continue }
        let range = words[index].start..<words[index + width - 1].end
        if case .parsed = parser.parse(.cardinal, in: snapshot, range: range) { return true }
        if case .parsed = parser.parse(.ordinal, in: snapshot, range: range) { return true }
      }
      if index + 1 < words.count, words[index + 1].folded == grammar.connector { return true }
      return false
    }

    if key == grammar.connector || grammar.standalone[key] != nil
      || grammar.compoundUnits[key] != nil || grammar.tens[key] != nil
      || grammar.ordinalForms[key] != nil
    {
      return true
    }
    // Licensed compound prefixes, read from the grammar's own joints.
    for (spelling, form) in grammar.ordinalForms {
      let scalars = Array(spelling.unicodeScalars)
      for joint in form.joints {
        var prefix = String.UnicodeScalarView()
        prefix.append(contentsOf: scalars.prefix(joint))
        if String(prefix) == key { return true }
      }
    }
    return false
  }

  /// A unit or currency other than the clock marker after the hour chunk, past standalone
  /// punctuation and the marker, across horizontal whitespace only.
  private func hasCompetingUnit(after hourIndex: Int, words: [Word]) -> Bool {
    guard let tail = followingTail(after: hourIndex, words: words), tail.horizontal else {
      return false
    }
    return LanguageProtectedSpans.isMeasurementOrCurrencyUnit(words[tail.index].chunkText)
  }
}
