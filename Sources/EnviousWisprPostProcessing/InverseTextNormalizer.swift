import Foundation

/// Deterministic inverse text normalization (ITN): spoken-form → written-form.
/// "two zero three nine five four…" → "203-954-8879", "twenty twenty six" → "2026",
/// "eighty million dollars" → "$80 million".
///
/// This is a faithful Swift port of the hand-rolled deterministic normalizer that
/// won the #145 ITN bake-off (research lane, 2026-06-02): it matched/beat canonical
/// NeMo on accuracy, ships in house style, runs ~40x faster, and needs no C++/OpenFst
/// packaging. Validated on independent Google-TN data (digit-content 82%, real-prose
/// corruption ~0%), original corpus 99.8%, holdout 99.7%.
///
/// The Python reference is the ORACLE; `Tests/.../InverseTextNormalizer/parity.jsonl`
/// pins byte-for-byte behavioral equivalence (see `InverseTextNormalizerParityTests`).
///
/// Pure value transform, no state, `Sendable`. Context-aware where cheap; ambiguous
/// minimal pairs ("meet at one twenty" = 1:20 vs "paid one twenty" = $1.20) are left
/// for the AI-polish layer by design — every rule/grammar engine scores ~39% on those,
/// only an LLM cracks them, so context belongs above the deterministic floor.
public struct InverseTextNormalizer: Sendable {

  public init() {}

  // MARK: - Lexicon

  static let units: [String: Int] = [
    // 'o' (the letter) = 0 in spoken digit reads — real ASR emits it constantly for
    // leading-zero phone numbers ("o five two one…") and decimals ("three point o eight").
    // Safe globally: a lone/mid-cardinal zero makes wordsToInt return nil (the v==0 guard),
    // so cardinals with 'o' stay untouched; only the digit-read / decimal passes map it.
    "zero": 0, "oh": 0, "o": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
    "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
    "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
    "eighteen": 18, "nineteen": 19,
  ]
  static let tens: [String: Int] = [
    "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
    "eighty": 80, "ninety": 90,
  ]
  static let scales: [String: Int] = [
    "hundred": 100, "thousand": 1000, "million": 1_000_000, "billion": 1_000_000_000,
  ]
  static let ordinalWord: [String: Int] = [
    "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6,
    "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12,
    "thirteenth": 13, "fourteenth": 14, "fifteenth": 15, "sixteenth": 16, "seventeenth": 17,
    "eighteenth": 18, "nineteenth": 19, "twentieth": 20, "thirtieth": 30, "thirty first": 31,
    "twenty first": 21, "twenty second": 22, "twenty third": 23, "twenty fourth": 24,
    "twenty fifth": 25, "twenty sixth": 26, "twenty seventh": 27, "twenty eighth": 28,
    "twenty ninth": 29,
  ]
  static let ordUnit: [String: Int] = [
    "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6,
    "seventh": 7, "eighth": 8, "ninth": 9,
  ]
  static let ordStandalone: [String: Int] = [
    "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
    "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14, "fifteenth": 15,
    "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19, "twentieth": 20,
    "thirtieth": 30, "fortieth": 40, "fiftieth": 50, "sixtieth": 60, "seventieth": 70,
    "eightieth": 80, "ninetieth": 90,
  ]
  static let ordContextual: [String: Int] = ["first": 1, "second": 2, "third": 3]
  // "thirty second video" is a 30-SECOND duration, not the 32nd: guard the second/seconds collision.
  static let durationNouns: Set<String> = [
    "second", "seconds", "video", "clip", "ad", "ads", "advert", "advertisement",
    "commercial", "timer", "countdown", "break", "intro", "introduction", "delay",
    "pause", "window", "interval", "mark", "segment", "spot", "trailer", "teaser",
    "rule", "gap", "lead", "burst", "sprint", "rest", "head", "window.",
  ]
  // Year-pair concatenation (founder call 2026-06-02: convert years always). Bound to
  // YEAR-SHAPED century pairs so "twenty one"->21 (cardinal) survives.
  static let century: [String: Int] = [
    "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20,
  ]
  static let months: [String: Int] = [
    "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6, "july": 7,
    "august": 8, "september": 9, "october": 10, "november": 11, "december": 12,
  ]
  static let monthsW: [String] = [
    "", "January", "February", "March", "April", "May", "June", "July", "August",
    "September", "October", "November", "December",
  ]

