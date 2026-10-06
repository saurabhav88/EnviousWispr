import Foundation

// MARK: - Number style for numbers the engine already wrote (#1677)
//
// ONE pure pass over text the engine already wrote in digits. Measured: both German engines write
// cardinals, decimals, money, dates and house numbers as digits, but
//  1. WhisperKit sometimes keeps a unit WORD after a number ("48 Prozent" where Parakeet writes
//     "48%"): the pass writes the unit's symbol glued to the number ("48%");
//  2. both write a postcode with a thousands dot ("Hauptstraße 12 10.115 Berlin", "Postleitzahl
//     50.667 Köln"): the pass removes the dot when the number is a postcode by position, right
//     after a postcode label or after a house number that follows a street name, and before a
//     capitalised place name.
// Every edit keeps every digit (the editor checks it again); the word data is
// `LanguageNumberStyleRules`, the logic is shared.

struct LanguageNumberStyleRules: Sendable, Equatable {
  let unitSymbols: [String: String]
  let postcodeLabels: Set<String>
  let streetSuffixes: [String]
  let postcodeDigits: Int

  enum BuildError: Error, Equatable {
    case empty(String)
  }

  static func german() throws -> LanguageNumberStyleRules {
    typealias D = GermanNumberStyleData
    let symbols = Dictionary(
      D.unitSymbols.map { (LanguageNumberGrammar.fold($0.word), $0.symbol) },
      uniquingKeysWith: { first, _ in first })
    guard !symbols.isEmpty else { throw BuildError.empty("unitSymbols") }
    guard !D.postcodeLabels.isEmpty else { throw BuildError.empty("postcodeLabels") }
    guard !D.streetSuffixes.isEmpty else { throw BuildError.empty("streetSuffixes") }
    return LanguageNumberStyleRules(
      unitSymbols: symbols, postcodeLabels: Set(D.postcodeLabels.map(LanguageNumberGrammar.fold)),
      streetSuffixes: D.streetSuffixes.map(LanguageNumberGrammar.fold),
      postcodeDigits: D.postcodeDigits)
  }
}

struct LanguageNumberStylePass: Sendable {
  let rules: LanguageNumberStyleRules

  /// Every proposed edit against `snapshot`, in text order. Each covers whole chunks.
  func propose(in snapshot: LanguageTextSnapshot) -> [LanguageTextEdit] {
    let chunks = LanguageProtectedSpans.chunks(of: snapshot.text)
    let words = chunks.map { Self.split($0.text) }
    var edits: [LanguageTextEdit] = []
    var index = 0
    while index < chunks.count {
      // 1. number + unit word -> number + symbol
      if index + 1 < chunks.count, chunks[index].gapAfterIsHorizontal,
        words[index].trailing.isEmpty, words[index + 1].leading.isEmpty,
        Self.isWrittenNumber(words[index].core),
        let symbol = rules.unitSymbols[LanguageNumberGrammar.fold(words[index + 1].core)]
      {
        let range = chunks[index].range.lowerBound..<chunks[index + 1].range.upperBound
        let replacement =
          words[index].leading + words[index].core + symbol + words[index + 1].trailing
        if case .success(let edit) = snapshot.edit(rewritingNumberAndUnitIn: range, with: replacement) {
          edits.append(edit)
          index += 2
          continue
        }
      }
      // 2. a dotted postcode by position
      if isPostcodePosition(index, chunks: chunks, words: words) {
        let word = words[index]
        let replacement = word.leading + word.core.filter { $0 != "." } + word.trailing
        if case .success(let edit) = snapshot.edit(
          regroupingDigitsIn: chunks[index].range, with: replacement)
        {
          edits.append(edit)
        }
      }
      index += 1
    }
    return edits
  }

  private func isPostcodePosition(
    _ index: Int, chunks: [LanguageProtectedSpans.Chunk], words: [Word]
  ) -> Bool {
    let core = words[index].core
    let parts = core.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2, parts.allSatisfy({ $0.allSatisfy(\.isASCIIDigit) }),
      parts[0].count == 2, parts[0].count + parts[1].count == rules.postcodeDigits,
      words[index].leading.isEmpty
    else { return false }
    // A capitalised place name follows on the same line.
    guard index + 1 < chunks.count, chunks[index].gapAfterIsHorizontal,
      let first = words[index + 1].core.first, first.isUppercase, first.isLetter
    else { return false }
    guard index >= 1, chunks[index - 1].gapAfterIsHorizontal else { return false }
    let previous = LanguageNumberGrammar.fold(words[index - 1].core)
    if rules.postcodeLabels.contains(previous) { return true }
    // "<street> <house number>[,] <postcode> <place>"
    guard index >= 2, chunks[index - 2].gapAfterIsHorizontal,
      Self.isHouseNumber(words[index - 1].core)
    else { return false }
    let street = LanguageNumberGrammar.fold(words[index - 2].core)
    return rules.streetSuffixes.contains(where: { street.hasSuffix($0) })
  }

  // MARK: Words

  struct Word {
    let leading: String
    let core: String
    let trailing: String
  }

  private static let opening = CharacterSet(charactersIn: "([{\"'«„“‘")
  private static let closing = CharacterSet(charactersIn: ".,;:!?)]}\"'»”’“‘")

  static func split(_ text: String) -> Word {
    var scalars = Array(text.unicodeScalars)
    var lead = String.UnicodeScalarView()
    while let first = scalars.first, opening.contains(first) {
      lead.append(first)
      scalars.removeFirst()
    }
    var trail: [Unicode.Scalar] = []
    // A dot after digits may be part of the number only inside it; a final dot is punctuation.
    while let last = scalars.last, closing.contains(last) {
      trail.insert(last, at: 0)
      scalars.removeLast()
    }
    var core = String.UnicodeScalarView()
    core.append(contentsOf: scalars)
    var trailing = String.UnicodeScalarView()
    trailing.append(contentsOf: trail)
    return Word(leading: String(lead), core: String(core), trailing: String(trailing))
  }

  /// "48", "3,5", "1.200", "0,8": ASCII digits with German thousands dots and one decimal comma.
  static func isWrittenNumber(_ core: String) -> Bool {
    let parts = core.split(separator: ",", omittingEmptySubsequences: false)
    guard (1...2).contains(parts.count), let integer = parts.first, !integer.isEmpty else {
      return false
    }
    if parts.count == 2, parts[1].isEmpty || !parts[1].allSatisfy(\.isASCIIDigit) { return false }
    let groups = integer.split(separator: ".", omittingEmptySubsequences: false)
    guard groups.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }) else { return false }
    if groups.count > 1 {
      return groups[0].count <= 3 && groups.dropFirst().allSatisfy { $0.count == 3 }
    }
    return true
  }

  /// "12", "5a", "23B", "148": a house number of one to four digits and at most one letter.
  static func isHouseNumber(_ core: String) -> Bool {
    let digits = core.prefix(while: \.isASCIIDigit)
    let rest = core.dropFirst(digits.count)
    return (1...4).contains(digits.count) && rest.count <= 1 && rest.allSatisfy(\.isLetter)
  }
}

extension Character {
  fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
