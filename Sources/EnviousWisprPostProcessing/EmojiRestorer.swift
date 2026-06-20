import Foundation

/// Deterministic post-polish emoji restore (#761). The Apple on-device (AFM)
/// polish step strips ~70-90% of the emoji glyphs the deterministic
/// `EmojiFormatter` inserts BEFORE polish. This type compares the pre-polish
/// text (emoji-bearing) against the polish output (stripped) and re-inserts the
/// dropped glyphs at their original anchor — never repositioning emoji the model
/// kept.
///
/// Pure value type: no model, no network, no I/O, never throws. Restores
/// deletions ONLY: an emoji the model kept (even if it moved it) nets to zero
/// dropped, so the guard leaves it untouched. Zero dropped → the polished text
/// is returned byte-for-byte.
///
/// Algorithm — token-level alignment, not positional rules:
///   1. Tokenize both texts into WORD streams (punctuation excluded — polish
///      remaps it freely, so it is a poor anchor; content words survive).
///   2. LCS-align the two word streams. The match is monotonic, so the Nth
///      occurrence of a repeated word maps to the corresponding occurrence —
///      this is what makes sentence splits, merges, reorders, and repeated
///      anchors fall out of one mechanism instead of special-casing each.
///   3. For each dropped emoji, anchor to its neighbor word's aligned image: it
///      hugs the side it is NOT separated from by punctuation (comma/period on
///      the right → trails the left word; punctuation on the left → leads the
///      right word). If that anchor was deleted by polish, fall back to the
///      nearest surviving word, first within the emoji's own sentence.
/// A contiguous run of dropped glyphs (whitespace-only gaps in the pre-polish
/// text) is re-inserted as ONE verbatim slice, preserving the internal spacing
/// the speaker dictated. Validated on 300 real on-device cases at 100% emoji
/// retention; design notes + head-to-head vs the prior positional placer:
/// `docs/feature-requests/issue-761-2026-06-19-emoji-guard-design-notes.md`.
public struct EmojiRestorer: Sendable {

  /// Restore outcome. Counts only — used for telemetry (`telemetry-privacy-boundary`:
  /// never carries glyphs or transcript text).
  public struct Result: Sendable {
    /// The polished text with dropped emoji re-inserted (== `polished` when
    /// nothing was dropped).
    public let text: String
    /// Emoji clusters present in the pre-polish text.
    public let emojiInInput: Int
    /// Clusters present pre-polish but absent post-polish (the restore targets).
    public let dropped: Int
    /// Clusters actually re-inserted. Equals `dropped` by construction; a value
    /// below `dropped` is an anomaly the caller surfaces to Sentry.
    public let restored: Int
  }

  public init() {}

  // MARK: - Emoji detection (BASE ranges)

  private static func isEmoji(_ c: Character) -> Bool {
    guard let s = c.unicodeScalars.first else { return false }
    let v = s.value
    return (0x1F000...0x1FAFF).contains(v)
      || (0x2600...0x27BF).contains(v)
      || (0x2B00...0x2BFF).contains(v)
      || (0x2190...0x21FF).contains(v)
      || (0x2300...0x23FF).contains(v)
  }

  /// Normalize a glyph for kept-vs-dropped matching: strip VS16 + skin tone so
  /// `❤️`==`❤` and `👍🏽`==`👍`. Restore stays verbatim.
  private static func matchKey(_ glyph: String) -> String {
    var out = String.UnicodeScalarView()
    for s in glyph.unicodeScalars {
      if s.value == 0xFE0F { continue }
      if (0x1F3FB...0x1F3FF).contains(s.value) { continue }
      out.append(s)
    }
    return String(out)
  }

  private static func isWordChar(_ c: Character) -> Bool {
    (c.isLetter || c.isNumber) && !isEmoji(c)
  }
  private static func isEnder(_ c: Character) -> Bool { c == "." || c == "!" || c == "?" }

  /// Symbols that bind to the token on their LEFT (no space before them); a
  /// trailing emoji must land AFTER the whole token, not inside it (`12.5% 🔥`).
  private static let boundTrailingSymbols: Set<Character> = ["%", "°", "+", "#", "*", "‰"]
  /// Punctuation that takes no space before it when an emoji is inserted ahead.
  private static let noSpaceBefore: Set<Character> = [
    ".", ",", "!", "?", ";", ":", ")", "]", "}", "%", "°", "'", "\u{2019}", "\u{2026}",
  ]

  private struct WTok {
    let key: String
    let start: Int
    let end: Int
  }

