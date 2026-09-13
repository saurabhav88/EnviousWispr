import Foundation

/// Places the ONE document cleanup's words back onto speaker turns (#2851, after phase 4 of
/// #2807): each cleanup passage is aligned word-by-word against its own raw text with
/// `WordDiff`'s tokens and edits, and the cleaned words are cut at the raw turn boundaries.
/// No second cleanup, no model call, no speaker name near a prompt.
///
/// The contract that matters: a word is never shown under the wrong speaker where the
/// alignment can see the move. It compares within ONE passage (each passage is cleaned on
/// its own, so a cleanup cannot carry a word from one passage into another): every edit
/// inside a turn, and a word one turn lost and a NEIGHBOURING turn gained. The one accepted
/// blind spot is a word carried across two or more turns inside one passage (see the last
/// rule). Wherever the alignment cannot say who a cleaned word belongs to, the turn keeps
/// its raw words (`processedText` nil) and is disclosed, rather than guessed. The rules,
/// from the plan's §2.5 P3, P5, P6:
/// - An equal word belongs to the turn its raw range lies in; a raw word whose range
///   straddles two turns is unassignable and fails both.
/// - A hunk (a maximal run of deletes and inserts between equals) whose deleted raw words
///   belong to more than one turn fails every turn it touches. A deleted word at a turn's
///   FIRST or LAST position fails both turns at that boundary when the deleted run shares
///   any word with the neighbouring turn ("yes / yes", "go now" | "yes go now please"):
///   Myers may have kept either copy, so ownership there is a guess. A distinct filler
///   removed at an edge is attributed.
/// - A turn whose cleaned words all vanished keeps its raw words, disclosed.
/// - A pure insertion (no deletes) belongs to the turn of the nearest preceding raw word in
///   the passage that had an owner; at a passage start, the following one.
/// - A word one turn lost and a NEIGHBOURING turn gained in the same passage was moved
///   across their boundary: both turns fail. A move two or more turns away is not seen.
/// - A passage the caller could not place in the raw text, and the raw interval up to the
///   next placed passage, are untrustworthy: turns overlapping them fall back.
/// - A passage not yet cleaned leaves its turns raw. A passage whose part failed to polish
///   (`wasPolished == false`) is aligned like any other (its text is what the document
///   shows) but its turns report `wasPolished == false`.
public enum TurnTextAligner {

  public struct Passage: Equatable, Sendable {
    public enum Placement: Equatable, Sendable {
      /// UTF-16 ranges in the raw transcript from the coordinator's own scan (never a
      /// cumulative length): `rawRange` is the passage's ORIGINAL text including the gap
      /// that precedes its first word; `contentRange` is the piece the scan actually found.
      /// The gap can hold words an UNPLACEABLE earlier passage failed to claim, which is why
      /// poisoning reads `contentRange` and slicing reads `rawRange` (chunk 1 review).
      case placed(rawRange: Range<Int>, contentRange: Range<Int>)
      case unplaceable
    }
    public let placement: Placement
    /// The cleanup's text for this passage, or nil when the cleanup has not reached it.
    public let cleaned: String?
    /// False when the part's polish was attempted and failed, so `cleaned` is the
    /// deterministic floor the document shows for it. A part the user chose not to have
    /// polished reads true: a bypass is not a failure.
    public let wasPolished: Bool

    public init(placement: Placement, cleaned: String?, wasPolished: Bool) {
      self.placement = placement
      self.cleaned = cleaned
      self.wasPolished = wasPolished
    }
  }

  public struct TurnText: Equatable, Sendable {
    public let turnID: String
    /// The turn's cleaned words, or nil when the turn keeps its raw words.
    public let processedText: String?
    /// True when `processedText` came from a trustworthy cut.
    public let cleanedCut: Bool
    /// False when any passage contributing to this turn failed to polish, or the turn keeps
    /// its raw words.
    public let wasPolished: Bool
  }

  /// Why a turn kept its raw words; for the log line and the telemetry counts.
  public enum Fallback: Equatable, Sendable {
    /// A repeated word or a straddling rewrite at a turn boundary.
    case boundary
    /// The passage could not be placed in the raw text.
    case unplaced
    /// The cleanup has not reached the passage yet.
    case unreached
    /// The cleanup removed every word of the turn; raw words shown instead.
    case emptied
  }

