import EnviousWisprCore
import Foundation

/// American to British spelling for the English (UK) dictation choice (#3124).
///
/// Replaces whole words from a bundled table (`british-spelling.json`) generated from VarCon by
/// `scripts/generate-british-spelling.py`. The table already excludes every word VarCon marks as
/// sense-dependent ("program", "check", "practice", "license"...), so this type makes no meaning
/// judgements of its own: it decides only WHICH tokens in a text are prose words it may touch.
///
/// A token is left alone, and the reason is the user-visible failure it prevents, when it is:
/// - Title-case in mid-sentence: a name ("Kennedy Center", "Labor Day"). Respelling a name changes
///   a fact. A Title-case word at the start of a sentence IS converted, so a name that opens a
///   sentence ("Color Street is...") converts too; nothing in the text tells the two apart.
/// - ALL-CAPS or mixed case ("COLOR", "iColor"): an acronym, a shout or an identifier.
/// - Touching a digit, a letter outside ASCII, or `_ @ / \ # $ = < >`, or joined to a word by `.`
///   or `:` with no space ("color.js", "self.color", "https://center.io"): code, a path or an
///   address, where a changed letter breaks the reference.
/// - One of the user's Custom Words, or inside a snippet sentinel: the user's own spelling, or a
///   token that must survive the chain byte for byte.
///
/// A hyphen separates prose words ("colour-coded", "well-organised"), so a hyphenated CSS name
/// ("background-color") converts as well. That is an accepted limit: hyphen compounds in dictation
/// are overwhelmingly prose.
///
/// Pure and synchronous. `swaps` counts replaced tokens; when it is zero the input comes back
/// unchanged, byte for byte.
public struct BritishSpellingConverter: Sendable {
  public enum LoadError: Error, CustomStringConvertible {
    case missingResource(String)
    case decodeFailed(String)

    public var description: String {
      switch self {
      case .missingResource(let s): return "BritishSpellingConverter: resource missing: \(s)"
      case .decodeFailed(let s): return "BritishSpellingConverter: decode failed: \(s)"
      }
    }
  }

  public struct Result: Sendable, Equatable {
    public let text: String
    public let swaps: Int
  }

  static let resourceName = "british-spelling"

  /// Lowercased American form (apostrophes as `'`) to its British form.
  private let table: [String: String]

  /// Number of American forms the table maps.
  public var entryCount: Int { table.count }

  init(table: [String: String]) {
    self.table = table
  }

  /// The bundled table, loaded once per process and shared by every consumer (the dictation
  /// chain and the live preview), or the error that stopped it loading. The one place the table
  /// is read in production, so there is one load and one failure to report.
  public static let shared: Shared = {
    do {
      return .loaded(try load())
    } catch {
      return .failed(String(describing: error))
    }
  }()

  /// The outcome of the one production load: the converter, or why it failed.
  public enum Shared: Sendable {
    case loaded(BritishSpellingConverter)
    case failed(String)

    /// The converter, or nil when the table failed to load.
    public var converter: BritishSpellingConverter? {
      if case .loaded(let converter) = self { return converter }
      return nil
    }
  }

  /// The lowercased words a British conversion must leave alone: the USER's own Custom Words from
  /// `vocabulary`, every canonical and every word inside a multi-word one (a Custom Word "Kennedy
  /// Center" protects "center"). Built-in and pack terms are excluded on purpose: they are
  /// app-authored American defaults ("recognizer", and "offense" in the legal pack), and protecting
  /// them would override the user's British choice. The one rule for the dictation chain and the
  /// live preview.
  public static func protectedWords(fromUserWordsIn vocabulary: CorrectorVocabulary) -> Set<String> {
    var words: Set<String> = []
    for term in vocabulary.terms where term.source == .user {
      let canonical = term.canonical.lowercased()
      words.insert(canonical)
      for word in canonical.split(whereSeparator: { !($0.isLetter || $0 == "'" || $0 == "\u{2019}") }) {
        words.insert(String(word).replacingOccurrences(of: "\u{2019}", with: "'"))
      }
    }
    return words
  }

  /// Loads the bundled table. Throws on a missing, unreadable or empty table; the caller decides
  /// what a failure means for the feature.
  public static func load() throws -> BritishSpellingConverter {
    try load(from: .module)
  }

