import Foundation

/// Deterministic post-polish emoji restore (#761). The Apple on-device (AFM)
/// polish step strips ~70-90% of the emoji glyphs the deterministic
/// `EmojiFormatter` inserts BEFORE polish. This type compares the pre-polish
/// text (emoji-bearing) against the polish output (stripped) and re-inserts the
/// dropped glyphs at their correct position — never repositioning emoji the
/// model kept.
///
/// Pure value type: no model, no network, no I/O, never throws. Position-aware
/// placement (v2 algorithm) validated on 300 real on-device cases — 100% emoji
/// retention, 97% landed on the exact anchor word on messy self-correction
/// dictation. Design + empirical case:
/// `docs/feature-requests/issue-761-2026-06-19-emoji-guard-design-notes.md`.
///
/// Algorithm (per dropped glyph, or contiguous run of dropped glyphs):
///   1. Classify it as lead / trail / mid of its pre-polish sentence.
///   2. Anchor it to a CONTENT word (skipping fillers) found in the ALIGNED
///      output sentence — polish keeps content words, drops filler, so the
///      anchor survives sentence restructuring.
///   3. Fall back to the matching sentence boundary (lead → start, trail → end)
///      when no anchor word survives.
/// A contiguous run of dropped glyphs (separated only by whitespace in the
/// pre-polish text) is re-inserted as ONE verbatim slice, preserving the
/// internal spacing the speaker dictated. Restores deletions ONLY: an emoji the
/// model kept (even if it moved it) nets to zero dropped, so the guard leaves it
/// untouched. Zero dropped → the polished text is returned byte-for-byte.
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

  // MARK: - Public entry

  /// Re-insert into `polished` every emoji `prePolish` carried that `polished`
  /// lost. Pure; never throws.
  public func restore(polished: String, prePolish: String) -> Result {
    let before = Array(prePolish)
    let after = Array(polished)

    let beforeClusters = Self.emojiClusters(before)
    let afterClusters = Self.emojiClusters(after)
    let emojiInInput = beforeClusters.count

    let beforeSentences = Self.sentenceSpans(before)
    let afterSentences = Self.sentenceSpans(after)

    // Detection — match each KEPT after-occurrence to the before-occurrence that
    // shares its left content-word anchor (else first-unmatched). This preserves
    // the per-glyph multiset count AND fixes the repeated-glyph case where AFM
    // keeps a LATER instance and drops an earlier one: a pure prefix-count match
    // would mis-flag the earlier (surviving-looking) occurrence as dropped and
    // stack the restored glyph next to the kept one. Anchoring flags the
    // genuinely-missing occurrence instead. `droppedFlags` starts all-true; each
    // matched kept occurrence flips one before-occurrence to false.
    // Glyphs are grouped by a variant-normalized key (presentation selector /
    // skin-tone stripped) so AFM normalizing ❤️ (VS16) → ❤ reads as "kept", not
    // "dropped ❤️ + new ❤" (which would DUPLICATE it). The restored glyph is
    // still the verbatim pre-polish form — only the kept-vs-dropped match uses
    // the key.
    var droppedFlags = [Bool](repeating: true, count: beforeClusters.count)
    var beforeIdxByGlyph: [String: [Int]] = [:]
    for (i, c) in beforeClusters.enumerated() {
      beforeIdxByGlyph[Self.matchKey(c.glyph), default: []].append(i)
    }
    for ac in afterClusters {
      guard let idxs = beforeIdxByGlyph[Self.matchKey(ac.glyph)] else { continue }
      let afterAnchor = Self.leftContentWord(after, afterSentences, ac.index)
      let chosen =
        idxs.first(where: {
          droppedFlags[$0]
            && Self.leftContentWord(before, beforeSentences, beforeClusters[$0].index)
              == afterAnchor
        }) ?? idxs.first(where: { droppedFlags[$0] })
      if let chosen { droppedFlags[chosen] = false }  // this occurrence survived
    }
    let droppedCount = droppedFlags.filter { $0 }.count

    // No-op fast paths — return the polished text UNCHANGED so emoji the model
    // kept (and any whitespace it chose) are never disturbed.
    guard droppedCount > 0 else {
      return Result(text: polished, emojiInInput: emojiInInput, dropped: 0, restored: 0)
    }

    // Group dropped clusters into contiguous runs (adjacent in the pre-polish
    // text, separated only by whitespace). Each run is one verbatim insertion.
    let runs = Self.droppedRuns(
      before: before, clusters: beforeClusters, droppedFlags: droppedFlags)

    var jobs: [InsertJob] = []
    for run in runs {
      let job = Self.placeRun(
        run: run,
        before: before, after: after,
        beforeSentences: beforeSentences, afterSentences: afterSentences)
      jobs.append(job)
    }

    // Splice insertions into the output, left to right. `before` insertions sort
    // ahead of `after` insertions at the same position.
    jobs.sort {
      ($0.position, $0.side == .before ? 0 : 1) < ($1.position, $1.side == .before ? 0 : 1)
    }

    var out = ""
    var restored = 0
    var last = 0
    for job in jobs {
      if job.position > last {
        out += String(after[last..<job.position])
        last = job.position
      } else if job.position < last {
        // Defensive: two jobs that resolved out of order — never observed, but
        // clamp rather than slice backwards.
        // (last already past this position; insert at the cursor.)
      }
      out += Self.spaced(
        glyph: job.glyph,
        prev: out.last,
        next: job.position < after.count ? after[job.position] : nil)
      restored += job.glyphClusterCount
    }
    out += String(after[last...])

    return Result(
      text: out, emojiInInput: emojiInInput, dropped: droppedCount, restored: restored)
  }

  // MARK: - Placement

  private enum Side { case before, after }

  private struct InsertJob {
    /// Verbatim slice from the pre-polish text (one or more glyphs + their
    /// original internal spacing).
    let glyph: String
    /// Number of emoji clusters in `glyph` (for the restored count).
    let glyphClusterCount: Int
    /// Index into the `after` Character array to insert at.
    let position: Int
    /// Which side of `position` the glyph sits (orders same-position inserts).
    let side: Side
  }

  /// A maximal run of consecutive dropped clusters separated only by whitespace.
  private struct Run {
    let startIndex: Int  // char index of the run's first glyph
    let endIndex: Int  // char index just past the run's last glyph
    let clusterCount: Int
  }

  /// Decide where a dropped run lands in the polished text.
  private static func placeRun(
    run: Run,
    before: [Character], after: [Character],
    beforeSentences: [(lo: Int, hi: Int)], afterSentences: [(lo: Int, hi: Int)]
  ) -> InsertJob {
    let glyph = String(before[run.startIndex..<run.endIndex])
      .trimmingCharacters(in: .whitespaces)

    // Which pre-polish sentence does the run sit in, and the output char range it
    // maps to. Polish often SPLITS one dictated run-on into several sentences, so
    // the range can span multiple output sentences — without this the anchor
    // search is scoped to only the first split and a later-clause emoji lands in
    // the wrong sentence.
    let si =
      beforeSentences.firstIndex(where: { run.startIndex >= $0.lo && run.startIndex < $0.hi })
      ?? (beforeSentences.count - 1)
    let aSpan = afterBlock(
      before: before, after: after,
      beforeSentences: beforeSentences, afterSentences: afterSentences, si: si)

    let sentenceWords = words(before, beforeSentences[si].lo, beforeSentences[si].hi)
    let first = sentenceWords.first
    let last = sentenceWords.last

    let positionType: PositionType
    if let first, run.startIndex < first.end {
      positionType = .lead
    } else if let last, run.startIndex >= last.end {
      positionType = .trail
    } else {
      positionType = .mid
    }

    switch positionType {
    case .lead:
      // Anchor before the first surviving content word; fall back to the
      // sentence start.
      for w in contentWords(sentenceWords) {
        let spans = findWordSpans(after, w.text, aSpan.lo, aSpan.hi)
        if let firstSpan = spans.first {
          return InsertJob(
            glyph: glyph, glyphClusterCount: run.clusterCount,
            position: firstSpan.start, side: .before)
        }
      }
      return InsertJob(
        glyph: glyph, glyphClusterCount: run.clusterCount, position: aSpan.lo, side: .before)

    case .trail:
      // Anchor after the last surviving content word, then extend past any symbol
      // bound to it (%, °, +, …) so a trailing emoji lands after the WHOLE token
      // ("12.5% 🔥", not "12.5 🔥 %"). Stop at whitespace or clause/closing
      // punctuation so it never jumps a comma into the next clause. Fall back to
      // just before the sentence-ending punctuation.
      for w in contentWords(sentenceWords).reversed() {
        let spans = findWordSpans(after, w.text, aSpan.lo, aSpan.hi)
        if let lastSpan = spans.last {
          return InsertJob(
            glyph: glyph, glyphClusterCount: run.clusterCount,
            position: tokenEnd(after, lastSpan.end, aSpan.hi), side: .after)
        }
      }
      let punctStart = lastSentenceEnderStart(after, aSpan.lo, aSpan.hi)
      return InsertJob(
        glyph: glyph, glyphClusterCount: run.clusterCount, position: punctStart, side: .before)

    case .mid:
      // Anchor to the nearest surviving content word on the left (insert after),
      // disambiguating by the right neighbour; else the right word (insert
      // before); else the sentence-end fallback.
      let leftWords = sentenceWords.filter { $0.end <= run.startIndex }
      let rightWords = sentenceWords.filter { $0.start >= run.endIndex }
      if let lw = leftWords.last {
        let spans = findWordSpans(after, lw.text, aSpan.lo, aSpan.hi)
        if !spans.isEmpty {
          var chosen = spans[spans.count - 1]
          if let rw = rightWords.first {
            for cand in spans {
              let windowEnd = min(cand.end + 40, after.count)
              let window = String(after[cand.end..<windowEnd]).lowercased()
              if window.contains(rw.text.lowercased()) {
                chosen = cand
                break
              }
            }
          }
          // If the model turned the clause into its own sentence right after the
          // anchor (inserted ? / . / !), follow the break so a question reads
          // "review? 👍 Link", not "review 👍? Link". Only a sentence-ender run
          // is jumped — a comma stays a clause separator (handled by `tokenEnd`).
          var pos = tokenEnd(after, chosen.end, aSpan.hi)
          while pos < aSpan.hi, sentenceEnders.contains(after[pos]) { pos += 1 }
          return InsertJob(
            glyph: glyph, glyphClusterCount: run.clusterCount, position: pos, side: .after)
        }
      }
      if let rw = rightWords.first {
        let spans = findWordSpans(after, rw.text, aSpan.lo, aSpan.hi)
        if let firstSpan = spans.first {
          return InsertJob(
            glyph: glyph, glyphClusterCount: run.clusterCount,
            position: firstSpan.start, side: .before)
        }
      }
      let punctStart = lastSentenceEnderStart(after, aSpan.lo, aSpan.hi)
      return InsertJob(
        glyph: glyph, glyphClusterCount: run.clusterCount, position: punctStart, side: .before)
    }
  }

  private enum PositionType { case lead, trail, mid }

  // MARK: - Spacing

  /// Build the spaced replacement for one insertion. Mirrors
  /// `EmojiFormatter.spliceReplacement`: a single space against an alphanumeric
  /// neighbour, no space inside brackets/quotes or before closing punctuation.
  private static func spaced(glyph: String, prev: Character?, next: Character?) -> String {
    let lead = needsLeadingSpace(after: prev)
    let trail = needsTrailingSpace(before: next)
    return (lead ? " " : "") + glyph + (trail ? " " : "")
  }

  private static let noSpaceAfter: Set<Character> = ["(", "[", "{", "\"", "\u{201C}", "\u{2018}"]
  private static let noSpaceBefore: Set<Character> = [
    ".", "!", "?", ",", ";", ":", ")", "]", "}", "\"", "\u{201D}", "\u{2019}", "\u{2014}",
    "\u{2013}",
  ]

  private static func needsLeadingSpace(after prev: Character?) -> Bool {
    guard let prev else { return false }  // start of string
    if prev.isWhitespace { return false }
    return !noSpaceAfter.contains(prev)
  }

  private static func needsTrailingSpace(before next: Character?) -> Bool {
    guard let next else { return false }  // end of string
    if next.isWhitespace { return false }
    return !noSpaceBefore.contains(next)
  }

  // MARK: - Emoji detection

  /// Emoji base-scalar ranges (mirror the validated prototype's `BASE`):
  /// pictographs/emoji, misc symbols, arrows, technical, dingbats. A Swift
  /// `Character` already groups VS16 / skin-tone / ZWJ sequences into one
  /// grapheme, so a single Character is one cluster.
  private static func isEmoji(_ c: Character) -> Bool {
    guard let first = c.unicodeScalars.first else { return false }
    let v = first.value
    return (0x1F000...0x1FAFF).contains(v)
      || (0x2600...0x27BF).contains(v)
      || (0x2B00...0x2BFF).contains(v)
      || (0x2190...0x21FF).contains(v)
      || (0x2300...0x23FF).contains(v)
  }

  /// Kept-vs-dropped match key: the glyph with presentation selectors (VS16) and
  /// skin-tone modifiers stripped, so AFM normalizing a variant (❤️ → ❤,
  /// 👍🏽 → 👍) reads as the SAME glyph and is not double-restored. Identity only —
  /// the restored glyph is always the verbatim pre-polish form.
  private static func matchKey(_ glyph: String) -> String {
    String(
      String.UnicodeScalarView(
        glyph.unicodeScalars.filter {
          $0.value != 0xFE0F && !(0x1F3FB...0x1F3FF).contains($0.value)
        }
      ))
  }

  private struct Cluster {
    let glyph: String
    let index: Int  // char index in the source array
  }

  private static func emojiClusters(_ chars: [Character]) -> [Cluster] {
    var out: [Cluster] = []
    for (i, c) in chars.enumerated() where isEmoji(c) {
      out.append(Cluster(glyph: String(c), index: i))
    }
    return out
  }

  /// Group dropped clusters that are adjacent in the pre-polish text (only
  /// whitespace between consecutive dropped glyphs) into maximal runs.
  private static func droppedRuns(
    before: [Character], clusters: [Cluster], droppedFlags: [Bool]
  ) -> [Run] {
    var runs: [Run] = []
    var i = 0
    while i < clusters.count {
      guard droppedFlags[i] else {
        i += 1
        continue
      }
      let runStart = clusters[i].index
      var lastEnd = clusters[i].index + 1
      var count = 1
      var j = i + 1
      while j < clusters.count, droppedFlags[j] {
        // Only whitespace may separate consecutive run members.
        let gap = before[lastEnd..<clusters[j].index]
        if gap.allSatisfy({ $0.isWhitespace }) {
          lastEnd = clusters[j].index + 1
          count += 1
          j += 1
        } else {
          break
        }
      }
      runs.append(Run(startIndex: runStart, endIndex: lastEnd, clusterCount: count))
      i = j
    }
    return runs
  }

  // MARK: - Sentence / word segmentation

  private static let sentenceEnders: Set<Character> = [".", "!", "?"]

  /// Split on maximal runs of sentence-ending punctuation; each sentence ends
  /// at the end of its terminating run. A trailing fragment is its own sentence.
  /// A `.` flanked by alphanumerics on BOTH sides is an intra-token dot (URL
  /// `example.com`, decimal `3.50`) — NOT a sentence boundary — so the anchor
  /// search isn't mis-scoped to a fragment.
  private static func sentenceSpans(_ chars: [Character]) -> [(lo: Int, hi: Int)] {
    var spans: [(lo: Int, hi: Int)] = []
    var start = 0
    var i = 0
    let n = chars.count
    while i < n {
      if sentenceEnders.contains(chars[i]) {
        var j = i
        while j < n, sentenceEnders.contains(chars[j]) { j += 1 }
        let beforeIsWord = i > 0 && isWordChar(chars[i - 1])
        let afterIsWord = j < n && isWordChar(chars[j])
        if beforeIsWord && afterIsWord {
          i = j  // intra-token dot — keep scanning the same sentence
        } else {
          spans.append((lo: start, hi: j))
          start = j
          i = j
        }
      } else {
        i += 1
      }
    }
    if start < n { spans.append((lo: start, hi: n)) }
    return spans.isEmpty ? [(lo: 0, hi: n)] : spans
  }

  private struct Word {
    let text: String
    let start: Int
    let end: Int
  }

  private static func isWordChar(_ c: Character) -> Bool {
    c.isLetter || c.isNumber
  }

  /// Words in `[lo, hi)`: alphanumeric runs, optionally carrying one internal
  /// apostrophe (`it's`, `we're`).
  private static func words(_ chars: [Character], _ lo: Int, _ hi: Int) -> [Word] {
    var out: [Word] = []
    var i = lo
    let bound = min(hi, chars.count)
    while i < bound {
      guard isWordChar(chars[i]) else {
        i += 1
        continue
      }
      let start = i
      while i < bound, isWordChar(chars[i]) { i += 1 }
      // One internal apostrophe joined to more word chars.
      if i < bound, chars[i] == "'" || chars[i] == "\u{2019}", i + 1 < bound,
        isWordChar(chars[i + 1])
      {
        i += 1
        while i < bound, isWordChar(chars[i]) { i += 1 }
      }
      out.append(Word(text: String(chars[start..<i]), start: start, end: i))
    }
    return out
  }

  private static let fillers: Set<String> = [
    "um", "uh", "er", "ah", "so", "well", "okay", "ok", "like", "yeah", "oh", "hmm", "mm",
  ]

  /// Drop filler words so the anchor latches onto something polish preserves;
  /// if a sentence is ALL filler, keep them all (better an anchor than none).
  private static func contentWords(_ ws: [Word]) -> [Word] {
    let content = ws.filter { !fillers.contains($0.text.lowercased()) }
    return content.isEmpty ? ws : content
  }

  /// The output char range a pre-polish sentence maps to. Polish frequently
  /// SPLITS one dictated run-on into several sentences; the range then spans all
  /// of them, located by where the NEXT dictated sentence's first content word
  /// appears in the output. `lo` stays the index-aligned sentence start (keeps
  /// leading-emoji behavior); `hi` extends across the split block so a trailing /
  /// later-clause emoji's anchor is searched in the right sentence.
  private static func afterBlock(
    before: [Character], after: [Character],
    beforeSentences: [(lo: Int, hi: Int)], afterSentences: [(lo: Int, hi: Int)], si: Int
  ) -> (lo: Int, hi: Int) {
    func firstContentWordPos(_ i: Int, from searchLo: Int) -> Int? {
      for w in contentWords(words(before, beforeSentences[i].lo, beforeSentences[i].hi)) {
        if let f = findWordSpans(after, w.text, searchLo, after.count).first { return f.start }
      }
      return nil
    }
    let aligned = afterSentences[min(si, afterSentences.count - 1)]
    let lo = aligned.lo
    let hi: Int
    if si + 1 < beforeSentences.count {
      // Bound by where the next dictated sentence's content begins — searched
      // from AFTER this sentence's index-aligned region so a word that repeats
      // INSIDE this sentence (e.g. "the", "report") can't mis-bound the block to
      // the middle of it. Else the conservative index-aligned sentence end.
      let nextLo = firstContentWordPos(si + 1, from: aligned.hi) ?? aligned.hi
      hi = nextLo > lo ? nextLo : aligned.hi
    } else {
      hi = after.count  // the last (or only) dictated sentence owns the rest.
    }
    return (lo, hi)
  }

  /// The lowercased content word immediately to the LEFT of the cluster at `idx`,
  /// scoped to its sentence, or nil for a sentence-leading cluster. Used to match
  /// a kept after-occurrence to the before-occurrence at the same anchor.
  private static func leftContentWord(
    _ chars: [Character], _ sentences: [(lo: Int, hi: Int)], _ idx: Int
  ) -> String? {
    let si = sentences.firstIndex(where: { idx >= $0.lo && idx < $0.hi }) ?? (sentences.count - 1)
    let cw = contentWords(words(chars, sentences[si].lo, sentences[si].hi))
    return cw.last(where: { $0.end <= idx })?.text.lowercased()
  }

  /// Whole-word, case-insensitive matches of `word` within `[lo, hi)`. Returns
  /// (start, end) char-index spans.
  private static func findWordSpans(
    _ chars: [Character], _ word: String, _ lo: Int, _ hi: Int
  ) -> [(start: Int, end: Int)] {
    // Compare per-Character lowercased STRINGS, never `Character(_:.lowercased())`
    // — `Character.init(String)` has a single-grapheme precondition that would
    // trap on any exotic glyph whose lowercasing is multi-grapheme. A limb must
    // never crash the heart, so a worst case here is a missed match (then the
    // sentence-boundary fallback), never a trap.
    let needle = word.lowercased().map { String($0) }
    guard !needle.isEmpty else { return [] }
    var out: [(start: Int, end: Int)] = []
    let bound = min(hi, chars.count)
    var i = lo
    while i + needle.count <= bound {
      var match = true
      for k in 0..<needle.count where chars[i + k].lowercased() != needle[k] {
        match = false
        break
      }
      if match {
        let beforeOK = i == 0 || !isWordChar(chars[i - 1])
        let afterIdx = i + needle.count
        let afterOK = afterIdx >= chars.count || !isWordChar(chars[afterIdx])
        if beforeOK && afterOK { out.append((start: i, end: afterIdx)) }
      }
      i += 1
    }
    return out
  }

  /// Advance from `pos` past characters bound to the preceding token — symbols
  /// like `%`, `°`, `+` that attach to a value — so an emoji anchored "after a
  /// word" lands after the WHOLE token (`12.5% 🔥`, not `12.5 🔥 %`). Stops at
  /// whitespace or clause/closing punctuation, so it never jumps a comma or
  /// period into the next clause.
  private static func tokenEnd(_ chars: [Character], _ pos: Int, _ hi: Int) -> Int {
    var p = pos
    let bound = min(hi, chars.count)
    while p < bound, !chars[p].isWhitespace, !noSpaceBefore.contains(chars[p]) {
      p += 1
    }
    return p
  }

  /// Char index where the sentence's final punctuation run begins (so a trailing
  /// glyph lands before the period); the sentence end when there is none.
  private static func lastSentenceEnderStart(_ chars: [Character], _ lo: Int, _ hi: Int) -> Int {
    let bound = min(hi, chars.count)
    var i = bound - 1
    while i >= lo, chars[i].isWhitespace { i -= 1 }
    var enderStart: Int? = nil
    while i >= lo, sentenceEnders.contains(chars[i]) {
      enderStart = i
      i -= 1
    }
    return enderStart ?? bound
  }
}
