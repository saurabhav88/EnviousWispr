import Foundation

// Support helpers for `InverseTextNormalizer` — a faithful Swift analog of the Python
// reference's regex toolkit (`re.sub(pattern, func)`, `re.findall`, `re.search`,
// `re.split`) plus the small formatting utilities. NSRegularExpression (ICU) is used,
// not Swift's native `Regex`, because ICU matches Python `re` semantics for the
// constructs the oracle relies on: named groups `(?<name>)`, single-char negative
// lookbehind `(?<![-\d.])`, and `\b` word boundaries (Codex grounded review 2026-06-02).

/// One regex match, exposing whole-match text and named / indexed capture groups —
/// the Swift analog of a Python `re.Match` object inside an `re.sub` callback.
struct Match {
  let result: NSTextCheckingResult
  let ns: NSString

  /// `m.group(0)` — the entire matched span.
  var whole: String { ns.substring(with: result.range) }

  /// `m.group(i)` — nil when the group did not participate (Python returns None).
  func g(_ i: Int) -> String? {
    guard i < result.numberOfRanges else { return nil }
    let r = result.range(at: i)
    return r.location == NSNotFound ? nil : ns.substring(with: r)
  }

  /// `m.group("name")` — nil when the named group did not participate.
  func g(_ name: String) -> String? {
    let r = result.range(withName: name)
    return r.location == NSNotFound ? nil : ns.substring(with: r)
  }
}

/// Compiled-regex cache. Each pass compiles a constant pattern (built from static
/// alternations), so caching turns ~20 compilations-per-call into one-time work and
/// keeps the eventual wired step well under its latency budget. `@unchecked Sendable`
/// is justified by the internal `NSLock` guarding all access to mutable state.
private final class RegexCache: @unchecked Sendable {
  static let shared = RegexCache()
  private let lock = NSLock()
  private var store: [String: NSRegularExpression] = [:]

  func regex(_ pattern: String, _ options: NSRegularExpression.Options) -> NSRegularExpression? {
    let key = "\(options.rawValue)\u{1}\(pattern)"
    lock.lock()
    defer { lock.unlock() }
    if let cached = store[key] { return cached }
    guard let compiled = try? NSRegularExpression(pattern: pattern, options: options) else {
      // A malformed pattern would silently no-op the pass (and break oracle parity). Crash loudly
      // in DEBUG/tests so it is caught at build time; in release the limb degrades gracefully
      // (ITN must never crash the heart path) — the pass is skipped, raw text passes through.
      assertionFailure("ITN regex failed to compile: \(pattern)")
      return nil
    }
    store[key] = compiled
    return compiled
  }
}

/// `re.sub(pattern, repl, s)` with a callback: `repl` receives each match and returns the
/// replacement, or nil to leave the matched span unchanged (the Python `return m.group(0)`
/// idiom). Single left-to-right non-overlapping pass — identical to Python `re.sub`.
func reSub(
  _ pattern: String, _ s: String, caseInsensitive: Bool = true, _ repl: (Match) -> String?
) -> String {
  let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
  guard let re = RegexCache.shared.regex(pattern, options) else { return s }
  let ns = s as NSString
  let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
  if matches.isEmpty { return s }
  var out = ""
  var last = 0
  for m in matches {
    let r = m.range
    out += ns.substring(with: NSRange(location: last, length: r.location - last))
    out += repl(Match(result: m, ns: ns)) ?? ns.substring(with: r)
    last = r.location + r.length
  }
  out += ns.substring(with: NSRange(location: last, length: ns.length - last))
  return out
}

/// `re.search(pattern, s)` existence — returns the matched substring, or nil.
func firstMatch(_ pattern: String, _ s: String, caseInsensitive: Bool = true) -> String? {
  let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
  guard let re = RegexCache.shared.regex(pattern, options) else { return nil }
  let ns = s as NSString
  guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else {
    return nil
  }
  return ns.substring(with: m.range)
}