  /// Loads the table from `bundle`; `load()` passes `Bundle.module`.
  public static func load(from bundle: Bundle) throws -> BritishSpellingConverter {
    guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
      throw LoadError.missingResource("\(resourceName).json not in bundle")
    }
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw LoadError.missingResource("read \(resourceName).json: \(error.localizedDescription)")
    }
    let table: [String: String]
    do {
      table = try JSONDecoder().decode([String: String].self, from: data)
    } catch {
      throw LoadError.decodeFailed("decode \(resourceName).json: \(error.localizedDescription)")
    }
    guard !table.isEmpty else {
      throw LoadError.decodeFailed("\(resourceName).json is empty")
    }
    return BritishSpellingConverter(table: table)
  }

  /// The `Bundle.module` URL of the bundled table, or nil if the resource bundle did not ship.
  /// The same lookup `load()` uses, so a test can prove the shipped resource resolves.
  // periphery:ignore - test seam (resource-resolution diagnostic)
  public static var bundledTableURLForDiagnostics: URL? {
    Bundle.module.url(forResource: resourceName, withExtension: "json")
  }

  /// Converts every eligible American spelling in `text` to British.
  ///
  /// - Parameters:
  ///   - protectedWords: lowercased words that are never changed (the user's Custom Words).
  ///   - protectedSpans: exact substrings whose tokens are never changed (snippet sentinels).
  public func convert(
    _ text: String, protectedWords: Set<String> = [], protectedSpans: [String] = []
  ) -> Result {
    let chars = Array(text)
    guard !chars.isEmpty else { return Result(text: text, swaps: 0) }
    let blocked = Self.blockedMask(chars: chars, spans: protectedSpans)

    var output = ""
    output.reserveCapacity(text.utf8.count)
    var swaps = 0
    var index = 0
    while index < chars.count {
      guard Self.isASCIILetter(chars[index]) else {
        output.append(chars[index])
        index += 1
        continue
      }
      var end = index + 1
      while end < chars.count {
        if Self.isASCIILetter(chars[end]) {
          end += 1
        } else if Self.isApostrophe(chars[end]), end + 1 < chars.count,
          Self.isASCIILetter(chars[end + 1])
        {
          end += 1
        } else {
          break
        }
      }
      if let british = replacement(
        start: index, end: end, chars: chars, blocked: blocked, protectedWords: protectedWords)
      {
        output.append(british)
        swaps += 1
      } else {
        output.append(contentsOf: chars[index..<end])
      }
      index = end
    }
    return Result(text: swaps == 0 ? text : output, swaps: swaps)
  }

  // MARK: - Token decision

  private func replacement(
    start: Int, end: Int, chars: [Character], blocked: [Bool], protectedWords: Set<String>
  ) -> String? {
    if blocked[start..<end].contains(true) { return nil }
    if Self.isCodeContext(start: start, end: end, chars: chars) { return nil }

    let token = chars[start..<end]
    var key = ""
    var apostrophe: Character?
    for character in token {
      if Self.isApostrophe(character) {
        apostrophe = character
        key.append("'")
      } else {
        key.append(contentsOf: character.lowercased())
      }
    }
    if protectedWords.contains(key) { return nil }
    guard let british = table[key] else { return nil }

    let isLower = token.allSatisfy { !$0.isUppercase }
    let isTitle =
      token.first?.isUppercase == true && token.dropFirst().allSatisfy { !$0.isUppercase }
    guard isLower || (isTitle && Self.isSentenceStart(start, chars: chars)) else { return nil }

    var result = british
    if let apostrophe, apostrophe != "'" {
      result = result.replacingOccurrences(of: "'", with: String(apostrophe))
    }
    if isTitle {
      result = result.prefix(1).uppercased() + result.dropFirst()
    }
    return result
  }

  /// True when the token is part of an identifier, a path, an address or a number.
  private static func isCodeContext(start: Int, end: Int, chars: [Character]) -> Bool {
    if start > 0 {
      let previous = chars[start - 1]
      if isCodeNeighbour(previous) { return true }
      // "self.color", "https://center.io": joined to the word before by `.` or `:`.
      if previous == "." || previous == ":", start > 1, !chars[start - 2].isWhitespace {
        return true
      }
    }
    if end < chars.count {
      let next = chars[end]
      if isCodeNeighbour(next) { return true }
      // "color.js", "color:red": joined to what follows. A sentence end ("the color.") or a
      // closing quote after it is prose.
      if next == "." || next == ":", end + 1 < chars.count {
        let after = chars[end + 1]
        if !after.isWhitespace, !isClosingPunctuation(after) { return true }
      }
    }
    return false
  }

  /// Start of text, or only spaces and opening quotes/brackets back to `.`, `!`, `?` or a newline.
  private static func isSentenceStart(_ start: Int, chars: [Character]) -> Bool {
    var cursor = start - 1
    while cursor >= 0, chars[cursor] == " " || chars[cursor] == "\t" || isOpening(chars[cursor]) {
      cursor -= 1
    }
    guard cursor >= 0 else { return true }
    let character = chars[cursor]
    return character == "." || character == "!" || character == "?" || character.isNewline
  }

  /// Marks every character inside every occurrence of a protected span, overlapping occurrences
  /// included. Spans are indexed by their first character, so each position is compared only with
  /// the spans that could start there; the worst case is text length times total span length.
  /// Spans are the take's snippet sentinels (a handful, short, distinct), so that bound is small in
  /// practice; a general multi-pattern matcher would add machinery for inputs we never pass.
  /// Works on the same `Character` array the scan uses, so positions agree by construction.
  private static func blockedMask(chars: [Character], spans: [String]) -> [Bool] {
    var blocked = [Bool](repeating: false, count: chars.count)
    var byFirst: [Character: [[Character]]] = [:]
    for span in spans {
      let pattern = Array(span)
      guard let first = pattern.first else { continue }
      byFirst[first, default: []].append(pattern)
    }
    guard !byFirst.isEmpty else { return blocked }
    for start in chars.indices {
      guard let candidates = byFirst[chars[start]] else { continue }
      for pattern in candidates
      where start + pattern.count <= chars.count
        && chars[start..<(start + pattern.count)].elementsEqual(pattern)
      {
        for position in start..<(start + pattern.count) { blocked[position] = true }
      }
    }
    return blocked
  }

  // MARK: - Character classes

  private static func isASCIILetter(_ character: Character) -> Bool {
    guard let value = character.asciiValue else { return false }
    return (65...90).contains(value) || (97...122).contains(value)
  }

  private static func isApostrophe(_ character: Character) -> Bool {
    character == "'" || character == "\u{2019}"
  }

  private static func isOpening(_ character: Character) -> Bool {
    "\"'([\u{201C}\u{2018}".contains(character)
  }

  private static func isClosingPunctuation(_ character: Character) -> Bool {
    "\"')]\u{201D}\u{2019}".contains(character)
  }

  private static func isCodeNeighbour(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || "_@/\\#$=<>".contains(character)
  }
}
