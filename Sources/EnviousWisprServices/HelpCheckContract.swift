import Foundation

/// The wire contract with POST https://enviouswispr.com/api/app/help-check (#3275), owned by
/// website/functions/_lib/help-check.js. The request carries the message text, never the email or
/// diagnostics; the reply carries help-center targets and scores, never the user's words.

/// One concern as the on-device split produced it, before offsets and coalescing.
public struct HelpCheckConcern: Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case bug
    case howTo = "how_to"
    case featureRequest = "feature_request"
    case other
  }

  public let summary: String
  public let evidence: String
  public let kind: Kind

  public init(summary: String, evidence: String, kind: Kind) {
    self.summary = summary
    self.evidence = evidence
    self.kind = kind
  }
}

/// What the on-device split gave the check.
public enum HelpCheckDecomposition: Equatable, Sendable {
  /// Concerns in order. `hitCap` is true when the model returned as many as it may (five), so the
  /// message may hold more than it listed; that blocks suppression.
  case concerns([HelpCheckConcern], hitCap: Bool)
  /// No split: the check sends the whole message as one concern that can never be suppressed.
  case unavailable(FeedbackHelpOutcome.FailureReason)
}

struct HelpCheckRequest: Encodable, Equatable {
  struct Issue: Encodable, Equatable {
    let id: String
    let summary: String
    let kind: HelpCheckConcern.Kind
    let evidence: String
    let startUTF16: Int?
    let endUTF16: Int?

    enum CodingKeys: String, CodingKey {
      case id, summary, kind, evidence
      case startUTF16 = "start_utf16"
      case endUTF16 = "end_utf16"
    }

    // Offsets are always written, as null when unknown: the server reads both-or-neither.
    func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(id, forKey: .id)
      try c.encode(summary, forKey: .summary)
      try c.encode(kind, forKey: .kind)
      try c.encode(evidence, forKey: .evidence)
      try c.encode(startUTF16, forKey: .startUTF16)
      try c.encode(endUTF16, forKey: .endUTF16)
    }
  }

  let v = 1
  let originalMessage: String
  let mode: FeedbackHelpOutcome.Mode
  let issues: [Issue]
  let overflow: Bool
  let decompositionVersion: String
  let appVersion: String

  enum CodingKeys: String, CodingKey {
    case v, mode, issues, overflow
    case originalMessage = "original_message"
    case decompositionVersion = "decomposition_version"
    case appVersion = "app_version"
  }
}

/// The server's answer, decoded strictly: anything unknown or out of range is `nil`, and the
/// check then sends the report as written.
public struct HelpCheckReply: Equatable, Sendable {
  public enum Status: String, Decodable, Sendable {
    case ok
    case sendFeedback = "send_feedback"
  }

  public struct Result: Equatable, Sendable {
    public enum MatchType: String, Decodable, Sendable { case section, page, none }

    public let id: String
    public let matchType: MatchType
    public let pageSlug: String?
    /// The help page's title, for the card's title; nil from a server that does not send it.
    public let pageTitle: String?
    public let sectionID: String?
    public let heading: String?
    public let text: String?
    public let url: URL?
    public let deflection: FeedbackHelpOutcome.Deflection?
    public let resolutionEligible: Bool
    public let requiresSend: Bool
    public let scores: Scores
  }

  /// The server's scores for one concern, each in [0, 1]; nil where a stage did not run.
  public struct Scores: Equatable, Sendable, Decodable {
    public let pageP: Double?
    public let pageConfidence: Double?
    public let useful: Double?
    public let sectionP: Double?
    public let sectionConfidence: Double?
    public let resolves: Double?

    enum CodingKeys: String, CodingKey {
      case useful, resolves
      case pageP = "page_p"
      case pageConfidence = "page_confidence"
      case sectionP = "section_p"
      case sectionConfidence = "section_confidence"
    }

    var allInRange: Bool {
      [pageP, pageConfidence, useful, sectionP, sectionConfidence, resolves].allSatisfy {
        $0.map { (0...1).contains($0) } ?? true
      }
    }
  }

  public let status: Status
  public let reason: String
  public let coverage: Double?
  public let suppressionAllowed: Bool
  public let results: [Result]
  public let versions: FeedbackHelpOutcome.Versions?
}

extension HelpCheckReply {
  /// The only help-center host a card may link to.
  static let helpURLPrefix = "https://enviouswispr.com/help/"
  /// The server's g3 gates (website/functions/_lib/help-check.js GATES), applied again here so a
  /// card the scores do not support is refused whatever the server's verdict says.
  public static let coverageGate = 0.5
  static let pagePGate = 0.5
  static let pageConfidenceGate = 0.5
  static let usefulGate = 0.5
  static let sectionPGate = 0.5
  static let sectionConfidenceGate = 0.7
  static let resolvesGate = 0.7
  static let pageLinkPGate = 0.8

  /// Whether the scores support the match the server returned, by the same gates it uses.
  static func scoresSupport(_ match: Result.MatchType, _ s: Scores) -> Bool {
    switch match {
    case .none:
      return true
    case .section:
      guard let pageP = s.pageP, let pageConf = s.pageConfidence, let useful = s.useful,
        let sectionP = s.sectionP, let sectionConf = s.sectionConfidence, let resolves = s.resolves
      else { return false }
      return pageP >= pagePGate && pageConf >= pageConfidenceGate && useful >= usefulGate
        && sectionP >= sectionPGate && sectionConf >= sectionConfidenceGate
        && resolves >= resolvesGate
    case .page:
      guard let pageP = s.pageP, let pageConf = s.pageConfidence, let useful = s.useful,
        let resolves = s.resolves
      else { return false }
      return pageP >= pageLinkPGate && pageConf >= pageConfidenceGate && useful >= usefulGate
        && resolves >= resolvesGate
    }
  }

