import Foundation

/// The fill-ins a saved snippet may carry, and the only three there are (#3018).
///
/// A CLOSED set on purpose. The import, the editor, the matcher and the resolver all ask this one
/// type what a `{{...}}` span means, so "which fill-ins exist" has a single answer that a new case
/// changes everywhere at once. Anything else inside braces is not a fill-in: it is carried through
/// byte for byte by `resolve`, and refused by the import through
/// `carriesUnsupportedPlaceholder(_:)`.
public enum SnippetPlaceholder: String, CaseIterable, Sendable {
  case date, time, clipboard

  /// The canonical spelling the editor inserts. Matching is case-insensitive, so this is the
  /// spelling we WRITE, never the only one we read.
  public var token: String { "{{\(rawValue)}}" }
}

/// Everything a fill-in needs to become text, frozen at one instant (#3018).
///
/// A value rather than a set of closures, because `SnippetExpander.expand` reads the same saved
/// text TWICE in one take — once into the sentinel-collision domain and once at the fire site — and
/// the two must agree. A frozen snapshot makes that agreement a property of the type instead of a
/// comment asking a future reader to keep two call sites in step.
///
/// `.current`, never `.autoupdatingCurrent`: an autoupdating locale or zone tracks later system
/// changes, which is exactly the property this type exists to refuse.
public struct SnippetDynamicValues: Sendable, Equatable {
  /// The single instant every fill-in in this take is rendered against.
  public let now: Date
  public let locale: Locale
  public let timeZone: TimeZone
  /// nil when the clipboard was not read, or holds no plain text. Both resolve to the empty
  /// string, so a snippet never pastes the word "nil" and never leaves its own token behind.
  public let clipboard: String?

  public init(now: Date, locale: Locale, timeZone: TimeZone, clipboard: String?) {
    self.now = now
    self.locale = locale
    self.timeZone = timeZone
    self.clipboard = clipboard
  }
}

/// One piece of a resolved expansion: a literal run of the saved text, or one substituted value.
///
/// `internal`, and the test module reaches it through `@testable import`. Nothing outside this
/// package has any use for it.
enum SnippetResolvedSegment: Sendable, Equatable {
  case literal(String)
  /// The value a fill-in resolved to. The SAME string for every expansion in a take that uses it,
  /// which is what lets a search scan a large clipboard once instead of once per snippet.
  case value(SnippetPlaceholder, String)
}

