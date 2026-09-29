import Foundation
import Testing

@testable import EnviousWisprServices

/// #3269: the envelope a bug report travels in and how Sentry's answer is read. No network: the
/// HTTP call is a recorder. Expected bytes and decisions are literals.
@Suite("Feedback sender (#3269)", .tags(.observabilityContract))
struct FeedbackSenderTests {

  static let dsnString = "https://abc123@o999.ingest.us.sentry.io/4507"
  static let context = FeedbackRecord.Context(
    appVersion: "2.5.2", appBuild: "252", release: "com.enviouswispr.app@2.5.2",
    environment: "development", osVersion: "15.4.0", osBuild: "24E248")

  static func record(
    message: String = "hi", email: String? = nil, attachment: Data? = nil,
    helpOutcome: FeedbackHelpOutcome? = nil
  ) -> FeedbackRecord {
    FeedbackRecord(
      id: UUID(uuidString: "5D1E6A2B-9C3F-4E7A-8B10-2F4C6D8E0A1B")!,
      submittedAt: Date(timeIntervalSince1970: 1_790_000_000), message: message, email: email,
      attachment: attachment, context: context, attempts: 0, nextAttemptAt: nil, state: .pending,
      rejectedStatus: nil, helpOutcome: helpOutcome)
  }

  /// A help-check outcome (#3275) with one of each match kind and resolution.
  static let helpOutcome = FeedbackHelpOutcome(
    terminalOutcome: .partialSent, failureReason: nil, mode: .decomposed, overflow: false,
    coveragePassed: true,
    versions: FeedbackHelpOutcome.Versions(
      kb: "72134d105fb3", jevModel: "jev-1.13.0", decomposition: "afm-26.1",
      decision: "2026-09-28.1", threshold: "g3-0.5-0.5-u0.5-0.5-0.7-0.7-0.8-c0.5", app: "2.6.0"),
    shownCardCount: 2,
    issues: [
      FeedbackHelpOutcome.Issue(
        index: 0, matchKind: .section, pageSlug: "toggle-mode",
        sectionID: "toggle-mode#turning-it-on", deflection: .canResolve, resolution: .solved)!,
      FeedbackHelpOutcome.Issue(
        index: 1, matchKind: .page, pageSlug: "paste-not-working", sectionID: nil,
        deflection: .showButAlwaysSend, resolution: .stillHappening)!,
      FeedbackHelpOutcome.Issue(
        index: 2, matchKind: .none, pageSlug: nil, sectionID: nil, deflection: nil,
        resolution: .unmatched)!,
    ])!

  // MARK: - DSN

  @Test("The DSN gives the envelope address and the public key; a path prefix and port are kept")
  func dsnParsing() throws {
    let plain = try #require(FeedbackDSN(Self.dsnString))
    #expect(
      plain.envelopeURL.absoluteString == "https://o999.ingest.us.sentry.io/api/4507/envelope/")
    #expect(plain.publicKey == "abc123")

