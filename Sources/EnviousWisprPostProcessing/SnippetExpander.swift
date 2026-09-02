import EnviousWisprCore
import Foundation

/// One expansion the pipeline owes the user: the sentinel that stands in for it through the
/// text chain, and the exact text that must replace that sentinel before anything is stored,
/// shown, or pasted (#628).
public struct SnippetExpansionRecord: Sendable, Equatable {
  /// The opaque token substituted into the text. Unique within its run.
  public let sentinel: String
  /// The user's saved text, byte-for-byte. Never sent to a model.
  public let expansion: String

  public init(sentinel: String, expansion: String) {
    self.sentinel = sentinel
    self.expansion = expansion
  }
}

public struct SnippetExpansionOutcome: Sendable, Equatable {
  /// The text with each fired snippet replaced by its sentinel.
  public let text: String
  /// One record per fired snippet, in the order they appear. Empty means nothing fired and
  /// every downstream stage is a no-op.
  public let records: [SnippetExpansionRecord]

  public init(text: String, records: [SnippetExpansionRecord]) {
    self.text = text
    self.records = records
  }

  public var didFire: Bool { !records.isEmpty }
}

/// Pure, Sendable snippet matcher (#628). Sibling of `WordCorrector`, and deliberately its
/// opposite: `WordCorrector` is fuzzy across six passes, this is literal in one.
///
/// Semantics ported from the approved design prototype's `expand()`
/// (`docs/feature-requests/issue-628-design/EnviousWispr Snippets.dc.html`), which is the
/// behavioural authority for matching:
///
/// - A snippet fires only when the keyword is spoken immediately before its trigger.
/// - Trigger tokens compare through `SnippetText.normalize` — literal, never fuzzy.
/// - **Longest match wins** when several triggers match at one position.
/// - Trailing punctuation clinging to the last trigger word is re-attached AFTER the
///   substitution, so "…backslash my email address." keeps its full stop.
/// - The keyword is consumed on a hit and left in place on a miss, which is what makes
///   "the path is backslash users" come through untouched.
public struct SnippetExpander: Sendable {
  /// Mints a sentinel candidate. Injectable so tests can force a collision rather than wait
  /// for one — a uniqueness check whose failure branch is never executed is a comment.
  public typealias CandidateSource = @Sendable () -> String

  /// The sentinel shape, and the reasoning is the whole point of the choice.
  ///
  /// A single unbroken alphanumeric token: no whitespace for tokenisation to split, no
  /// punctuation for `InverseTextNormalizer` to convert, not a word `FillerRemoval` knows, and
  /// long and meaningless enough that `WordCorrector`'s similarity passes have no candidate
  /// anywhere near it. Uppercase-and-hex so it reads as an opaque identifier to a polish model
  /// rather than as prose to rewrite.
  ///
  /// This shape is a CANDIDATE, not a proven constant. Premise P2 in the plan requires it to be
  /// driven through the full deterministic chain adversarially before it is depended on; if a
  /// step mangles it, the fix is here and the tests fail loudly rather than a user seeing it.
  static let prefix = "EWSNIP"

  private let candidateSource: CandidateSource

  public init(candidateSource: @escaping CandidateSource = SnippetExpander.randomCandidate) {
    self.candidateSource = candidateSource
  }

  public static let randomCandidate: CandidateSource = {
    var hex = ""
    for _ in 0..<4 {
      hex += String(format: "%08x", UInt32.random(in: UInt32.min...UInt32.max))
    }
    return prefix + hex
  }

  /// Expand every fired snippet in `text` into a sentinel.
  ///
  /// Returns the input unchanged with no records when the vocabulary cannot fire, so a user
  /// with no snippets takes a byte-identical path.
  public func expand(_ text: String, using vocabulary: SnippetVocabulary) -> SnippetExpansionOutcome
  {
    guard vocabulary.canFire else { return SnippetExpansionOutcome(text: text, records: []) }
    let keyword = SnippetText.normalize(vocabulary.keyword)
    let pieces = Self.split(text)
    let wordIndices = pieces.indices.filter { !pieces[$0].isWhitespaceRun }

    // Seeded with any whitespace BEFORE the first word. The loop below walks word pieces and
    // appends the gap that FOLLOWS each one, so a leading run belongs to no word and was
    // silently dropped — on every dictation that armed the step, whether or not a snippet
    // matched. Found by review, not by a test, because every fixture happened to start with a
    // letter.
    var out = pieces.first?.isWhitespaceRun == true ? pieces[0].text : ""
    var records: [SnippetExpansionRecord] = []
    var issued: Set<String> = []
    var cursor = 0

    while cursor < wordIndices.count {
      let pieceIndex = wordIndices[cursor]
      let token = pieces[pieceIndex].text

      guard
        SnippetText.normalize(token) == keyword,
        let hit = Self.longestMatch(
          in: vocabulary.snippets, pieces: pieces, wordIndices: wordIndices, startingAt: cursor + 1)
      else {
        out += token
        if let gap = Self.whitespaceAfter(pieceIndex, in: pieces) { out += gap }
        cursor += 1
        continue
      }

      let lastWordIndex = wordIndices[cursor + hit.length]
      let lastToken = pieces[lastWordIndex].text
      let sentinel = mintSentinel(
        rawInput: text, expansions: vocabulary.snippets.map(\.expansion), alreadyIssued: issued)
      issued.insert(sentinel)
      records.append(
        SnippetExpansionRecord(sentinel: sentinel, expansion: hit.snippet.expansion))

      // The punctuation the user actually spoke belongs after the pasted text, not swallowed
      // with the trigger. Same set `SnippetText.normalize` stripped, so the two cannot drift.
      out += sentinel + SnippetText.trailingPunctuation(lastToken)
      if let gap = Self.whitespaceAfter(lastWordIndex, in: pieces) { out += gap }
      cursor += hit.length + 1
    }

    return SnippetExpansionOutcome(text: out, records: records)
  }

