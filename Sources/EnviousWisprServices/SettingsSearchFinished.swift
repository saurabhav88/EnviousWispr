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
    // A word with a dot between letters and a known top-level ending ("example.com").
    let pattern =
      #"[a-z0-9-]+\.(com|net|org|io|de|co|app|dev|ai|edu|gov|uk|fr|es|it|nl|ch|at|info|me)\b"#
    return query.range(of: pattern, options: .regularExpression) != nil
  }

  private static func looksLikeCredential(_ query: String) -> Bool {
    for word in query.split(whereSeparator: { $0.isWhitespace }) {
      let token = String(word)
      if token.hasPrefix("sk-") || token.hasPrefix("aiza") || token.hasPrefix("ghp_")
        || token.hasPrefix("xox")
      {
        return true
      }
      // A long run of letters, digits and token punctuation with both letters and digits.
      let tokenish = token.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)
      }
      let hasDigit = token.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains)
      let hasLetter = token.unicodeScalars.contains(where: CharacterSet.letters.contains)
      if tokenish, token.count >= 20, hasDigit, hasLetter { return true }
    }
    return false
  }
}