/// The sentinel-collision domain, WITHOUT building the resolved strings (#3018).
///
/// **Why this type exists, measured rather than assumed.** The domain answers one question: does a
/// sentinel candidate occur in any expansion that could be substituted back into the text? The
/// first build of this feature answered it by resolving every saved expansion into a real String.
/// That materializes one copy of the user's clipboard PER SAVED clipboard snippet: sixteen snippets
/// and a 10 MiB clipboard built 160 MiB and scanned all of it, which took 2161 ms against the
/// step's 1 second backstop, so the snippet silently did not fire. Measured in Release on
/// 2026-09-16; the table is in the plan's section 16.
///
/// Segments are held instead, so a value is REFERENCED once per expansion rather than copied, and
/// a search scans each distinct value at most once per query.
///
/// **The contract is ONE-WAY, and that is the right contract rather than a concession.** `contains`
/// never misses an occurrence, and may report one the fully resolved string does not have. It is
/// used to REJECT a sentinel candidate, so an extra report costs one more mint from a source of
/// random 128-bit tokens, while a miss would put a live sentinel into text the finalizer has
/// already checked. The asymmetry of the contract is the asymmetry of the consequences.
///
/// What it must never miss, written out. Let `w` be the needle's length in Characters. A match lies
/// wholly inside one segment, or it spans a splice. Each segment is searched whole, which covers
/// the first case. For the second, the search also inspects a WINDOW: the last `2w` characters of
/// everything before the segment in the SAME expansion, joined to that segment's first `2w`
/// characters. A match spanning a splice is `w` characters long, so it cannot reach past either
/// bound, and a run of short segments is traversed because the window is carried forward rather
/// than taken pairwise. Windows never cross from one expansion into another.
///
/// **Where the over-reporting comes from, found by a test rather than asserted not to happen.**
/// Swift compares text by grapheme, and two segments MERGE at their splice: `café` followed by a
/// combining acute becomes `caf` plus one grapheme carrying two accents, so the resolved text no
/// longer contains `café` while the segment on its own still does. Chasing that to exactness costs
/// interior slicing and overlap arithmetic at every splice and buys a user nothing, because the
/// only effect of the extra report is a different random sentinel.
///
/// `2w` rather than `w - 1` on each side for the same reason: one cheap over-approximation instead
/// of reasoning about how far a merge can move a grapheme boundary.
package struct SnippetResolvedExpansions: Sendable {
  private let expansions: [[SnippetResolvedSegment]]

  package init(savedTexts: [String], using values: SnippetDynamicValues) {
    // Each distinct value is folded ONCE here, not per query. `SnippetPlaceholder.segments` stays
    // faithful to what `resolve` emits; only this search copy is composed.
    var composedValues: [SnippetPlaceholder: String] = [:]
    self.expansions = savedTexts.map { saved in
      SnippetPlaceholder.segments(of: saved, using: values).map { segment in
        switch segment {
        case .literal(let text):
          return .literal(Self.searchForm(of: text))
        case .value(let placeholder, let text):
          if let known = composedValues[placeholder] { return .value(placeholder, known) }
          let folded = Self.searchForm(of: text)
          composedValues[placeholder] = folded
          return .value(placeholder, folded)
        }
      }
    }
  }

  /// The form this type SEARCHES. Never delivered: `resolve` owns the user's bytes.
  ///
  /// **Canonically composed, so a byte search can be trusted in both directions.** A non-ASCII
  /// character can canonically EQUAL an ASCII one — U+212A KELVIN SIGN is `K`, U+037E GREEK
  /// QUESTION MARK is `;`, U+1FEF GREEK VARIA is a backtick — and a raw byte search would miss
  /// those, which this type's contract forbids. Composing folds every such character into the ASCII
  /// it equals, because a canonical equivalence class has ONE composed form. That removes the whole
  /// class, in place of a hand-kept list of characters.
  ///
  /// Skipped for an all-ASCII string, which is already its own composed form: that check is a byte
  /// scan of about 1 ms per 10 MiB against about 54 ms to compose, so an ordinary clipboard pays
  /// almost nothing (#3018 §16e).
  private static func searchForm(of text: String) -> String {
    if isAllASCII(text) { return text }
    return text.precomposedStringWithCanonicalMapping
  }

  /// Whether every byte is ASCII, read off the CONTIGUOUS buffer.
  ///
  /// `text.utf8.allSatisfy { $0 < 0x80 }` walks `String.UTF8View` as a generic Sequence and cost
  /// 58 ms per 10 MiB, which made an ordinary all-ASCII clipboard 14 times slower than it needed to
  /// be; the same shape as the generic `firstRange(of:)` this file already rejected twice. Over the
  /// buffer it is about 1 ms (#3018 §16e).
  private static func isAllASCII(_ text: String) -> Bool {
    let answer: Bool? = text.utf8.withContiguousStorageIfAvailable { bytes in
      !bytes.contains(where: { $0 >= 0x80 })
    }
    return answer ?? text.utf8.allSatisfy { $0 < 0x80 }
  }

  /// Whether `needle` occurs in ANY resolved expansion, over-reporting rather than missing.
  package func contains(_ rawNeedle: String) -> Bool {
    if rawNeedle.isEmpty { return false }
    // The haystacks are already composed, so the needle must be too, or a canonically equal pair
    // could still differ byte for byte.
    let needle: String = Self.searchForm(of: rawNeedle)
    let edge: Int = 2 * needle.count
    // The answer for a substituted value is the same wherever it appears, so a large clipboard is
    // scanned once per query rather than once per snippet that uses it.
    var valueHoldsNeedle: [SnippetPlaceholder: Bool] = [:]

    for segments in expansions {
      var carry: String = ""
      for segment in segments {
        let text: String = Self.text(of: segment)

        // The splice. Skipped for the first segment, which has nothing before it.
        if !carry.isEmpty {
          let window: String = carry + String(text.prefix(edge))
          if Self.occurs(needle, in: window) { return true }
        }

        switch segment {
        case .literal(let literal):
          if Self.occurs(needle, in: literal) { return true }
        case .value(let placeholder, let value):
          if let known: Bool = valueHoldsNeedle[placeholder] {
            if known { return true }
          } else {
            let answer: Bool = Self.occurs(needle, in: value)
            valueHoldsNeedle[placeholder] = answer
            if answer { return true }
          }
        }

        carry = Self.lastCharacters(edge, ofCarry: carry, followedBy: text)
      }
    }
    return false
  }

  /// Search for `needle` in `haystack`. Both are already in this type's composed search form.
  ///
  /// **Measured on this Mac, Release, one 10 MiB haystack (#3018 §16b, §16e):**
  ///
  /// ```
  /// String.contains                  126 ms
  /// haystack.utf8.firstRange(of:)   1166 ms
  /// memmem                             4 ms
  /// composing a mixed 10 MiB once     54 ms
  /// ```
  ///
  /// `Collection.firstRange(of:)` over `String.UTF8View` is a generic naive scan, NINE times worse
  /// than doing nothing clever; an earlier version of this shipped it and had to be reverted.
  ///
  /// **Why the bytes are trusted in both directions.** A UTF-8 continuation byte is always >= 0x80,
  /// so an ASCII byte never occurs inside a multi-byte character: a byte hit is a real hit. And
  /// both sides are composed, so anything canonically equal to an ASCII needle has already been
  /// folded into that ASCII: a byte miss is a real miss.
  ///
  /// It may still REPORT a match grapheme comparison would reject — `"a\r\nb"` byte-contains
  /// `"\n"` while `contains` says false, because CRLF is one grapheme — which is the
  /// over-approximation the one-way contract allows.
  ///
  /// A haystack with no contiguous UTF-8, a string still bridged from `NSString`, has no buffer to
  /// hand `memmem` and falls back to `String.contains`, which is correct and merely slower.
  /// `ClipboardCleanup.userPlainText` makes the clipboard contiguous once at the boundary.
  private static func occurs(_ needle: String, in haystack: String) -> Bool {
    guard needle.utf8.allSatisfy({ $0 < 0x80 }) else { return haystack.contains(needle) }
    let outer: Bool?? = haystack.utf8.withContiguousStorageIfAvailable { hay -> Bool? in
      let inner: Bool?? = needle.utf8.withContiguousStorageIfAvailable { needleBytes -> Bool? in
        guard let hayBase = hay.baseAddress, let needleBase = needleBytes.baseAddress,
          !needleBytes.isEmpty
        else { return nil }
        return memmem(hayBase, hay.count, needleBase, needleBytes.count) != nil
      }
      return inner ?? nil
    }
    return (outer ?? nil) ?? haystack.contains(needle)
  }

  private static func text(of segment: SnippetResolvedSegment) -> String {
    switch segment {
    case .literal(let literal): return literal
    case .value(_, let value): return value
    }
  }

  /// The last `count` characters of `carry + text`.
  ///
  /// Taken from the END of a long segment so a large value is never copied to compute them.
  /// `String.count` is avoided for the same reason: it walks the whole string.
  private static func lastCharacters(
    _ count: Int, ofCarry carry: String, followedBy text: String
  ) -> String {
    if let start = text.index(text.endIndex, offsetBy: -count, limitedBy: text.startIndex) {
      return String(text[start...])
    }
    let joined: String = carry + text
    return String(joined.suffix(count))
  }
}