    let prefixed = try #require(FeedbackDSN("https://k@sentry.example.com:9000/relay/42"))
    #expect(
      prefixed.envelopeURL.absoluteString
        == "https://sentry.example.com:9000/relay/api/42/envelope/")
  }

  @Test(
    "A malformed DSN is refused",
    arguments: [
      "", "not a url", "https://host/42", "https://k@/42", "https://k@host/", "https://k@host/abc",
      "ftp://k@host/1", "http://k@host/1",
    ])
  func malformedDSN(value: String) {
    #expect(FeedbackDSN(value) == nil)
  }

  // MARK: - Envelope

  @Test("Unticked: one feedback item with level error, the words, email and versions only")
  func envelopeWithoutAttachment() throws {
    let dsn = try #require(FeedbackDSN(Self.dsnString))
    let data = FeedbackSender.envelope(
      for: Self.record(message: "Zeile 1\nÜmlaut 🙂", email: "a@b.de"), dsn: dsn,
      sentAt: Date(timeIntervalSince1970: 1_790_000_100))
    let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)

    let header = try JSONSerialization.jsonObject(with: lines[0]) as? [String: Any]
    #expect(header?["event_id"] as? String == "5d1e6a2b9c3f4e7a8b102f4c6d8e0a1b")
    #expect(header?["dsn"] as? String == Self.dsnString)
    let itemHeader = try JSONSerialization.jsonObject(with: lines[1]) as? [String: Any]
    #expect(itemHeader?["type"] as? String == "feedback")
    #expect(itemHeader?["length"] as? Int == lines[2].count)

    let payload = try #require(try JSONSerialization.jsonObject(with: lines[2]) as? [String: Any])
    #expect(payload["level"] as? String == "error")
    #expect(payload["type"] as? String == "feedback")
    // Sentry must not store the sender's IP address (the SDK's own setting with PII off).
    let sdk = try #require(payload["sdk"] as? [String: Any])
    #expect((sdk["settings"] as? [String: Any])?["infer_ip"] as? String == "never")
    #expect(payload["event_id"] as? String == "5d1e6a2b9c3f4e7a8b102f4c6d8e0a1b")
    #expect(payload["timestamp"] as? Double == 1_790_000_000)
    #expect(payload["release"] as? String == "com.enviouswispr.app@2.5.2")
    #expect(payload["environment"] as? String == "development")
    let contexts = try #require(payload["contexts"] as? [String: Any])
    let feedback = try #require(contexts["feedback"] as? [String: Any])
    #expect(feedback["message"] as? String == "Zeile 1\nÜmlaut 🙂")
    #expect(feedback["contact_email"] as? String == "a@b.de")
    #expect(Set(contexts.keys) == ["feedback", "app", "os"])
    // Nothing from the telemetry lane rides along.
    #expect(
      Set(payload.keys) == [
        "event_id", "type", "timestamp", "platform", "level", "release", "environment", "sdk",
        "contexts",
      ])
    // Header, item header, payload, then the trailing newline: no attachment item.
    #expect(lines.count == 4)
    #expect(lines[3].isEmpty)
  }

  // MARK: - Help-check outcome (#3275)

  @Test("A help-check outcome adds only its fixed tags; everything else in the report is unchanged")
  func helpOutcomeTags() throws {
    let dsn = try #require(FeedbackDSN(Self.dsnString))
    let bytes = Data("{\n  \"schema_version\" : 1\n}".utf8)
    let plain = Self.record(message: "Paste fails 🙂", email: "a@b.de", attachment: bytes)
    let helped = Self.record(
      message: "Paste fails 🙂", email: "a@b.de", attachment: bytes, helpOutcome: Self.helpOutcome)

    var payload = FeedbackSender.feedbackPayload(for: helped)
    let tags = try #require(payload.removeValue(forKey: "tags") as? [String: String])
    #expect(
      tags == [
        "help_v": "1", "help_outcome": "partial_sent", "help_mode": "decomposed",
        "help_overflow": "false", "help_coverage": "pass", "help_kb": "72134d105fb3",
        "help_jev": "jev-1.13.0", "help_decomp": "afm-26.1", "help_decision": "2026-09-28.1",
        "help_threshold": "g3-0.5-0.5-u0.5-0.5-0.7-0.7-0.8-c0.5", "help_app": "2.6.0",
        "help_issues": "3", "help_cards": "2", "help_sections": "1", "help_pages": "1",
        "help_solved": "1", "help_unresolved": "1", "help_unmatched": "1",
        "help_i0_resolution": "solved", "help_i0_match": "section", "help_i0_page": "toggle-mode",
        "help_i0_section": "toggle-mode#turning-it-on", "help_i0_policy": "can_resolve",
        "help_i1_resolution": "still_happening", "help_i1_match": "page",
        "help_i1_page": "paste-not-working", "help_i1_policy": "show_but_always_send",
        "help_i2_resolution": "unmatched", "help_i2_match": "none",
      ])
    #expect(tags.values.allSatisfy { $0.count <= 200 })
    // Without the tags, the payload is the plain report's payload, key for key.
    let plainPayload = FeedbackSender.feedbackPayload(for: plain)
    #expect(
      NSDictionary(dictionary: payload).isEqual(to: plainPayload),
      "the tags are the only difference")
    #expect(payload["level"] as? String == "error")
    #expect(plainPayload["tags"] == nil)

    // The envelope still carries the message once and the attachment bytes exactly.
    let envelope = FeedbackSender.envelope(
      for: helped, dsn: dsn, sentAt: Date(timeIntervalSince1970: 0))
    let text = String(decoding: envelope, as: UTF8.self)
    #expect(text.components(separatedBy: "Paste fails").count == 2)
    var tail = bytes
    tail.append(0x0A)
    #expect(Data(envelope.suffix(tail.count)) == tail)
  }

  @Test("A fallback outcome tags its closed reason and no versions it never received")
  func fallbackOutcomeTags() throws {
    let outcome = try #require(
      FeedbackHelpOutcome(
        terminalOutcome: .fallbackSent, failureReason: .afmTimeout, mode: .decomposed,
        overflow: false, coveragePassed: nil, versions: nil, shownCardCount: 0, issues: []))
    let tags = try #require(
      FeedbackSender.feedbackPayload(for: Self.record(helpOutcome: outcome))["tags"]
        as? [String: String])
    #expect(
      tags == [
        "help_v": "1", "help_outcome": "fallback_sent", "help_failure": "afm_timeout",
        "help_mode": "decomposed", "help_overflow": "false", "help_issues": "0", "help_cards": "0",
        "help_sections": "0", "help_pages": "0", "help_solved": "0", "help_unresolved": "0",
        "help_unmatched": "0",
      ])
  }

  @Test("A stored outcome claiming solved where the form never offers it does not decode")
  func solvedOutsideTheFormDoesNotDecode() throws {
    let good = try JSONEncoder().encode(Self.helpOutcome)
    #expect(try JSONDecoder().decode(FeedbackHelpOutcome.self, from: good) == Self.helpOutcome)
    let text = String(decoding: good, as: UTF8.self)
    // The page-link concern (i1) edited to solved.
    let pageSolved = text.replacingOccurrences(
      of: #""resolution":"still_happening""#, with: #""resolution":"solved""#)
    #expect(pageSolved != text)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(FeedbackHelpOutcome.self, from: Data(pageSolved.utf8))
    }
    // A one-concern outcome with i0 solved, edited to whole-message mode: only the mode differs.
    let single = try #require(
      FeedbackHelpOutcome(
        terminalOutcome: .stillSent, failureReason: nil, mode: .decomposed, overflow: false,
        coveragePassed: true, versions: nil, shownCardCount: 1, issues: [Self.helpOutcome.issues[0]]))
    let singleText = String(decoding: try JSONEncoder().encode(single), as: UTF8.self)
    #expect(try JSONDecoder().decode(FeedbackHelpOutcome.self, from: Data(singleText.utf8)) == single)
    let wholeSolved = singleText.replacingOccurrences(
      of: #""mode":"decomposed""#, with: #""mode":"whole_message_always_send""#)
    #expect(wholeSolved != singleText)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(FeedbackHelpOutcome.self, from: Data(wholeSolved.utf8))
    }
  }

  typealias Help = FeedbackHelpOutcome

  @Test("A help-check outcome out of bounds cannot be frozen")
  func helpOutcomeBounds() {
    let section = { (i: Int) in
      Help.Issue(
        index: i, matchKind: .section, pageSlug: "toggle-mode", sectionID: "toggle-mode#a",
        deflection: .canResolve, resolution: .stillHappening)!
    }
    let solved = Help.Issue(
      index: 0, matchKind: .section, pageSlug: "toggle-mode", sectionID: "toggle-mode#a",
      deflection: .canResolve, resolution: .solved)!
    let make = {
      (outcome: Help.TerminalOutcome, reason: Help.FailureReason?, mode: Help.Mode, cards: Int,
        issues: [Help.Issue]) in
      Help(
        terminalOutcome: outcome, failureReason: reason, mode: mode, overflow: false,
        coveragePassed: true, versions: nil, shownCardCount: cards, issues: issues)
    }
    // Each line changes one thing from a valid outcome.
    #expect(make(.stillSent, nil, .decomposed, 1, [section(0)]) != nil)
    #expect(make(.stillSent, nil, .decomposed, 3, (0..<5).map(section)) != nil)
    #expect(make(.stillSent, nil, .decomposed, 3, (0..<6).map { section($0 % 5) }) == nil)
    #expect(make(.stillSent, nil, .decomposed, 1, [section(1)]) == nil)
    #expect(make(.stillSent, nil, .decomposed, 4, (0..<5).map(section)) == nil)
    #expect(make(.stillSent, nil, .decomposed, 2, [section(0)]) == nil)
    #expect(make(.stillSent, .timeout, .decomposed, 1, [section(0)]) == nil)
    #expect(make(.fallbackSent, nil, .decomposed, 0, []) == nil)
    #expect(make(.stillSent, nil, .wholeMessageAlwaysSend, 1, [section(0), section(1)]) == nil)
    #expect(make(.partialSent, nil, .decomposed, 1, [section(0)]) == nil)
    // Solved exists only where the form offers it: a decomposed check that reached its cards.
    #expect(make(.stillSent, nil, .decomposed, 1, [solved]) != nil)
    #expect(make(.stillSent, nil, .wholeMessageAlwaysSend, 1, [solved]) == nil)
    #expect(make(.fallbackSent, .timeout, .decomposed, 0, [solved]) == nil)
    #expect(make(.fallbackSent, .timeout, .decomposed, 1, [section(0)]) == nil)
    #expect(make(.fallbackSent, .timeout, .decomposed, 0, [section(0)]) != nil)

    let issue = {
      (kind: Help.MatchKind, page: String?, sectionID: String?, r: Help.Resolution,
        policy: Help.Deflection?) in
      Help.Issue(
        index: 0, matchKind: kind, pageSlug: page, sectionID: sectionID, deflection: policy,
        resolution: r)
    }
    #expect(issue(.section, "toggle-mode", "toggle-mode#a", .solved, .canResolve) != nil)
    #expect(issue(.section, "toggle-mode", "toggle-mode#a", .solved, .showButAlwaysSend) == nil)
    #expect(issue(.section, "toggle-mode", "toggle-mode#a", .stillHappening, .showButAlwaysSend) != nil)
    #expect(issue(.section, "toggle-mode", "toggle-mode#a", .stillHappening, nil) == nil)
    #expect(issue(.page, "toggle-mode", nil, .solved, .canResolve) == nil)
    #expect(issue(.page, "toggle-mode", nil, .stillHappening, nil) == nil)
    #expect(issue(.none, nil, nil, .unmatched, .canResolve) == nil)
    #expect(issue(.section, "toggle-mode", "paste-not-working#a", .solved, .canResolve) == nil)
    #expect(issue(.section, "toggle-mode", nil, .solved, .canResolve) == nil)
    #expect(issue(.section, "Toggle-Mode", "Toggle-Mode#a", .solved, .canResolve) == nil)
    #expect(issue(.section, "toggle-mode", "toggle-mode#a b", .solved, .canResolve) == nil)
    #expect(issue(.page, String(repeating: "a", count: 99), nil, .stillHappening, .canResolve) != nil)
    #expect(issue(.page, String(repeating: "a", count: 100), nil, .stillHappening, .canResolve) == nil)
    #expect(issue(.page, "toggle-mode", "toggle-mode#a", .stillHappening, .canResolve) == nil)
    #expect(issue(.page, "toggle-mode", nil, .unmatched, .canResolve) == nil)
    #expect(issue(.none, nil, nil, .unmatched, nil) != nil)
    #expect(issue(.none, "toggle-mode", nil, .unmatched, nil) == nil)
    #expect(issue(.none, nil, nil, .solved, nil) == nil)
    #expect(
      Help.Issue(
        index: 5, matchKind: .none, pageSlug: nil, sectionID: nil, deflection: nil,
        resolution: .unmatched) == nil)

    let version = { (v: String) in
      Help.Versions(kb: v, jevModel: "j", decomposition: "d", decision: "d", threshold: "t", app: "a")
    }
    #expect(version("72134d105fb3") != nil)
    #expect(version("") == nil)
    #expect(version("has space") == nil)
    #expect(version(String(repeating: "a", count: 65)) == nil)
    #expect(version("ünicode") == nil)
  }

  @Test("Ticked: the attachment item follows in the same envelope with the exact bytes")
  func envelopeWithAttachment() throws {
    let dsn = try #require(FeedbackDSN(Self.dsnString))
    // Pretty-printed like the real snapshot: newlines inside must not end the item.
    let bytes = Data("{\n  \"diary\" : {\"entries\" : []},\n  \"schema_version\" : 1\n}".utf8)
    let data = FeedbackSender.envelope(
      for: Self.record(attachment: bytes), dsn: dsn, sentAt: Date(timeIntervalSince1970: 0))
    let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)

    // The envelope ends with exactly the attachment bytes and one newline.
    var expectedTail = bytes
    expectedTail.append(0x0A)
    #expect(Data(data.suffix(expectedTail.count)) == expectedTail)
    let attachmentHeader = try JSONSerialization.jsonObject(with: lines[3]) as? [String: Any]
    #expect(attachmentHeader?["type"] as? String == "attachment")
    #expect(attachmentHeader?["filename"] as? String == "enviouswispr-diagnostics.json")
    #expect(attachmentHeader?["content_type"] as? String == "application/json")
    #expect(attachmentHeader?["length"] as? Int == bytes.count)
  }

  // MARK: - Answers

  @Test("A plain 2xx is accepted")
  func accepted() {
    #expect(
      FeedbackSender.classify(status: 200, headers: [:], now: .distantPast)
        == .accepted(holdUntil: nil))
  }

  @Test("A 200 delivers the report; a feedback rate limit in it holds later sends, longest wins")
  func rateLimitOn200() {
    let now = Date(timeIntervalSince1970: 1000)
    let result = FeedbackSender.classify(
      status: 200,
      headers: ["X-Sentry-Rate-Limits": "60:transaction:key, 120:feedback:organization, 30::key"],
      now: now)
    #expect(result == .accepted(holdUntil: now.addingTimeInterval(120)))
  }

  @Test("A rate limit on other categories does not hold feedback")
  func unrelatedLimit() {
    let result = FeedbackSender.classify(
      status: 200, headers: ["x-sentry-rate-limits": "600:transaction;session:key"],
      now: .distantPast)
    #expect(result == .accepted(holdUntil: nil))
  }

  @Test("A 429 waits for Retry-After, or 60 seconds without it")
  func tooManyRequests() {
    let now = Date(timeIntervalSince1970: 1000)
    #expect(
      FeedbackSender.classify(status: 429, headers: ["Retry-After": "90"], now: now)
        == .retry(notBefore: now.addingTimeInterval(90)))
    #expect(
      FeedbackSender.classify(status: 429, headers: [:], now: now)
        == .retry(notBefore: now.addingTimeInterval(60)))
    // The HTTP-date form waits until that moment, not the 60 s fallback.
    #expect(
      FeedbackSender.classify(
        status: 429, headers: ["Retry-After": "Fri, 11 Sep 2026 19:00:00 GMT"],
        now: Date(timeIntervalSince1970: 1_789_146_000))
        == .retry(notBefore: Date(timeIntervalSince1970: 1_789_153_200)))
  }

  @Test(
    "Server errors and timeouts are retried with backoff; bad payloads are rejected; auth pauses",
    arguments: [
      (500, FeedbackSender.Result.retry(notBefore: nil)),
      (503, FeedbackSender.Result.retry(notBefore: nil)),
      (408, FeedbackSender.Result.retry(notBefore: nil)),
      (400, FeedbackSender.Result.rejected(status: 400, holdUntil: nil)),
      (413, FeedbackSender.Result.rejected(status: 413, holdUntil: nil)),
      (401, FeedbackSender.Result.configurationFailure(holdUntil: nil)),
      (403, FeedbackSender.Result.configurationFailure(holdUntil: nil)),
      (404, FeedbackSender.Result.configurationFailure(holdUntil: nil)),
    ])
  func statusMapping(status: Int, expected: FeedbackSender.Result) {
    #expect(FeedbackSender.classify(status: status, headers: [:], now: .distantPast) == expected)
  }

  @Test("A feedback rate limit is kept on every outcome: delivered, refused, bad credentials, retry")
  func limitKeptOnEveryOutcome() {
    let now = Date(timeIntervalSince1970: 1000)
    let headers = ["X-Sentry-Rate-Limits": "300:feedback:organization"]
    let hold = now.addingTimeInterval(300)
    #expect(FeedbackSender.classify(status: 200, headers: headers, now: now) == .accepted(holdUntil: hold))
    #expect(
      FeedbackSender.classify(status: 413, headers: headers, now: now)
        == .rejected(status: 413, holdUntil: hold))
    #expect(
      FeedbackSender.classify(status: 401, headers: headers, now: now)
        == .configurationFailure(holdUntil: hold))
    #expect(FeedbackSender.classify(status: 503, headers: headers, now: now) == .retry(notBefore: hold))
    #expect(FeedbackSender.classify(status: 429, headers: headers, now: now) == .retry(notBefore: hold))
  }

  @Test("A network error is a retry; the request is a POST with envelope type and public-key auth")
  func sendRequestShapeAndNetworkError() async throws {
    let dsn = try #require(FeedbackDSN(Self.dsnString))
    let seen = RequestBox()
    let sender = FeedbackSender(
      dsn: dsn,
      http: { request in
        seen.set(request)
        throw URLError(.notConnectedToInternet)
      }, now: { Date(timeIntervalSince1970: 0) })

    let result = await sender.send(Self.record())

    #expect(result == .retry(notBefore: nil))
    let request = try #require(seen.value)
    #expect(request.httpMethod == "POST")
    #expect(request.url == dsn.envelopeURL)
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-sentry-envelope")
    #expect(
      request.value(forHTTPHeaderField: "X-Sentry-Auth")
        == "Sentry sentry_version=7, sentry_key=abc123, sentry_client=enviouswispr-feedback/2.5.2")
  }

  final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URLRequest?
    var value: URLRequest? { lock.withLock { stored } }
    func set(_ request: URLRequest) { lock.withLock { stored = request } }
  }
}
