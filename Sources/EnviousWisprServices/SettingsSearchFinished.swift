import Foundation

/// One finished Settings search attempt (#3482 plan §8.1): event `settings.search_finished`.
/// Counts and closed values, plus the typed text ONLY for a search that found nothing or that
/// the person bypassed with the sidebar, and only after `SettingsSearchQueryFilter` accepts it.
/// The text is a question about the app's own settings, never dictated content; it is sent only
/// while "Share usage metrics" is on (checked by the caller at the terminal).
public struct SettingsSearchFinished: Equatable, Sendable {
  public enum Outcome: String, Sendable {
    case resultChosen = "result_chosen"
    case zeroResults = "zero_results"
    case sidebarBypass = "sidebar_bypass"
    case abandoned
  }

  public enum EndedBy: String, Sendable {
    case searchResult = "search_result"
    case sidebar
    case externalDestination = "external_destination"
    case escape
    case clear
    case queryEmpty = "query_empty"
    case windowClose = "window_close"
  }

  public let outcome: Outcome
  public let endedBy: EndedBy
  public let resultCount: Int
  public let appLanguage: String
  /// Encoding plus scoring time of the final query's meaning pass, when it completed.
  public let meaningElapsedMilliseconds: Double?
  /// Raw values of the page (and tab) a committed sidebar navigation opened.
  public let sidebarPage: String?
  public let sidebarTab: String?
  /// The filtered query, or nil: never for result_chosen or abandoned, never unfiltered.
  public let query: String?

  public init(
    outcome: Outcome, endedBy: EndedBy, resultCount: Int, appLanguage: String,
    meaningElapsedMilliseconds: Double? = nil, sidebarPage: String? = nil,
    sidebarTab: String? = nil, typedQuery: String?
  ) {
    self.outcome = outcome
    self.endedBy = endedBy
    self.resultCount = max(0, resultCount)
    self.appLanguage = appLanguage == "de" ? "de" : "en"
    self.meaningElapsedMilliseconds = meaningElapsedMilliseconds
    let navigatedBySidebar = endedBy == .sidebar
    self.sidebarPage = navigatedBySidebar ? sidebarPage : nil
    self.sidebarTab = navigatedBySidebar ? sidebarTab : nil
    let mayCarryQuery = outcome == .zeroResults || outcome == .sidebarBypass
    self.query = mayCarryQuery ? typedQuery.flatMap(SettingsSearchQueryFilter.reportable) : nil
  }
}

/// The privacy filter for a failed search's text (#3482 plan §8.1): trimmed and lowercased,
/// 3 to 80 characters and at most 320 UTF-8 bytes; the WHOLE query is dropped (never a shortened
/// prefix) when it looks like an email address (also spelled out with "at" and "dot"), a web,
/// IP or hardware address, a home-folder path, a bank account number, has seven or more digits,
/// or looks like a credential or token. "API key" itself is fine. Arbitrary personal text (a name,
/// a password with no label) cannot be recognised; the privacy policy discloses failed-search text.
public enum SettingsSearchQueryFilter {
  public static func reportable(_ text: String) -> String? {
    let query = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard (3...80).contains(query.count), query.utf8.count <= 320 else { return nil }
    let checked = detectionCopy(query)
    if checked.contains("@") { return nil }
    if looksLikeWebAddress(checked) { return nil }
    if checked.unicodeScalars.filter(CharacterSet.decimalDigits.contains).count >= 7 { return nil }
    if looksLikePersonalAddress(checked) { return nil }
    if looksLikeLabelledPassword(checked) { return nil }
    if looksLikeCredential(checked) { return nil }
    return query
  }

  /// What the checks read; the sent text stays the query itself. Invisible format characters
  /// (zero-width spaces and joiners) are removed, so one hidden inside a key or an address cannot
  /// split it, compatibility forms (full-width punctuation) become plain ones, and every kind of
  /// whitespace (a non-breaking space too) becomes one plain space, so the patterns below match
  /// whatever spacing was typed.
  static func detectionCopy(_ query: String) -> String {
    var out = String.UnicodeScalarView()
    var lastWasSpace = false
    // Compatibility forms first (a full-width colon or letter reads as the plain one).
    let folded = query.precomposedStringWithCompatibilityMapping
    for scalar in folded.unicodeScalars where scalar.properties.generalCategory != .format {
      if CharacterSet.whitespacesAndNewlines.contains(scalar) {
        if !lastWasSpace { out.append(" ") }
        lastWasSpace = true
      } else {
        out.append(scalar)
        lastWasSpace = false
      }
    }
    return String(out)
  }

  /// A password written after its label ("password: ...", "pwd=...") in a few languages.
  private static func looksLikeLabelledPassword(_ query: String) -> Bool {
    let pattern = #"\b(?:password|passwd|pwd|passwort|kennwort|mot de passe|contraseña|senha|wachtwoord|hasło)\s*[:=]"#
    return query.range(of: pattern, options: .regularExpression) != nil
  }

