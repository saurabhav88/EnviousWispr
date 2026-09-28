import Foundation

/// One bug report as the user submitted it (#3269), frozen at Send. Nothing here is rebuilt at
/// retry time: not the settings, not the SDK scope, not the diary. A report carries only what
/// the Send Feedback form chose (founder, 2026-09-28: bug reports are their own lane).
struct FeedbackRecord: Codable, Equatable, Sendable {
  enum State: String, Codable, Sendable {
    case pending
    /// Sentry refused this payload (a 400 or 413). Kept, never retried automatically.
    case rejected
  }

  /// UUID v4; its 32-hex form is the Sentry event id on every attempt.
  let id: UUID
  let submittedAt: Date
  let message: String
  let email: String?
  /// The previewed diagnostics bytes, exactly, or nil when the box was unticked.
  let attachment: Data?
  let context: Context
  var attempts: Int
  var nextAttemptAt: Date?
  var state: State
  var rejectedStatus: Int?

  /// Basic submission-time versions, the only context a report carries outside the attachment.
  struct Context: Codable, Equatable, Sendable {
    let appVersion: String
    let appBuild: String
    let release: String
    let environment: String
    let osVersion: String
    let osBuild: String
  }

  var eventID: String { id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
}

/// Sentry's DSN, parsed once: where envelopes go and the public key that authenticates them.
struct FeedbackDSN: Equatable, Sendable {
  let original: String
  let envelopeURL: URL
  let publicKey: String

  /// `https://<key>@<host>[:port][/<path prefix>]/<project id>`. Nil for anything else,
  /// including plain http: a report never travels unencrypted.
  init?(_ string: String) {
    guard var components = URLComponents(string: string),
      components.scheme == "https",
      let key = components.user, !key.isEmpty, components.host?.isEmpty == false
    else { return nil }
    var segments = components.path.split(separator: "/").map(String.init)
    guard let project = segments.popLast(), !project.isEmpty,
      project.allSatisfy(\.isNumber)
    else { return nil }
    let prefix = segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
    components.user = nil
    components.password = nil
    components.path = "\(prefix)/api/\(project)/envelope/"
    components.query = nil
    components.fragment = nil
    guard let url = components.url else { return nil }
    self.original = string
    self.envelopeURL = url
    self.publicKey = key
  }
}

/// Builds the Sentry envelope for one report and reads Sentry's answer (#3269). Pure except for
/// the injected HTTP call, so every decision is testable without the network. Protocol:
/// develop.sentry.dev envelopes, feedback (one `feedback` item, attachments in the same envelope)
/// and rate limiting (evidence in docs/audits/2026-09-28-issue-3269-outbox-design.md).
struct FeedbackSender: Sendable {
  static let attachmentFilename = FeedbackDiagnosticsSnapshot.filename
  static let attachmentContentType = FeedbackDiagnosticsSnapshot.contentType

  /// What one attempt concluded.
  enum Result: Equatable, Sendable {
    /// Sentry accepted the envelope. Not a guarantee it is visible in Sentry yet.
    case accepted
    /// Keep the report; try again no earlier than `notBefore` (nil = the outbox's own backoff).
    case retry(notBefore: Date?)
    /// Sentry refused this payload; keep it and stop retrying it.
    case rejected(status: Int)
    /// The DSN or credentials are wrong; pause every send until the next launch.
    case configurationFailure
  }

  typealias HTTP = @Sendable (URLRequest) async throws -> (status: Int, headers: [String: String])

  let dsn: FeedbackDSN
  let http: HTTP
  let now: @Sendable () -> Date

  func send(_ record: FeedbackRecord) async -> Result {
    var request = URLRequest(url: dsn.envelopeURL, timeoutInterval: 30)
    request.httpMethod = "POST"
    request.setValue("application/x-sentry-envelope", forHTTPHeaderField: "Content-Type")
    request.setValue(
      "Sentry sentry_version=7, sentry_key=\(dsn.publicKey), sentry_client=enviouswispr-feedback/\(record.context.appVersion)",
      forHTTPHeaderField: "X-Sentry-Auth")
    request.httpBody = Self.envelope(for: record, dsn: dsn, sentAt: now())
    do {
      let response = try await http(request)
      return Self.classify(status: response.status, headers: response.headers, now: now())
    } catch {
      return .retry(notBefore: nil)
    }
  }

