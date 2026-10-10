import Foundation

// MARK: - The hour-first clock pass (#1677)
//
// ONE pure pass for the languages that say the hour first (French, Spanish, Italian, Portuguese):
// where an anchored clock idiom stands, propose an edit that replaces ONLY the idiom with its
// written time. Spanish and Italian write `8:15`, French and Portuguese `8h15` (what the engines
// already write themselves for these languages). The anchor and every byte outside the idiom stay.
//
// FORMS (all words from the generated `HourFirstClockData`):
//  - H connector FRACTION       es `a las 8 y cuarto` -> `a las 8:15`, it `alle 7 e mezza`
//  - H minus FRACTION           es `a las 9 menos cuarto` -> `a las 8:45`, fr `à 8h moins le quart`
//  - H minus MM (digits 1-30)   es `a las 10 menos 20` -> `a las 9:40`
//  - MINUTES before ART H       es `a un cuarto para las 8` -> `a 7:45`, pt `às 20 para as 4`
// H is a written hour (1-23 digits; French also `8h`), a spelled hour 1-12, or a noon or midnight
// word. French requires its hour marker (`8h`, `8 heures`, `sept heures`).
//
// ADMISSION (all must hold, otherwise the text stays as written):
//  1. an anchor phrase directly before the hour (or, for MINUTES before H, before the minutes),
//     across horizontal whitespace, no punctuation inside the idiom or between anchor and idiom;
//  2. one complete form above. H connector + DIGIT minutes (`a las 6 y 10`) is NOT a form: it is
//     also a pair of numbers. A "to" form on hour 1 (`la una menos cuarto`) needs a clock-face
//     choice the written form cannot make and is not converted;
//  3. no digit and no unit or currency word follows the idiom.
// No AM/PM or 24-hour inference: the written hour is the spoken hour (one less for a "to" form).

struct LanguageHourFirstClockRules: Sendable {
  enum Style: Sendable { case colon, h }

  let style: Style
  let hourAnchors: [[String]]
  let gluedAnchors: [String]
  let hours: [String: Int]
  let hourMarkers: Set<String>
  let noon: Set<String>
  let midnight: Set<String>
  let noonAnchors: [[String]]
  let connector: String
  let fractions: [(words: [String], minutes: Int)]
  let minus: String
  let minusFractions: [(words: [String], minutes: Int)]
  let beforeWord: String?
  let beforeArticles: Set<String>
  let articleBeforeTime: Bool
  let minuteFirstAnchors: [[String]]

  /// The rules for a base language code, or nil when the generated data has no entry or an entry
  /// this adapter cannot read.
  init?(language: String) {
    guard let data = HourFirstClockData.languages[language], !data.hourAnchors.isEmpty,
      data.hours.count == 12, !data.connector.isEmpty, !data.minus.isEmpty,
      !data.fractions.isEmpty, !data.minusFractions.isEmpty
    else { return nil }
    switch data.style {
    case "colon": style = .colon
    case "h": style = .h
    default: return nil
    }
    hourAnchors = data.hourAnchors
    gluedAnchors = data.gluedAnchors
    hours = Dictionary(
      data.hours.map { ($0.word, $0.value) }, uniquingKeysWith: { first, _ in first })
    hourMarkers = Set(data.hourMarkers)
    noon = Set(data.noon)
    midnight = Set(data.midnight)
    noonAnchors = data.noonAnchors
    connector = data.connector
    // Longest phrase first, so `un cuarto` wins over `cuarto` wherever both could start.
    fractions = data.fractions.sorted { $0.words.count > $1.words.count }
    minus = data.minus
    minusFractions = data.minusFractions.sorted { $0.words.count > $1.words.count }
    beforeWord = data.beforeWord
    beforeArticles = Set(data.beforeArticles)
    articleBeforeTime = data.articleBeforeTime
    minuteFirstAnchors = data.minuteFirstAnchors
  }
}

struct LanguageHourFirstClockPass: Sendable {

  let rules: LanguageHourFirstClockRules

  static let maxSpanUTF16 = 128

  // MARK: Words

  /// One chunk reduced to its word: range and text without opening or closing punctuation.
  private struct Word {
    let start: Int
    let end: Int
    let folded: String
    let hasLeadingPunctuation: Bool
    let hasTrailingPunctuation: Bool
    let gapAfterIsHorizontal: Bool
    let chunkText: String
    let chunkEnd: Int
    let hasDigit: Bool
  }

