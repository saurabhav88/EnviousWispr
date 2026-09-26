import Foundation

/// #3210: spoken identifiers the number passes used to leave half-converted.
///
/// Founder dictations, 2026-09-26 (`app.log`, RAW ASR → deterministic output):
/// `Version two point five point zero.` → `Version 2.5 point zero.`,
/// `One nine two dot one six eight dot one dot one.` unchanged, `S dash one.` unchanged.
/// Parakeet writes these shapes itself for a clean synthetic voice
/// (`docs/audits/2026-09-26-3210-spoken-codes/`, 42 clips) and leaves them spoken for the
/// founder's real voice, so both forms reach this layer.
///
/// Every pass here converts a whole identifier or nothing: a part it cannot read refuses the
/// match, because a half-converted identifier ("2.5 point zero") looks broken where the spoken
/// form merely looks unconverted.
extension InverseTextNormalizer {

  // MARK: - Connector words

  /// Spoken separators inside a dotted number ("two point five point zero", "eins neun zwei
  /// Punkt …"). English words may join NUMBER WORDS; every other word joins DIGITS only,
  /// because this file reads English number words and nothing else.
  static let englishNumberDotWords: Set<String> = ["point", "dot"]
  /// German `Punkt`, Spanish/Italian `punto`, Portuguese `ponto`. French says `point`, which
  /// the English set already holds.
  static let foreignNumberDotWords: Set<String> = ["punkt", "punto", "ponto"]
  static let numberDotWordAlt = alt(englishNumberDotWords.union(foreignNumberDotWords))

  /// Spoken hyphens between a code and its number ("S dash one", "B Bindestrich 2"). The
  /// English words may be followed by number words; the others by digits only (same reason as
  /// the dot words). Measured on Parakeet (`docs/audits/2026-09-26-3210-spoken-codes/`): it keeps
  /// `trattino` and `traço` as words beside a digit (`S trattino 1.`, `S traço 1.`).
  static let englishDashWords: Set<String> = ["dash", "hyphen"]
  static let foreignDashWords: Set<String> = [
    "strich", "bindestrich",  // German
    "tiret",  // French
    "guion", "guión",  // Spanish
    "trattino",  // Italian
    "traço", "hífen", "hifen",  // Portuguese
  ]
  static let dashWordAlt = alt(englishDashWords.union(foreignDashWords))

  /// One number inside an identifier: a digit run, or English number words without "and"
  /// (units, teens, tens, hundred).
  static let identifierNumberWordAlt = alt(
    Set(units.keys).union(tens.keys).union(["hundred"]))
  static let identifierPartPat =
    #"(?:\d+|(?:"# + identifierNumberWordAlt + #")(?:\s+(?:"# + identifierNumberWordAlt + #"))*)"#

  /// The digits one identifier part spells, or nil. A run of single digit words is read digit by
  /// digit ("one nine two" → 192, "oh" → 0); anything else must be one cardinal ("twelve",
  /// "one hundred sixty eight"). `allowWords` is false for a part joined by a non-English
  /// connector.
  static func identifierPartDigits(_ raw: String, allowWords: Bool) -> String? {
    let words = splitWords(raw.lowercased())
    guard !words.isEmpty else { return nil }
    if words.count == 1, isFixedDigits(words[0], 1...9) { return words[0] }
    guard allowWords else { return nil }
    if words.allSatisfy({ (units[$0].map { $0 < 10 }) ?? false }) {
      return words.map { String(units[$0]!) }.joined()
    }
    return wordsToInt(words).map(String.init)
  }

