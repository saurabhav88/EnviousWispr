import Foundation

/// #3226: spoken addresses, links and codes in French, Spanish, Polish and Dutch, on a take the
/// app resolved as non-English (`normalizeLanguageNeutral`).
///
/// Target is the CORRECTLY HEARD sentence: a speaker of these languages uses WhisperKit with the
/// language set and repairs a misheard word with the custom dictionary, which runs before this
/// cleanup (founder, 2026-09-26). Measured on 120 Azure clips (#3226 baseline v3): perfect-hearing
/// transcripts 54/120 before this file. No open-source inverse normalizer covers these shapes for
/// Polish or Dutch (NeMo has fr/es spelled-letter emails only; survey on #3226); the word lists
/// follow NeMo's fr/es electronic tables and each language's own dictionary words.
///
/// Every pass converts a whole address or nothing, and runs ONLY on this route, so English output
/// is untouched. A lost word is never inferred: `Localhost 2.3000` stays as written.
extension InverseTextNormalizer {

  // MARK: - Word tables

  /// One language's spoken URL syntax. Multi-word phrases match with any whitespace between
  /// their words; `glueSlash` lets the recogniser's `schuine streephelp` read as slash + segment.
  struct SpokenURLWords {
    let dot: [String]
    let slash: [String]
    let colon: [String]
    let glueSlash: Bool
  }

  static let spokenURLWords: [SpokenURLWords] = [
    // French; Parakeet writes `bar oblique` for `barre oblique`.
    SpokenURLWords(
      dot: ["point"], slash: ["barre oblique", "bar oblique"],
      colon: ["deux points", "deux-points"], glueSlash: false),
    SpokenURLWords(dot: ["punto"], slash: ["barra"], colon: ["dos puntos"], glueSlash: false),
    SpokenURLWords(dot: ["kropka"], slash: ["ukośnik"], colon: ["dwukropek"], glueSlash: false),
    SpokenURLWords(
      dot: ["punt"], slash: ["schuine streep"], colon: ["dubbele punt"], glueSlash: true),
  ]

