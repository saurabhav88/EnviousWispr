import Foundation

/// What the in-app help check (#3275) did for one report that is still sent, frozen with the
/// report at Send and carried unchanged through every retry. Counts, closed outcomes, version
/// stamps and help-center ids only: never the message (FeedbackRecord.message holds it once), the
/// email, a concern summary or quote, card text, a URL or a server reply. A report the user marked
/// all solved is never saved, so it has no outcome here.
///
/// `init?` is the only way to build one, so a value that exists is always within bounds.
public struct FeedbackHelpOutcome: Codable, Equatable, Sendable {
  public static let schemaVersion = 1
  public static let maxIssues = 5
  public static let maxShownCards = 3

  public enum TerminalOutcome: String, Codable, Sendable {
    /// Cards were shown and the user sent the report without marking everything solved.
    case stillSent = "still_sent"
    /// Some concerns were marked solved; the rest were sent.
    case partialSent = "partial_sent"
    /// The user closed the suggestions and the report was sent.
    case dismissedSent = "dismissed_sent"
    /// The check could not run or failed; the report was sent as written.
    case fallbackSent = "fallback_sent"
  }

  /// Why a check fell back. Closed on purpose: a server's variable HTTP status is `httpError`.
  public enum FailureReason: String, Codable, Sendable {
    case disabled, config, unavailable, network, timeout
    case invalidRequest = "invalid_request"
    case messageTooLong = "message_too_long"
    case tooLarge = "too_large"
    case invalidDecomposition = "invalid_decomposition"
    case httpError = "http_error"
    case badReply = "bad_reply"
    case badTarget = "bad_target"
    case afmUnavailable = "afm_unavailable"
    case afmTimeout = "afm_timeout"
    case afmRefused = "afm_refused"
    case afmError = "afm_error"
  }

  public enum Mode: String, Codable, Sendable {
    case decomposed
    case wholeMessageAlwaysSend = "whole_message_always_send"
  }

  public enum MatchKind: String, Codable, Sendable {
    case section, page, none
  }

  /// The matched article's help policy, as the server returned it. `never_intervene` is never
  /// shown, so it never appears here.
  public enum Deflection: String, Codable, Sendable {
    case canResolve = "can_resolve"
    case showButAlwaysSend = "show_but_always_send"
  }

  public enum Resolution: String, Codable, Sendable {
    case solved
    case stillHappening = "still_happening"
    case unmatched
  }

  /// One concern, in the order the check returned it (`i0`...`i4`).
  public struct Issue: Codable, Equatable, Sendable {
    public let id: String
    public let matchKind: MatchKind
    /// The help article's slug, for a section or page match.
    public let pageSlug: String?
    /// `<slug>#<anchor>`, for a section match.
    public let sectionID: String?
    /// The article's policy, for a section or page match.
    public let deflection: Deflection?
    public let resolution: Resolution

    /// `solved` only where the form can offer it: a section whose article can resolve the problem.
    /// A page link or a show-but-always-send article is still happening or sent, never solved.
    public init?(
      index: Int, matchKind: MatchKind, pageSlug: String?, sectionID: String?,
      deflection: Deflection?, resolution: Resolution
    ) {
      guard (0..<FeedbackHelpOutcome.maxIssues).contains(index) else { return nil }
      switch matchKind {
      case .none:
        guard pageSlug == nil, sectionID == nil, deflection == nil, resolution == .unmatched
        else { return nil }
      case .page:
        guard let slug = pageSlug, Self.isSlug(slug), sectionID == nil, deflection != nil,
          resolution == .stillHappening
        else { return nil }
      case .section:
        guard let slug = pageSlug, Self.isSlug(slug), let section = sectionID,
          section.hasPrefix(slug + "#"), Self.isSlug(String(section.dropFirst(slug.count + 1))),
          let deflection, resolution != .unmatched,
          resolution != .solved || deflection == .canResolve
        else { return nil }
      }
      self.id = "i\(index)"
      self.matchKind = matchKind
      self.pageSlug = pageSlug
      self.sectionID = sectionID
      self.deflection = deflection
      self.resolution = resolution
    }