  /// The one link the catalog gives a page or section: `/help/<slug>/`, or `/help/<slug>/#<anchor>`
  /// (an article's intro has id `<slug>#intro` and the page link).
  static func canonicalURL(slug: String, sectionID: String?) -> [String] {
    let page = helpURLPrefix + slug + "/"
    guard let sectionID else { return [page] }
    let anchor = String(sectionID.dropFirst(slug.count + 1))
    return anchor == "intro" ? [page, page + "#intro"] : [page + "#" + anchor]
  }
  static let maxTextLength = 20_000
  static let maxReasonLength = 64

  private struct Wire: Decodable {
    struct Issue: Decodable {
      let id: String
      let match_type: Result.MatchType
      let page_slug: String?
      let page_title: String?
      let section_id: String?
      let heading: String?
      let text: String?
      let url: String?
      let deflection: String?
      let resolution_eligible: Bool
      let requires_send: Bool
      let scores: Scores
    }
    let v: Int
    let status: Status
    let reason: String
    let coverage: Double?
    let suppression_allowed: Bool
    let issues: [Issue]
    let kb_version: String?
    let jev_model_version: String?
    let decomposition_version: String?
    let decision_version: String?
    let threshold_version: String?
    let app_version: String?
  }

  /// Decodes and checks a reply for the request that was sent. Nil when anything is malformed,
  /// contradictory or does not line up with the request's concerns.
  static func decode(_ data: Data, expectedIssues: Int) -> HelpCheckReply? {
    guard let wire = try? JSONDecoder().decode(Wire.self, from: data), wire.v == 1,
      wire.reason.count <= maxReasonLength
    else { return nil }
    if let coverage = wire.coverage, !(0...1).contains(coverage) { return nil }
    var results: [Result] = []
    for (k, issue) in wire.issues.enumerated() {
      guard issue.id == "i\(k)" else { return nil }
      let deflection = issue.deflection.flatMap(FeedbackHelpOutcome.Deflection.init(rawValue:))
      if issue.deflection != nil, deflection == nil { return nil }  // unknown or never_intervene
      let url = issue.url.flatMap(URL.init(string:))
      switch issue.match_type {
      case .none:
        guard issue.page_slug == nil, issue.page_title == nil, issue.section_id == nil, issue.url == nil,
          deflection == nil, !issue.resolution_eligible, issue.requires_send
        else { return nil }
      case .page, .section:
        guard let slug = issue.page_slug, FeedbackHelpOutcome.Issue.isSlug(slug), deflection != nil,
          let raw = issue.url, url != nil,
          (issue.heading?.count ?? 0) <= maxTextLength, (issue.text?.count ?? 0) <= maxTextLength,
          (issue.page_title?.count ?? 0) <= maxTextLength
        else { return nil }
        if issue.match_type == .section {
          guard let section = issue.section_id, section.hasPrefix(slug + "#"),
            FeedbackHelpOutcome.Issue.isSlug(String(section.dropFirst(slug.count + 1))),
            issue.text != nil
          else { return nil }
        } else {
          guard issue.section_id == nil, !issue.resolution_eligible else { return nil }
        }
        guard canonicalURL(slug: slug, sectionID: issue.section_id).contains(raw) else { return nil }
      }
      guard issue.scores.allInRange, scoresSupport(issue.match_type, issue.scores) else { return nil }
      // A result the server says may be resolved must be a can_resolve section and need no send.
      if issue.resolution_eligible {
        guard issue.match_type == .section, deflection == .canResolve, !issue.requires_send
        else { return nil }
      }
      results.append(
        Result(
          id: issue.id, matchType: issue.match_type, pageSlug: issue.page_slug,
          pageTitle: issue.page_title, sectionID: issue.section_id, heading: issue.heading, text: issue.text, url: url,
          deflection: deflection, resolutionEligible: issue.resolution_eligible,
          requiresSend: issue.requires_send, scores: issue.scores))
    }
    switch wire.status {
    case .sendFeedback:
      guard results.isEmpty, !wire.suppression_allowed else { return nil }
    case .ok:
      // Every concern sent comes back, in order; the server derives one for a whole message.
      guard results.count == expectedIssues else { return nil }
    }
    let versions: FeedbackHelpOutcome.Versions? = {
      guard let kb = wire.kb_version, let jev = wire.jev_model_version,
        let decomposition = wire.decomposition_version, let decision = wire.decision_version,
        let threshold = wire.threshold_version, let app = wire.app_version
      else { return nil }
      return FeedbackHelpOutcome.Versions(
        kb: kb, jevModel: jev, decomposition: decomposition, decision: decision,
        threshold: threshold, app: app)
    }()
    // An answered check carries its version stamps; without them it cannot be recorded.
    if wire.status == .ok, versions == nil { return nil }
    return HelpCheckReply(
      status: wire.status, reason: wire.reason, coverage: wire.coverage,
      suppressionAllowed: wire.suppression_allowed, results: results, versions: versions)
  }
}
