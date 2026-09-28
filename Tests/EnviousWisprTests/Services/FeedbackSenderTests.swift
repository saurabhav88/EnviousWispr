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

  static func record(message: String = "hi", email: String? = nil, attachment: Data? = nil)
    -> FeedbackRecord
  {
    FeedbackRecord(
      id: UUID(uuidString: "5D1E6A2B-9C3F-4E7A-8B10-2F4C6D8E0A1B")!,
      submittedAt: Date(timeIntervalSince1970: 1_790_000_000), message: message, email: email,
      attachment: attachment, context: context, attempts: 0, nextAttemptAt: nil, state: .pending,
      rejectedStatus: nil)
  }

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
      "ftp://k@host/1",
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
        "event_id", "timestamp", "platform", "level", "release", "environment", "contexts",
      ])
    // Header, item header, payload, then the trailing newline: no attachment item.
    #expect(lines.count == 4)
    #expect(lines[3].isEmpty)
  }

  @Test("Ticked: the attachment item follows in the same envelope with the exact bytes")
  func envelopeWithAttachment() throws {
    let dsn = try #require(FeedbackDSN(Self.dsnString))
    let bytes = Data(#"{"diary":{"entries":[]},"schema_version":1}"#.utf8)
    let data = FeedbackSender.envelope(
      for: Self.record(attachment: bytes), dsn: dsn, sentAt: Date(timeIntervalSince1970: 0))
    let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)

    let attachmentHeader = try JSONSerialization.jsonObject(with: lines[3]) as? [String: Any]
    #expect(attachmentHeader?["type"] as? String == "attachment")
    #expect(attachmentHeader?["filename"] as? String == "enviouswispr-diagnostics.json")
    #expect(attachmentHeader?["content_type"] as? String == "application/json")
    #expect(attachmentHeader?["length"] as? Int == bytes.count)
    #expect(Data(lines[4]) == bytes)
  }

  // MARK: - Answers

  @Test("A plain 2xx is accepted")
  func accepted() {
    #expect(FeedbackSender.classify(status: 200, headers: [:], now: .distantPast) == .accepted)
  }

  @Test("A rate limit on feedback holds the report even on a 200, for the longest limit")
  func rateLimitOn200() {
    let now = Date(timeIntervalSince1970: 1000)
    let result = FeedbackSender.classify(
      status: 200,
      headers: ["X-Sentry-Rate-Limits": "60:transaction:key, 120:feedback:organization, 30::key"],
      now: now)
    #expect(result == .retry(notBefore: now.addingTimeInterval(120)))
  }

  @Test("A rate limit on other categories does not hold feedback")
  func unrelatedLimit() {
    let result = FeedbackSender.classify(
      status: 200, headers: ["x-sentry-rate-limits": "600:transaction;session:key"],
      now: .distantPast)
    #expect(result == .accepted)
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
  }

  @Test(
    "Server errors and timeouts are retried with backoff; bad payloads are rejected; auth pauses",
    arguments: [
      (500, FeedbackSender.Result.retry(notBefore: nil)),
      (503, FeedbackSender.Result.retry(notBefore: nil)),
      (408, FeedbackSender.Result.retry(notBefore: nil)),
      (400, FeedbackSender.Result.rejected(status: 400)),
      (413, FeedbackSender.Result.rejected(status: 413)),
      (401, FeedbackSender.Result.configurationFailure),
      (403, FeedbackSender.Result.configurationFailure),
      (404, FeedbackSender.Result.configurationFailure),
    ])
  func statusMapping(status: Int, expected: FeedbackSender.Result) {
    #expect(FeedbackSender.classify(status: status, headers: [:], now: .distantPast) == expected)
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