extension SnippetPlaceholder {

  /// One `{{...}}` run in the source text, and what it means.
  private struct Span {
    let range: Range<String.Index>
    /// nil for a span this app does not fill in.
    let placeholder: SnippetPlaceholder?
  }

  /// The ONE scanner. Every question about fill-ins is answered from this walk, so the import's
  /// idea of a span and the resolver's idea of a span cannot drift apart
  /// (`code-design-rules.md` RULE: parse-structured-input-dont-regex-and-iterate).
  ///
  /// Walk left to right. On `{{`, find the next `}}` after the opener. If there is none, the rest
  /// of the string is literal and the walk ends. Otherwise the span is `{{` ... `}}`; its inner
  /// text is trimmed with `.whitespacesAndNewlines`, lowercased, and matched against the closed
  /// enum. Resume after the closer.
  ///
  /// Two decisions a reader must be able to check:
  ///
  /// - **An unterminated `{{` is literal, not an error.** That is also what the TypeWhisper
  ///   import's own scanner decided before this type replaced it, so no import changes its answer
  ///   on that input.
  /// - **Overlap resolves left to right, non-overlapping.** `{{{{date}}}}` is one span whose inner
  ///   text is `{{date` — unsupported, therefore literal — followed by a literal `}}`. Ambiguous
  ///   input is carried through rather than guessed at.
  ///
  /// The trimming alphabet is `.whitespacesAndNewlines` rather than `.whitespaces` because it
  /// decides a real input: a saved snippet is routinely multi-line, so `{{\ndate\n}}` is reachable
  /// and is a supported span.
  private static func spans(in text: String) -> [Span] {
    var spans: [Span] = []
    var cursor = text.startIndex
    while let open = text.range(of: "{{", options: .literal, range: cursor..<text.endIndex) {
      guard
        let close = text.range(
          of: "}}", options: .literal, range: open.upperBound..<text.endIndex)
      else { break }
      let inner = text[open.upperBound..<close.lowerBound]
      let name = inner.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      spans.append(
        Span(
          range: open.lowerBound..<close.upperBound,
          placeholder: SnippetPlaceholder(rawValue: name)))
      cursor = close.upperBound
    }
    return spans
  }