    /// Help-center slugs and anchors: lowercase letters, digits and hyphens. 99 each keeps a
    /// `<slug>#<anchor>` tag within Sentry's 200-character tag value (longest today: 93).
    static func isSlug(_ value: String) -> Bool {
      (1...99).contains(value.count)
        && value.unicodeScalars.allSatisfy {
          ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
        }
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      let id = try c.decode(String.self, forKey: .id)
      guard id.count == 2, id.first == "i", let index = Int(id.dropFirst()),
        let value = Self(
          index: index, matchKind: try c.decode(MatchKind.self, forKey: .matchKind),
          pageSlug: try c.decodeIfPresent(String.self, forKey: .pageSlug),
          sectionID: try c.decodeIfPresent(String.self, forKey: .sectionID),
          deflection: try c.decodeIfPresent(Deflection.self, forKey: .deflection),
          resolution: try c.decode(Resolution.self, forKey: .resolution))
      else {
        throw DecodingError.dataCorruptedError(
          forKey: .id, in: c, debugDescription: "help issue out of bounds")
      }
      self = value
    }
  }

  /// Version stamps from the help check's answer, as the server returned them. Nil when the check
  /// never answered (a fallback before or without the server).
  public struct Versions: Codable, Equatable, Sendable {
    public let kb: String
    public let jevModel: String
    public let decomposition: String
    public let decision: String
    public let threshold: String
    public let app: String

    public init?(
      kb: String, jevModel: String, decomposition: String, decision: String, threshold: String,
      app: String
    ) {
      guard [kb, jevModel, decomposition, decision, threshold, app].allSatisfy(Self.isToken)
      else { return nil }
      self.kb = kb
      self.jevModel = jevModel
      self.decomposition = decomposition
      self.decision = decision
      self.threshold = threshold
      self.app = app
    }

    /// The server's own token rule: `^[A-Za-z0-9._+-]{1,64}$`.
    static func isToken(_ value: String) -> Bool {
      (1...64).contains(value.count)
        && value.unicodeScalars.allSatisfy {
          ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
            || ".-_+".unicodeScalars.contains($0)
        }
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      guard
        let value = Self(
          kb: try c.decode(String.self, forKey: .kb),
          jevModel: try c.decode(String.self, forKey: .jevModel),
          decomposition: try c.decode(String.self, forKey: .decomposition),
          decision: try c.decode(String.self, forKey: .decision),
          threshold: try c.decode(String.self, forKey: .threshold),
          app: try c.decode(String.self, forKey: .app))
      else {
        throw DecodingError.dataCorruptedError(
          forKey: .kb, in: c, debugDescription: "help version out of bounds")
      }
      self = value
    }
  }

  public let schemaVersion: Int
  public let terminalOutcome: TerminalOutcome
  public let failureReason: FailureReason?
  public let mode: Mode
  public let overflow: Bool
  /// Whether the server's whole-list coverage score passed its gate; nil when it never answered.
  public let coveragePassed: Bool?
  public let versions: Versions?
  /// Cards on screen after grouping concerns that share a remedy (at most three).
  public let shownCardCount: Int
  public let issues: [Issue]

  // Counts are derived from `issues`, so they cannot disagree with them.
  public var issueCount: Int { issues.count }
  public var sectionMatchCount: Int { issues.filter { $0.matchKind == .section }.count }
  public var pageOnlyCount: Int { issues.filter { $0.matchKind == .page }.count }
  public var solvedIssueCount: Int { issues.filter { $0.resolution == .solved }.count }
  public var unresolvedIssueCount: Int { issues.filter { $0.resolution == .stillHappening }.count }
  public var unmatchedIssueCount: Int { issues.filter { $0.resolution == .unmatched }.count }