  /// A sentinel that appears in NONE of: the raw input, any saved expansion, or the sentinels
  /// already issued for this run.
  ///
  /// All three domains matter and the second is the one that is easy to miss: restoration
  /// substitutes expansions back into the text, so an expansion containing a live sentinel would
  /// reintroduce one after the finalizer had already checked. Re-minting is bounded — a
  /// collision on 128 random bits is not a case that recurs — but the loop is written to
  /// terminate rather than to trust that.
  func mintSentinel(rawInput: String, expansions: [String], alreadyIssued: Set<String>) -> String {
    for _ in 0..<8 {
      let candidate = candidateSource()
      if rawInput.contains(candidate) { continue }
      if alreadyIssued.contains(candidate) { continue }
      if expansions.contains(where: { $0.contains(candidate) }) { continue }
      return candidate
    }
    // Exhausted only when the candidate source is degenerate (a test forcing a collision).
    // Falling back to a value derived from the attempt count keeps the contract — a sentinel is
    // returned and it is not one of the values we were told to avoid — rather than returning a
    // known-colliding token and letting it reach the user.
    var suffix = 0
    while true {
      let candidate = "\(Self.prefix)fallback\(suffix)"
      let collides =
        rawInput.contains(candidate) || alreadyIssued.contains(candidate)
        || expansions.contains(where: { $0.contains(candidate) })
      if !collides { return candidate }
      suffix += 1
    }
  }

  // MARK: - Matching

  private struct Match {
    let snippet: Snippet
    /// Number of word tokens the trigger consumed.
    let length: Int
  }

  /// The longest trigger matching the word tokens starting at `startingAt`, or nil.
  ///
  /// Longest-match rather than first-match because triggers nest: with both "my email" and
  /// "my email address" saved, first-match would strand the word "address" after the pasted
  /// address. Ties cannot arise — `Snippet.collidesWith` refuses a duplicate trigger at the
  /// door, so two snippets never share a token sequence.
  private static func longestMatch(
    in snippets: [Snippet], pieces: [Piece], wordIndices: [Int], startingAt: Int
  ) -> Match? {
    var best: Match?
    for snippet in snippets {
      let tokens = snippet.triggerTokens
      guard !tokens.isEmpty, startingAt + tokens.count <= wordIndices.count else { continue }
      var matched = true
      for offset in tokens.indices {
        let piece = pieces[wordIndices[startingAt + offset]]
        if SnippetText.normalize(piece.text) != tokens[offset] {
          matched = false
          break
        }
      }
      guard matched else { continue }
      if best == nil || tokens.count > best!.length {
        best = Match(snippet: snippet, length: tokens.count)
      }
    }
    return best
  }

  // MARK: - Tokenisation that preserves the original spacing

  private struct Piece {
    let text: String
    let isWhitespaceRun: Bool
  }

  /// Split into alternating runs of whitespace and non-whitespace, keeping both.
  ///
  /// The whitespace is kept rather than re-synthesised because the expansion must land in text
  /// that is otherwise untouched: rebuilding with single spaces would silently reformat the
  /// user's line breaks and double spaces on every dictation that fires a snippet.
  private static func split(_ text: String) -> [Piece] {
    var pieces: [Piece] = []
    var current = ""
    var currentIsSpace: Bool?
    for character in text {
      let isSpace = character.isWhitespace
      if currentIsSpace == nil || currentIsSpace == isSpace {
        current.append(character)
        currentIsSpace = isSpace
      } else {
        pieces.append(Piece(text: current, isWhitespaceRun: currentIsSpace!))
        current = String(character)
        currentIsSpace = isSpace
      }
    }
    if let currentIsSpace, !current.isEmpty {
      pieces.append(Piece(text: current, isWhitespaceRun: currentIsSpace))
    }
    return pieces
  }

  private static func whitespaceAfter(_ index: Int, in pieces: [Piece]) -> String? {
    let next = index + 1
    guard next < pieces.count, pieces[next].isWhitespaceRun else { return nil }
    return pieces[next].text
  }
}