  /// True when a connector word stands just before or just after the match with more after it:
  /// the spoken identifier goes on past what the pass read, and converting the readable part is a
  /// half-conversion. Bounded windows, so a long take stays linear.
  func identifierContinues(_ m: Match, connectorAlt: String) -> Bool {
    let r = m.result.range
    let lead = min(r.location, 24)
    let end = r.location + r.length
    let before = m.ns.substring(with: NSRange(location: r.location - lead, length: lead))
    let after = m.ns.substring(with: NSRange(location: end, length: min(m.ns.length - end, 24)))
    // A digit right after means the recogniser split one number ("S dash 1 2", diff review).
    return firstMatch(#"(?:^|\s)(?:"# + connectorAlt + #")\s+$"#, before) != nil
      || firstMatch(#"^\s+(?:"# + connectorAlt + #")\s+\S"#, after) != nil
      || firstMatch(#"^\s+\d"#, after) != nil
  }

  // MARK: - Dotted numbers: versions and IP addresses

  /// "two point five point zero" → `2.5.0`, "one nine two dot one six eight dot one dot one" →
  /// `192.168.1.1`, "2.5 point zero" → `2.5.0`, "2 Punkt 5 Punkt 0" → `2.5.0`.
  ///
  /// Needs two or more separators (or one after an already-dotted number), so a single "X point
  /// Y" stays the decimal pass's job. Replaces the earlier shield that protected spoken `dot`
  /// chains and left them for AI polish: polish did not convert them (founder log above), and the
  /// shield existed to stop the decimal pass converting HALF a chain, which a whole-chain
  /// conversion also prevents.
  func dottedNumberChains(_ t: String, englishWords: Bool) -> String {
    let part = englishWords ? Self.identifierPartPat : #"\d+"#
    let sep = #"\s+(?:"# + Self.numberDotWordAlt + #")\s+"#
    let pat =
      #"(?<![\w.])(?:\d+(?:\.\d+)+(?:"# + sep + part + #")+|"# + part + #"(?:"# + sep + part
      + #"){2,})(?![\w]|\.\d)"#
    return reSub(pat, t) { m in
      // The chain must be the WHOLE identifier. A separator or a "double"/"triple" digit word
      // just before it, or a separator just after it, means the spoken identifier goes on in a
      // part this pass cannot read ("two two five dot double five dot o dot four o"), and
      // converting the readable tail is the half-conversion this pass exists to end. Refused
      // here, it is shielded whole by the caller.
      if identifierContinues(m, connectorAlt: Self.numberDotWordAlt + "|double|triple") {
        return nil
      }
      // Split on the spoken separators; an already-dotted first part splits on its dots.
      let pieces = splitOnPattern(m.whole, #"\s+(?:"# + Self.numberDotWordAlt + #")\s+"#)
      let seps = allMatches(#"\s+("# + Self.numberDotWordAlt + #")\s+"#, m.whole).map {
        $0.lowercased()
      }
      let englishOnly = seps.allSatisfy { Self.englishNumberDotWords.contains($0) }
      var out: [String] = []
      for (i, piece) in pieces.enumerated() {
        if i == 0, piece.contains(".") {
          out.append(piece)
          continue
        }
        guard let digits = Self.identifierPartDigits(piece, allowWords: englishOnly) else {
          return nil
        }
        out.append(digits)
      }
      return out.joined(separator: ".")
    }
  }

  /// "Python three point twelve" → `Python 3.12`. The decimal pass reads single digits after
  /// "point" only, so a two-digit minor version came out as "three point 12". A cardinal minor
  /// part is read ONLY after a name-shaped word or a version word: "at one point twelve people
  /// left" is prose, and "point" is an everyday noun.
  func twoDigitMinorVersions(_ t: String) -> String {
    let minor =
      #"(?:(?:"# + Self.tensAlt + #")(?:\s+(?:"# + Self.unit19Alt + #"))?|"#
      + Self.teenAlt + #")"#
    let pat =
      #"(?<lead>\b(?:version|v|release|build|update|[A-Z][A-Za-z]*|[a-z]+[A-Z][A-Za-z]*))\s+"#
      + #"(?<major>(?i:"# + Self.identifierPartPat + #"))\s+(?i:point)\s+(?<minor>(?i:"# + minor
      + #"))"#
      + #"(?=[\s.,;:!?)\]”"']|$)"#
    return reSub(pat, t, caseInsensitive: false) { m in
      let lead = m.g("lead") ?? ""
      guard !Self.minorVersionRefusedLeads.contains(lead.lowercased()) else { return nil }
      // "Python three point twelve point x": the version goes on past what reads.
      guard !identifierContinues(m, connectorAlt: Self.numberDotWordAlt) else { return nil }
      guard let major = Self.identifierPartDigits(m.g("major") ?? "", allowWords: true),
        let minor = Self.wordsToInt(Self.splitWords((m.g("minor") ?? "").lowercased()))
      else { return nil }
      return "\(lead) \(major).\(minor)"
    }
  }

  /// Capitalised function words that start a sentence ("At one point twenty people left").
  static let minorVersionRefusedLeads: Set<String> = [
    "at", "to", "in", "on", "by", "for", "of", "and", "or", "but", "the", "a", "an", "from",
    "with", "about", "after", "before", "around", "until", "since", "so", "then", "when", "if",
    "we", "i", "it", "he", "she", "they", "you", "there", "that", "this",
  ]

  // MARK: - Dashed codes: S-1, F-16, GPT-40, COVID-19

  /// An upper-case code of one to five letters, a spoken dash, then a number. Upper case is the
  /// evidence: Parakeet capitalises a spelled letter or an acronym, and a lower-case word before
  /// "dash" is prose ("make a dash for it", "a dash of salt" has no number after it anyway). A
  /// lone `I` is the pronoun, refused as the list-marker pass refuses it. Up to four single
  /// capitals may precede the code, for a spelled acronym.
  func dashedCodes(_ t: String, englishWords: Bool) -> String {
    // "S dash one hundred and two": the number may carry an internal "and" after "hundred" or
    // "thousand" only, so "S dash 12 and 3" keeps its separate 3 (local Codex r1, diff review).
    let number =
      englishWords
      ? Self.identifierPartPat + #"(?:(?<=hundred|thousand)\s+and\s+"# + Self.identifierPartPat
        + #")*"# : #"\d+"#
    let pat =
      #"(?<![\w-])(?:(?<code>(?:[A-Z][ \t]+){0,3}[A-Z]{1,5})\s+(?<dw>(?i:"# + Self.dashWordAlt
      + #"))\s+|(?<hcode>[A-Z]{1,5}|[a-z])-[ \t]+)(?<num>(?i:"# + number + #"))(?![\w-])"#
    return reSub(pat, t, caseInsensitive: false) { m in
      // A spelled acronym arrives as separate capitals ("E G dash one", founder log); the code
      // is the letters joined, as the recogniser writes the unspoken form ("EG-1").
      // The recogniser also writes the dash itself and leaves the number spoken: "s- one" (Live
      // UAT, 2026-09-26, Parakeet in the app). A lone letter there is a spelled capital.
      let hcode = m.g("hcode")
      let code =
        hcode.map { $0.count == 1 ? $0.uppercased() : $0 }
        ?? (m.g("code") ?? "").filter { !$0.isWhitespace }
      guard code != "I", hcode?.lowercased() != "a", hcode != "i" else { return nil }
      // "A dash B dash one", "S dash one dash x": the code goes on past what reads.
      guard !identifierContinues(m, connectorAlt: Self.dashWordAlt) else { return nil }
      let dw = (m.g("dw") ?? "").lowercased()
      let allowWords = englishWords && (hcode != nil || Self.englishDashWords.contains(dw))
      guard let digits = Self.identifierPartDigits(m.g("num") ?? "", allowWords: allowWords)
      else { return nil }
      return "\(code)-\(digits)"
    }
  }

  // MARK: - Dashed dates

  /// "twenty twenty six dash nine dash twenty six" → `2026-09-26`, and the recogniser's own
  /// unpadded `2026-9-26` → `2026-09-26`. Only a valid month and day convert; the year must be
  /// four digits or year-shaped words.
  func dashedDates(_ t: String, englishWords: Bool) -> String {
    var t = t
    if englishWords {
      let yearWords =
        #"(?:"# + Self.numwordNoAndAlt + #")(?:\s+(?:"# + Self.numwordNoAndAlt
        + #")){1,3}"#
      let pat =
        #"(?<![\w-])(?<y>\d{4}|"# + yearWords + #")\s+(?:dash|hyphen)\s+(?<m>"#
        + Self.identifierPartPat + #")\s+(?:dash|hyphen)\s+(?<d>"# + Self.identifierPartPat
        + #")(?![\w-])"#
      t = reSub(pat, t) { m in
        guard !identifierContinues(m, connectorAlt: "dash|hyphen") else { return nil }
        let yRaw = (m.g("y") ?? "").lowercased()
        guard let year = Int(yRaw) ?? Self.parseYear(Self.splitWords(yRaw)),
          (1000...2999).contains(year),
          let mon = Self.identifierPartDigits(m.g("m") ?? "", allowWords: true).flatMap({ Int($0) }
          ),
          let day = Self.identifierPartDigits(m.g("d") ?? "", allowWords: true).flatMap({ Int($0) }
          ),
          Self.isCalendarDate(year: year, month: mon, day: day)
        else { return nil }
        return "\(year)-\(pad2(mon))-\(pad2(day))"
      }
    }
    return reSub(#"(?<![\w.-])(\d{4})-(\d{1,2})-(\d{1,2})(?![\w-]|\.\d)"#, t) { m in
      guard !identifierContinues(m, connectorAlt: Self.dashWordAlt) else { return nil }
      guard let year = Int(m.g(1) ?? ""), let mon = Int(m.g(2) ?? ""), let day = Int(m.g(3) ?? ""),
        Self.isCalendarDate(year: year, month: mon, day: day),
        (m.g(2) ?? "").count == 1 || (m.g(3) ?? "").count == 1
      else { return nil }
      return "\(m.g(1) ?? "")-\(pad2(mon))-\(pad2(day))"
    }
  }

  /// A real calendar date: the day fits its month, February 29 only in a leap year
  /// ("2026 dash 2 dash 31" stays as spoken, second-pass review).
  static func isCalendarDate(year: Int, month: Int, day: Int) -> Bool {
    guard (1...12).contains(month), day >= 1 else { return false }
    let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    return day <= lengths[month - 1]
  }

  // MARK: - localhost ports

  /// "localhost colon three thousand" → `localhost:3000`. A port is never grouped with commas.
  func localhostPorts(_ t: String) -> String {
    let pat =
      #"\b(?<host>localhost)\s+colon\s+(?<p>(?:"# + Self.numwordNoAndAlt + #")(?:\s+(?:"#
      + Self.numwordNoAndAlt + #")|(?<=hundred|thousand)\s+and)*|\d[\d,]*)(?![\w])"#
    return reSub(pat, t) { m in
      let raw = (m.g("p") ?? "").replacingOccurrences(of: ",", with: "")
      let words = Self.splitWords(raw.lowercased())
      let port = Int(raw) ?? (Self.digitString(words) ?? Self.wordsToInt(words).map(String.init))
        .flatMap { Int($0) }
      guard let port, (1...65535).contains(port) else { return nil }
      return "\(m.g("host") ?? "localhost"):\(port)"
    }
  }

  // MARK: - Spoken protocol

  /// "https colon slash slash www.example.com …" → "https://www.example.com …", so the URL
  /// passes below read one address instead of refusing the host beside a spoken protocol.
  /// The word `http`/`https` only: the spelled "h t t p colon slash slash" shape has its own
  /// oracle rows (`parity_holdout.jsonl`) and is left to the punctuation pass. Converted only
  /// when a host follows, spoken or already joined.
  func spokenProtocolPrefix(_ t: String) -> String {
    let label = Self.urlHostLabelPat
    let slash = #"(?:forward\s+)?slash"#
    let pat =
      #"\b(?<p>https?)\s+(?:colon\s+|:\s*)"# + slash + #"\s+"# + slash + #"\s+(?="# + label
      + #")"#
    // The WHOLE host that follows decides, read greedily so it cannot stop at a supported ending
    // with more labels after it ("docs dot example dot com dot xyz", local Codex r2). Its last
    // label must be an ending the URL passes read: a spoken-dot host the spoken pass's set, a
    // fully joined host the joined pass's set.
    let chainPat = #"^"# + label + #"(?:(?:\.|\s+dot\s+)"# + label + #")+"#
    let spokenEnd = #"^(?:"# + Self.lowerRiskURLTLDAlt + "|" + Self.emailTLDAlt + #")$"#
    let joinedEnd = #"^(?:"# + Self.urlTLDAlt + #")$"#
    return reSub(pat, t) { m in
      let end = m.result.range.location + m.result.range.length
      let tail = m.ns.substring(with: NSRange(location: end, length: min(256, m.ns.length - end)))
      guard let chain = firstMatch(chainPat, tail) else { return nil }
      // URL syntax this file does not read, spoken right after the host ("… dot com question
      // mark page"), means the address goes on; the prefix alone would be a half-URL.
      let rest = (tail as NSString).substring(from: (chain as NSString).length)
      guard
        firstMatch(
          #"^\s+(?:question\s+mark|equals|ampersand|hash|pound|percent|tilde|underscore|colon)\b"#,
          rest) == nil
      else { return nil }
      let labels = splitOnPattern(chain, #"\.|\s+dot\s+"#)
      guard let last = labels.last?.lowercased(), labels.count > 1 else { return nil }
      let spoken = firstMatch(#"\s+dot\s+"#, chain) != nil
      guard firstMatch(spoken ? spokenEnd : joinedEnd, last) != nil else { return nil }
      // Mirror the spoken URL pass's own host checks, so the prefix never converts ahead of a
      // host that pass then refuses (local Codex r4): a country-code ending needs 2+ host labels,
      // and a one-label host that is an English function word is prose.
      if spoken {
        let hostLabels = Array(labels.dropLast())
        let lowRisk = firstMatch(#"^(?:"# + Self.lowerRiskURLTLDAlt + #")$"#, last) != nil
        guard hostLabels.count > 1 || lowRisk else { return nil }
        if hostLabels.count == 1, let host = hostLabels.first, host.count > 1,
          Self.englishProseDomainWords.contains(host.lowercased())
        {
          return nil
        }
      }
      return "\((m.g("p") ?? "https").lowercased())://"
    }
  }

  // MARK: - Language-neutral entry

  /// The subset of `normalize` that is safe on a NON-ENGLISH take (#3210 international scope).
  ///
  /// `InverseTextNormalizationStep` skips the English engine for a take the resolver reads as
  /// another language, because English number and time words collide with other languages
  /// (`ten` is a Polish demonstrative, German `am` is not the meridiem; #2763). These passes
  /// read no English number words: digits joined by a spoken dot or dash word, the
  /// recogniser's unpadded dates, and addresses whose at-word and dot-word belong to one
  /// language (`addressWordPairs`).
  public func normalizeLanguageNeutral(_ text: String) -> String {
    // No padding and no whitespace cleanup: none of these passes emits padding, so a take with
    // nothing to convert comes back byte-identical.
    var t = emails(text, neutral: true)
    t = dottedNumberChains(t, englishWords: false)
    t = dashedCodes(t, englishWords: false)
    return dashedDates(t, englishWords: false)
  }
}
