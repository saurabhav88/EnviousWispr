import Foundation

/// A word-level comparison of the raw transcript against the cleaned document (#2773).
///
/// **What it answers:** the founder's question, "how much cleanup actually happened". Two
/// blocks of prose side by side cannot say; this marks the ORIGINAL words with what the
/// cleanup did to them and counts it: words removed, words changed.
///
/// **Two treatments, founder-specified.** A word the cleanup removed is struck through. A
/// word it altered is highlighted. A word it ADDED has no original to mark, so it is shown
/// highlighted in place: from the reader's side it is a change. Removed and altered are
/// observable in the diff; no category ("filler", "grammar") is inferred, because the
/// polisher never says why it changed anything.
///
/// **Tokens, and what counts as the same one.** Counts are over whitespace-separated tokens.
/// Two tokens compare equal after lowercasing and stripping LEADING and TRAILING punctuation
/// and symbols from an otherwise non-empty token, so "hello" and "Hello," are one word: a
/// comma or a capital is not the cleanup the count is about, and counting it would make every
/// sentence look rewritten. Internal punctuation stays significant ("don't" and "dont"
/// differ). A token that is only punctuation or only an emoji stays a token and can count.
/// A replacement hunk counts its ORIGINAL tokens once; an insert-only hunk counts what it
/// inserted. The original's exact spelling and spacing are what get rendered.
///
/// **Myers' algorithm in linear space** (the middle-snake refinement). The quadratic-memory
/// form would need half a gigabyte at a three-hour transcript. Time is linear in the edit
/// distance as well as the length: the cleanup-shaped inputs measured on #2773 took 1.8 ms
/// at 2,000 words, 26 ms at 9,000 and 107 ms at 27,000 in Release, and two transcripts with
/// nothing in common at 27,000 took about three seconds (Codex, chunk review). The
/// coordinator therefore runs it off the main actor and the view shows a placeholder.
public enum WordDiff {

  public enum Kind: Equatable, Sendable {
    /// The cleanup kept this word.
    case same
    /// The cleanup dropped this word and put nothing in its place.
    case removed
    /// The cleanup replaced this word with something else.
    case changed
    /// The cleanup added this word; it has no original.
    case added
  }

  /// One token of the marked-up text, in reading order, with the whitespace that followed
  /// it in the original so the original's layout survives.
  public struct Segment: Equatable, Sendable {
    public let kind: Kind
    public let text: String
    public let trailing: String

    public init(kind: Kind, text: String, trailing: String) {
      self.kind = kind
      self.text = text
      self.trailing = trailing
    }
  }

  public struct Result: Equatable, Sendable {
    public let segments: [Segment]
    /// Original words dropped with nothing in their place.
    public let removedWords: Int
    /// Original words replaced, plus words added with no original: what the highlight marks.
    public let changedWords: Int

    public init(segments: [Segment], removedWords: Int, changedWords: Int) {
      self.segments = segments
      self.removedWords = removedWords
      self.changedWords = changedWords
    }

    /// The legend above the text. Founder's example: "1,204 words removed · 318 changed".
    /// Numbers follow the locale: a German user reads "1.204".
    public var legend: String { legend(locale: .current) }

    public func legend(locale: Locale) -> String {
      let removed = Self.count(removedWords, "word", "words", locale: locale)
      let changed = changedWords.formatted(.number.locale(locale))
      return "\(removed) removed · \(changed) changed"
    }

    private static func count(_ n: Int, _ singular: String, _ plural: String, locale: Locale)
      -> String
    {
      "\(n.formatted(.number.locale(locale))) \(n == 1 ? singular : plural)"
    }

    /// Two results in reading order, as one. Counts add; the segments concatenate.
    func appending(_ other: Result) -> Result {
      Result(
        segments: segments + other.segments, removedWords: removedWords + other.removedWords,
        changedWords: changedWords + other.changedWords)
    }
  }

  /// One passage of the original with what the cleanup made of it, or nil when the cleanup
  /// never reached it.
  public struct Passage: Equatable, Sendable {
    public let original: String
    public let cleaned: String?

    public init(original: String, cleaned: String?) {
      self.original = original
      self.cleaned = cleaned
    }
  }

  // MARK: - Tokens

  struct Token: Equatable {
    let text: String
    let trailing: String
    let key: String
  }

