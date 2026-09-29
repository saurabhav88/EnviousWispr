import Foundation

/// Turns the on-device split into the concerns the help check sends (#3275): each quote located
/// in the untouched message by UTF-16 range, and exact repeats merged. Measured need: the macOS 26
/// model pads a message with copies of one concern (docs/feature-requests/issue-3275-...md,
/// "macOS 26 VALIDATION"). Nothing is dropped: a quote that cannot be placed stays, unanchored,
/// and an unanchored concern can show help but can never be marked solved.
enum HelpCheckPreparation {
  struct Prepared: Equatable {
    let issues: [HelpCheckRequest.Issue]
    /// True when the split hit its cap or more concerns remain after merging than the check
    /// sends; either way the list may be incomplete, which blocks suppression.
    let overflow: Bool
  }

  static let maxIssues = FeedbackHelpOutcome.maxIssues
  static let maxSummaryLength = 300

  static func prepare(_ concerns: [HelpCheckConcern], hitCap: Bool, in message: String) -> Prepared
  {
    var kept: [(concern: HelpCheckConcern, range: Range<Int>?)] = []
    for concern in concerns {
      let range = utf16Range(of: concern.evidence, in: message)
      // Merge only an exact repeat: same quote, same summary, same kind, same unique place.
      // A quote contained in another is a different concern (a second problem can be stated
      // inside the first sentence), so containment never merges.
      let isRepeat = kept.contains { other in
        other.range != nil && other.range == range && other.concern.kind == concern.kind
          && normalized(other.concern.evidence) == normalized(concern.evidence)
          && normalized(other.concern.summary) == normalized(concern.summary)
      }
      if !isRepeat { kept.append((concern, range)) }
    }
    let issues = kept.prefix(maxIssues).enumerated().map { index, item in
      HelpCheckRequest.Issue(
        id: "i\(index)", summary: String(item.concern.summary.prefix(maxSummaryLength)),
        kind: item.concern.kind, evidence: item.concern.evidence,
        startUTF16: item.range?.lowerBound, endUTF16: item.range?.upperBound)
    }
    return Prepared(issues: issues, overflow: hitCap || kept.count > maxIssues)
  }

  /// The quote's UTF-16 range when it occurs exactly once, verbatim; else once ignoring case (the
  /// macOS 26 model capitalises quotes), with the range of the message's own text. Nil when absent
  /// or ambiguous. A case-folded match is sent with its range, and the server treats a span that
  /// differs only in case as unanchored, so it can show help but never be solved.
  static func utf16Range(of evidence: String, in message: String) -> Range<Int>? {
    let quote = evidence.utf16
    guard !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      quote.count <= message.utf16.count
    else { return nil }
    if let exact = uniqueRange(of: Array(quote), in: Array(message.utf16)) { return exact }
    // Lowercasing keeps UTF-16 length for the scripts that differ only in case here; a message
    // whose lowercase changes length cannot be compared by offset and is left unanchored.
    let lowerMessage = message.lowercased()
    let lowerQuote = evidence.lowercased()
    guard lowerMessage.utf16.count == message.utf16.count, lowerQuote.utf16.count == quote.count
    else { return nil }
    return uniqueRange(of: Array(lowerQuote.utf16), in: Array(lowerMessage.utf16))
  }

  private static func uniqueRange(of needle: [UInt16], in haystack: [UInt16]) -> Range<Int>? {
    guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
    var found: Range<Int>?
    for start in 0...(haystack.count - needle.count)
    where haystack[start] == needle[0] && Array(haystack[start..<start + needle.count]) == needle {
      if found != nil { return nil }
      found = start..<start + needle.count
    }
    return found
  }

  /// Lowercased, whitespace collapsed, surrounding punctuation and quotes trimmed.
  static func normalized(_ text: String) -> String {
    let collapsed = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return collapsed.trimmingCharacters(
      in: CharacterSet.punctuationCharacters.union(.whitespaces).union(
        CharacterSet(charactersIn: "\"'“”‘’")))
  }
}
