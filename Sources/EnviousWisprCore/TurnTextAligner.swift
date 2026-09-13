import Foundation

/// Places the ONE document cleanup's words back onto speaker turns (#2851, after phase 4 of
/// #2807): each cleanup passage is aligned word-by-word against its own raw text with
/// `WordDiff`'s tokens and edits, and the cleaned words are cut at the raw turn boundaries.
/// No second cleanup, no model call, no speaker name near a prompt.
///
/// The contract that matters: a word is NEVER moved between speakers. Wherever the alignment
/// cannot say who a cleaned word belongs to, the turn keeps its raw words (`processedText`
/// nil) and is disclosed, rather than guessed. The rules, from the plan's §2.5 P3, P5, P6:
/// - An equal word belongs to the turn its raw range lies in; a raw word whose range
///   straddles two turns is unassignable and fails both.
/// - A hunk (a maximal run of deletes and inserts between equals) whose deleted raw words
///   belong to more than one turn fails every turn it touches. A deleted word at a turn's
///   FIRST or LAST position fails both turns at that boundary only when it repeats the
///   neighbouring turn's adjacent word ("yes / yes"): Myers may have kept either copy, so
///   ownership there is a guess. A distinct filler removed at an edge is attributed.
/// - A turn whose cleaned words all vanished keeps its raw words, disclosed.
/// - A pure insertion (no deletes) belongs to the turn of the nearest preceding raw word in
///   the passage; at a passage start, the following one.
/// - A passage the caller could not place in the raw text, and the raw interval up to the
///   next placed passage, are untrustworthy: turns overlapping them fall back.
/// - A passage not yet cleaned leaves its turns raw. A passage whose part failed to polish
///   (`wasPolished == false`) is aligned like any other (its text is what the document
///   shows) but its turns report `wasPolished == false`.
public enum TurnTextAligner {

  public struct Passage: Equatable, Sendable {
    public enum Placement: Equatable, Sendable {
      /// UTF-16 range of the passage's ORIGINAL text in the raw transcript, from the
      /// coordinator's own scan (never a cumulative length).
      case placed(Range<Int>)
      case unplaceable
    }
    public let placement: Placement
    /// The cleanup's text for this passage, or nil when the cleanup has not reached it.
    public let cleaned: String?
    /// Whether the part's polish actually landed; false means `cleaned` is the
    /// deterministic floor the document shows for a failed part.
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
    /// True only when every passage contributing to this turn actually polished.
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
      case .placed(let range):
        previousEnd = range.upperBound
      case .unplaceable:
        let nextStart =
          passages[(index + 1)...].lazy.compactMap { p -> Int? in
            if case .placed(let r) = p.placement { return r.lowerBound }
            return nil
          }.first ?? raw.count
        for turn in turnsOverlapping(previousEnd..<max(previousEnd, nextStart)) {
          fail(turn.id, .unplaced)
        }
      }
    }

    // 2. Each placed passage: align, attribute, cut.
    for (passageIndex, passage) in passages.enumerated() {
      guard case .placed(let passageRange) = passage.placement else { continue }
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
      /// Whether the deleted boundary word `ai` has the same key as the neighbouring turn's
      /// adjacent word: its last word when looking backwards, its first when forwards.
      func repeatsAcross(_ ai: Int, into neighbour: Turn, before: Bool) -> Bool {
        let key = a[ai].key
        let candidates = a.indices.filter { overlappingTurn(absolute[$0], is: neighbour) }
        guard let adjacent = before ? candidates.last : candidates.first else {
          // The neighbour's words are outside this passage: treat as a repeat (unknown).
          return true
        }
        return a[adjacent].key == key
      }
      func overlappingTurn(_ range: Range<Int>, is turn: Turn) -> Bool {
        turn.originalTextRange.overlaps(range)
      }
      func failAllTouching(_ ai: Int, _ reason: Fallback) {
        for turn in overlapping where turn.originalTextRange.overlaps(absolute[ai]) {
          fail(turn.id, reason)
        }
      }

      var attributed: [(turnID: String, text: String)] = []
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
            for bi in inserts { attributed.append((target.id, b[bi].text + b[bi].trailing)) }
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
          if absolute[ai].lowerBound == turn.originalTextRange.lowerBound,
            let n = neighbour(of: turn, before: true), repeatsAcross(ai, into: n, before: true)
          {
            trustworthy = false
            touched.insert(n.id)
          }
          if absolute[ai].upperBound == turn.originalTextRange.upperBound,
            let n = neighbour(of: turn, before: false),
            repeatsAcross(ai, into: n, before: false)
          {
            trustworthy = false
            touched.insert(n.id)
          }
        }
        guard trustworthy, owners.count == 1, let turnID = owners.first else {
          for id in touched { fail(id, .boundary) }
          continue
        }
        for bi in inserts { attributed.append((turnID, b[bi].text + b[bi].trailing)) }
        lastOwner = ordered[indexByID[turnID]!]
      }

      // The passage original's leading whitespace is layout `tokenize` drops (its first
      // token starts after it); it belongs BETWEEN a turn's pieces when the turn continues
      // from the previous passage, and is trimmed away when the turn starts here.
      let leading = String(original.prefix { $0.isWhitespace })
      var perTurn: [String: String] = [:]
      var order: [String] = []
      for (turnID, text) in attributed {
        if perTurn[turnID] == nil {
          order.append(turnID)
          perTurn[turnID] = leading
        }
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
          case .placed(let prev) = passages[previousIndex].placement,
          case .placed(let next) = passages[passageIndex].placement,
          prev.upperBound <= next.lowerBound
        {
          joined += String(decoding: raw[prev.upperBound..<next.lowerBound], as: UTF16.self)
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
