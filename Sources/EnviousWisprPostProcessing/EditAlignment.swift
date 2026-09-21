import Foundation

// MARK: - Edit alignment (#996 §3.1 step 5)
//
// Turns "what the app pasted" and "what the text became after the user
// edited it" into the bounded changed runs a judge may be asked about. Pure
// and deterministic: no store, no judge, no vocabulary. Tokens come from
// `InverseTextNormalizer.splitWords` (whitespace runs), the same tokenizer
// the rest of the text layer uses, so a run's words are the words the
// corrector would see.

package enum EditAlignment {

  /// One cell of the word alignment.
  package enum Label: Sendable, Equatable {
    /// Same token on both sides.
    case match
    /// A different token on both sides.
    case substitute
    /// The same letters in different case (compared casefolded).
    case casing
    /// A token only in the edited text.
    case insert
    /// A token only in the pasted text.
    case delete
  }

  /// One aligned step; `original`/`edited` are the SURFACE tokens exactly as
  /// split, so no comparison normalisation ever reaches the returned run.
  package struct Step: Sendable, Equatable {
    package let label: Label
    package let original: String?
    package let edited: String?
  }

  /// A maximal contiguous changed region with both sides present. `original`
  /// and `replacement` are the surface tokens joined by one space; the index
  /// ranges are token positions in the pasted and edited token arrays.
  package struct Run: Sendable, Equatable {
    /// Surface text of the changed region, tokens joined by one space.
    package let original: String
    package let replacement: String
    /// The word or phrase being corrected, with sentence decoration removed
    /// from each token's edges by the corrector's own boundary convention
    /// (`WordCorrector.stripPunctuationStatic`: leading/trailing punctuation
    /// runs; internal apostrophes, hyphens and identifier punctuation stay).
    /// Target resolution, ownership, the pair key and the judge read these.
    package let coreOriginal: String
    package let coreReplacement: String
    package let originalRange: Range<Int>
    package let editedRange: Range<Int>
    package let labels: [Label]

    package init(
      original: String, replacement: String, originalRange: Range<Int>, editedRange: Range<Int>,
      labels: [Label]
    ) {
      self.original = original
      self.replacement = replacement
      self.coreOriginal = EditAlignment.lexicalCore(original)
      self.coreReplacement = EditAlignment.lexicalCore(replacement)
      self.originalRange = originalRange
      self.editedRange = editedRange
      self.labels = labels
    }
  }

  /// Why a changed region was NOT returned as a run. Counted, never silent.
  package enum DropReason: String, Sendable, Equatable, CaseIterable {
    /// One side is empty: words were only added or only removed.
    case insertionOrDeletionOnly
    /// More than `maxWordsPerSide` words on a side.
    case tooLong
    /// Casing-, punctuation- or symbol-only change (`EditRunShape`, EC-BRAND-006).
    case casingOrPunctuationOnly
    /// A single CJK token on each side: whole clauses collapse to one
    /// "word" without spaces, so a one-token run is not an edited run.
    case cjkSingleToken
    /// Nothing but decoration on a side, or identical cores: the edit changed
    /// only quotes, brackets or terminal punctuation around the run.
    case decorationOnly
  }

  package struct Dropped: Sendable, Equatable {
    package let run: Run
    package let reason: DropReason
  }

  package struct Result: Sendable, Equatable {
    package let runs: [Run]
    package let dropped: [Dropped]
    package let steps: [Step]
    /// The token counts exceeded `maxAlignmentCells`: nothing was aligned.
    /// An explicit processing limit, distinct from "no changes found".
    package let limitExceeded: Bool
  }

  /// Plan §3.1 step 5: 1 to 4 words on each side of a run.
  package static let maxWordsPerSide = 4
  /// The distance matrix is `(m + 1) × (n + 1)` cells over the two token
  /// counts; above this it is not allocated (500 × 500 tokens, about 2 MB of
  /// `Int`). A settled paste is one dictation; the 20,000-unit AX read
  /// upstream does not bound TOKENS, so alignment bounds them itself.
  package static let maxAlignmentCells = 250_000

  /// Align and extract the eligible runs. Deterministic tie-breaking in the
  /// Levenshtein backtrace: prefer the diagonal (match or casing, then
  /// substitute), then consuming an original word (delete), then an edited
  /// word (insert), so equal-cost alignments always produce the same runs.
  package static func align(pasted: String, edited: String) -> Result {
    let a = InverseTextNormalizer.splitWords(pasted)
    let b = InverseTextNormalizer.splitWords(edited)
    guard (a.count + 1) * (b.count + 1) <= maxAlignmentCells else {
      return Result(runs: [], dropped: [], steps: [], limitExceeded: true)
    }
    let steps = alignTokens(a, b)
    var runs: [Run] = []
    var dropped: [Dropped] = []
    var i = 0
    var ai = 0
    var bi = 0
    while i < steps.count {
      if steps[i].label == .match {
        ai += 1
        bi += 1
        i += 1
        continue
      }
      let aStart = ai
      let bStart = bi
      var labels: [Label] = []
      var originals: [String] = []
      var editeds: [String] = []
      while i < steps.count, steps[i].label != .match {
        let s = steps[i]
        labels.append(s.label)
        if let o = s.original {
          originals.append(o)
          ai += 1
        }
        if let e = s.edited {
          editeds.append(e)
          bi += 1
        }
        i += 1
      }
      let run = Run(
        original: originals.joined(separator: " "), replacement: editeds.joined(separator: " "),
        originalRange: aStart..<ai, editedRange: bStart..<bi, labels: labels)
      if let reason = dropReason(originals: originals, editeds: editeds) {
        dropped.append(Dropped(run: run, reason: reason))
      } else {
        runs.append(run)
      }
    }
    return Result(runs: runs, dropped: dropped, steps: steps, limitExceeded: false)
  }

  static func dropReason(originals: [String], editeds: [String]) -> DropReason? {
    if originals.isEmpty || editeds.isEmpty { return .insertionOrDeletionOnly }
    if originals.count > maxWordsPerSide || editeds.count > maxWordsPerSide { return .tooLong }
    let o = originals.joined(separator: " ")
    let r = editeds.joined(separator: " ")
    if EditRunShape.isCasingOrPunctuationOnly(original: o, replacement: r) {
      return .casingOrPunctuationOnly
    }
    if originals.count == 1, editeds.count == 1, containsCJK(o), containsCJK(r) {
      return .cjkSingleToken
    }
    let co = lexicalCore(o)
    let cr = lexicalCore(r)
    if co.isEmpty || cr.isEmpty || co == cr { return .decorationOnly }
    return nil
  }

  /// The run without sentence decoration: each token stripped of leading and
  /// trailing punctuation runs by the corrector's own convention, empty
  /// tokens dropped, joined by one space.
  package static func lexicalCore(_ text: String) -> String {
    InverseTextNormalizer.splitWords(text)
      .map { WordCorrector.stripPunctuationStatic($0) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  /// Han, Hiragana, Katakana and Hangul blocks: scripts written without
  /// word spaces, where one "token" is a clause.
  static func containsCJK(_ text: String) -> Bool {
    text.unicodeScalars.contains { s in
      switch s.value {
      case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF,
        0x20000...0x2FA1F:
        return true
      default:
        return false
      }
    }
  }

  /// Word-level Levenshtein with a casing-aware cost: match 0, casing 0
  /// (labelled separately), substitute/insert/delete 1.
  static func alignTokens(_ a: [String], _ b: [String]) -> [Step] {
    let m = a.count
    let n = b.count
    // Comparison forms once per token, never inside a cell: NFC for exact
    // equality (Swift `==` is canonical-equivalence aware, but the casefold
    // below is not), lowercased for the casing test.
    let na = a.map { $0.precomposedStringWithCanonicalMapping }
    let nb = b.map { $0.precomposedStringWithCanonicalMapping }
    let la = na.map { $0.lowercased() }
    let lb = nb.map { $0.lowercased() }
    func exact(_ i: Int, _ j: Int) -> Bool { na[i] == nb[j] }
    func same(_ i: Int, _ j: Int) -> Bool { exact(i, j) || la[i] == lb[j] }
    var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
    for i in 0...m { dp[i][0] = i }
    for j in 0...n { dp[0][j] = j }
    if m > 0 && n > 0 {
      for i in 1...m {
        for j in 1...n {
          let diag = dp[i - 1][j - 1] + (same(i - 1, j - 1) ? 0 : 1)
          dp[i][j] = min(diag, dp[i - 1][j] + 1, dp[i][j - 1] + 1)
        }
      }
    }
    // Backtrace with the documented tie order: diagonal, delete, insert.
    var steps: [Step] = []
    var i = m
    var j = n
    while i > 0 || j > 0 {
      if i > 0, j > 0 {
        let diagCost = dp[i - 1][j - 1] + (same(i - 1, j - 1) ? 0 : 1)
        if dp[i][j] == diagCost {
          let label: Label = exact(i - 1, j - 1) ? .match : (same(i - 1, j - 1) ? .casing : .substitute)
          steps.append(Step(label: label, original: a[i - 1], edited: b[j - 1]))
          i -= 1
          j -= 1
          continue
        }
      }
      if i > 0, dp[i][j] == dp[i - 1][j] + 1 {
        steps.append(Step(label: .delete, original: a[i - 1], edited: nil))
        i -= 1
        continue
      }
      steps.append(Step(label: .insert, original: nil, edited: b[j - 1]))
      j -= 1
    }
    steps.reverse()
    return steps
  }

}