  // MARK: - Envelope

  /// Header line, the feedback item, and the attachment item only when the report has one. Each
  /// item header carries the payload's exact UTF-8 byte length; lines end with "\n".
  static func envelope(for record: FeedbackRecord, dsn: FeedbackDSN, sentAt: Date) -> Data {
    var data = Data()
    let header: [String: Any] = [
      "event_id": record.eventID, "sent_at": iso8601(sentAt), "dsn": dsn.original,
    ]
    data.append(json(header))
    data.append(0x0A)
    let payload = json(feedbackPayload(for: record))
    data.append(json(["type": "feedback", "length": payload.count]))
    data.append(0x0A)
    data.append(payload)
    data.append(0x0A)
    if let attachment = record.attachment {
      data.append(
        json([
          "type": "attachment", "length": attachment.count, "filename": attachmentFilename,
          "content_type": attachmentContentType,
        ]))
      data.append(0x0A)
      data.append(attachment)
      data.append(0x0A)
    }
    return data
  }

  /// The feedback event: the user's words, the optional email, basic versions, and level error
  /// (the sentry-triage Worker alerts only on error or fatal, #3275). `type` is "feedback" as the
  /// SDK sets it (sentry-cocoa 9.26.1 `SentryClient.m:613`). No user, tags or breadcrumbs.
  static func feedbackPayload(for record: FeedbackRecord) -> [String: Any] {
    var feedback: [String: Any] = ["message": record.message, "source": "custom"]
    if let email = record.email { feedback["contact_email"] = email }
    return [
      "event_id": record.eventID,
      "type": "feedback",
      "timestamp": record.submittedAt.timeIntervalSince1970,
      "platform": "cocoa",
      "level": "error",
      "release": record.context.release,
      "environment": record.context.environment,
      "contexts": [
        "feedback": feedback,
        "app": ["app_version": record.context.appVersion, "app_build": record.context.appBuild],
        "os": [
          "name": "macOS", "version": record.context.osVersion, "build": record.context.osBuild,
        ],
      ],
    ]
  }

  private static func json(_ object: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
  }

  private static func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  // MARK: - Response

  /// The rate-limit categories that stop a feedback envelope: all categories (empty), feedback,
  /// and attachments.
  static let limitingCategories: Set<String> = ["", "feedback", "user_report_v2", "attachment"]

  /// Reads the status and rate-limit headers. A limit that applies to feedback holds the report
  /// even on a 200, because Sentry reports quota rejections that way.
  static func classify(status: Int, headers: [String: String], now: Date) -> Result {
    let lowered = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }) { a, _ in a }
    if let limits = lowered["x-sentry-rate-limits"],
      let seconds = longestApplicableLimit(limits)
    {
      return .retry(notBefore: now.addingTimeInterval(seconds))
    }
    switch status {
    case 200..<300:
      return .accepted
    case 429:
      let seconds = lowered["retry-after"].flatMap(TimeInterval.init) ?? 60
      return .retry(notBefore: now.addingTimeInterval(max(seconds, 1)))
    case 401, 403, 404:
      return .configurationFailure
    case 400, 413:
      return .rejected(status: status)
    default:
      return .retry(notBefore: nil)
    }
  }

  /// `X-Sentry-Rate-Limits: <seconds>:<categories>:<scope>[:...], ...`, categories separated by
  /// ";" and empty meaning every category. Returns the longest limit that applies to feedback.
  static func longestApplicableLimit(_ header: String) -> TimeInterval? {
    var longest: TimeInterval?
    for quota in header.split(separator: ",") {
      let fields = quota.trimmingCharacters(in: .whitespaces).split(
        separator: ":", omittingEmptySubsequences: false)
      guard fields.count >= 2, let seconds = TimeInterval(fields[0]), seconds > 0 else { continue }
      let categories = fields[1].isEmpty ? [""] : fields[1].split(separator: ";").map(String.init)
      guard categories.contains(where: limitingCategories.contains) else { continue }
      longest = max(longest ?? 0, seconds)
    }
    return longest
  }
}
