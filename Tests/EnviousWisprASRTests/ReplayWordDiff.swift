import Foundation

/// #4254 chunk 4: ordered word edits between two transcripts, for the replay's preservation
/// report. Occurrences count (no sets); unspaced scripts (Chinese, Japanese, Thai and the like)
/// compare character by character, spaced scripts word by word, case-insensitively, without
/// punctuation.
enum ReplayWordDiff {
  struct Edit: Equatable, Codable {
    enum Kind: String, Codable { case insert, delete, substitute }
    let kind: Kind
    /// Position in the expected (left) token list.
    let position: Int
    let expected: String?
    let actual: String?
  }

  static func tokens(_ text: String) -> [String] {
    var out: [String] = []
    var word = ""
    func flush() {
      if !word.isEmpty { out.append(word) }
      word = ""
    }
    for character in text.lowercased() {
      // Punctuation first: an unspaced script's marks (・, 。) are separators, not words.
      if (character.isLetter || character.isNumber) && isUnspaced(character) {
        flush()
        out.append(String(character))
      } else if character.isLetter || character.isNumber {
        word.append(character)
      } else {
        flush()
      }
    }
    flush()
    return out
  }

  /// The fewest insert, delete and substitute edits turning `expected` into `actual`, in order.
  static func edits(expected: [String], actual: [String]) -> [Edit] {
    let n = expected.count
    let m = actual.count
    var cost = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
    for i in 0...n { cost[i][0] = i }
    for j in 0...m { cost[0][j] = j }
    if n > 0, m > 0 {
      for i in 1...n {
        for j in 1...m {
          let same = expected[i - 1] == actual[j - 1]
          cost[i][j] = min(
            cost[i - 1][j - 1] + (same ? 0 : 1), cost[i - 1][j] + 1, cost[i][j - 1] + 1)
        }
      }
    }
    var edits: [Edit] = []
    var (i, j) = (n, m)
    while i > 0 || j > 0 {
      if i > 0, j > 0, cost[i][j] == cost[i - 1][j - 1] + (expected[i - 1] == actual[j - 1] ? 0 : 1)
      {
        if expected[i - 1] != actual[j - 1] {
          edits.append(
            Edit(
              kind: .substitute, position: i - 1, expected: expected[i - 1], actual: actual[j - 1]))
        }
        i -= 1
        j -= 1
      } else if i > 0, cost[i][j] == cost[i - 1][j] + 1 {
        edits.append(Edit(kind: .delete, position: i - 1, expected: expected[i - 1], actual: nil))
        i -= 1
      } else {
        edits.append(Edit(kind: .insert, position: i, expected: nil, actual: actual[j - 1]))
        j -= 1
      }
    }
    return edits.reversed()
  }

  /// A clip's comparison against its reference, or why there is none.
  enum ReferenceComparison: Equatable {
    case compared([Edit])
    /// No human or publisher reference: a change here cannot be adjudicated by reference.
    case notAdjudicated
  }

  static func compare(_ text: String, reference: String?) -> ReferenceComparison {
    guard let reference, !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .notAdjudicated
    }
    return .compared(edits(expected: tokens(reference), actual: tokens(text)))
  }

  private static func isUnspaced(_ character: Character) -> Bool {
    guard let scalar = character.unicodeScalars.first?.value else { return false }
    let ranges: [ClosedRange<UInt32>] = [
      0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF, 0x3040...0x30FF,
      0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
    ]
    return ranges.contains { $0.contains(scalar) }
  }
}

/// #4254 chunk 4: runs `body`, then awaits `cleanup` on success, error and cancellation alike,
/// so a replay never leaves the executor's model loaded behind a failed clip.
enum ReplayCleanup {
  static func run<T>(_ body: () async throws -> T, finally cleanup: () async -> Void) async throws -> T {
    let value: T
    do {
      value = try await body()
    } catch {
      await cleanup()
      throw error
    }
    await cleanup()
    return value
  }
}
