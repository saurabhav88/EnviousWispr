import Foundation

// MARK: - Spans that are already written (#1677, PR 2 chunk 3)
//
// A language pass must never rewrite text that is already in written form, whether the engine
// wrote it, the language-neutral subset wrote it (`normalizeLanguageNeutral`), or the speaker
// dictated it that way. This file finds those spans in ONE original text and the editor refuses
// any edit that crosses one. It owns no language inventory and reads no registry: neutral
// output is recognized by SHAPE (digits, an at-sign, a scheme separator, a dotted host), so it
// needs no list of what the neutral subset covers.
//
// RECOGNIZED FORMS (finite; nothing outside this list is claimed):
//  - number: a whitespace-delimited chunk holding a decimal digit. That covers integers,
//    decimals, percentages, dates (`05.05.2024`, `2026-09-26`), clock times (`12:30`), written
//    telephone numbers (`+49`, `00 49`), identifiers and codes with digits (`B-2`, `GPT-4`),
//    version chains (`2.5.0`) and host:port (`localhost:3000`).
//  - address: a chunk with an at-sign, a `://` separator, a `mailto:` prefix, a `www.` prefix, or
//    a dotted host (two or more labels, a final label of two or more letters), with or without a
//    path (`exemple.fr/aide`).
//  - money: a currency symbol, ISO currency code or currency word beside a number chunk.
//  - measurement: a unit symbol or unit word after a number chunk (`%`, `°C`, `kg`, `Uhr`, `Grad`).
// NOT CLAIMED: identifiers without a digit, paths without a scheme, spelled-out numbers, and
// dates written with a month name.
//
// FAIL CLOSED: the unit of protection is the whole chunk, punctuation included, so a trailing
// comma or a quote never opens a gap inside an address. Over-protecting only withholds an
// improvement; under-protecting would rewrite text the user or an earlier pass already wrote.
// There is no length cap: a long URL is one chunk and is protected to its last character.

struct LanguageProtectedSpan: Sendable, Equatable {
  enum Kind: String, Sendable, CaseIterable {
    case number
    case address
    case money
    case measurement
  }

  /// UTF-16 range in the original snapshot.
  let range: Range<Int>
  let kind: Kind
}

enum LanguageProtectedSpans {

  /// Every protected span of the snapshot, ascending by start. Spans never overlap.
  static func collect(in snapshot: LanguageTextSnapshot) -> [LanguageProtectedSpan] {
    let chunks = chunks(of: snapshot.text)
    var kinds = [LanguageProtectedSpan.Kind?](repeating: nil, count: chunks.count)
    for (index, chunk) in chunks.enumerated() {
      if isAddress(chunk.text) {
        kinds[index] = .address
      } else if chunk.hasDecimalDigit {
        kinds[index] = .number
      }
    }
    for index in chunks.indices where kinds[index] == .number {
      if index + 1 < chunks.count, kinds[index + 1] == nil, chunks[index].gapAfterIsHorizontal {
        let word = core(chunks[index + 1].text)
        if currencies.contains(word) {
          kinds[index + 1] = .money
        } else if units.contains(word) {
          kinds[index + 1] = .measurement
        }
      }
      if index > 0, kinds[index - 1] == nil, chunks[index - 1].gapAfterIsHorizontal,
        currencies.contains(core(chunks[index - 1].text))
      {
        kinds[index - 1] = .money
      }
    }
    var spans: [LanguageProtectedSpan] = []
    for (index, chunk) in chunks.enumerated() {
      if let kind = kinds[index] {
        spans.append(LanguageProtectedSpan(range: chunk.range, kind: kind))
      }
    }
    return spans
  }

  /// The first span that shares at least one UTF-16 unit with `range`, or nil. A range that only
  /// touches a span's edge does not intersect it.
  static func firstIntersecting(_ range: Range<Int>, in spans: [LanguageProtectedSpan])
    -> LanguageProtectedSpan?
  {
    spans.first { $0.range.lowerBound < range.upperBound && range.lowerBound < $0.range.upperBound }
  }

  // MARK: Chunking

  private struct Chunk {
    let range: Range<Int>
    let text: String
    let hasDecimalDigit: Bool
    /// True when only horizontal whitespace separates this chunk from the next one.
    var gapAfterIsHorizontal: Bool
  }

  private static let lineBreaks: Set<UInt32> = [0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029]