  private static let openingPunctuation = CharacterSet(charactersIn: "([{\"«„“‘¿¡")
  private static let closingPunctuation = CharacterSet(charactersIn: ".,;:!?)]}\"»”’“‘")

  private static func words(of chunks: [LanguageProtectedSpans.Chunk]) -> [Word] {
    chunks.map { chunk in
      var scalars = Array(chunk.text.unicodeScalars)
      var lead = 0
      var trail = 0
      while let first = scalars.first, openingPunctuation.contains(first) {
        lead += first.utf16.count
        scalars.removeFirst()
      }
      // A closing apostrophe belongs to a glued anchor (`all'`), so `'` is not closing here.
      while let last = scalars.last, closingPunctuation.contains(last) {
        trail += last.utf16.count
        scalars.removeLast()
      }
      var view = String.UnicodeScalarView()
      view.append(contentsOf: scalars)
      let folded = LanguageNumberGrammar.fold(String(view)).replacingOccurrences(of: "’", with: "'")
      return Word(
        start: chunk.range.lowerBound + lead, end: chunk.range.upperBound - trail, folded: folded,
        hasLeadingPunctuation: lead > 0, hasTrailingPunctuation: trail > 0,
        gapAfterIsHorizontal: chunk.gapAfterIsHorizontal, chunkText: chunk.text,
        chunkEnd: chunk.range.upperBound, hasDigit: chunk.hasDecimalDigit)
    }
  }

  /// `count` consecutive words from `first`, joined by horizontal whitespace, with no punctuation
  /// between them (the last word may carry closing punctuation when `lastMayClose`).
  private func contiguous(_ words: [Word], from first: Int, count: Int, lastMayClose: Bool) -> Bool
  {
    guard count > 0, first >= 0, first + count <= words.count else { return false }
    for offset in 0..<count {
      let word = words[first + offset]
      if word.folded.isEmpty { return false }
      if offset > 0, word.hasLeadingPunctuation { return false }
      let isLast = offset == count - 1
      if !isLast, word.hasTrailingPunctuation || !word.gapAfterIsHorizontal { return false }
      if isLast, !lastMayClose, word.hasTrailingPunctuation { return false }
    }
    return true
  }

  private func matches(_ phrase: [String], at index: Int, in words: [Word], lastMayClose: Bool)
    -> Bool
  {
    guard contiguous(words, from: index, count: phrase.count, lastMayClose: lastMayClose) else {
      return false
    }
    for (offset, token) in phrase.enumerated() where words[index + offset].folded != token {
      return false
    }
    return true
  }

  /// True when one of `anchors` ends directly before `index`, joined to it by horizontal
  /// whitespace with no punctuation.
  private func anchored(before index: Int, by anchors: [[String]], in words: [Word]) -> Bool {
    guard index > 0, !words[index].hasLeadingPunctuation else { return false }
    for anchor in anchors {
      let first = index - anchor.count
      guard first >= 0, matches(anchor, at: first, in: words, lastMayClose: false),
        words[index - 1].gapAfterIsHorizontal
      else { continue }
      return true
    }
    return false
  }

  /// The ASCII digits of a word that is ONLY one or two digits (plus an `h` when `allowH`), or nil.
  private static func digitValue(_ folded: String, allowH: Bool) -> (value: Int, hasH: Bool)? {
    var text = Substring(folded)
    var hasH = false
    if allowH, text.hasSuffix("h") {
      hasH = true
      text = text.dropLast()
    }
    guard (1...2).contains(text.count), text.allSatisfy({ $0.isASCII && $0.isNumber }),
      let value = Int(text)
    else { return nil }
    return (value, hasH)
  }

  // MARK: Entry

  enum Outcome: Sendable, Equatable {
    case ran([LanguageTextEdit])
    case unavailable(String)
  }

  func propose(in snapshot: LanguageTextSnapshot) -> Outcome {
    let words = Self.words(of: LanguageProtectedSpans.chunks(of: snapshot.text))
    var edits: [LanguageTextEdit] = []
    var index = 0
    while index < words.count {
      if let (edit, next) = minuteFirst(at: index, words: words, snapshot: snapshot)
        ?? hourFirst(at: index, words: words, snapshot: snapshot)
      {
        if let edit { edits.append(edit) }
        index = next
      } else {
        index += 1
      }
    }
    return .ran(edits)
  }

  // MARK: Hour