/// `re.findall(pattern, s)` with one capture group — returns group 1 of every match
/// (group 0 if the pattern has no capture group).
func allMatches(_ pattern: String, _ s: String, caseInsensitive: Bool = true) -> [String] {
  let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
  guard let re = RegexCache.shared.regex(pattern, options) else { return [] }
  let ns = s as NSString
  return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap { m in
    let idx = m.numberOfRanges > 1 ? 1 : 0
    let r = m.range(at: idx)
    return r.location == NSNotFound ? nil : ns.substring(with: r)
  }
}

/// `re.split(pattern, s, flags=re.I)` for a separator pattern.
private func splitOnPattern(_ s: String, _ pattern: String) -> [String] {
  guard let re = RegexCache.shared.regex(pattern, [.caseInsensitive]) else { return [s] }
  let ns = s as NSString
  var parts: [String] = []
  var last = 0
  for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
    parts.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
    last = m.range.location + m.range.length
  }
  parts.append(ns.substring(with: NSRange(location: last, length: ns.length - last)))
  return parts
}

/// `re.split(r"\s+slash\s+", s, flags=re.I)`.
func splitOnSlash(_ s: String) -> [String] { splitOnPattern(s, #"\s+slash\s+"#) }

/// `re.split(r"\s+by\s+", s, flags=re.I)` — for chained dimensions ("two by four by six").
func splitOnBy(_ s: String) -> [String] { splitOnPattern(s, #"\s+by\s+"#) }

/// `f"{n:,}"` — thousands grouping, locale-independent (matches Python).
func comma(_ n: Int) -> String {
  let negative = n < 0
  let digits = Array(String(n.magnitude))
  var grouped: [Character] = []
  for (i, ch) in digits.reversed().enumerated() {
    if i != 0 && i % 3 == 0 { grouped.append(",") }
    grouped.append(ch)
  }
  return (negative ? "-" : "") + String(grouped.reversed())
}

/// `f"{n:02d}"`.
func pad2(_ n: Int) -> String { String(format: "%02d", n) }

/// English ordinal suffix: 1->st, 2->nd, 3->rd, 11/12/13->th, etc.
func ordSuffix(_ n: Int) -> String {
  if (11...13).contains(n % 100) { return "th" }
  switch n % 10 {
  case 1: return "st"
  case 2: return "nd"
  case 3: return "rd"
  default: return "th"
  }
}

/// 10 digits -> NXX-NXX-XXXX, 7 -> NXX-XXXX, else unchanged.
func fmtPhone(_ d: String) -> String {
  let c = Array(d)
  if c.count == 10 {
    return "\(String(c[0..<3]))-\(String(c[3..<6]))-\(String(c[6..<10]))"
  }
  if c.count == 7 {
    return "\(String(c[0..<3]))-\(String(c[3..<7]))"
  }
  return d
}

/// `f"{x:.3f}".rstrip("0").rstrip(".")` — drop trailing zeros, then a trailing dot.
func stripTrailingZeros(_ s: String) -> String {
  var out = s
  while out.hasSuffix("0") { out.removeLast() }
  if out.hasSuffix(".") { out.removeLast() }
  return out
}

extension InverseTextNormalizer {
  /// Python `str.split()` — split on any whitespace run, drop empties.
  static func splitWords(_ s: String) -> [String] {
    s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
  }

  /// `re.fullmatch(r"[\d,]+", w)` — non-empty, all ASCII digits or commas.
  static func isDigitComma(_ w: String) -> Bool {
    !w.isEmpty && w.allSatisfy { ("0"..."9").contains($0) || $0 == "," }
  }

  /// `re.fullmatch(r"\d{1,4}", w)` style — `count` in range, all ASCII digits.
  static func isFixedDigits(_ w: String, _ range: ClosedRange<Int>) -> Bool {
    range.contains(w.count) && !w.isEmpty && w.allSatisfy { ("0"..."9").contains($0) }
  }
}