  /// Splits on the Unicode White_Space property, by scalar: grapheme-cluster whitespace tests
  /// disagree with it for a combining mark after a space.
  private static func chunks(of text: String) -> [Chunk] {
    var result: [Chunk] = []
    var offset = 0
    var start: Int?
    var scalars = String.UnicodeScalarView()
    var digit = false
    var sawLineBreak = false

    func close(at end: Int) {
      guard let begin = start else { return }
      result.append(
        Chunk(
          range: begin..<end, text: String(scalars), hasDecimalDigit: digit,
          gapAfterIsHorizontal: true))
      start = nil
      scalars = String.UnicodeScalarView()
      digit = false
      sawLineBreak = false
    }

    for scalar in text.unicodeScalars {
      if scalar.properties.isWhitespace {
        close(at: offset)
        if lineBreaks.contains(scalar.value), !result.isEmpty { sawLineBreak = true }
      } else {
        if start == nil {
          start = offset
          if sawLineBreak { result[result.count - 1].gapAfterIsHorizontal = false }
          sawLineBreak = false
        }
        scalars.append(scalar)
        if scalar.properties.numericType == .decimal { digit = true }
      }
      offset += scalar.value > 0xFFFF ? 2 : 1
    }
    close(at: offset)
    return result
  }

  // MARK: Address shapes

  private static func isAddress(_ chunk: String) -> Bool {
    if chunk.contains("@") || chunk.contains("://") { return true }
    let lowered = chunk.lowercased()
    if lowered.hasPrefix("mailto:") || lowered.hasPrefix("www.") { return true }
    return isDottedHost(chunk)
  }

  /// `label.label[.label…]` with an optional `/path` or `:port`, a final label of two or more
  /// letters (or an encoded `xn--` label), after peeling leading and trailing punctuation.
  private static func isDottedHost(_ chunk: String) -> Bool {
    var body = Substring(chunk)
    while let first = body.first, !first.isLetter, !first.isNumber { body = body.dropFirst() }
    while let last = body.last, !last.isLetter, !last.isNumber { body = body.dropLast() }
    let host = body.prefix { $0 != "/" && $0 != ":" }
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return false }
    guard labels.allSatisfy({ $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }) else {
      return false
    }
    guard let last = labels.last, last.count >= 2 else { return false }
    // A final label is letters, or an ASCII encoded internationalized label (`xn--…`). Encoded
    // labels are protected conservatively: this recognizes a written structure and certifies no
    // domain.
    let folded = last.lowercased()
    let encodedLabel =
      folded.hasPrefix("xn--") && folded.count > 4
      && folded.utf8.allSatisfy {
        (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2D
      }
    guard last.allSatisfy({ $0.isLetter }) || encodedLabel else { return false }
    return true
  }

  // MARK: Money and measurement words

  private static let leadingPunctuation = CharacterSet(charactersIn: "([{\"'«„“‘")
  private static let trailingPunctuation = CharacterSet(charactersIn: ".,;:!?)]}\"'»“”’")

  /// A neighbour chunk reduced to the word it carries: lower-cased, without wrapping punctuation.
  private static func core(_ chunk: String) -> String {
    var scalars = Array(chunk.lowercased().unicodeScalars)
    while let first = scalars.first, leadingPunctuation.contains(first) { scalars.removeFirst() }
    while let last = scalars.last, trailingPunctuation.contains(last) { scalars.removeLast() }
    var view = String.UnicodeScalarView()
    view.append(contentsOf: scalars)
    return String(view)
  }

  private static let currencies: Set<String> = [
    "€", "$", "£", "¥", "₹", "₽", "₩", "₺", "₪", "₫", "฿", "eur", "usd", "gbp", "chf", "jpy",
    "cny", "inr", "euro", "euros", "dollar", "cent", "franken", "rappen", "pfund",
  ]

  private static let units: Set<String> = [
    "%", "‰", "°", "°c", "°f", "prozent", "grad", "uhr", "km", "m", "cm", "mm", "kg", "g", "mg",
    "t", "l", "ml", "h", "min", "s", "ms", "sek", "std", "kb", "mb", "gb", "tb", "hz", "khz",
    "mhz", "ghz", "w", "kw", "kwh", "v", "meter", "kilometer", "zentimeter", "millimeter",
    "kilogramm", "gramm", "liter", "minute", "minuten", "sekunde", "sekunden", "stunde",
    "stunden", "tag", "tage", "tagen", "woche", "wochen", "monat", "monate", "monaten", "jahr",
    "jahre", "jahren",
  ]
}