  /// `alt` for phrases: whitespace inside a phrase matches any run of whitespace, and a straight
  /// or typographic apostrophe matches either.
  static func phraseAlt(_ phrases: [String]) -> String {
    phrases.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
      .map { p in
        p.split(separator: " ").map {
          NSRegularExpression.escapedPattern(for: String($0)).replacingOccurrences(
            of: "'", with: "['’]")
        }.joined(separator: #"\s+"#)
      }.joined(separator: "|")
  }

  /// A Unicode label: letters (with combining marks after a base), digits, inner `_`/`-`.
  static let uLabel = #"[\p{L}\p{N}][\p{L}\p{M}\p{N}_-]*(?<![_-])"#
  /// Nothing that can continue a label may stand at a boundary.
  static let uLabelChar = #"[\p{L}\p{M}\p{N}_]"#
  static let neutralTLDAlt = alt(
    Set(
      ["com", "org", "io", "co", "dev", "me", "net", "edu", "gov", "ai", "app", "xyz"]
        + countryCodeTLDs))

  // MARK: - Dash words (neutral route only)

  /// Dash words the neutral route reads in a code, beside the shared `foreignDashWords`. Kept
  /// out of `dashWordAlt`, which the English route and the date guard also read.
  static let neutralOnlyDashWords = [
    "łącznik", "myślnik", "kreska",  // Polish
    "streepje", "koppelteken", "koppel teken",  // Dutch
    "trait d'union",  // French
  ]
  static let dutchDashWords: Set<String> = ["streepje", "koppelteken", "koppel teken"]
  static let neutralDashWordAlt =
    phraseAlt(Array(foreignDashWords) + neutralOnlyDashWords + Array(englishDashWords))
  /// Dutch digit words, read only as the number of a code joined by a Dutch dash word
  /// (`GPT streepje vier`). `een` is left out: it is the article.
  static let dutchDigitWords: [String: String] = [
    "nul": "0", "één": "1", "twee": "2", "drie": "3", "vier": "4", "vijf": "5", "zes": "6",
    "zeven": "7", "acht": "8", "negen": "9",
  ]

  // MARK: - Number dot words (neutral route only)

  /// Polish `kropka` and Dutch `punt` between DIGITS (`2 kropka 5 kropka 0`). Neutral route only:
  /// the English route's `numberDotWordAlt` is unchanged.
  static let neutralNumberDotWordAlt = numberDotWordAlt + "|kropka|punt"

  // MARK: - Emails with Unicode names, or a domain the recogniser already dotted

  /// `maría punto lópez arroba gmail punto com` → `maría.lópez@gmail.com`,
  /// `recepción arroba empresa.es` → `recepción@empresa.es`,
  /// `łukasz małpa przykład kropka pl` → `łukasz@przykład.pl`.
  ///
  /// The ASCII frame in `emails` stays the English route's; this one reads Unicode labels and a
  /// domain the recogniser already joined. Every spoken dot-word must belong to the at-word's
  /// language (`addressWordPairs`). The English at-word is not read here, except German `at`
  /// paired with `punkt` (German borrowed "at"). A joined domain needs a non-English at-word:
  /// the already-dotted shape stays closed for `at` (#2770).
  func neutralUnicodeEmails(_ t: String) -> String {
    let dot = #"\s+(?:"# + Self.addressDotAlt + #")\s+"#
    let sep = #"(?:\.|"# + dot + #")"#
    let label = Self.uLabel
    let pat =
      #"(?<![\p{L}\p{M}\p{N}_.@-])(?<name>"# + label + #"(?:"# + sep + label + #"){0,5})\s+(?<atw>"#
      + Self.addressAtAlt + #")(?<comma>,)?\s+(?<dom>"# + label + #"(?:"# + sep + label
      + #"){0,5})"# + sep + #"(?<tld>"# + Self.emailTLDAlt + #")(?![\p{L}\p{M}\p{N}_-]|\.[\p{L}\p{N}])"#
    return reSub(pat, t) { m in
      guard !Self.startsAfterSpokenDot(m) else { return nil }
      let atw = (m.g("atw") ?? "").lowercased()
      let whole = " " + m.whole + " "
      let dots = allMatches(#"\s("# + Self.addressDotAlt + #")(?=\s)"#, whole).map {
        $0.lowercased()
      }
      guard dots.allSatisfy({ Self.isPairedAddressWording(atw, $0) }) else { return nil }
      if atw == "at" {
        // German only: `at` with `punkt`, and at least one spoken dot in the domain.
        guard !dots.isEmpty, dots.allSatisfy({ $0 == "punkt" }) else { return nil }
      }
      // The ASCII frame already converted every all-ASCII fully spoken address; what reaches
      // here needs a Unicode letter or a joined domain to be new (otherwise `emails` refused it
      // for a reason this frame must not override).
      let spokenDomainDot =
        firstMatch(dot, " " + (m.g("dom") ?? "") + " ") != nil
        || firstMatch(
          #"(?:"# + Self.addressDotAlt + #")\s+(?:"# + Self.emailTLDAlt + #")$"#,
          m.whole) != nil
      let ascii = m.whole.unicodeScalars.allSatisfy { $0.isASCII }
      if ascii, spokenDomainDot { return nil }
      // `małpa` is also "monkey": beside a domain the recogniser already joined it needs an
      // address cue ("Ta małpa zoo.pl" stays).
      if atw == "małpa" || atw == "malpa", !spokenDomainDot, !hasAddressCue(m) { return nil }
      // A comma after the at-word: Polish `małpa` only, and only after an address cue
      // ("Teraz to Łukasz małpa, przykład.pl"; Codex plan r2 N2).
      if m.g("comma") != nil {
        guard atw == "małpa" || atw == "malpa", hasAddressCue(m) else { return nil }
      }
      // The address goes on past what reads ("… kropka pl kropka xyz").
      guard !hasFurtherSpokenLabel(m) else { return nil }
      let nameLabels = splitOnPattern(m.g("name") ?? "", sep)
      if nameLabels.count > 1, let last = nameLabels.last?.lowercased(),
        Self.dottedNameRefusedSuffixes.contains(last)
      {
        return nil
      }
      let domLabels = splitOnPattern(m.g("dom") ?? "", sep)
      return nameLabels.joined(separator: ".").lowercased() + "@"
        + (domLabels + [m.g("tld") ?? ""]).joined(separator: ".").lowercased()
    }
  }

  /// True when a dot-word (any language's) or a `.` stands right before the match: an address
  /// chain began earlier than the bounded pattern reads, and converting its tail would be a
  /// half-conversion.
  static func startsAfterSpokenDot(_ m: Match) -> Bool {
    let r = m.result.range
    let lead = min(r.location, 24)
    let before = m.ns.substring(with: NSRange(location: r.location - lead, length: lead))
    return firstMatch(#"(?:(?:^|\s)(?:"# + addressDotAlt + #")\s+|\.)$"#, before) != nil
  }

  /// An address word shortly before the match, alone or inside a compound ("adres", "privéadres",
  /// "e-mail", "correo", "adresse").
  func hasAddressCue(_ m: Match) -> Bool {
    let r = m.result.range
    let lead = min(r.location, 48)
    let before = m.ns.substring(with: NSRange(location: r.location - lead, length: lead))
    return firstMatch(
      #"\p{L}*(?:mail|adres|correo)\p{L}*|(?:^|[^\p{L}])(?:napisz|wyślij|bericht)(?:[^\p{L}]|$)"#,
      before) != nil
  }

  /// Dutch `apenstaartje` glued into the name by the recogniser:
  /// `receptieapenstaartjebedrijf.nl` → `receptie@bedrijf.nl`,
  /// `jan.jansenapenstaartje gmail.com` → `jan.jansen@gmail.com`.
  /// Needs an address cue before it, and a glued domain may not start with `s` (the plural
  /// `apenstaartjes`; Codex plan r2 N1). Polish `małpa` is never split out of a word: it is also
  /// "monkey" and sits inside inflected forms.
  func neutralGluedDutchEmails(_ t: String) -> String {
    let label = Self.uLabel
    let pat =
      #"(?<![\p{L}\p{M}\p{N}_.@-])(?<name>[\p{L}\p{N}][\p{L}\p{M}\p{N}_.-]*?)(?<atw>apenstaartje|apestaartje)(?<gap>\s?)(?<dom>"#
      + label + #"(?:\."# + label + #")*)\.(?<tld>"# + Self.emailTLDAlt
      + #")(?![\p{L}\p{M}\p{N}_-]|\.[\p{L}\p{N}])"#
    return reSub(pat, t) { m in
      let name = m.g("name") ?? ""
      let dom = m.g("dom") ?? ""
      guard !name.isEmpty, !name.hasSuffix("."), !name.hasSuffix("-") else { return nil }
      if (m.g("gap") ?? "").isEmpty, dom.lowercased().hasPrefix("s") { return nil }
      guard hasAddressCue(m) else { return nil }
      return name.lowercased() + "@" + dom.lowercased() + "." + (m.g("tld") ?? "").lowercased()
    }
  }

  // MARK: - Links: protocol, path, www, localhost

  /// A host: labels joined by `.` or this language's dot word, ending in an allowed TLD.
  static func neutralHostPat(_ w: SpokenURLWords) -> String {
    let sep = #"(?:\.|\s+(?:"# + phraseAlt(w.dot) + #")\s+)"#
    return uLabel + #"(?:"# + sep + uLabel + #"){0,5}"# + sep + #"(?:"# + neutralTLDAlt + #")"#
  }

  static func neutralHostLabels(_ host: String, _ w: SpokenURLWords) -> [String] {
    splitOnPattern(host, #"\.|\s+(?:"# + phraseAlt(w.dot) + #")\s+"#)
  }

  /// Spoken URL syntax just BEFORE a host (`https dos puntos barra barra …`, a slash word) means
  /// a longer link the scheme pass refused; a later pass converting its tail would half-convert it.
  func neutralLinkStartsEarlier(_ m: Match, _ w: SpokenURLWords) -> Bool {
    let r = m.result.range
    let lead = min(r.location, 48)
    let before = m.ns.substring(with: NSRange(location: r.location - lead, length: lead))
    let syntax = Self.phraseAlt(w.dot + w.slash + w.colon)
    return firstMatch(#"(?:^|[^\p{L}])(?:https?|"# + syntax + #")\s+$"#, before) != nil
      || firstMatch(#"/\s*$"#, before) != nil
  }

  /// A spoken host with no `www` or protocol takes the lower-risk endings only: `ai`, `app` and
  /// `xyz` are ordinary words, and a path after them still reads as notation (the English URL
  /// pass keeps the same split, `lowerRiskURLTLDAlt`). A host the recogniser joined may use any.
  func neutralSpokenHostEndingAllowed(_ host: String, _ w: SpokenURLWords) -> Bool {
    let spoken = firstMatch(#"\s+(?:"# + Self.phraseAlt(w.dot) + #")\s+"#, host) != nil
    guard spoken, firstMatch(#"^www\b"#, host) == nil,
      let last = Self.neutralHostLabels(host, w).last?.lowercased()
    else { return true }
    return !["ai", "app", "xyz"].contains(last)
  }

  /// Spoken URL syntax right after a converted link means the link goes on past what reads.
  func neutralLinkContinues(_ rest: String, _ w: SpokenURLWords) -> Bool {
    let syntax = Self.phraseAlt(w.dot + w.slash + w.colon)
    return firstMatch(#"^\s+(?:"# + syntax + #")(?:\s+|$)[\p{L}\p{N}]?"#, rest) != nil
      || firstMatch(#"^[\p{L}\p{M}\p{N}_@-]"#, rest) != nil
  }

  /// `https deux points barre oblique barre oblique exemple point fr` → `https://exemple.fr`.
  func neutralURLSchemes(_ t: String) -> String {
    var t = t
    for w in Self.spokenURLWords {
      let slash = #"(?:"# + Self.phraseAlt(w.slash) + #")"#
      let pat =
        #"(?<![\p{L}\p{N}])(?<p>https?)\s+(?:"# + Self.phraseAlt(w.colon) + #")\s+"# + slash
        + #"\s+"# + slash + #"\s+(?<host>"# + Self.neutralHostPat(w) + #")(?<path>(?:\s+"#
        + slash + #"\s+"# + Self.uLabel + #")*)"#
      t = reSub(pat, t) { m in
        let end = m.result.range.location + m.result.range.length
        let rest = m.ns.substring(from: end)
        guard !neutralLinkContinues(rest, w) else { return nil }
        let host = Self.neutralHostLabels(m.g("host") ?? "", w).joined(separator: ".")
        let segs = splitOnPattern(m.g("path") ?? "", #"\s+(?:"# + slash + #")\s+"#)
          .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return (m.g("p") ?? "https").lowercased() + "://" + host.lowercased()
          + segs.map { "/" + $0 }.joined()
      }
    }
    return t
  }

  /// `ejemplo punto es barra ayuda` / `ejemplo.es barra ayuda` → `ejemplo.es/ayuda`. The host
  /// must end in an allowed TLD and a slash phrase must follow it, so `la barra del bar` has no
  /// host to attach to. Path case is kept as written (`przykład.pl/Pomoc`).
  func neutralURLPaths(_ t: String) -> String {
    var t = t
    for w in Self.spokenURLWords {
      let slash = #"(?:"# + Self.phraseAlt(w.slash) + #")"#
      let gap = w.glueSlash ? #"\s*"# : #"\s+"#
      let pat =
        #"(?<![\p{L}\p{M}\p{N}_.@/:-])(?<host>(?:www(?:\.|\s+(?:"# + Self.phraseAlt(w.dot)
        + #")\s+))?"# + Self.neutralHostPat(w) + #")(?<path>(?:\s+"# + slash + gap + Self.uLabel
        + #")+)(?![\p{L}\p{M}\p{N}_@-])"#
      t = reSub(pat, t) { m in
        let end = m.result.range.location + m.result.range.length
        guard !neutralLinkContinues(m.ns.substring(from: end), w),
          !neutralLinkStartsEarlier(m, w),
          neutralSpokenHostEndingAllowed(m.g("host") ?? "", w)
        else { return nil }
        let host = Self.neutralHostLabels(m.g("host") ?? "", w).joined(separator: ".")
        let segs = splitOnPattern(m.g("path") ?? "", #"\s+"# + slash + gap)
          .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !segs.isEmpty else { return nil }
        return host.lowercased() + segs.map { "/" + $0 }.joined()
      }
    }
    return t
  }

  /// `www punto ejemplo punto es` → `www.ejemplo.es`. A spoken host with no `www`, protocol or
  /// path is left alone: prose about a website reads the same way.
  func neutralWWWHosts(_ t: String) -> String {
    var t = t
    for w in Self.spokenURLWords {
      let dot = #"\s+(?:"# + Self.phraseAlt(w.dot) + #")\s+"#
      let www =
        #"(?:www|w\s+w\s+w|wu\s+wu\s+wu|uve\s+doble\s+uve\s+doble\s+uve\s+doble|triple\s+w)"#
      let pat =
        #"(?<![\p{L}\p{M}\p{N}_.@/-])"# + www + dot + #"(?<rest>"# + Self.uLabel + #"(?:(?:\.|"#
        + dot + #")"# + Self.uLabel + #")*(?:\.|"# + dot + #")(?:"# + Self.neutralTLDAlt + #"))"#
      t = reSub(pat, t) { m in
        let end = m.result.range.location + m.result.range.length
        guard !neutralLinkContinues(m.ns.substring(from: end), w), !neutralLinkStartsEarlier(m, w)
        else { return nil }
        let labels = Self.neutralHostLabels(m.g("rest") ?? "", w)
        return "www." + labels.joined(separator: ".").lowercased()
      }
    }
    return t
  }

  /// `localhost dos puntos 3000` → `localhost:3000`. Digits only; a colon word is read only
  /// right after `localhost`, so `Ganamos dos puntos` stays.
  func neutralLocalhostPorts(_ t: String) -> String {
    let colon = Self.phraseAlt(Self.spokenURLWords.flatMap { $0.colon })
    let pat =
      #"(?<![\p{L}\p{N}])(?<h>localhost)\s+(?:"# + colon
      + #")\s+(?<p>\d+)(?![\p{L}\p{N}.,]\d|[\p{L}\p{N}])"#
    return reSub(pat, t) { m in
      guard let port = Int(m.g("p") ?? ""), (1...65535).contains(port) else { return nil }
      return "\((m.g("h") ?? "localhost").lowercased()):\(port)"
    }
  }
}