  private struct Hour {
    /// First word of the idiom and the UTF-16 offset where the replaced text starts (after a
    /// glued anchor).
    let first: Int
    let start: Int
    /// The word after the hour (and its marker).
    let next: Int
    let value: Int
    let kind: Kind
    enum Kind { case clock, noon, midnight }
  }

  /// The hour at `index` with its anchor checked, or nil.
  private func hour(at index: Int, words: [Word], anchors: [[String]]) -> Hour? {
    let word = words[index]
    let markerRequired = !rules.hourMarkers.isEmpty
    // A glued anchor: `all'una`, `dall'1`.
    for glued in rules.gluedAnchors
    where word.folded.hasPrefix(glued) && !word.hasLeadingPunctuation {
      let rest = String(word.folded.dropFirst(glued.count))
      let gluedUTF16 = glued.utf16.count
      if let value = rules.hours[rest] ?? Self.digitValue(rest, allowH: false).map(\.value),
        (1...23).contains(value), !markerRequired
      {
        return Hour(
          first: index, start: word.start + gluedUTF16, next: index + 1, value: value, kind: .clock)
      }
    }
    if rules.noon.contains(word.folded) || rules.midnight.contains(word.folded) {
      guard anchored(before: index, by: rules.noonAnchors, in: words) else { return nil }
      let isNoon = rules.noon.contains(word.folded)
      return Hour(
        first: index, start: word.start, next: index + 1, value: isNoon ? 12 : 0,
        kind: isNoon ? .noon : .midnight)
    }
    guard anchored(before: index, by: anchors, in: words) else { return nil }
    if let spelled = rules.hours[word.folded] {
      if markerRequired {
        guard index + 1 < words.count,
          contiguous(words, from: index, count: 2, lastMayClose: false),
          rules.hourMarkers.contains(words[index + 1].folded)
        else { return nil }
        return Hour(first: index, start: word.start, next: index + 2, value: spelled, kind: .clock)
      }
      return Hour(first: index, start: word.start, next: index + 1, value: spelled, kind: .clock)
    }
    guard let digits = Self.digitValue(word.folded, allowH: markerRequired),
      (1...23).contains(digits.value)
    else { return nil }
    if markerRequired && !digits.hasH {
      guard index + 1 < words.count, contiguous(words, from: index, count: 2, lastMayClose: false),
        rules.hourMarkers.contains(words[index + 1].folded)
      else { return nil }
      return Hour(
        first: index, start: word.start, next: index + 2, value: digits.value, kind: .clock)
    }
    return Hour(first: index, start: word.start, next: index + 1, value: digits.value, kind: .clock)
  }

  // MARK: Forms

  /// H connector FRACTION, H minus FRACTION, H minus MM.
  private func hourFirst(at index: Int, words: [Word], snapshot: LanguageTextSnapshot)
    -> (LanguageTextEdit?, Int)?
  {
    guard let hour = hour(at: index, words: words, anchors: rules.hourAnchors) else { return nil }
    let operatorIndex = hour.next
    guard operatorIndex < words.count,
      contiguous(
        words, from: hour.first, count: operatorIndex - hour.first + 1, lastMayClose: false)
    else { return nil }
    let op = words[operatorIndex].folded
    let tail = operatorIndex + 1
    // An opening mark before the minutes ("y (un cuarto") would be dropped by the edit.
    guard tail < words.count, !words[tail].hasLeadingPunctuation else { return nil }
    var minutes: Int?
    var last = -1
    var isTo = false
    if op == rules.connector {
      for fraction in rules.fractions
      where matches(fraction.words, at: tail, in: words, lastMayClose: true) {
        minutes = fraction.minutes
        last = tail + fraction.words.count - 1
        break
      }
    } else if op == rules.minus {
      isTo = true
      for fraction in rules.minusFractions
      where matches(fraction.words, at: tail, in: words, lastMayClose: true) {
        minutes = 60 - fraction.minutes
        last = tail + fraction.words.count - 1
        break
      }
      if minutes == nil, tail < words.count,
        contiguous(words, from: tail, count: 1, lastMayClose: true),
        let digits = Self.digitValue(words[tail].folded, allowH: false),
        (1...30).contains(digits.value)
      {
        minutes = 60 - digits.value
        last = tail
      }
    }
    guard let minutes, last >= 0 else { return nil }
    return finish(
      hourValue: hour.value, kind: hour.kind, isTo: isTo, minutes: minutes, start: hour.start,
      first: hour.first, last: last, words: words, snapshot: snapshot)
  }