  /// Which supported fill-ins `text` uses.
  ///
  /// Read from the SAVED text, which is the only place the token still exists: after `resolve` the
  /// token is gone, replaced by its value.
  public static func placeholders(in text: String) -> Set<SnippetPlaceholder> {
    Set(spans(in: text).compactMap(\.placeholder))
  }

  /// True when `text` carries a `{{...}}` span this app cannot fill in.
  ///
  /// The import's question. A row using only supported fill-ins is imported verbatim; a row using
  /// anything else is excluded and counted, exactly as every `{{...}}` row was before.
  public static func carriesUnsupportedPlaceholder(_ text: String) -> Bool {
    spans(in: text).contains { $0.placeholder == nil }
  }

  /// Replace every supported fill-in with its value, copying everything else byte for byte.
  ///
  /// **Single pass. A substituted value is never re-scanned.** The clipboard is arbitrary user
  /// content, so a second pass would let whatever the user copied drive further substitution: a
  /// clipboard holding `{{date}}` pastes those eight characters, which is what the user copied.
  public static func resolve(_ text: String, using values: SnippetDynamicValues) -> String {
    let found = spans(in: text)
    // The same String back, not a rebuilt copy, for the overwhelmingly common snippet that
    // carries no fill-in at all.
    guard !found.isEmpty else { return text }

    var out = ""
    var cursor = text.startIndex
    for span in found {
      out += text[cursor..<span.range.lowerBound]
      if let placeholder = span.placeholder {
        out += value(of: placeholder, using: values)
      } else {
        out += text[span.range]
      }
      cursor = span.range.upperBound
    }
    out += text[cursor...]
    return out
  }

  /// The pieces a resolved expansion is made of, in order, without concatenating them.
  ///
  /// Reads the SAME `spans(in:)` walk as `resolve`, so the two cannot disagree about where a
  /// fill-in starts and ends. An unsupported span is a literal, exactly as `resolve` emits it.
  static func segments(
    of text: String, using values: SnippetDynamicValues
  ) -> [SnippetResolvedSegment] {
    let found = spans(in: text)
    guard !found.isEmpty else { return [.literal(text)] }

    var segments: [SnippetResolvedSegment] = []
    var cursor = text.startIndex
    for span in found {
      if cursor < span.range.lowerBound {
        segments.append(.literal(String(text[cursor..<span.range.lowerBound])))
      }
      if let placeholder = span.placeholder {
        segments.append(.value(placeholder, value(of: placeholder, using: values)))
      } else {
        segments.append(.literal(String(text[span.range])))
      }
      cursor = span.range.upperBound
    }
    if cursor < text.endIndex { segments.append(.literal(String(text[cursor...]))) }
    return segments
  }

  /// The one place a fill-in becomes text.
  ///
  /// `.abbreviated` rather than `.numeric` because `9/16/2026` and `16/9/2026` are the same nine
  /// characters read two ways, and a snippet's output is read by other people. `.long` is too wide
  /// for a chat line.
  ///
  /// Locale, calendar and zone go in the INITIALIZER, never the chained `.timeZone(_:)` modifier,
  /// which spells a zone rather than selecting one (`swift-patterns.md`
  /// RULE: date-formatstyle-timezone-belongs-in-the-initializer). The calendar comes from the
  /// frozen locale rather than from `Calendar.autoupdatingCurrent`, the style's own default: a user
  /// who runs a non-Gregorian calendar still gets theirs, because `Locale.current` carries that
  /// preference, and the snapshot stays frozen.
  private static func value(
    of placeholder: SnippetPlaceholder, using values: SnippetDynamicValues
  ) -> String {
    switch placeholder {
    case .date:
      return values.now.formatted(
        Date.FormatStyle(
          date: .abbreviated, time: .omitted, locale: values.locale,
          calendar: values.locale.calendar, timeZone: values.timeZone))
    case .time:
      return values.now.formatted(
        Date.FormatStyle(
          date: .omitted, time: .shortened, locale: values.locale,
          calendar: values.locale.calendar, timeZone: values.timeZone))
    case .clipboard:
      return values.clipboard ?? ""
    }
  }
}