  public init?(
    terminalOutcome: TerminalOutcome, failureReason: FailureReason?, mode: Mode, overflow: Bool,
    coveragePassed: Bool?, versions: Versions?, shownCardCount: Int, issues: [Issue]
  ) {
    guard issues.count <= Self.maxIssues,
      issues.enumerated().allSatisfy({ $0.element.id == "i\($0.offset)" }),
      (0...Self.maxShownCards).contains(shownCardCount),
      shownCardCount <= issues.filter({ $0.matchKind != .none }).count,
      (failureReason != nil) == (terminalOutcome == .fallbackSent),
      mode == .decomposed || issues.count <= 1,
      // Only a decomposed check that ran to the cards can have a concern marked solved.
      mode == .decomposed || !issues.contains { $0.resolution == .solved },
      terminalOutcome != .fallbackSent
        || (shownCardCount == 0 && !issues.contains { $0.resolution == .solved }),
      terminalOutcome != .partialSent
        || (issues.contains { $0.resolution == .solved }
          && issues.contains { $0.resolution != .solved })
    else { return nil }
    self.schemaVersion = Self.schemaVersion
    self.terminalOutcome = terminalOutcome
    self.failureReason = failureReason
    self.mode = mode
    self.overflow = overflow
    self.coveragePassed = coveragePassed
    self.versions = versions
    self.shownCardCount = shownCardCount
    self.issues = issues
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    guard try c.decode(Int.self, forKey: .schemaVersion) == Self.schemaVersion,
      let value = Self(
        terminalOutcome: try c.decode(TerminalOutcome.self, forKey: .terminalOutcome),
        failureReason: try c.decodeIfPresent(FailureReason.self, forKey: .failureReason),
        mode: try c.decode(Mode.self, forKey: .mode),
        overflow: try c.decode(Bool.self, forKey: .overflow),
        coveragePassed: try c.decodeIfPresent(Bool.self, forKey: .coveragePassed),
        versions: try c.decodeIfPresent(Versions.self, forKey: .versions),
        shownCardCount: try c.decode(Int.self, forKey: .shownCardCount),
        issues: try c.decode([Issue].self, forKey: .issues))
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion, in: c, debugDescription: "help outcome out of bounds")
    }
    self = value
  }

  /// Sentry tags for the report: fixed keys, bounded values, no user-written text.
  var sentryTags: [String: String] {
    var tags: [String: String] = [
      "help_v": String(schemaVersion),
      "help_outcome": terminalOutcome.rawValue,
      "help_mode": mode.rawValue,
      "help_overflow": String(overflow),
      "help_issues": String(issueCount),
      "help_cards": String(shownCardCount),
      "help_sections": String(sectionMatchCount),
      "help_pages": String(pageOnlyCount),
      "help_solved": String(solvedIssueCount),
      "help_unresolved": String(unresolvedIssueCount),
      "help_unmatched": String(unmatchedIssueCount),
    ]
    if let failureReason { tags["help_failure"] = failureReason.rawValue }
    if let coveragePassed { tags["help_coverage"] = coveragePassed ? "pass" : "fail" }
    if let versions {
      tags["help_kb"] = versions.kb
      tags["help_jev"] = versions.jevModel
      tags["help_decomp"] = versions.decomposition
      tags["help_decision"] = versions.decision
      tags["help_threshold"] = versions.threshold
      tags["help_app"] = versions.app
    }
    for issue in issues {
      tags["help_\(issue.id)_resolution"] = issue.resolution.rawValue
      tags["help_\(issue.id)_match"] = issue.matchKind.rawValue
      if let deflection = issue.deflection { tags["help_\(issue.id)_policy"] = deflection.rawValue }
      if let page = issue.pageSlug { tags["help_\(issue.id)_page"] = page }
      if let section = issue.sectionID { tags["help_\(issue.id)_section"] = section }
    }
    return tags
  }
}