  /// Word tokens (alphanumeric runs, one internal apostrophe) with char spans.
  /// Punctuation is excluded — polish remaps it freely, so it is a poor anchor;
  /// content words survive restructuring.
  private static func wordTokens(_ chars: [Character]) -> [WTok] {
    var out: [WTok] = []
    var i = 0
    let n = chars.count
    while i < n {
      guard isWordChar(chars[i]) else {
        i += 1
        continue
      }
      let start = i
      while i < n, isWordChar(chars[i]) { i += 1 }
      if i < n, chars[i] == "'" || chars[i] == "\u{2019}", i + 1 < n, isWordChar(chars[i + 1]) {
        i += 1
        while i < n, isWordChar(chars[i]) { i += 1 }
      }
      out.append(WTok(key: String(chars[start..<i]).lowercased(), start: start, end: i))
    }
    return out
  }

  /// LCS alignment: for each pre word token, the matched post word index or nil.
  /// Monotonic by construction — the Nth occurrence of a repeated word maps to
  /// the corresponding occurrence, which is what kills the repeated-anchor bug.
  private static func alignWords(_ pre: [WTok], _ post: [WTok]) -> [Int?] {
    let n = pre.count
    let m = post.count
    var matchPost = [Int?](repeating: nil, count: n)
    if n == 0 || m == 0 { return matchPost }
    // dp[i][j] = LCS length of pre[i...] vs post[j...]
    var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
    var i = n - 1
    while i >= 0 {
      var j = m - 1
      while j >= 0 {
        if pre[i].key == post[j].key {
          dp[i][j] = dp[i + 1][j + 1] + 1
        } else {
          dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
        }
        j -= 1
      }
      i -= 1
    }
    var a = 0
    var b = 0
    while a < n && b < m {
      if pre[a].key == post[b].key {
        matchPost[a] = b
        a += 1
        b += 1
      } else if dp[a + 1][b] >= dp[a][b + 1] {
        a += 1
      } else {
        b += 1
      }
    }
    return matchPost
  }

  /// Advance past symbols bound to the token at `e` (`%`, `°`, …) and across a
  /// hyphenated continuation (`medium-high`) so a trailing emoji lands after the
  /// whole compound, never wedged inside it.
  private static func tokenEnd(_ chars: [Character], _ e: Int) -> Int {
    var p = e
    while p < chars.count {
      if boundTrailingSymbols.contains(chars[p]) {
        p += 1
        continue
      }
      if chars[p] == "-" || chars[p] == "\u{2011}", p + 1 < chars.count, isWordChar(chars[p + 1]) {
        p += 1
        while p < chars.count, isWordChar(chars[p]) { p += 1 }
        continue
      }
      break
    }
    return p
  }

  /// Contiguous PRE sentence spans, split on runs of `.!?`. A `.` flanked by
  /// alphanumerics on both sides (URLs, decimals) does not split. Spans cover
  /// `[0, n)` with no gaps so every char (incl. inter-sentence space) has a home.
  private static func sentenceSpans(_ chars: [Character]) -> [(lo: Int, hi: Int)] {
    var spans: [(lo: Int, hi: Int)] = []
    var lo = 0
    var i = 0
    let n = chars.count
    while i < n {
      if isEnder(chars[i]) {
        let dotGuarded =
          chars[i] == "." && i > 0 && i + 1 < n && isWordChar(chars[i - 1])
          && isWordChar(chars[i + 1])
        if !dotGuarded {
          var j = i + 1
          while j < n, isEnder(chars[j]) { j += 1 }
          spans.append((lo, j))
          lo = j
          i = j
          continue
        }
      }
      i += 1
    }
    if lo < n { spans.append((lo, n)) }
    return spans
  }

  // MARK: - Public entry