  /// Whitespace-separated runs, each carrying the whitespace that followed it, keyed by
  /// their letters for comparison.
  static func tokenize(_ text: String) -> [Token] {
    var tokens: [Token] = []
    var word = ""
    var space = ""
    func flush() {
      guard !word.isEmpty else { return }
      tokens.append(Token(text: word, trailing: space, key: key(for: word)))
      word = ""
      space = ""
    }
    for c in text {
      if c.isWhitespace || c.isNewline {
        if word.isEmpty {
          // Whitespace before any word: attach to the previous token's trailing run. At the
          // very start there is no token yet; `compare` keeps that run as its own segment.
          if var last = tokens.popLast() {
            last = Token(text: last.text, trailing: last.trailing + String(c), key: last.key)
            tokens.append(last)
          }
        } else {
          space.append(c)
          // A run of whitespace ends the word once the next non-space arrives; keep
          // accumulating until then.
          continue
        }
      } else {
        if !space.isEmpty { flush() }
        word.append(c)
      }
    }
    flush()
    return tokens
  }

  static func key(for word: String) -> String {
    let trimmed = word.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    return (trimmed.isEmpty ? word : trimmed).lowercased()
  }

  // MARK: - The comparison

  /// Passage by passage, which is how the cleanup itself ran. Comparing the whole original
  /// against the whole output as one block lost the boundaries: after a Stop, a global
  /// alignment could match the finished part's few words against the START of the original
  /// and mark the untouched waiting passages as removed, and a passage the splitter cut
  /// inside a run with no spaces read as two words against one. Each passage is compared
  /// with its own original; a passage the cleanup never reached is all `.same`. The
  /// original's own whitespace carries the layout between passages; the raw transcript is
  /// the concatenation of its pieces, so nothing is inserted between them.
  public static func compare(passages: [Passage]) -> Result {
    var result = Result(segments: [], removedWords: 0, changedWords: 0)
    for passage in passages {
      let piece: Result
      if let cleaned = passage.cleaned {
        piece = compare(original: passage.original, cleaned: cleaned)
      } else {
        piece = Result(
          segments: tokenize(passage.original).map {
            Segment(kind: .same, text: $0.text, trailing: $0.trailing)
          },
          removedWords: 0, changedWords: 0)
      }
      result = result.appending(piece)
    }
    return result
  }

  public static func compare(original: String, cleaned: String) -> Result {
    let a = tokenize(original)
    let b = tokenize(cleaned)
    let ops = edits(a.map(\.key), b.map(\.key))
    let result = assemble(ops, original: a, cleaned: b)
    // The original's leading whitespace is layout, not a word: kept as an unmarked segment
    // so the rendering starts where the original did.
    let leading = String(original.prefix { $0.isWhitespace })
    guard !leading.isEmpty else { return result }
    return Result(
      segments: [Segment(kind: .same, text: leading, trailing: "")] + result.segments,
      removedWords: result.removedWords, changedWords: result.changedWords)
  }

  enum Op: Equatable {
    case equal(Int, Int)  // a index, b index
    case delete(Int)  // a index
    case insert(Int)  // b index
  }

  /// Groups runs of deletes and inserts into hunks, which is where "removed" and "changed"
  /// are decided: a hunk with deletes and no inserts removed words; a hunk with both changed
  /// them; a hunk with inserts and no deletes added words, counted as changed.
  static func assemble(_ ops: [Op], original a: [Token], cleaned b: [Token]) -> Result {
    var segments: [Segment] = []
    var removed = 0
    var changed = 0
    var i = 0
    while i < ops.count {
      if case .equal(let ai, _) = ops[i] {
        segments.append(Segment(kind: .same, text: a[ai].text, trailing: a[ai].trailing))
        i += 1
        continue
      }
      // A hunk: consecutive deletes and inserts, in whatever order Myers emitted them.
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
      let kind: Kind = inserts.isEmpty ? .removed : .changed
      for ai in deletes {
        segments.append(Segment(kind: kind, text: a[ai].text, trailing: a[ai].trailing))
      }
      if deletes.isEmpty {
        for bi in inserts {
          // An addition after the original's last word needs a separator the original
          // never had; everywhere else the original's own whitespace does the job.
          if let previous = segments.last, previous.trailing.isEmpty {
            segments[segments.count - 1] = Segment(
              kind: previous.kind, text: previous.text, trailing: " ")
          }
          segments.append(Segment(kind: .added, text: b[bi].text, trailing: b[bi].trailing))
        }
        changed += inserts.count
      } else if inserts.isEmpty {
        removed += deletes.count
      } else {
        changed += deletes.count
      }
    }
    return Result(segments: segments, removedWords: removed, changedWords: changed)
  }

  // MARK: - Myers, linear space

  static func edits(_ a: [String], _ b: [String]) -> [Op] {
    var ops: [Op] = []
    ops.reserveCapacity(a.count + b.count)
    solve(a, b, 0, a.count, 0, b.count, &ops)
    return ops
  }