  private static func looksLikeWebAddress(_ query: String) -> Bool {
    if query.contains("://") || query.hasPrefix("www.") { return true }
    // Any domain shape, whatever its ending ("example.com", "example.cloud", "a.b.xyz"). This
    // drops a few harmless dotted words too; dropping is the safe direction.
    let pattern = #"\b(?:[a-z0-9-]+\.)+[a-z]{2,63}\b"#
    return query.range(of: pattern, options: .regularExpression) != nil
  }

  /// An email spelled out ("jane at example dot com"), an IPv4, IPv6 or MAC address, a home-folder
  /// path, or an IBAN with letters in its account part (one with seven digits is already dropped).
  private static func looksLikePersonalAddress(_ query: String) -> Bool {
    let patterns = [
      // "at" and "dot" only as whole words or in brackets: "formatting dot points" is a search.
      #"\b[a-z0-9._%+-]+(?:\s+at\s+|\s*[\[(]\s*at\s*[\])]\s*)[a-z0-9-]+(?:(?:\s+dot\s+|\s*[\[(]\s*dot\s*[\])]\s*)[a-z0-9-]+)+\b"#,
      #"\b\d{1,3}(?:\s?\.\s?\d{1,3}){3}\b"#,
      #"[0-9a-f]{0,4}::[0-9a-f]{0,4}|\b(?:[0-9a-f]{1,4}:){3,}[0-9a-f]{1,4}\b"#,
      #"\b(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}\b"#,
      #"/users/|/home/|(?:^|[^a-z0-9])~/|[a-z]:[\\/]users[\\/]"#,
      #"\b[a-z]{2}\d{2}(?:\s?[a-z0-9]{4}){3,}\b"#,
    ]
    return patterns.contains { query.range(of: $0, options: .regularExpression) != nil }
  }

  /// Known key and token prefixes (lowercased: the query is lowercased first). OpenAI and
  /// Anthropic `sk-`, Stripe-style `sk_`/`rk_`/`pk_`, Google `aiza` and `ya29.`, GitHub
  /// `ghp_`/`gho_`/`ghu_`/`ghs_`/`ghr_`/`github_pat_`, Slack `xox`, GitLab `glpat-`, Hugging
  /// Face `hf_`. AWS access key ids (`akia`/`asia` plus 16 characters) are matched by length too,
  /// so a search for "asia" or "asian languages" is kept.
  static let credentialPrefixes = [
    "sk-", "sk_", "rk_", "pk_", "aiza", "ya29.", "ghp_", "gho_", "ghu_", "ghs_", "ghr_",
    "github_pat_", "xox", "glpat-", "hf_",
  ]

  private static func looksLikeCredential(_ query: String) -> Bool {
    // Candidates are the runs of letters, digits and key punctuation ("-_.+/", base64 too), so a
    // key glued to a label or wrapped in punctuation ("token:...", "key=...", "(...)") is seen on
    // its own. "=" separates (it only pads base64 at the end), so "key=<value>" splits.
    let tokenCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.+/"))
    for candidate in runs(of: query, in: tokenCharacters) {
      // A label joined by "/", "+" or "." still hides a known prefix, so each piece is checked
      // too, and the whole run (Google's "ya29." keeps its dot).
      let pieces = [candidate] + candidate.split(whereSeparator: { "/+.".contains($0) }).map(String.init)
      // A prefix also counts after "-" or "_" inside a run ("key_glpat-..."), but not inside a
      // word ("desk-top" is not "sk-").
      if credentialPrefixes.contains(where: { prefix in
        candidate.range(
          of: "(?:^|[^a-z0-9])" + NSRegularExpression.escapedPattern(for: prefix),
          options: .regularExpression) != nil
      }) { return true }
      for piece in pieces {
        if credentialPrefixes.contains(where: piece.hasPrefix) { return true }
        if piece.count == 20, piece.hasPrefix("akia") || piece.hasPrefix("asia") { return true }
        for part in piece.split(whereSeparator: { "-_".contains($0) }) where part.count == 20 {
          if part.hasPrefix("akia") || part.hasPrefix("asia") { return true }
        }
      }
      let hasDigit = candidate.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains)
      let hasLetter = candidate.unicodeScalars.contains(where: CharacterSet.letters.contains)
      // A long mixed run of letters and digits, or a Latin run longer than any real word (the
      // longest German settings compound, "spracherkennungseinstellungen", has 29). Measured on
      // ASCII sub-runs: Japanese and Chinese phrases are written without spaces, and a non-ASCII
      // label ("clé") must not hide the key after it.
      if candidate.count >= 20, hasDigit, hasLetter { return true }
      let ascii = CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127))
      if runs(of: candidate, in: ascii).contains(where: { $0.count >= 32 }) { return true }
    }
    return false
  }

  /// The maximal runs of `query` made only of `characters`.
  private static func runs(of query: String, in characters: CharacterSet) -> [String] {
    var result: [String] = []
    var current = String.UnicodeScalarView()
    for scalar in query.unicodeScalars {
      if characters.contains(scalar) {
        current.append(scalar)
      } else if !current.isEmpty {
        result.append(String(current))
        current = String.UnicodeScalarView()
      }
    }
    if !current.isEmpty { result.append(String(current)) }
    return result
  }
}