  /// MINUTES before ARTICLE H: `a un cuarto para las 8`, `às 20 para as 4`.
  private func minuteFirst(at index: Int, words: [Word], snapshot: LanguageTextSnapshot)
    -> (LanguageTextEdit?, Int)?
  {
    guard let before = rules.beforeWord,
      anchored(before: index, by: rules.minuteFirstAnchors, in: words)
    else { return nil }
    var minutesTo: Int?
    var afterMinutes = index
    for fraction in rules.minusFractions
    where matches(fraction.words, at: index, in: words, lastMayClose: false) {
      minutesTo = fraction.minutes
      afterMinutes = index + fraction.words.count
      break
    }
    if minutesTo == nil, let digits = Self.digitValue(words[index].folded, allowH: false),
      (1...30).contains(digits.value)
    {
      minutesTo = digits.value
      afterMinutes = index + 1
    }
    guard let minutesTo, afterMinutes + 2 < words.count,
      contiguous(words, from: index, count: afterMinutes - index + 2, lastMayClose: false),
      words[afterMinutes].folded == before,
      rules.beforeArticles.contains(words[afterMinutes + 1].folded),
      let hour = hour(
        at: afterMinutes + 2, words: words, anchors: [[words[afterMinutes + 1].folded]]),
      hour.first == afterMinutes + 2, hour.next == hour.first + 1
    else { return nil }
    // Spanish keeps the article before the written time (`a un cuarto para las 8` to
    // `a las 7:45`); the Portuguese anchors already carry it (`às`).
    let article = words[afterMinutes + 1]
    let prefix =
      rules.articleBeforeTime ? (snapshot.substring(article.start..<article.end) ?? "") + " " : ""
    return finish(
      hourValue: hour.value, kind: hour.kind, isTo: true, minutes: 60 - minutesTo,
      start: words[index].start, first: index, last: hour.first, words: words, snapshot: snapshot,
      prefix: prefix)
  }

  // MARK: Decision

  private func finish(
    hourValue: Int, kind: Hour.Kind, isTo: Bool, minutes: Int, start: Int, first: Int, last: Int,
    words: [Word], snapshot: LanguageTextSnapshot, prefix: String = ""
  ) -> (LanguageTextEdit?, Int)? {
    let next = last + 1
    // A digit, a unit or a currency right after the idiom: part of something longer.
    if next < words.count, words[last].gapAfterIsHorizontal, !words[last].hasTrailingPunctuation {
      let following = words[next]
      if following.hasDigit
        || LanguageProtectedSpans.isMeasurementOrCurrencyUnit(following.chunkText)
      {
        return (nil, next)
      }
    }
    var written = hourValue
    if isTo {
      switch kind {
      case .clock:
        // `la una menos cuarto`: 12:45 or 0:45 is a clock-face choice; not converted.
        guard hourValue > 1 else { return (nil, next) }
        written = hourValue - 1
      case .noon: written = 11
      case .midnight: written = 23
      }
    }
    let minuteText = minutes < 10 ? "0\(minutes)" : "\(minutes)"
    let separator = rules.style == .colon ? ":" : "h"
    let time = prefix + "\(written)\(separator)\(minuteText)"
    // The whole chunks the idiom covers; a digit chunk is replaced whole, closing marks carried.
    let lastWord = words[last]
    let end = lastWord.hasDigit ? lastWord.chunkEnd : lastWord.end
    let closing =
      lastWord.hasDigit ? (snapshot.substring(lastWord.end..<lastWord.chunkEnd) ?? "") : ""
    let range = start..<end
    guard range.count <= Self.maxSpanUTF16 else { return (nil, next) }
    let digitChunks: [Range<Int>] = (first...last).compactMap { position in
      let word = words[position]
      guard word.hasDigit else { return nil }
      // The whole chunk; a glued anchor's chunk (`all'1`) starts before the replaced text, so
      // the editor refuses it.
      return (word.chunkEnd - word.chunkText.utf16.count)..<word.chunkEnd
    }
    let minted: Result<LanguageTextEdit, LanguageEditRefusal>
    if digitChunks.isEmpty {
      minted = snapshot.edit(replacing: range, with: time)
    } else {
      minted = snapshot.edit(
        replacing: range, consumingClockChunks: digitChunks, with: time + closing)
    }
    switch minted {
    case .success(let edit): return (edit, next)
    case .failure: return (nil, next)
    }
  }
}