  /// number-word set: UNITS ∪ TENS ∪ SCALES ∪ {"and"}.
  static let numword: Set<String> = Set(units.keys).union(tens.keys).union(scales.keys)
    .union(["and"])

  // MARK: - Precomputed alternations (longest-first, deterministic — strictly safe vs
  // Python's hash-ordered sets: \b-wrapped uses and backtracking make output identical).

  /// `|`-joined, longest token first, then alphabetical (deterministic). Tokens are
  /// `[a-z]` only — no regex metacharacters, no escaping needed.
  static func alt(_ words: [String]) -> String {
    words.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }.joined(separator: "|")
  }
  static func alt(_ words: Set<String>) -> String { alt(Array(words)) }

  static let numwordAlt = alt(numword)
  // A number token: a number-WORD or an already-digit token ('20', '1,234') for mixed-state.
  static let numtok = alt(numword) + #"|\d[\d,]*"#
  static let tensAlt = alt(Array(tens.keys))
  static let unit19Alt = alt(units.filter { (1...9).contains($0.value) }.map(\.key))
  static let teenAlt = alt(units.filter { (10...19).contains($0.value) }.map(\.key))
  static let digitWordAlt = alt(units.filter { $0.value < 10 }.map(\.key))
  static let unitsTensAlt = alt(Set(units.keys).union(tens.keys))
  static let monthsAlt = alt(Array(months.keys))
  static let centuryAlt = alt(Array(century.keys))

  // MARK: - Public entry point

  public func normalize(_ text: String) -> String {
    var t = " " + text.trimmingCharacters(in: .whitespacesAndNewlines) + " "

    // register-preserve (our enhancement): keep "quarter to/past N", "half past N" spelled,
    // plus ordinal idioms ("eleventh hour"). Shielded from the number passes via a sentinel.
    var protected: [String] = []
    let protect: (Match) -> String? = { m in
      protected.append(m.whole)
      return " \u{0}\(protected.count - 1)\u{0} "
    }
    t = reSub(#"\b(?:a |an )?(?:quarter|half)\s+(?:past|to)\s+\w+"#, t) { protect($0) }
    t = reSub(
      #"\beleventh hour\b|\bseventh heaven\b|\bthe fourth wall\b|\bthe fifth wheel\b"#
        + #"|\bthe fifth column\b|\bthe fourth estate\b|\bfirst among equals\b"#, t
    ) { protect($0) }

    t = emails(t)
    t = urls(t)
    t = decimals(t)

    t = moneyPct(t)  // currency + percent (re-run after years below)

    // time: H [M] a m/p m ; H o'clock ; preserve quarter to/past
    if firstMatch(#"\bquarter (to|past)\b|\bhalf past\b"#, t) == nil {
      let timePat =
        #"\s(?<h>"# + Self.unitsTensAlt + #"|\d{1,2})(?:\s+(?<m>(?:"# + Self.numtok
        + #")(?:\s+(?:"# + Self.numtok + #"))*))?\s+(?<ap>[ap]\s*m)\b"#
      t = reSub(timePat, t) { m in
        guard let h = Self.wordsToInt(Self.splitWords(m.g("h") ?? "")) else { return nil }
        var mins = 0
        if let mraw = m.g("m") {
          let mw = Self.splitWords(mraw)
          if let parsed = Self.wordsToInt(mw) {
            mins = parsed
          } else if mw.allSatisfy({ (Self.units[$0].map { $0 < 10 }) ?? false }) {
            mins = Int(mw.map { String(Self.units[$0]!) }.joined()) ?? 0  // 'o five'->05
          } else {
            return nil
          }
        }
        let ap = (m.g("ap") ?? "").replacingOccurrences(of: " ", with: "").uppercased()
        return " \(h):\(pad2(mins)) \(ap) "
      }
      let oclockPat = #"\s("# + Self.unitsTensAlt + #")\s+o'?clock\b"#
      t = reSub(oclockPat, t) { m in
        guard let n = Self.wordsToInt([m.g(1) ?? ""]) else { return nil }
        return " \(n):00 "
      }
    }

    // date: MONTH ORDINAL YEAR(words) -> Month D, YYYY
    let ordAlt = Self.alt(Array(Self.ordinalWord.keys))
    let datePat =
      #"\s(?<mon>"# + Self.monthsAlt + #")\s+(?<day>"# + ordAlt + #"|\d{1,2})\s+(?<yr>(?:"#
      + Self.numwordAlt + #")(?:\s+(?:"# + Self.numwordAlt + #")){0,3})\s"#
    t = reSub(datePat, t) { m in
      guard let mon = Self.months[(m.g("mon") ?? "").lowercased()] else { return nil }
      let dayraw = (m.g("day") ?? "").trimmingCharacters(in: .whitespaces)
      let day: Int? = Int(dayraw) ?? Self.ordinalWord[dayraw.lowercased()]
      guard let day, (1...31).contains(day) else { return nil }
      guard let yr = Self.parseYear(Self.splitWords(m.g("yr") ?? "")) else { return nil }
      return " \(Self.monthsW[mon]) \(day), \(yr) "
    }

    // standalone ordinals: after dates consume "Month Nth Year", before cardinals.
    t = ordinals(t)
    // year-pairs (founder option 1): after dates/ordinals, before cardinals.
    t = years(t)
    t = moneyPct(t)  // re-run: 'twenty twenty six dollars'->'2026 dollars'->'$2,026' (idempotence)

    // phone / digit-read runs (before generic cardinal so "two zero three…" stays a read).
    let runPat = #"(?:\b(?:"# + Self.digitWordAlt + #")\b\s*|\b\d{1,4}\b\s*){2,}"#
    t = reSub(runPat, t) { m in
      let toks = Self.splitWords(m.whole)
      var out: [String] = []
      for w in toks {
        let wl = w.lowercased()
        if let v = Self.units[wl], v < 10 {
          out.append(String(v))
        } else if Self.isFixedDigits(w, 1...4) {
          out.append(w)
        } else {
          return nil
        }
      }
      let d = out.joined()
      if d.count == 7 || d.count == 10 { return " " + fmtPhone(d) + " " }
      // short WORD-driven reads ("two zero three"->203) only: explicit zero-word AND length <=6.
      let hasWord = toks.contains { (Self.units[$0.lowercased()].map { $0 < 10 }) ?? false }
      let hasWordZero = toks.contains { ["zero", "oh", "o"].contains($0.lowercased()) }
      if hasWord && hasWordZero && d.count <= 6 { return " " + d + " " }
      return nil
    }

    // mixed-state: 'digit + scale' like '15 hundred'->1,500. hundred|thousand only (idempotence).
    let digitScalePat =
      #"\b(\d[\d,]*\s+(?:hundred|thousand)(?:\s+(?:"# + Self.numwordAlt + #"))*)\b"#
    t = reSub(digitScalePat, t) { m in
      guard let n = Self.wordsToInt(Self.splitWords(m.g(1) ?? "")) else { return nil }
      return " \(comma(n)) "
    }

    // generic cardinals: longest runs of number-words -> int. Left case-SENSITIVE on purpose: a
    // capitalized number word here has no unit/operator anchor, so it is ambiguous between a count
    // and prose / a proper noun ("Hundred Acre Wood", "One Million Moms"). A scale word does NOT
    // disambiguate (proper nouns use them too), so capitalized cardinals stay untouched and that
    // context call is left to the AI-polish layer. (Unit-anchored caps ARE handled — see currency/
    // percent/decimals below.)
    let cardPat = #"(?:\b(?:"# + Self.numwordAlt + #")\b\s*){1,}"#
    t = reSub(cardPat, t) { m in
      let words = Self.splitWords(m.whole)
      guard !words.isEmpty, m.whole.trimmingCharacters(in: .whitespaces) != "and",
        let n = Self.wordsToInt(words)
      else { return nil }
      return " \(comma(n)) "
    }

    // numeric slash-dates: "4 slash 6 slash 2,021" -> "4/6/2021". digit-slash-digit only.
    t = reSub(#"\b[\d,]+(?:\s+slash\s+[\d,]+)+\b"#, t) { m in
      let parts = splitOnSlash(m.whole)
      return " "
        + parts.map {
          $0.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        }.joined(separator: "/") + " "
    }

    // numeric ranges: "6 to 55" -> "6-55". digit-to-digit only; lookbehind rejects -/. lead.
    t = reSub(#"(?<![-\d.])\b(\d+)\s+to\s+(\d+)\b"#, t, caseInsensitive: false) { m in
      "\(m.g(1) ?? "")-\(m.g(2) ?? "")"
    }

    t = keepMagnitude(t)  // '$80,000,000'->'$80 million' (founder house style), keep the word
    t = applyPunct(t)

    // restore register-preserved spans verbatim
    for (i, p) in protected.enumerated() {
      t = t.replacingOccurrences(
        of: "\u{0}\(i)\u{0}", with: p.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    t = reSub(#"\s+([,.!?;:])"#, t, caseInsensitive: false) { m in m.g(1) }
    t = reSub(#"[ \t]+"#, t, caseInsensitive: false) { _ in " " }  // collapse spaces (keep newlines)
    return t.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - Strict cardinal parser

  /// Parse number-words into an Int as a STRICT cardinal. Returns nil for any sequence that
  /// is not a single valid English cardinal so the caller leaves it untouched rather than
  /// summing wrongly. This kills 'two zero three'->5, 'twenty twenty'->40, 'one twenty'->21.
  static func wordsToInt(_ words: [String]) -> Int? {
    if words.isEmpty { return nil }
    if words.count == 1, words[0].lowercased() == "zero" || words[0] == "0" { return 0 }
    var total = 0
    var current = 0
    var last: String? = nil
    var seen = false
    for w in words {
      if w == "and" { continue }
      if isDigitComma(w) {
        guard let dv = Int(w.replacingOccurrences(of: ",", with: "")) else { return nil }
        if dv == 0 { return nil }
        current += dv
        seen = true
        last = dv < 10 ? "unit" : dv < 20 ? "teen" : dv < 100 ? "ten" : "big"
        continue
      }
      if let v = units[w] {
        if v == 0 { return nil }
        if v < 10 {
          if last == "unit" || last == "teen" { return nil }
          current += v
          last = "unit"
        } else {
          if last == "unit" || last == "teen" || last == "ten" { return nil }
          current += v
          last = "teen"
        }
        seen = true
      } else if let tv = tens[w] {
        if last == "unit" || last == "teen" || last == "ten" { return nil }
        current += tv
        last = "ten"
        seen = true
      } else if w == "hundred" {
        if (last == "unit" || last == "teen" || last == "ten") && (1...99).contains(current) {
          current *= 100
        } else if last == nil || last == "scale" {
          current = 100
        } else {
          return nil
        }
        last = "hundred"
        seen = true
      } else if let sv = scales[w] {
        if current == 0 && total == 0 && last == nil { return nil }  // lone leading scale (idempotence)
        total += (current == 0 ? 1 : current) * sv
        current = 0
        last = "scale"
        seen = true
      } else {
        return nil
      }
    }
    return seen ? total + current : nil
  }

  static func parseYear(_ wordsIn: [String]) -> Int? {
    let words = wordsIn.filter { !$0.isEmpty }.map { $0 == "o" ? "oh" : $0 }  // 'twenty o six'=='twenty oh six'
    if words.contains("thousand") || words.contains("hundred") { return wordsToInt(words) }
    if words.contains("oh"), words.count == 3 {
      let a = wordsToInt([words[0]])
      let c = wordsToInt([words[2]])
      if let a, a != 0, let c { return a * 100 + c }
    }
    if words.count >= 2 {
      for split in 1..<words.count {
        let left = wordsToInt(Array(words[0..<split]))
        let right = wordsToInt(Array(words[split...]))
        if let left, let right, (10...99).contains(left), (0...99).contains(right) {
          return left * 100 + right
        }
      }
    }
    return wordsToInt(words)
  }

  // MARK: - Lexical passes (email / url / decimals)

  private func emails(_ t: String) -> String {
    let pat =
      #"\b(?<name>[a-z][a-z0-9_]*)\s+at\s+(?<dom>[a-z][a-z0-9-]*)\s+dot\s+"#
      + #"(?<tld>com|org|io|co|dev|me|net|edu|gov)\b"#
    return reSub(pat, t) { m in
      let name = (m.g("name") ?? "").replacingOccurrences(of: " ", with: "")
      return "\(name)@\(m.g("dom") ?? "").\(m.g("tld") ?? "")"
    }
  }

  private func urls(_ t: String) -> String {
    let pat =
      #"\b(?<host>[a-z]+)\s+dot\s+(?<tld>com|org|io|co|dev|me|net)\b"#
      + #"(?<path>(?:\s+slash\s+[a-z]+)*)"#
    return reSub(pat, t) { m in
      var s = "\(m.g("host") ?? "").\(m.g("tld") ?? "")"
      if let path = m.g("path"), !path.isEmpty {
        for p in allMatches(#"slash\s+([a-z]+)"#, path) { s += "/" + p }
      }
      return s
    }
  }

  private func decimals(_ t: String) -> String {
    let pat =
      #"\s(?<w>(?:"# + Self.numtok + #")(?:\s+(?:"# + Self.numtok + #"))*)\s+point\s+"#
      + #"(?<d>(?:"# + Self.digitWordAlt + #")(?:\s+(?:"# + Self.digitWordAlt + #"))*)"#
      + #"(?:\s+(?<scale>million|billion|thousand))?\s"#
    return reSub(pat, t) { m in
      // 'point' anchors numeric intent, so lowercasing the captured amount is corruption-safe.
      guard let whole = Self.wordsToInt(Self.splitWords((m.g("w") ?? "").lowercased())) else {
        return nil
      }
      // Lowercase the fraction words too: the case-insensitive regex can capture 'Five' in
      // 'Three Point Five', and Self.units[$0]! would force-unwrap nil on the capitalized key.
      let digs = Self.splitWords((m.g("d") ?? "").lowercased()).map { String(Self.units[$0]!) }
        .joined()
      let scale = (m.g("scale") ?? "").trimmingCharacters(in: .whitespaces).lowercased()
      if !scale.isEmpty, let sv = Self.scales[scale] {
        let value = (Double("\(whole).\(digs)") ?? 0) * Double(sv)
        return " \(comma(Int(value.rounded(.toNearestOrEven)))) "
      }
      return " \(whole).\(digs) "
    }
  }

  // MARK: - Currency / percent

  private func moneyPct(_ t0: String) -> String {
    var t = t0
    let curPat =
      #"\s((?<d>(?:"# + Self.numtok + #")(?:\s+(?:"# + Self.numtok + #"))*)\s+dollars"#
      + #"(?:\s+and\s+(?<c>(?:"# + Self.numtok + #")(?:\s+(?:"# + Self.numtok
      + #"))*)\s+cents)?)\s"#
    // 'dollars'/'cents'/'percent' anchor numeric intent, so lowercasing the captured amount is
    // corruption-safe: a capitalized sentence-initial 'Twenty dollars'/'Twenty percent' is a number,
    // never prose. (Bare cardinals stay case-sensitive — see the cardinal pass above.)
    t = reSub(curPat, t) { m in
      guard let d = Self.wordsToInt(Self.splitWords((m.g("d") ?? "").lowercased())) else {
        return nil
      }
      if let cRaw = m.g("c"), let c = Self.wordsToInt(Self.splitWords(cRaw.lowercased())) {
        return " $\(comma(d)).\(pad2(c)) "
      }
      return " $\(comma(d)) "
    }
    let centsPat =
      #"\s((?<c>(?:"# + Self.numtok + #")(?:\s+(?:"# + Self.numtok + #"))*)\s+cents)\s"#
    t = reSub(centsPat, t) { m in
      guard let c = Self.wordsToInt(Self.splitWords((m.g("c") ?? "").lowercased())) else {
        return nil
      }
      return " $\(String(format: "%.2f", Double(c) / 100.0)) "
    }
    let pctPat = #"\s((?:"# + Self.numtok + #")(?:\s+(?:"# + Self.numtok + #"))*)\s+percent\b"#
    t = reSub(pctPat, t) { m in
      guard let n = Self.wordsToInt(Self.splitWords((m.g(1) ?? "").lowercased())) else {
        return nil
      }
      return " \(n)% "
    }
    return t
  }

  // MARK: - Years

  private func years(_ t0: String) -> String {
    var t = t0
    // low part for a century pair: tens[+unit] (20-99) | teen (10-19) | oh/o + unit (01-09).
    let low =
      #"(?:(?:"# + Self.tensAlt + #")(?:\s+(?:"# + Self.unit19Alt + #"))?|(?:"#
      + Self.teenAlt + #")|(?:oh|o)\s+(?:"# + Self.unit19Alt + #"))"#
    let centPat = #"\b(?<c>"# + Self.centuryAlt + #")\s+(?<low>"# + low + #")\b"#
    t = reSub(centPat, t) { m in
      let c = Self.century[(m.g("c") ?? "").lowercased()]!
      let lw = Self.splitWords(m.g("low") ?? "")
      if lw.first == "oh" || lw.first == "o" {
        if lw.count > 1, let u = Self.units[lw[1]] { return " \(c * 100 + u) " }
        return nil
      }
      guard let lv = Self.wordsToInt(lw), (0...99).contains(lv) else { return nil }
      return " \(c * 100 + lv) "
    }
    // 'two thousand <1-99>' -> 2000+low, but NOT when a scale word follows.
    let low2 =
      #"(?:(?:"# + Self.tensAlt + #")(?:\s+(?:"# + Self.unit19Alt + #"))?|(?:"#
      + Self.teenAlt + #")|(?:"# + Self.unit19Alt + #")|(?:oh|o)\s+(?:"# + Self.unit19Alt + #"))"#
    let y2kPat =
      #"\btwo thousand(?:\s+and)?\s+(?<low>"# + low2
      + #")\b(?!\s+(?:hundred|thousand|million|billion))"#
    t = reSub(y2kPat, t) { m in
      guard let lv = Self.wordsToInt(Self.splitWords(m.g("low") ?? "")), (1...99).contains(lv)
      else { return nil }
      return " \(2000 + lv) "
    }
    return t
  }

  // MARK: - Ordinals

  private func ordinals(_ t0: String) -> String {
    var t = t0
    let unitAlt = Self.alt(Array(Self.ordUnit.keys))
    // compound: '<tens> <unit-ordinal>' -> 'Nth' ('seventy third'->73rd), capturing the next word
    // so the 'second' duration guard fires ('thirty second video'->left).
    let compPat =
      #"\b(?<t>"# + Self.tensAlt + #")\s+(?<u>"# + unitAlt + #")\b(?:\s+(?<nxt>[a-z]+))?"#
    t = reSub(compPat, t) { m in
      let uw = (m.g("u") ?? "").lowercased()
      let nxt = m.g("nxt") ?? ""
      if uw == "second" && Self.durationNouns.contains(nxt.lowercased()) { return nil }
      let n = Self.tens[(m.g("t") ?? "").lowercased()]! + Self.ordUnit[uw]!
      let tail = nxt.isEmpty ? "" : " " + nxt
      return " \(n)\(ordSuffix(n))\(tail) "
    }
    // standalone unambiguous: 'fourth'->4th, 'fiftieth'->50th, 'twentieth'->20th
    let simpleAlt = Self.alt(Array(Self.ordStandalone.keys))
    t = reSub(#"\b(?:"# + simpleAlt + #")\b"#, t) { m in
      let n = Self.ordStandalone[m.whole.lowercased()]!
      return "\(n)\(ordSuffix(n))"
    }
    // contextual first/second/third: only after 'the' or a month name.
    let ctxAlt = Self.alt(Array(Self.ordContextual.keys))
    let ctxPat = #"(?<lead>\b(?:the|"# + Self.monthsAlt + #")\s+)(?<w>"# + ctxAlt + #")\b"#
    t = reSub(ctxPat, t) { m in
      let n = Self.ordContextual[(m.g("w") ?? "").lowercased()]!
      return "\(m.g("lead") ?? "")\(n)\(ordSuffix(n))"
    }
    return t
  }

  // MARK: - Keep-magnitude (house style)

  private func keepMagnitude(_ t: String) -> String {
    // ONLY comma-grouped numbers: everything WE render >=1000 carries commas, so a bare digit
    // run (8000000, an ID/phone/account/serial) is passthrough input and must NOT collapse.
    // (?!\.\d) so '$5,000,000.00' is not split into '$5 million.00'.
    return reSub(#"(?<cur>\$)?(?<n>\d{1,3}(?:,\d{3})+)\b(?!\.\d)"#, t, caseInsensitive: false) {
      m in
      let cur = m.g("cur") ?? ""
      guard let n = Int((m.g("n") ?? "").replacingOccurrences(of: ",", with: "")) else {
        return nil
      }
      for (word, val) in [
        ("trillion", 1_000_000_000_000), ("billion", 1_000_000_000),
        ("million", 1_000_000),
      ] {
        if n >= val && n % (val / 1000) == 0 {
          let xm = n / (val / 1000)  // value in thousandths of the magnitude
          if xm >= 1_000_000 { continue }  // coefficient >= 1000 -> not a clean "X mag"
          let coeff: String
          if xm % 1000 == 0 {
            coeff = String(xm / 1000)
          } else {
            coeff = stripTrailingZeros(String(format: "%.3f", Double(xm) / 1000.0))
          }
          return "\(cur)\(coeff) \(word)"
        }
      }
      return nil
    }
  }

  // MARK: - Punctuation

  private static let punct: [(String, String)] = [
    (#"\bnew paragraph\b"#, "\n\n"), (#"\bnew line\b"#, "\n"),
    (#"\s+comma\b"#, ","), (#"\s+period\b"#, "."), (#"\s+full stop\b"#, "."),
    (#"\s+question mark\b"#, "?"), (#"\s+exclamation (mark|point)\b"#, "!"),
    (#"\s+colon\b"#, ":"), (#"\s+semicolon\b"#, ";"),
  ]

  private func applyPunct(_ t0: String) -> String {
    var t = t0
    for (pat, rep) in Self.punct {
      t = reSub(pat, t) { _ in rep }
    }
    // capitalize sentence starts crudely (no case-insensitivity: targets lowercase only)
    t = reSub(#"(^|[.!?]\s+)([a-z])"#, t, caseInsensitive: false) { m in
      (m.g(1) ?? "") + (m.g(2) ?? "").uppercased()
    }
    return t
  }
}
