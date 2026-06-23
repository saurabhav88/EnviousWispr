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

  // ── AP-style number policy ──────────────────────────────────────────────────
  static let apThreshold = 10  // spell out 1..9, digits for 10+
  static let unitNouns: Set<String> = [
    "miles", "mile", "feet", "foot", "inch", "inches", "yard", "yards", "pound", "pounds", "lb",
    "lbs", "ounce", "ounces", "oz", "kg", "kilogram", "kilograms", "gram", "grams", "km",
    "kilometer", "kilometers", "meter", "meters", "metre", "metres", "cm", "centimeter",
    "centimeters", "liter", "liters", "litre", "litres", "gallon", "gallons", "cup", "cups",
    "tablespoon", "tablespoons", "tbsp", "teaspoon", "teaspoons", "tsp", "degree", "degrees",
    "mph", "percent", "milligram", "milligrams", "mg", "milliliter", "milliliters", "ml",
    "millimeter", "millimeters", "mm",
  ]
  static let agePeriods: Set<String> = [
    "year", "years", "month", "months", "week", "weeks", "day", "days",
  ]
  // compound-ordinal tails (additive): final ordinal word in 'one hundred (and) <tail>'.
  static let ordTail: [String: Int] = [
    "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7,
    "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13,
    "fourteenth": 14, "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18,
    "nineteenth": 19, "twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50,
    "sixtieth": 60, "seventieth": 70, "eightieth": 80, "ninetieth": 90,
  ]
  // scale ordinals: '(coeff) hundredth/thousandth/...' -> coeff*scale, suffix 'th'.
  static let ordScale: [String: Int] = [
    "hundredth": 100, "thousandth": 1000, "millionth": 1_000_000, "billionth": 1_000_000_000,
  ]
  /// `re.sub(r"[^a-z]", "", w.lower())` — strip to bare lowercase letters.
  static func clean(_ w: String) -> String {
    String(w.lowercased().unicodeScalars.filter { ("a"..."z").contains(Character($0)) })
  }

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
  // AP additions
  static let numwordNoAnd = numword.subtracting(["and"])
  static let numwordNoAndAlt = alt(numwordNoAnd)
  // range/slash/by token: a number-word (no "and") OR an already-digit token.
  static let rangeTok = alt(numwordNoAnd) + #"|\d[\d,]*"#
  static let rangeTokFull = alt(numword) + #"|\d[\d,]*"#  // later tokens may be "and"
  static let rangeRun = #"(?:"# + rangeTok + #")(?:\s+(?:"# + rangeTok + #"))*"#  // no "and" (between)
  // to/through/slash/by endpoints allow an internal "and" so spoken hundreds parse whole
  // ("one hundred and five to one hundred and ten" -> "105-110", not "100 5-100 and 10").
  static let rangeRunAnd = #"(?:"# + rangeTok + #")(?:\s+(?:"# + rangeTokFull + #"))*"#
  // bare number-word run (no "and"), for the cardinal pass.
  static let numwordRun = #"(?:"# + numwordNoAndAlt + #")(?:\s+(?:"# + numwordAlt + #"))*"#
  static let ordTailAlt = alt(Array(ordTail.keys))
  static let ordScaleAlt = alt(Array(ordScale.keys))
  static let cardRun = #"(?:"# + numwordAlt + #")(?:\s+(?:"# + numwordAlt + #"))*"#

  // MARK: - Public entry point

  public func normalize(_ text: String) -> String {
    var t = " " + text.trimmingCharacters(in: .whitespacesAndNewlines) + " "

    // "shout" = the whole utterance is upper-case (typed in caps). In shout text a capitalized
    // number word is a number, not a proper noun, so the cardinal pass converts it. Computed from
    // the original text (capitalization is preserved through the passes). A Title fragment inside
    // normal text ('TWELVE ANGRY MEN screened tonight') is NOT shout, so titles stay protected.
    let lineAlpha = String(
      text.unicodeScalars.filter {
        ("A"..."Z").contains(Character($0)) || ("a"..."z").contains(Character($0))
      })
    let shout = lineAlpha.count > 1 && lineAlpha == lineAlpha.uppercased()

    // register-preserve (our enhancement): keep "quarter to/past N", "half past N" spelled,
    // plus ordinal idioms ("eleventh hour"). Shielded from the number passes via a sentinel.
    var protected: [String] = []
    let protect: (Match) -> String? = { m in
      protected.append(m.whole)
      return " \u{0}\(protected.count - 1)\u{0} "
    }
    let protectSub: (String) -> String = { val in
      protected.append(val)
      return " \u{0}\(protected.count - 1)\u{0} "
    }
    t = reSub(#"\b(?:a |an )?(?:quarter|half)\s+(?:past|to)\s+\w+"#, t) { protect($0) }
    t = reSub(
      #"\beleventh hour\b|\bseventh heaven\b|\bthe fourth wall\b|\bthe fifth wheel\b"#
        + #"|\bthe fifth column\b|\bthe fourth estate\b|\bfirst among equals\b"#, t
    ) { protect($0) }
    // AP "a hundred": shield approximations ("a couple/few/several/many hundred" stay spelled),
    // then drop the article on a bare "a/an hundred" so the cardinal pass yields 100 (not "a 100").
    t = reSub(#"\b(?:a |an )?(?:couple|few|several|many)\s+hundred\b"#, t) { protect($0) }
    // lowercase only: a capitalized "A Hundred ..." is a title ("A Hundred Years of Solitude"),
    // not a number — dropping its article would corrupt the title.
    // not before a hyphenated compound ("a hundred-year lease" keeps its article); only bare
    // "a hundred <noun>" drops the article so the cardinal yields 100.
    t = reSub(#"\b(?:a|an)\s+(hundred\b)(?!-)"#, t, caseInsensitive: false) { m in
      " " + (m.g(1) ?? "")
    }
    // idiom: keep "the whole nine yards" spelled despite the unit rule on "yards"
    t = reSub(#"\bthe whole nine yards\b"#, t) { protect($0) }
    // idiom "Catch-22" ONLY as a determiner-led noun phrase ("a/the/that catch twenty two"), so the
    // literal verb usage "catch twenty two fish" still becomes "catch 22 fish".
    t = reSub(#"\b(a|an|the|this|that|another)\s+catch[\s-]+twenty[\s-]+two\b"#, t) { m in
      " \(m.g(1) ?? "") " + protectSub("Catch-22")
    }
    t = reSub(#"\b(a|an|the|this|that|another)\s+catch[\s-]+22\b"#, t) { m in
      " \(m.g(1) ?? "") " + protectSub("Catch-22")
    }
    // join hyphenated number compounds: "twenty-two" -> "twenty two" so the run parses as 22.
    // EXCLUDE "and": a hyphenated "and" ("one-and-done") is an idiom, not a spoken compound.
    // First part any-case, second part LOWERCASE: joins "twenty-two" and sentence-start
    // "Twenty-two" (-> 22) but NOT the Title "Twenty-Two" (a name; second part capitalized).
    // second part may also be an ordinal tail ("twenty-first" -> "twenty first" -> "21st").
    let hyphenJoinPat =
      #"\b((?i:"# + Self.numwordNoAndAlt + #"))-(?=(?:"# + Self.numwordNoAndAlt + #"|"#
      + Self.ordTailAlt + #")\b)"#
    var prev = ""
    while prev != t {
      prev = t
      t = reSub(hyphenJoinPat, t, caseInsensitive: false) { m in (m.g(1) ?? "") + " " }
    }

    t = emails(t)
    t = urls(t)
    // protect spoken dotted chains (versions / IP-like: "one dot two dot three", >=2 dots) so the
    // 'dot'-decimal path can't partly convert them ("1.2 dot three"). A single "X dot Y" still
    // becomes a decimal; only multi-dot chains are shielded and left for the AI-polish layer.
    let dotPart =
      #"(?:"# + Self.digitWordAlt + #"|\d[\d,]*)(?:\s+(?:"# + Self.digitWordAlt + #"|\d[\d,]*))*"#
    let dotChainPat: String = #"\b"# + dotPart + #"(?:\s+dot\s+"# + dotPart + #"){2,}\b"#
    t = reSub(dotChainPat, t) { protect($0) }
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
    // year must be year-SHAPED (>=2 number words: "twenty twelve", "two thousand nine"); a single
    // word ("On June second, five people signed up") is a count, not a year -> no false date match.
    let datePat =
      #"\s(?<mon>"# + Self.monthsAlt + #")\s+(?<day>"# + ordAlt + #"|\d{1,2}),?\s+(?<yr>(?:"#
      + Self.numwordAlt + #")(?:\s+(?:"# + Self.numwordAlt + #")){1,3})(?=[\s.,;:!?)\]”"']|$)"#
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

    // AP word-ranges / word-slashes / dimensions: BEFORE the cardinal threshold so spoken
    // endpoints are digitized (a range/date is a numeric context -> digits regardless of size).
    // Endpoints may be number-words OR already-digit tokens; pure-digit pairs defer to the guarded
    // numeric passes below.
    func rng(_ a: String, _ b: String) -> String? {
      let digitCommaSpace: (String) -> Bool = { s in
        !s.isEmpty && s.allSatisfy { ("0"..."9").contains($0) || $0 == "," || $0 == " " }
      }
      if digitCommaSpace(a) && digitCommaSpace(b) { return nil }  // pure-digit -> numeric pass owns it
      guard let x = Self.wordsToInt(Self.splitWords(a.lowercased())),
        let y = Self.wordsToInt(Self.splitWords(b.lowercased()))
      else { return nil }
      return "\(comma(x))-\(comma(y))"  // group thousands ("one thousand to two thousand"->1,000-2,000)
    }
    let betweenPat =
      #"\bbetween\s+(?<a>"# + Self.rangeRun + #")\s+and\s+(?<b>"# + Self.rangeRun + #")\b"#
    // 'between A and B' uses no-"and" endpoints (the "and" is the separator). When an endpoint
    // itself contains "and" ("between one hundred and five and one hundred and ten") the split is
    // ambiguous, so DECLINE rather than corrupt: a trailing "and <number>" means the endpoint was
    // truncated — leave the phrase spelled for the AI-polish layer.
    let trailAndPat = #"^\s+and\s+(?:"# + Self.numwordAlt + #"|\d)"#  // number-word OR digit endpoint
    t = reSub(betweenPat, t) { m in
      let end = m.result.range.location + m.result.range.length
      if firstMatch(trailAndPat, m.ns.substring(from: end)) != nil { return nil }
      guard let r = rng(m.g("a") ?? "", m.g("b") ?? "") else { return nil }
      return " between \(r) "
    }
    let toPat =
      #"\b(?<a>"# + Self.rangeRunAnd + #")\s+(?:to|through)\s+(?<b>"# + Self.rangeRunAnd + #")\b"#
    t = reSub(toPat, t) { m in
      guard let r = rng(m.g("a") ?? "", m.g("b") ?? "") else { return nil }
      return " \(r) "
    }
    // match ALL slash-separated parts (not just 2-3) so a 4+ chain isn't left half-rewritten.
    let wslashPat =
      #"\b(?<a>"# + Self.rangeRunAnd + #")(?:\s+slash\s+(?:"# + Self.rangeRunAnd + #"))+\b"#
    t = reSub(wslashPat, t) { m in
      let parts = splitOnSlash(m.whole)
      let vals = parts.compactMap { Self.wordsToInt(Self.splitWords($0.lowercased())) }
      guard vals.count == parts.count else { return nil }
      return " " + vals.map { String($0) }.joined(separator: "/") + " "
    }
    // match ALL legs so a 3D size ("two by four by six" -> "2 by 4 by 6") is fully normalized.
    let byPat = #"\b(?<a>"# + Self.rangeRunAnd + #")(?:\s+by\s+(?:"# + Self.rangeRunAnd + #"))+\b"#
    t = reSub(byPat, t) { m in
      let parts = splitOnBy(m.whole)
      let legs = parts.compactMap { Self.wordsToInt(Self.splitWords($0.lowercased())) }
      guard legs.count == parts.count else { return nil }
      // idiom guard: "one by one" is prose ("do it one by one"), not a dimension. Narrow to
      // all-ones AND no unit noun after (so "one by one inch" stays a real dimension). "two by
      // two", "three by three", or any >=10 are dimensions and convert.
      let end = m.result.range.location + m.result.range.length
      let nxtAfter = Self.clean(Self.splitWords(m.ns.substring(from: end)).first ?? "")
      if Set(legs) == [1], !Self.unitNouns.contains(nxtAfter) { return nil }
      return " " + legs.map { comma($0) }.joined(separator: " by ") + " "
    }

    // generic cardinals -> AP policy. spell 1-9, digits 10+, with digit-forcing exceptions
    // (age / measurement unit) and ALL-CAPS handling (shout convert / isolated emphasis / Title
    // protect). A capitalized number word with no unit/operator anchor stays a word — it is
    // ambiguous between a count and a proper noun ("Hundred Acre Wood", "One Million Moms"), left
    // to the AI-polish layer. Unit-anchored caps ARE handled (see currency/percent/decimals).
    // First token may NOT be "and" (else "cats and fifteen" matches as a run and drops the "and");
    // subsequent tokens may be the full numword set ("one hundred and one").
    let cardPat = #"\b(?:"# + Self.numwordNoAndAlt + #")\b(?:\s+(?:"# + Self.numwordAlt + #")\b)*"#
    t = reSub(cardPat, t) { m in
      let raw = m.whole
      var words = Self.splitWords(raw)
      if words.isEmpty || raw.trimmingCharacters(in: .whitespaces) == "and" { return nil }
      // a trailing "and" is a conjunction, not part of the number ("Twenty and change"); strip it
      // and re-append so it isn't swallowed (wordsToInt ignores "and", which would drop it).
      var trailAnd = 0
      while let last = words.last, last.lowercased() == "and" {
        words.removeLast()
        trailAnd += 1
      }
      if words.isEmpty { return nil }
      let tailAnd = String(repeating: " and", count: trailAnd)
      let start = m.result.range.location
      let end = start + m.result.range.length
      let after = m.ns.substring(from: end)
      let toksAfter = Self.splitWords(after)
      let nxt = toksAfter.first ?? ""
      let nxtCap = nxt.first?.isUppercase ?? false
      // a capitalized hyphenated compound ('Twenty-Two') is not joined (lowercase-only join) and
      // the proper-noun guard can't see past the leading '-'; leave the whole compound spelled
      // rather than convert only the first half into '20-Two'.
      if after.first == "-",
        Self.numword.contains(Self.clean(nxt)) || Self.ordTail[Self.clean(nxt)] != nil
      {
        return nil  // capitalized hyphenated compound/ordinal ("Twenty-Two","Twenty-First") -> leave
      }
      guard let n = Self.wordsToInt(words.map { $0.lowercased() }) else {
        // dosage salvage: a failed run ending in a 1-9 word a unit noun anchors
        // ('two five milligram' = count + dosage -> 'two 5 milligram'); keep the count spelled.
        let lw = (words.last ?? "").lowercased()
        if words.count >= 2, let v = Self.units[lw], (1..<Self.apThreshold).contains(v),
          Self.unitNouns.contains(Self.clean(nxt))
        {
          return " \(words.dropLast().joined(separator: " ")) \(v)\(tailAnd) "
        }
        return nil
      }
      let firstCap = words[0].first?.isUppercase ?? false
      let noninitialCap = words.dropFirst().contains { $0.first?.isUppercase ?? false }
      let single = words.count == 1
      let capsw: (String) -> Bool = { w in
        !w.isEmpty && w.contains(where: { $0.isLetter }) && w == w.uppercased()
      }
      let runAllcaps = raw.contains(where: { $0.isLetter }) && raw == raw.uppercased()
      var capsConvert = false
      if runAllcaps {
        if shout {
          capsConvert = true
        } else {
          let prevW = Self.splitWords(m.ns.substring(to: start)).last ?? ""
          if capsw(prevW) || capsw(nxt) { return nil }  // part of an all-caps Title -> leave
          capsConvert = true  // isolated caps number = emphasis -> convert
        }
      }
      if !capsConvert {
        if noninitialCap { return nil }  // "One Million Moms"
        if firstCap && single && nxtCap { return nil }  // brand "Hundred Acre Wood","Forty Niners"
        if firstCap {
          var before = m.ns.substring(to: start)
          while let last = before.last, last.isWhitespace { before.removeLast() }
          let sentinel: Set<Character> = [".", "!", "?", "\n", "\"", "'", "(", "["]
          let sentenceInitial = before.isEmpty || sentinel.contains(before.last!)
          if !sentenceInitial { return nil }  // capitalized mid-sentence, ambiguous -> spelled
        }
      }
      var force = false
      if n < Self.apThreshold {
        let nxtw = Self.clean(nxt)
        if Self.unitNouns.contains(nxtw) {
          force = true
        } else if nxtw == "square" || nxtw == "cubic", toksAfter.count >= 2,
          Self.unitNouns.contains(Self.clean(toksAfter[1]))
        {
          force = true  // unit with a modifier: "two square miles", "two cubic meters"
        } else if Self.agePeriods.contains(nxtw), toksAfter.count >= 2,
          Self.clean(toksAfter[1]) == "old"
        {
          force = true
        } else if firstMatch(#"^-(?:year|month|week|day)s?-old\b"#, after) != nil {
          // hyphenated age compound ("five-year-old") is one token; AP uses figures for ages.
          force = true
        }
      }
      if n >= Self.apThreshold || force { return " \(comma(n))\(tailAnd) " }
      return nil
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

    // decimal percent: "5.5 percent" -> "5.5%" (the word-amount percent pass can't span the dot).
    t = reSub(#"\b(\d[\d,]*\.\d+)\s+(?:percent|per\s+cent)\b"#, t) { m in "\(m.g(1) ?? "")% " }

    t = keepMagnitude(t)  // '$80,000,000'->'$80 million' (founder house style), keep the word
    t = applyPunct(t)

    // restore register-preserved spans verbatim
    for (i, p) in protected.enumerated() {
      t = t.replacingOccurrences(
        of: "\u{0}\(i)\u{0}", with: p.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    t = reSub(#"\s+([,.!?;:])"#, t, caseInsensitive: false) { m in m.g(1) }
    t = reSub(#"([(\[“‘])\s+"#, t, caseInsensitive: false) { m in m.g(1) }  // open quote/bracket tight
    t = reSub(#"\s+([)\]”’])"#, t, caseInsensitive: false) { m in m.g(1) }  // space before close tight
    // straight-quoted number: tighten ONLY when a number is fully enclosed in straight quotes
    // ('" 23 "' -> '"23"'). A single-sided rule corrupted adjacent quotes ('twenty "special"' ->
    // '20"special"'), so require both quotes around the number.
    t = reSub(#""\s+(\d[\d.,]*)\s+""#, t, caseInsensitive: false) { m in "\"\(m.g(1) ?? "")\"" }
    // hyphenated compound modifier: converting "twenty-step" leaves "20 -step" (the cardinal pass
    // re-emits " 20 " with pad spaces). Re-tighten "digit space-hyphen word" -> "digit-word".
    t = reSub(#"(\d)\s+-(\w)"#, t, caseInsensitive: false) { m in "\(m.g(1) ?? "")-\(m.g(2) ?? "")"
    }
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

  private func decimals(_ t0: String) -> String {
    var t = t0
    let sep = #"(?:point|dot)"#  // 'dot' accepted alongside 'point' (spoken versions / measures)
    let endB = #"(?=[\s.,;:!?)\]”"']|$)"#
    func digsOf(_ s: String) -> String {
      Self.splitWords(s.lowercased()).compactMap { Self.units[$0].map { String($0) } }.joined()
    }
    let pat =
      #"\s(?<w>(?:"# + Self.numtok + #")(?:\s+(?:"# + Self.numtok + #"))*)\s+"# + sep + #"\s+"#
      + #"(?<d>(?:"# + Self.digitWordAlt + #")(?:\s+(?:"# + Self.digitWordAlt + #"))*)"#
      + #"(?:\s+(?<scale>million|billion|thousand))?"# + endB
    t = reSub(pat, t) { m in
      // 'point'/'dot' anchors numeric intent, so lowercasing the captured amount is corruption-safe.
      guard let whole = Self.wordsToInt(Self.splitWords((m.g("w") ?? "").lowercased())) else {
        return nil
      }
      let digs = digsOf(m.g("d") ?? "")
      let scale = (m.g("scale") ?? "").trimmingCharacters(in: .whitespaces).lowercased()
      if !scale.isEmpty, let sv = Self.scales[scale] {
        let value = (Double("\(whole).\(digs)") ?? 0) * Double(sv)
        return " \(comma(Int(value.rounded(.toNearestOrEven)))) "
      }
      return " \(whole).\(digs) "
    }
    // leading decimal (no integer word): 'negative point five'->'-0.5', 'point three zero one'
    // ->'0.301'. Fired only when unambiguous (sign word present, or >=3 fractional digits) so the
    // everyday noun 'point' ('at this point one thing') is safe.
    // LEADING decimal uses 'point' ONLY (never 'dot'): a leading 'dot N' is almost always a spoken
    // dotted identifier / IP segment, not a decimal, so converting it would corrupt the address.
    // (The main path keeps 'dot' — its required whole-number part disambiguates 'two dot oh'->2.0.)
    let leadPat =
      #"\s(?<sg>negative\s+|minus\s+)?point\s+(?<d>(?:"# + Self.digitWordAlt
      + #")(?:\s+(?:"# + Self.digitWordAlt + #"))*)"# + endB
    t = reSub(leadPat, t) { m in
      let sign = (m.g("sg") ?? "").trimmingCharacters(in: .whitespaces).lowercased()
      let digs = digsOf(m.g("d") ?? "")
      if sign.isEmpty && digs.count < 3 { return nil }
      return " \(sign.isEmpty ? "" : "negative ")0.\(digs) "
    }
    return t
  }

  // MARK: - Currency / percent

  private func moneyPct(_ t0: String) -> String {
    var t = t0
    // trailing boundary is a LOOKAHEAD (whitespace OR sentence punctuation OR end), not a consumed
    // space — otherwise a sentence-final "...dollars." / "...percent." never fires. "per cent"
    // (two words) is accepted alongside "percent".
    let endB = #"(?=[\s.,;:!?)\]”"']|$)"#
    let curPat =
      #"\s((?<d>(?:"# + Self.numtok + #")(?:\s+(?:"# + Self.numtok + #"))*)\s+dollars?"#
      + #"(?:\s+and\s+(?<c>(?:"# + Self.numtok + #")(?:\s+(?:"# + Self.numtok
      + #"))*)\s+cents?)?)"# + endB
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
      #"\s((?<c>(?:"# + Self.numtok + #")(?:\s+(?:"# + Self.numtok + #"))*)\s+cents?)"# + endB
    t = reSub(centsPat, t) { m in
      guard let c = Self.wordsToInt(Self.splitWords((m.g("c") ?? "").lowercased())) else {
        return nil
      }
      return " $\(String(format: "%.2f", Double(c) / 100.0)) "
    }
    let pctPat =
      #"\s((?:"# + Self.numtok + #")(?:\s+(?:"# + Self.numtok + #"))*)\s+(?:percent|per\s+cent)"#
      + endB
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
    // scale ordinals: 'one thousandth'->1,000th, 'two hundredth'->200th, bare 'thousandth'
    // ->1,000th. Optional cardinal coefficient.
    let scaleCard = [
      "hundredth": "hundred", "thousandth": "thousand", "millionth": "million",
      "billionth": "billion",
    ]
    let scalePat = #"\b(?:(?<lead>"# + Self.cardRun + #")\s+)?(?<s>"# + Self.ordScaleAlt + #")\b"#
    t = reSub(scalePat, t) { m in
      let sword = (m.g("s") ?? "").lowercased()
      let n: Int
      if let lead = m.g("lead") {
        // reconstruct the full cardinal phrase ('one thousand one hundredth' -> 'one thousand one
        // hundred' = 1100) instead of multiplying the lead (which overcounts compounds).
        guard
          let v = Self.wordsToInt(Self.splitWords((lead + " " + scaleCard[sword]!).lowercased()))
        else { return nil }
        n = v
      } else {
        n = Self.ordScale[sword]!  // bare 'thousandth' -> 1000th
      }
      return " \(comma(n))\(ordSuffix(n)) "
    }
    // additive compound with a SCALE lead: 'one hundred (and) tenth'->110th, 'hundred and first'
    // ->101st. Lead must end in a scale word so this never touches 'twenty third' (comp owns that).
    let leadScale =
      #"(?:(?:"# + Self.numwordAlt + #")\s+)*(?:hundred|thousand|million|billion)(?:\s+and)?"#
    let addPat = #"\b(?<lead>"# + leadScale + #")\s+(?<o>"# + Self.ordTailAlt + #")\b"#
    t = reSub(addPat, t) { m in
      guard let base = Self.wordsToInt(Self.splitWords((m.g("lead") ?? "").lowercased())) else {
        return nil
      }
      let n = base + Self.ordTail[(m.g("o") ?? "").lowercased()]!
      return " \(comma(n))\(ordSuffix(n)) "
    }
    // compound: '<tens> <unit-ordinal>' -> 'Nth' ('seventy third'->73rd), capturing the next word
    // so the 'second' duration guard fires ('thirty second video'->left). Result is always >=21.
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
    // standalone: 'tenth'->10th, 'twentieth'->20th. AP: spell first-ninth, so values <10 stay.
    let simpleAlt = Self.alt(Array(Self.ordStandalone.keys))
    t = reSub(#"\b(?:"# + simpleAlt + #")\b"#, t) { m in
      let n = Self.ordStandalone[m.whole.lowercased()]!
      if n < Self.apThreshold { return nil }  // first-ninth stay spelled under AP
      return "\(n)\(ordSuffix(n))"
    }
    // contextual first/second/third are all <10 under AP -> stay spelled (no conversion pass).
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
