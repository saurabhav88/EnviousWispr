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
  /// True when THIS SNIPPET OWNS ITS ENDING (#2637), so `SnippetFinalizer` must strip a
  /// sentence terminator sitting immediately after the sentinel in whatever polish returns.
  ///
  /// It records the DECISION, not whether anything was removed from the recogniser's text: a
  /// whole-dictation snippet the recogniser left unpunctuated still owns its ending, and the
  /// model is what puts a terminator there.
  ///
  /// **The decision has to TRAVEL, because a whole-dictation expansion CAN reach a model.**
  /// `LLMPolishStep` bypasses polish at three words or fewer, which is why an English lone
  /// sentinel never gets there — but that gate is whitespace-segmented, and for an unsegmented
  /// script (ja/zh/th/lo) the sibling gate counts CHARACTERS with a minimum of 10
  /// (`LLMPolishStep.swift:437`). A sentinel is 38 characters, so it clears that gate every
  /// time. Measured EG-1 does not add a terminator, but this is not a claim about one model:
  /// the user picks the provider, and `SnippetFinalizer` substitutes into whatever comes back.
  public let suppressFollowingSentenceEnding: Bool

  public init(
    sentinel: String, expansion: String, suppressFollowingSentenceEnding: Bool = false
  ) {
    self.sentinel = sentinel
    self.expansion = expansion
    self.suppressFollowingSentenceEnding = suppressFollowingSentenceEnding
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
/// - Trailing punctuation clinging to the last trigger word is normally re-attached AFTER the
///   substitution, so "…backslash my email address." keeps its full stop. A SENTENCE ending is
///   suppressed instead when the snippet owns its ending — see `trailingToRestore` (#2637).
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

      // The KEYWORD is a consumed token too, and it was the one the first version of this guard
      // could not see: "backslash. My email address is below" has the boundary on the keyword,
      // normalisation strips it, and the trigger words after it match perfectly. Checking the
      // trigger tokens alone let that fire.
      //
      // The complete set a boundary must be checked against is every token the match CONSUMES —
      // the keyword plus every trigger token — minus the last, which legitimately ends the
      // sentence the trigger is in. Written as one named condition so the set is visible rather
      // than split across two loops that each see half of it.
      guard
        SnippetText.normalize(token) == keyword,
        !SnippetText.endsSentence(token),
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
      let trailing = Self.trailingToRestore(
        lastToken: lastToken,
        expansion: hit.snippet.expansion,
        isWholeDictation: cursor == 0 && cursor + hit.length == wordIndices.count - 1)
      records.append(
        SnippetExpansionRecord(
          sentinel: sentinel,
          expansion: hit.snippet.expansion,
          suppressFollowingSentenceEnding: trailing.suppressed))

      // The punctuation the user actually spoke belongs AROUND the pasted text, not swallowed
      // with the trigger. Both ends, and both are load-bearing: the opening mark is stripped
      // from the KEYWORD token so the match can happen, the closing one from the LAST trigger
      // token. Restoring only the tail leaves an orphan closing quote, which review caught.
      // Same sets `SnippetText.normalize` strips, so the pairs cannot drift apart.
      // BOTH tokens that can carry an opening mark, because the user can put the quote in
      // either place: `"backslash my email"` attaches it to the keyword, `backslash "my email"`
      // to the first trigger word. Normalisation strips it from whichever one has it so the
      // match can happen, and restoring only the keyword's left an orphan closing quote in the
      // other arrangement. Two routes to one effect; fixing one looked exactly like fixing both.
      let firstTriggerToken = pieces[wordIndices[cursor + 1]].text
      out +=
        SnippetText.leadingPunctuation(token)
        + SnippetText.leadingPunctuation(firstTriggerToken) + sentinel
        + trailing.restored
      if let gap = Self.whitespaceAfter(lastWordIndex, in: pieces) { out += gap }
      cursor += hit.length + 1
    }

    return SnippetExpansionOutcome(text: out, records: records)
  }

  /// The trailing punctuation to re-attach after the expansion (#2637).
  ///
  /// Re-attaching is the DEFAULT and stays: in `Please contact me at <keyword> my email.` the
  /// full stop is the user's sentence, not the trigger's, and swallowing it was the original
  /// defect. What changed is that the recogniser's terminator is suppressed in the two cases
  /// where the snippet's own text is the authority on how it ends.
  ///
  /// Founder, 2026-09-03: "People will add punctuation and formatting to their snippet. We
  /// would honor that."
  ///
  /// - `isWholeDictation` — the keyword is the first word and the last trigger word is the
  ///   last word, so there is no surrounding sentence for the stop to belong to. Parakeet
  ///   punctuates a complete utterance, and a dictation that is nothing but a snippet phrase
  ///   IS one, so `Insert my email.` welded a stop onto an email address on every single use.
  ///   Measured on the founder's own log, three times at 23:22 on 2026-09-03.
  /// - the saved text already ends a sentence — otherwise a canned reply ending in `.`
  ///   arrives as `..`
  ///
  /// Scoped to a run that is ENTIRELY sentence-ending. A comma, a closing bracket or a closing
  /// quote is re-attached exactly as before, because the comma in `<keyword> my email, and let
  /// me know` belongs to the user's sentence and nothing about the snippet makes it wrong.
  /// Deliberately NOT widened to "strip any terminator": that would need a claim about every
  /// mark the recogniser can emit, and this needs a claim about three.
  /// `suppressed` reports the DECISION and is independent of whether the run contained anything
  /// to remove, because the model is a second source of terminators and the finalizer needs the
  /// decision either way.
  ///
  /// The run is FILTERED rather than tested wholesale. Refusing a run that is not entirely
  /// sentence-ending looked conservative and left `.\u{201D}` and `.)` untouched, so a saved
  /// expansion ending in a full stop still arrived as `..\u{201D}` — the exact outcome this
  /// exists to prevent, hidden behind one closing mark. Only the terminator goes; commas,
  /// brackets and closing quotes are re-attached exactly as before.
  static func trailingToRestore(
    lastToken: String, expansion: String, isWholeDictation: Bool
  ) -> (restored: String, suppressed: Bool) {
    let run = SnippetText.trailingPunctuation(lastToken)
    guard isWholeDictation || SnippetText.endsSentence(expansion) else { return (run, false) }
    return (SnippetText.droppingSentenceEndings(from: run), true)
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
        // Only an INTERIOR boundary blocks: punctuation on the LAST token belongs to the
        // trigger's surrounding context and is decided by `trailingToRestore`. The keyword's
        // own boundary is checked by the CALLER, because the keyword is consumed too and this
        // loop cannot see it — see `consumedTokensSpanASentenceBoundary`.
        if offset < tokens.count - 1, SnippetText.endsSentence(piece.text) {
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
