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

  /// Short function words that stand right before an at-word when the NAME was not heard
  /// ("envía a arroba gmail punto com", "stuur een bericht naar apenstaartje gmail punt com";
  /// local Codex diff review). A one-label name from this set is never a mailbox on the neutral
  /// route: converting it would invent an address the speaker did not say.
  static let neutralNameRefusedWords: Set<String> = [
    "a", "al", "de", "del", "en", "para", "por", "con", "y", "o", "e", "u", "es", "la", "el", "los", "las", "un", "una",  // es
    "à", "au", "aux", "du", "des", "pour", "par", "avec", "et", "ou", "le", "les", "une", "chez",  // fr
    "do", "na", "w", "z", "i", "dla", "od", "to", "jest", "ze", "we",  // pl
    "naar", "aan", "voor", "van", "met", "of", "het", "een", "op", "in", "bij", "is",  // nl
    "an", "zu", "für", "und", "oder", "der", "die", "das", "ein", "eine", "mit", "bei",  // de
  ]

  static func isRefusedNeutralName(_ labels: [String]) -> Bool {
    labels.count == 1 && neutralNameRefusedWords.contains(labels[0].lowercased())
  }

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
    // A spoken hyphen joins labels too ("jean trait d'union dupont", "juan guion pérez";
    // local Codex class enumeration), written `-`.
    let dash = #"\s+(?:"# + Self.neutralDashWordAlt + #")\s+"#
    let sep = #"(?:\.|"# + dot + "|" + dash + #")"#
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
      // A spoken dot-word inside the domain half (not only in the name).
      let spokenDomainDot =
        firstMatch(dot, " " + (m.g("dom") ?? "") + " ") != nil
        || firstMatch(
          #"(?:"# + Self.addressDotAlt + #")\s+(?:"# + Self.emailTLDAlt + #")$"#,
          m.whole) != nil
      if atw == "at" {
        // German only: `at` with `punkt`, spoken IN THE DOMAIN, so the already-dotted shape
        // stays closed for `at` ("john punkt smith at example.com" stays; local Codex diff review).
        guard !dots.isEmpty, dots.allSatisfy({ $0 == "punkt" }), spokenDomainDot else {
          return nil
        }
      }
      // The ASCII frame already converted every all-ASCII fully spoken address; what reaches
      // here needs a Unicode letter or a joined domain to be new (otherwise `emails` refused it
      // for a reason this frame must not override).
      let ascii = m.whole.unicodeScalars.allSatisfy { $0.isASCII }
      let spokenDash = firstMatch(dash, m.whole) != nil
      if ascii, spokenDomainDot, !spokenDash { return nil }
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
      guard !neutralEmailFollowedBySlash(m) else { return nil }
      let nameLabels = splitOnPattern(m.g("name") ?? "", sep)
      guard !Self.isRefusedNeutralName(nameLabels) else { return nil }
      if nameLabels.count > 1, let last = nameLabels.last?.lowercased(),
        Self.dottedNameRefusedSuffixes.contains(last)
      {
        return nil
      }
      let written: (String) -> String = { raw in
        var out = raw.replacingOccurrences(of: dash, with: "-", options: [.regularExpression, .caseInsensitive])
        out = out.replacingOccurrences(of: dot, with: ".", options: [.regularExpression, .caseInsensitive])
        return out.lowercased()
      }
      return written(m.g("name") ?? "") + "@" + written(m.g("dom") ?? "") + "."
        + (m.g("tld") ?? "").lowercased()
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

  /// True when a dash word stands right before the match (a hyphenated name began earlier).
  static func startsAfterSpokenDash(_ m: Match) -> Bool {
    let r = m.result.range
    let lead = min(r.location, 24)
    let before = m.ns.substring(with: NSRange(location: r.location - lead, length: lead))
    return firstMatch(#"(?:^|\s)(?:"# + neutralDashWordAlt + #")\s+$"#, before) != nil
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
      guard !name.isEmpty, !name.hasSuffix("."), !name.hasSuffix("-"),
        !Self.isRefusedNeutralName([name])
      else { return nil }
      if (m.g("gap") ?? "").isEmpty, dom.lowercased().hasPrefix("s") { return nil }
      guard hasAddressCue(m), !neutralEmailFollowedBySlash(m) else { return nil }
      return name.lowercased() + "@" + dom.lowercased() + "." + (m.g("tld") ?? "").lowercased()
    }
  }

  // MARK: - Links: protocol, path, www, localhost

  /// Spoken `www`: the word, or the letters as each language says them.
  static let neutralWWWAlias =
    #"(?:www|w\s+w\s+w|wu\s+wu\s+wu|uve\s+doble\s+uve\s+doble\s+uve\s+doble|triple\s+w)"#

  /// A host: an optional spoken `www`, labels joined by `.` or this language's dot word, ending
  /// in an allowed TLD.
  static func neutralHostPat(_ w: SpokenURLWords) -> String {
    let sep = #"(?:\.|\s+(?:"# + phraseAlt(w.dot) + #")\s+)"#
    return #"(?:"# + neutralWWWAlias + sep + #")?"# + uLabel + #"(?:"# + sep + uLabel
      + #"){0,5}"# + sep + #"(?:"# + neutralTLDAlt + #")"#
  }

  /// A host, or `localhost` with this language's colon word and a port (a path or a protocol
  /// around it reads as one link).
  static func neutralHostOrLocalPat(_ w: SpokenURLWords, portRequired: Bool) -> String {
    let port = #"\s+(?:"# + phraseAlt(w.colon) + #")\s+\d{1,5}"#
    // An IPv4 host, digits joined by `.` or the dot word ("192 punto 168 punto 1 punto 1").
    let ip = #"\d{1,3}(?:(?:\.|\s+(?:"# + phraseAlt(w.dot) + #")\s+)\d{1,3}){3}"#
    return #"(?:"# + neutralHostPat(w) + "|" + ip + #"|localhost(?:"# + port
      + (portRequired ? ")" : ")?") + #")"#
  }

  static func neutralHostLabels(_ host: String, _ w: SpokenURLWords) -> [String] {
    splitOnPattern(host, #"\.|\s+(?:"# + phraseAlt(w.dot) + #")\s+"#)
  }

  /// The written form of a matched host: a spoken `www` becomes `www`, labels join with `.`,
  /// `localhost <colon> 3000` becomes `localhost:3000`. Nil for a port outside 1...65535.
  static func neutralCanonicalHost(_ raw: String, _ w: SpokenURLWords) -> String? {
    if let local = firstMatch(#"^localhost\b"#, raw) {
      let rest = (raw as NSString).substring(from: (local as NSString).length)
      guard let digits = firstMatch(#"\d+$"#, rest) else { return "localhost" }
      guard let port = Int(digits), (1...65535).contains(port) else { return nil }
      return "localhost:\(port)"
    }
    var host = raw
    if let alias = firstMatch(#"^"# + neutralWWWAlias, host) {
      host = "www" + (host as NSString).substring(from: (alias as NSString).length)
    }
    return neutralHostLabels(host, w).joined(separator: ".").lowercased()
  }

  /// Path segments after a host: each language's slash phrase, then one segment; Dutch may
  /// glue `streep` to the segment (`schuine streephelp`).
  static func neutralPathPat(_ w: SpokenURLWords) -> (pattern: String, split: String) {
    let slash = #"(?:"# + phraseAlt(w.slash) + #")"#
    let gap = w.glueSlash ? #"\s*"# : #"\s+"#
    return (#"(?:\s+"# + slash + gap + uLabel + #")"#, #"\s+"# + slash + gap)
  }

  static func neutralPathSegments(_ raw: String, _ w: SpokenURLWords) -> [String] {
    splitOnPattern(raw, neutralPathPat(w).split)
      .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }

  /// Spoken URL syntax or an at-word just BEFORE a host (`https dos puntos barra barra …`, a
  /// slash word, `arroba`) means a longer link or address an earlier pass refused; converting
  /// its tail would half-convert it.
  func neutralLinkStartsEarlier(_ m: Match, _ words: [SpokenURLWords]) -> Bool {
    let r = m.result.range
    let lead = min(r.location, 48)
    let before = m.ns.substring(with: NSRange(location: r.location - lead, length: lead))
    let syntax = Self.phraseAlt(words.flatMap { $0.dot + $0.slash + $0.colon })
    // An at-word before the host: an address the email passes refused is not a link either.
    return firstMatch(
      #"(?:^|[^\p{L}])(?:https?|"# + syntax + "|" + Self.addressAtAlt + #")\s+$"#, before) != nil
      || firstMatch(#"/\s*$"#, before) != nil
  }

  /// A spoken host with no `www` or protocol takes the lower-risk endings only: `ai`, `app` and
  /// `xyz` are ordinary words, and a path after them still reads as notation (the English URL
  /// pass keeps the same split, `lowerRiskURLTLDAlt`). A host the recogniser joined may use any.
  func neutralSpokenHostEndingAllowed(_ host: String, _ w: SpokenURLWords) -> Bool {
    let spoken = firstMatch(#"\s+(?:"# + Self.phraseAlt(w.dot) + #")\s+"#, host) != nil
    guard spoken, firstMatch(#"^"# + Self.neutralWWWAlias, host) == nil,
      firstMatch(#"^localhost\b"#, host) == nil,
      let last = Self.neutralHostLabels(host, w).last?.lowercased()
    else { return true }
    return !["ai", "app", "xyz"].contains(last)
  }

  /// Spoken URL syntax right after a converted link means the link goes on past what reads.
  func neutralLinkContinues(_ rest: String, _ words: [SpokenURLWords]) -> Bool {
    // A dash word or a written `/` after the link also means it goes on ("… barra api guion v2",
    // "… punto es / ayuda"; local Codex class enumeration).
    let syntax = Self.phraseAlt(words.flatMap { $0.dot + $0.slash + $0.colon })
    return firstMatch(#"^\s+(?:"# + syntax + "|" + Self.neutralDashWordAlt + #")(?:\s+|$)"#, rest)
      != nil
      || firstMatch(#"^\s*/"#, rest) != nil
      || firstMatch(#"^[\p{L}\p{M}\p{N}_@-]"#, rest) != nil
  }

  /// A converted email followed by a slash phrase and a segment: an address with a path is not
  /// a mailbox, and converting the email alone would half-convert what was said.
  func neutralEmailFollowedBySlash(_ m: Match) -> Bool {
    let end = m.result.range.location + m.result.range.length
    let rest = m.ns.substring(
      with: NSRange(location: end, length: min(m.ns.length - end, 40)))
    let slash = Self.phraseAlt(Self.spokenURLWords.flatMap { $0.slash })
    return firstMatch(#"^\s+(?:"# + slash + #")\s*[\p{L}\p{N}]"#, rest) != nil
  }

  /// `https deux points barre oblique barre oblique exemple point fr` → `https://exemple.fr`,
  /// with a spoken `www`, a path, or `localhost` and its port.
  func neutralURLSchemes(_ t: String) -> String {
    var t = t
    for w in Self.spokenURLWords {
      let slash = #"(?:"# + Self.phraseAlt(w.slash) + #")"#
      let path = Self.neutralPathPat(w).pattern
      let pat =
        #"(?<![\p{L}\p{N}])(?<p>https?)\s+(?:"# + Self.phraseAlt(w.colon) + #")\s+"# + slash
        + #"\s+"# + slash + #"\s+(?<host>"# + Self.neutralHostOrLocalPat(w, portRequired: false)
        + #")(?<path>"# + path + #"*)(?![\p{L}\p{M}\p{N}_@-])"#
      t = reSub(pat, t) { m in
        let end = m.result.range.location + m.result.range.length
        guard !neutralLinkContinues(m.ns.substring(from: end), Self.spokenURLWords),
          let host = Self.neutralCanonicalHost(m.g("host") ?? "", w)
        else { return nil }
        let segs = Self.neutralPathSegments(m.g("path") ?? "", w)
        return (m.g("p") ?? "https").lowercased() + "://" + host + segs.map { "/" + $0 }.joined()
      }
    }
    return t
  }

  /// `ejemplo punto es barra ayuda` / `ejemplo.es barra ayuda` → `ejemplo.es/ayuda`. The host
  /// must end in an allowed TLD (or be `localhost` with a port) and a slash phrase must follow
  /// it, so `la barra del bar` has no host to attach to. Path case is kept as written
  /// (`przykład.pl/Pomoc`).
  func neutralURLPaths(_ t: String) -> String {
    var t = t
    for w in Self.spokenURLWords {
      let pat =
        #"(?<![\p{L}\p{M}\p{N}_.@/:-])(?<host>"# + Self.neutralHostOrLocalPat(w, portRequired: true)
        + #")(?<path>"# + Self.neutralPathPat(w).pattern + #"+)(?![\p{L}\p{M}\p{N}_@-])"#
      t = reSub(pat, t) { m in
        let end = m.result.range.location + m.result.range.length
        guard !neutralLinkContinues(m.ns.substring(from: end), Self.spokenURLWords),
          !neutralLinkStartsEarlier(m, Self.spokenURLWords),
          neutralSpokenHostEndingAllowed(m.g("host") ?? "", w),
          let host = Self.neutralCanonicalHost(m.g("host") ?? "", w)
        else { return nil }
        let segs = Self.neutralPathSegments(m.g("path") ?? "", w)
        guard !segs.isEmpty else { return nil }
        return host + segs.map { "/" + $0 }.joined()
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
      let pat =
        #"(?<![\p{L}\p{M}\p{N}_.@/-])(?<host>"# + Self.neutralWWWAlias + dot + Self.uLabel
        + #"(?:(?:\.|"# + dot + #")"# + Self.uLabel + #"){0,5}(?:\.|"# + dot + #")(?:"#
        + Self.neutralTLDAlt + #"))"#
      t = reSub(pat, t) { m in
        let end = m.result.range.location + m.result.range.length
        guard !neutralLinkContinues(m.ns.substring(from: end), Self.spokenURLWords),
          !neutralLinkStartsEarlier(m, Self.spokenURLWords)
        else { return nil }
        return Self.neutralCanonicalHost(m.g("host") ?? "", w)
      }
    }
    return t
  }

  /// `localhost dos puntos 3000` → `localhost:3000`. Digits only; a colon word is read only
  /// right after `localhost`, so `Ganamos dos puntos` stays. A path or protocol around it was
  /// read by the passes above; one they refused is left whole here.
  func neutralLocalhostPorts(_ t: String) -> String {
    let colon = Self.phraseAlt(Self.spokenURLWords.flatMap { $0.colon })
    let pat =
      #"(?<![\p{L}\p{N}])(?<h>localhost)\s+(?:"# + colon
      + #")\s+(?<p>\d+)(?![\p{L}\p{N}.,]\d|[\p{L}\p{N}])"#
    return reSub(pat, t) { m in
      let end = m.result.range.location + m.result.range.length
      guard !neutralLinkContinues(m.ns.substring(from: end), Self.spokenURLWords),
        !neutralLinkStartsEarlier(m, Self.spokenURLWords),
        let port = Int(m.g("p") ?? ""), (1...65535).contains(port)
      else { return nil }
      return "\((m.g("h") ?? "localhost").lowercased()):\(port)"
    }
  }
}