  public struct Outcome: Equatable, Sendable {
    public let texts: [TurnText]
    public let fallbacks: [String: Fallback]
  }

  public static func align(
    rawText: String, passages: [Passage], turns: [Turn], language: String? = nil
  ) -> Outcome {
    let locale = language.map { Locale(identifier: $0) }
    let raw = Array(rawText.utf16)
    let ordered = turns.sorted { $0.originalTextRange.lowerBound < $1.originalTextRange.lowerBound }
    let indexByID = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1.id, $0) })

    var pieces: [String: [(passageIndex: Int, text: String)]] = [:]
    var leadingWhitespace: [Int: String] = [:]
    var trailingWhitespace: [Int: String] = [:]
    var fallbacks: [String: Fallback] = [:]
    var polishedAll = Dictionary(uniqueKeysWithValues: turns.map { ($0.id, true) })

    func fail(_ turnID: String, _ reason: Fallback) {
      if fallbacks[turnID] == nil { fallbacks[turnID] = reason }
    }
    func turnsOverlapping(_ range: Range<Int>) -> [Turn] {
      ordered.filter { $0.originalTextRange.overlaps(range) }
    }
    func neighbour(of turn: Turn, before: Bool) -> Turn? {
      guard let index = indexByID[turn.id] else { return nil }
      let i = before ? index - 1 : index + 1
      return ordered.indices.contains(i) ? ordered[i] : nil
    }

    // 1. Untrustworthy intervals: an unplaceable passage poisons the raw text from the end
    //    of the previous placed passage up to the start of the next placed one.
    var previousEnd = 0
    for (index, passage) in passages.enumerated() {
      switch passage.placement {
      case .placed(let range, _):
        previousEnd = range.upperBound
      case .unplaceable:
        let nextStart =
          passages[(index + 1)...].lazy.compactMap { p -> Int? in
            if case .placed(_, let content) = p.placement { return content.lowerBound }
            return nil
          }.first ?? raw.count
        for turn in turnsOverlapping(previousEnd..<max(previousEnd, nextStart)) {
          fail(turn.id, .unplaced)
        }
      }
    }

    // 2. Each placed passage: align, attribute, cut.
    for (passageIndex, passage) in passages.enumerated() {
      guard case .placed(let passageRange, _) = passage.placement else { continue }
      let overlapping = turnsOverlapping(passageRange)
      guard let cleaned = passage.cleaned else {
        for turn in overlapping { fail(turn.id, .unreached) }
        continue
      }
      if !passage.wasPolished {
        for turn in overlapping { polishedAll[turn.id] = false }
      }
      let original = String(decoding: raw[passageRange], as: UTF16.self)
      let a = WordDiff.tokenize(original, locale: locale)
      let b = WordDiff.tokenize(cleaned, locale: locale)
      let ops = WordDiff.edits(a.map(\.key), b.map(\.key))

      // Each original token's absolute raw range, its owner (nil when it straddles two
      // turns), and whether it is its owner's first or last word in the whole document.
      let absolute: [Range<Int>] = a.map {
        (passageRange.lowerBound + $0.range.lowerBound)..<(passageRange.lowerBound
          + $0.range.upperBound)
      }
      let ownerOf: [Turn?] = absolute.map { range in
        let owners = overlapping.filter { $0.originalTextRange.overlaps(range) }
        return owners.count == 1 ? owners[0] : nil
      }
      /// Whether a deleted run touching a turn boundary could have been kept from the OTHER
      /// side instead: Myers keeps one copy of a repeated word or phrase and deletes the
      /// other, and the repeat need not sit at the edge (chunk 1 review, round 2: A "go now",
      /// B "yes go now please", cleaned "go now please" deletes B's "yes go now", whose
      /// prefixes never match A's end). So: any word the deleted run shares with the
      /// neighbouring turn makes the boundary ambiguous. The neighbour's words come from the
      /// RAW text, not this passage, so a boundary at a passage edge is compared too, and an
      /// unplaced or unreached neighbour still has its original words to compare.
      func repeatsAcross(_ run: [Int], into neighbour: Turn) -> Bool {
        let neighbourKeys = Set(
          WordDiff.tokenize(
            String(decoding: raw[neighbour.originalTextRange], as: UTF16.self), locale: locale
          ).map(\.key))
        return run.contains { neighbourKeys.contains(a[$0].key) }
      }
      /// The maximal run of consecutive original indices in `deletes` starting at `ai` and
      /// extending forward (from a turn's first word) or backward (to a turn's last word),
      /// returned in document order.
      func contiguousRun(from ai: Int, in deletes: [Int], forward: Bool) -> [Int] {
        let set = Set(deletes)
        var run = [ai]
        var next = forward ? ai + 1 : ai - 1
        while set.contains(next) {
          run.append(next)
          next += forward ? 1 : -1
        }
        return forward ? run : run.reversed()
      }
      func failAllTouching(_ ai: Int, _ reason: Fallback) {
        for turn in overlapping where turn.originalTextRange.overlaps(absolute[ai]) {
          fail(turn.id, reason)
        }
      }

      var attributed: [(turnID: String, text: String)] = []
      // A word the cleanup MOVED across a boundary: deleted from one turn, inserted into
      // a NEIGHBOURING turn (whole-diff review: raw "a b", A "a" | B "b", cleaned "b a"
      // deletes A's "a" and inserts it after B's "b"; round 2: "a x b" → "x b a" moves A's
      // FIRST word, so the deleted word's position in its turn does not matter). Neither
      // hunk alone is ambiguous, so the passage is checked as a whole after the walk.
      // Neighbours only: measured on the 48-minute row, comparing every inserted word
      // against every word ANY other turn lost read ordinary filler edits ("I", "the"
      // dropped in one turn, added in another) as moves and cost 60 more raw turns (313
      // aligned to 253). A move two or more turns away is not detected.
      var deletedWords: [(owner: Turn, key: String)] = []
      var insertedKeys: [(turnID: String, key: String)] = []
      var lastOwner: Turn?
      var i = 0
      while i < ops.count {
        if case .equal(let ai, let bi) = ops[i] {
          if let turn = ownerOf[ai] {
            attributed.append((turn.id, b[bi].text + b[bi].trailing))
            lastOwner = turn
          } else {
            failAllTouching(ai, .boundary)
          }
          i += 1
          continue
        }
        // A hunk: consecutive deletes and inserts, in whatever order Myers emitted them,
        // exactly as `WordDiff.assemble` groups them.
        var deletes: [Int] = []
        var inserts: [Int] = []
        while i < ops.count {
          switch ops[i] {
          case .equal: break
          case .delete(let ai):
            deletes.append(ai)
            i += 1
            continue
          case .insert(let bi):
            inserts.append(bi)
            i += 1
            continue
          }
          break
        }
        if deletes.isEmpty {
          // Pure insertion: the nearest preceding raw word's turn, else the following one.
          let target =
            lastOwner
            ?? ops[i...].lazy.compactMap { op -> Turn? in
              switch op {
              case .equal(let ai, _), .delete(let ai): return ownerOf[ai]
              case .insert: return nil
              }
            }.first
          if let target {
            for bi in inserts {
              attributed.append((target.id, b[bi].text + b[bi].trailing))
              insertedKeys.append((target.id, b[bi].key))
            }
          }
          continue
        }
        // A hunk with deletes: exactly one owner, and no repeated-word ambiguity at a turn
        // boundary. Measured on the 48-minute row (plan §3d step 1): failing EVERY
        // boundary-touching delete kept 111 of 372 turns raw (30%), mostly ordinary filler
        // removals ("like", "Mm-hmm") at a turn's edge; the ambiguity the rule exists for
        // is narrower: a deleted boundary word whose key repeats the neighbouring turn's
        // adjacent word, where Myers may have kept either copy.
        var owners = Set<String>()
        var touched = Set<String>()
        var trustworthy = true
        for ai in deletes {
          guard let turn = ownerOf[ai] else {
            trustworthy = false
            for t in overlapping where t.originalTextRange.overlaps(absolute[ai]) {
              touched.insert(t.id)
            }
            continue
          }
          owners.insert(turn.id)
          touched.insert(turn.id)
          deletedWords.append((turn, a[ai].key))
          if absolute[ai].lowerBound == turn.originalTextRange.lowerBound,
            let n = neighbour(of: turn, before: true),
            repeatsAcross(contiguousRun(from: ai, in: deletes, forward: true), into: n)
          {
            trustworthy = false
            touched.insert(n.id)
          }
          if absolute[ai].upperBound == turn.originalTextRange.upperBound,
            let n = neighbour(of: turn, before: false),
            repeatsAcross(
              contiguousRun(from: ai, in: deletes, forward: false), into: n)
          {
            trustworthy = false
            touched.insert(n.id)
          }
        }
        guard trustworthy, owners.count == 1, let turnID = owners.first else {
          for id in touched { fail(id, .boundary) }
          continue
        }
        for bi in inserts {
          attributed.append((turnID, b[bi].text + b[bi].trailing))
          insertedKeys.append((turnID, b[bi].key))
        }
        lastOwner = ordered[indexByID[turnID]!]
      }
      for (turnID, key) in insertedKeys {
        for (owner, lostKey) in deletedWords
        where lostKey == key
          && (neighbour(of: owner, before: true)?.id == turnID
            || neighbour(of: owner, before: false)?.id == turnID)
        {
          fail(turnID, .boundary)
          fail(owner.id, .boundary)
        }
      }

      // The passage original's leading whitespace is layout `tokenize` drops (its first
      // token starts after it); the join below puts it BETWEEN a turn's pieces when the turn
      // continues from an earlier passage.
      leadingWhitespace[passageIndex] = String(original.prefix { $0.isWhitespace })
      // And its trailing whitespace: `TranscriptSplitter`'s pieces carry the space after a
      // sentence, the cleanup's text does not, so a turn continuing into the next passage
      // would otherwise join "understand." and "Yeah," with nothing between (Live UAT,
      // 2026-09-13, the 4-minute clip).
      trailingWhitespace[passageIndex] = String(original.reversed().prefix { $0.isWhitespace }.reversed())
      var perTurn: [String: String] = [:]
      var order: [String] = []
      for (turnID, text) in attributed {
        if perTurn[turnID] == nil { order.append(turnID) }
        perTurn[turnID, default: ""] += text
      }
      for turnID in order {
        pieces[turnID, default: []].append((passageIndex, perTurn[turnID] ?? ""))
      }
    }

    // 3. Each turn's text; a turn spanning passages joins its pieces with the raw separator
    //    between those passages' placed ranges, reconstructed exactly once.
    var texts: [TurnText] = []
    for turn in turns {
      if fallbacks[turn.id] != nil {
        texts.append(
          TurnText(turnID: turn.id, processedText: nil, cleanedCut: false, wasPolished: false))
        continue
      }
      guard let parts = pieces[turn.id], !parts.isEmpty else {
        fail(turn.id, .emptied)
        texts.append(
          TurnText(turnID: turn.id, processedText: nil, cleanedCut: false, wasPolished: false))
        continue
      }
      var joined = ""
      var previousIndex: Int?
      for (passageIndex, text) in parts {
        if let previousIndex, previousIndex != passageIndex,
          case .placed(let prev, _) = passages[previousIndex].placement,
          case .placed(let next, _) = passages[passageIndex].placement,
          prev.upperBound <= next.lowerBound
        {
          // The separator is the previous passage's trailing whitespace (unless the piece
          // already ends with it), the raw text between the two placed ranges, and the next
          // passage's own leading whitespace. Only whitespace crosses: content in the gap
          // means a passage in between produced no piece for this turn (its words were all
          // removed), and copying it would restore deleted words (chunk 1 review); a single
          // space stands in.
          let carried = joined.last?.isWhitespace == true ? "" : (trailingWhitespace[previousIndex] ?? "")
          let gap =
            carried
            + String(decoding: raw[prev.upperBound..<next.lowerBound], as: UTF16.self)
            + (leadingWhitespace[passageIndex] ?? "")
          joined += gap.allSatisfy(\.isWhitespace) ? gap : " "
        }
        joined += text
        previousIndex = passageIndex
      }
      let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        // The cleanup removed every word of this turn (a lone "yeah" dropped as filler): show
        // the raw words rather than an empty turn, and disclose it.
        fail(turn.id, .emptied)
        texts.append(
          TurnText(turnID: turn.id, processedText: nil, cleanedCut: false, wasPolished: false))
        continue
      }
      texts.append(
        TurnText(
          turnID: turn.id, processedText: trimmed, cleanedCut: true,
          wasPolished: polishedAll[turn.id] ?? false))
    }
    return Outcome(texts: texts, fallbacks: fallbacks)
  }
}