  private static func solve(
    _ a: [String], _ b: [String], _ a0: Int, _ a1: Int, _ b0: Int, _ b1: Int,
    _ ops: inout [Op]
  ) {
    var a0 = a0
    var b0 = b0
    var a1 = a1
    var b1 = b1
    // Strip the common prefix and suffix first: cheap, and it keeps the recursion shallow on
    // the shape a cleanup produces, which is long runs of untouched words.
    while a0 < a1, b0 < b1, a[a0] == b[b0] {
      ops.append(.equal(a0, b0))
      a0 += 1
      b0 += 1
    }
    var suffix: [Op] = []
    while a0 < a1, b0 < b1, a[a1 - 1] == b[b1 - 1] {
      suffix.append(.equal(a1 - 1, b1 - 1))
      a1 -= 1
      b1 -= 1
    }
    defer { ops.append(contentsOf: suffix.reversed()) }

    if a0 == a1 {
      for bi in b0..<b1 { ops.append(.insert(bi)) }
      return
    }
    if b0 == b1 {
      for ai in a0..<a1 { ops.append(.delete(ai)) }
      return
    }
    let (x, y, u, v) = middleSnake(a, b, a0, a1, b0, b1)
    // A snake that covers no ground would recurse on the same problem for ever. It cannot
    // happen for non-empty inputs, and the fallback that makes that claim checkable is a
    // plain replacement of the range, which is always a valid (if longer) edit.
    guard (x, y, u, v) != (a0, b0, a0, b0) || (a1 - a0) + (b1 - b0) == 0 else {
      for ai in a0..<a1 { ops.append(.delete(ai)) }
      for bi in b0..<b1 { ops.append(.insert(bi)) }
      return
    }
    solve(a, b, a0, x, b0, y, &ops)
    var ai = x
    var bi = y
    while ai < u {
      ops.append(.equal(ai, bi))
      ai += 1
      bi += 1
    }
    solve(a, b, u, a1, v, b1, &ops)
  }

  /// Myers 1986 §4b. Returns the middle snake's start and end in absolute indices.
  private static func middleSnake(
    _ a: [String], _ b: [String], _ a0: Int, _ a1: Int, _ b0: Int, _ b1: Int
  ) -> (Int, Int, Int, Int) {
    let n = a1 - a0
    let m = b1 - b0
    let max = (n + m + 1) / 2 + 1
    let delta = n - m
    let odd = delta & 1 == 1
    let size = 2 * max + 2
    var vf = [Int](repeating: 0, count: size)
    var vb = [Int](repeating: 0, count: size)
    @inline(__always) func idx(_ k: Int) -> Int { k + max + 1 }
    vf[idx(1)] = 0
    vb[idx(1)] = 0
    for d in 0...max {
      // Forward.
      var k = -d
      while k <= d {
        var x: Int
        if k == -d || (k != d && vf[idx(k - 1)] < vf[idx(k + 1)]) {
          x = vf[idx(k + 1)]
        } else {
          x = vf[idx(k - 1)] + 1
        }
        var y = x - k
        let sx = x
        let sy = y
        while x < n, y < m, a[a0 + x] == b[b0 + y] {
          x += 1
          y += 1
        }
        vf[idx(k)] = x
        if odd, k >= delta - (d - 1), k <= delta + (d - 1) {
          let c = delta - k
          if c >= -(d - 1), c <= d - 1, vf[idx(k)] + vb[idx(c)] >= n {
            return (a0 + sx, b0 + sy, a0 + x, b0 + y)
          }
        }
        k += 2
      }
      // Backward.
      k = -d
      while k <= d {
        var x: Int
        if k == -d || (k != d && vb[idx(k - 1)] < vb[idx(k + 1)]) {
          x = vb[idx(k + 1)]
        } else {
          x = vb[idx(k - 1)] + 1
        }
        var y = x - k
        let ex = x
        let ey = y
        while x < n, y < m, a[a1 - 1 - x] == b[b1 - 1 - y] {
          x += 1
          y += 1
        }
        vb[idx(k)] = x
        if !odd, k >= delta - d, k <= delta + d {
          let c = delta - k
          if c >= -d, c <= d, vf[idx(c)] + vb[idx(k)] >= n {
            return (a1 - x, b1 - y, a1 - ex, b1 - ey)
          }
        }
        k += 2
      }
    }
    // Unreachable for non-empty inputs: the loop always finds a snake by d = max.
    return (a0, b0, a0, b0)
  }
}