  /// Re-insert into `polished` every emoji `prePolish` carried that `polished`
  /// lost. Pure; never throws.
  public func restore(polished: String, prePolish: String) -> Result {
    let pre = Array(prePolish)
    let post = Array(polished)

    var preEmoji: [(idx: Int, glyph: String)] = []
    for (i, c) in pre.enumerated() where Self.isEmoji(c) { preEmoji.append((i, String(c))) }
    let emojiInInput = preEmoji.count
    if emojiInInput == 0 {
      return Result(text: polished, emojiInInput: 0, dropped: 0, restored: 0)
    }

    let preWords = Self.wordTokens(pre)
    let postWords = Self.wordTokens(post)

    // The lowercased word immediately left of char index `idx`, or "" if none.
    func leftKey(_ words: [WTok], _ idx: Int) -> String {
      var ans = ""
      for w in words {
        if w.end <= idx { ans = w.key } else { break }
      }
      return ans
    }

    // Kept vs dropped, ANCHOR-AWARE. A surviving glyph is matched to the
    // pre-occurrence sharing its left-neighbor word FIRST, so when polish keeps a
    // LATER repeat of a glyph and drops an EARLIER one, the earlier (not the
    // surviving-looking earlier) is flagged dropped — never stacked beside the
    // kept one. Glyphs whose anchor word polish changed fall through to a plain
    // match-key match (a moved-but-kept emoji nets to zero).
    var postGlyphs: [(key: String, leftKey: String, consumed: Bool)] = []
    for (i, c) in post.enumerated() where Self.isEmoji(c) {
      postGlyphs.append((Self.matchKey(String(c)), leftKey(postWords, i), false))
    }
    var droppedFlags = [Bool](repeating: true, count: preEmoji.count)
    for (k, e) in preEmoji.enumerated() {
      let key = Self.matchKey(e.glyph)
      let lk = leftKey(preWords, e.idx)
      if let j = postGlyphs.firstIndex(where: { !$0.consumed && $0.key == key && $0.leftKey == lk })
      {
        postGlyphs[j].consumed = true
        droppedFlags[k] = false
      }
    }
    for (k, e) in preEmoji.enumerated() where droppedFlags[k] {
      let key = Self.matchKey(e.glyph)
      if let j = postGlyphs.firstIndex(where: { !$0.consumed && $0.key == key }) {
        postGlyphs[j].consumed = true
        droppedFlags[k] = false
      }
    }
    let droppedCount = droppedFlags.filter { $0 }.count
    if droppedCount == 0 {
      return Result(text: polished, emojiInInput: emojiInInput, dropped: 0, restored: 0)
    }

    // Group contiguous dropped clusters (whitespace-only gaps) into verbatim runs.
    struct Run {
      var glyphs: String
      var startIdx: Int
      var endIdx: Int
    }
    var runs: [Run] = []
    var k = 0
    while k < preEmoji.count {
      if !droppedFlags[k] {
        k += 1
        continue
      }
      let startIdx = preEmoji[k].idx
      var glyph = preEmoji[k].glyph
      var lastIdx = preEmoji[k].idx
      var kk = k + 1
      while kk < preEmoji.count, droppedFlags[kk] {
        let between = pre[(lastIdx + 1)..<preEmoji[kk].idx]
        if between.allSatisfy({ $0.isWhitespace }) {
          glyph += String(between) + preEmoji[kk].glyph
          lastIdx = preEmoji[kk].idx
          kk += 1
        } else {
          break
        }
      }
      runs.append(Run(glyphs: glyph, startIdx: startIdx, endIdx: lastIdx + 1))
      k = kk
    }

    let matchPost = Self.alignWords(preWords, postWords)

    func postImageStart(_ i: Int) -> Int? { matchPost[i].map { postWords[$0].start } }
    func postImageEnd(_ i: Int) -> Int? { matchPost[i].map { postWords[$0].end } }

    let preSentences = Self.sentenceSpans(pre)
    func sentenceOf(_ p: Int) -> (lo: Int, hi: Int) {
      for s in preSentences where p >= s.lo && p < s.hi { return s }
      return (0, pre.count)
    }

    // Nearest PRE word, restricted to the emoji's own sentence [lo, hi).
    func leftWordIn(_ p: Int, _ lo: Int) -> Int? {
      var ans: Int? = nil
      for (idx, w) in preWords.enumerated() {
        if w.start < lo { continue }
        if w.end <= p { ans = idx } else { break }
      }
      return ans
    }
    func rightWordIn(_ p: Int, _ hi: Int) -> Int? {
      for (idx, w) in preWords.enumerated() where w.start >= p && w.end <= hi { return idx }
      return nil
    }

    // Is the char immediately left of the run (skipping spaces) a real separator
    // the emoji follows? A comma / period there means the emoji LEADS the next
    // word; otherwise it trails the word it was dictated after. Bound symbols
    // (`%`, `°`) read as part of the preceding token, not a separator.
    func leftSeparator(_ start: Int) -> Bool {
      var i = start - 1
      while i >= 0, pre[i].isWhitespace { i -= 1 }
      guard i >= 0 else { return false }
      let c = pre[i]
      return !Self.isWordChar(c) && !Self.isEmoji(c) && !Self.boundTrailingSymbols.contains(c)
    }

    // Is the char immediately right of the run (skipping spaces) a sentence
    // ender in the PRE text? If so the emoji genuinely trails — a POST period
    // there is real, not a model insertion.
    func preEnderRight(_ end: Int) -> Bool {
      var i = end
      while i < pre.count, pre[i].isWhitespace { i += 1 }
      guard i < pre.count else { return false }
      return Self.isEnder(pre[i])
    }

    // Resolve the char position in `post` where a run should be inserted.
    func resolvePos(_ run: Run) -> Int {
      let sent = sentenceOf(run.startIdx)
      let leftW = leftWordIn(run.startIdx, sent.lo)
      let rightW = rightWordIn(run.endIdx, sent.hi)

      // Hug the LEFT word (the one dictated before the emoji) unless a separator
      // sits immediately to the emoji's left — a comma / period it follows — in
      // which case it leads the RIGHT word instead.
      let hugLeft = !leftSeparator(run.startIdx)

      // Follow a model-INSERTED sentence break: when the emoji floats between two
      // words that BOTH survive and PRE had no ender right after it, a POST ender
      // at the seam was inserted by polish — the emoji leads the new sentence, so
      // a left-anchored placement skips past it ("review 👍" → "review? 👍").
      // Not when the right word was deleted (then the emoji genuinely trails the
      // left clause) nor when PRE already had the ender (a real trailing emoji).
      let rightSurvives = rightW.flatMap { postImageStart($0) } != nil
      let followBreak = rightSurvives && !preEnderRight(run.endIdx)
      func afterLeft(_ e: Int) -> Int {
        var pos = Self.tokenEnd(post, e)
        if followBreak { while pos < post.count, Self.isEnder(post[pos]) { pos += 1 } }
        return pos
      }

      // Primary anchor on the hug side.
      if hugLeft {
        if let l = leftW, let e = postImageEnd(l) { return afterLeft(e) }
      } else {
        if let r = rightW, let s = postImageStart(r) { return s }
        // Hug-right but no right word in the sentence → trailing; fall to left.
        if rightW == nil, let l = leftW, let e = postImageEnd(l) { return afterLeft(e) }
      }

      // Fallback: the hug-side anchor was deleted by polish. Walk outward by char
      // distance, FIRST within the emoji's own PRE sentence, then across the
      // whole text — left word → after its image, right word → before its image.
      func scan(_ lo: Int, _ hi: Int) -> Int? {
        var cands: [(idx: Int, left: Bool, dist: Int)] = []
        for (idx, w) in preWords.enumerated() where w.start >= lo && w.end <= hi {
          if w.end <= run.startIdx {
            cands.append((idx, true, run.startIdx - w.end))
          } else if w.start >= run.endIdx {
            cands.append((idx, false, w.start - run.endIdx))
          }
        }
        // Nearest first; on a tie prefer the hug side.
        cands.sort {
          $0.dist != $1.dist ? $0.dist < $1.dist : ($0.left == hugLeft && $1.left != hugLeft)
        }
        for c in cands {
          if c.left, let e = postImageEnd(c.idx) { return afterLeft(e) }
          if !c.left, let s = postImageStart(c.idx) { return s }
        }
        return nil
      }
      return scan(sent.lo, sent.hi) ?? scan(0, pre.count) ?? post.count
    }

    var insertions: [(pos: Int, glyph: String)] = []
    for run in runs { insertions.append((resolvePos(run), run.glyphs)) }
    // Stable sort by position; equal positions keep run order (left-to-right).
    let ordered = insertions.enumerated().sorted {
      $0.element.pos != $1.element.pos ? $0.element.pos < $1.element.pos : $0.offset < $1.offset
    }.map { $0.element }

    var result: [Character] = []
    var cursor = 0
    for ins in ordered {
      let p = max(cursor, min(ins.pos, post.count))
      result.append(contentsOf: post[cursor..<p])
      var piece = ""
      if let lc = result.last, !lc.isWhitespace { piece += " " }
      piece += ins.glyph
      let rightChar = p < post.count ? post[p] : nil
      if let rc = rightChar, !rc.isWhitespace, !Self.noSpaceBefore.contains(rc) { piece += " " }
      result.append(contentsOf: Array(piece))
      cursor = p
    }
    result.append(contentsOf: post[cursor..<post.count])

    return Result(
      text: String(result), emojiInInput: emojiInInput, dropped: droppedCount,
      restored: droppedCount)
  }
}
