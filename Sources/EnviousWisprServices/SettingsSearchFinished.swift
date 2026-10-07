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
/// prefix) when it looks like an email address, a web address, has seven or more digits, or looks
/// like a credential or token. "API key" itself is fine.
public enum SettingsSearchQueryFilter {
  public static func reportable(_ text: String) -> String? {
    let query = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard (3...80).contains(query.count), query.utf8.count <= 320 else { return nil }
    if query.contains("@") { return nil }
    if looksLikeWebAddress(query) { return nil }
    if query.unicodeScalars.filter(CharacterSet.decimalDigits.contains).count >= 7 { return nil }
    if looksLikeCredential(query) { return nil }
    return query
  }

  private static func looksLikeWebAddress(_ query: String) -> Bool {
    if query.contains("://") || query.hasPrefix("www.") { return true }
    // Any domain shape, whatever its ending ("example.com", "example.cloud", "a.b.xyz"). This
    // drops a few harmless dotted words too; dropping is the safe direction.
    let pattern = #"\b(?:[a-z0-9-]+\.)+[a-z]{2,63}\b"#
    return query.range(of: pattern, options: .regularExpression) != nil
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
    // Candidates are the runs of letters, digits and token punctuation, so a key glued to a
    // label or wrapped in punctuation ("token:ghp_...", "key=sk-...", "(aiza...)") is still
    // seen on its own.
    let tokenCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    var candidates: [String] = []
    var current = ""
    for scalar in query.unicodeScalars {
      if tokenCharacters.contains(scalar) {
        current.unicodeScalars.append(scalar)
      } else if !current.isEmpty {
        candidates.append(current)
        current = ""
      }
    }
    if !current.isEmpty { candidates.append(current) }
    for token in candidates {
      if credentialPrefixes.contains(where: token.hasPrefix) { return true }
      if token.count == 20, token.hasPrefix("akia") || token.hasPrefix("asia") { return true }
      let hasDigit = token.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains)
      let hasLetter = token.unicodeScalars.contains(where: CharacterSet.letters.contains)
      // A long mixed run of letters and digits, or any run longer than a real word: the longest
      // German settings compound is under 32 characters ("spracherkennungseinstellungen", 29).
      if token.count >= 20, hasDigit, hasLetter { return true }
      if token.count >= 32 { return true }
    }
    return false
  }
}
