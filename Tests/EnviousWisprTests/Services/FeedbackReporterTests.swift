import Foundation
import Sentry
import Testing

@testable import EnviousWisprServices

/// #3153: what the Send Feedback form accepts, and what it hands to Sentry.
@Suite("Feedback reporter (#3153)", .tags(.productOutcome))
@MainActor
struct FeedbackReporterTests {

  // MARK: - Draft

  @Test("An empty or whitespace-only message cannot be sent")
  func emptyMessageRejected() {
    #expect(FeedbackDraft.issue(message: "", email: "") == .emptyMessage)
    #expect(FeedbackDraft.issue(message: "  \n\t ", email: "") == .emptyMessage)
    #expect(FeedbackDraft(message: "   ", email: "") == nil)
  }

  @Test("The length cap is inclusive at 4000 characters, after trimming")
  func lengthCap() {
    let atCap = String(repeating: "a", count: FeedbackDraft.maxMessageLength)
    #expect(FeedbackDraft.maxMessageLength == 4000)
    #expect(FeedbackDraft(message: atCap, email: "")?.message == atCap)
    #expect(FeedbackDraft.issue(message: atCap + "a", email: "") == .messageTooLong)
    // Surrounding whitespace does not count against the cap.
    #expect(FeedbackDraft(message: "  " + atCap + "\n", email: "")?.message == atCap)
  }

  @Test("A long message keeps every character; only surrounding whitespace is trimmed")
  func longMessageIntact() {
    let body = (0..<39).map { "Line \($0): the paste landed twice in Slack, then once." }
      .joined(separator: "\n")
    #expect(body.count > 1500)
    #expect(FeedbackDraft(message: "\n  " + body + "  \n", email: "")?.message == body)
  }

  @Test("Email: empty sends none; a shaped address is kept trimmed; a malformed one blocks Send")
  func emailRules() {
    #expect(FeedbackDraft(message: "hi", email: "")?.email == nil)
    #expect(FeedbackDraft(message: "hi", email: "   ")?.email == nil)
    #expect(FeedbackDraft(message: "hi", email: " a@b.co ")?.email == "a@b.co")
    #expect(FeedbackDraft.issue(message: "hi", email: "a@b") == .invalidEmail)
    #expect(FeedbackDraft.issue(message: "hi", email: "a b@c.co") == .invalidEmail)
    #expect(FeedbackDraft(message: "hi", email: "a@b") == nil)
  }

  // MARK: - Send

  @Test("With Sentry not running, nothing is captured and the form is told so")
  func unavailableWhenSentryOff() throws {
    let draft = try #require(FeedbackDraft(message: "hi", email: ""))
    var captured: [SentryFeedback] = []
    let outcome = FeedbackReporter.send(draft, isEnabled: false, capture: { captured.append($0) })
    #expect(outcome == .unavailable)
    #expect(captured.isEmpty)
  }

  @Test("The real entry point reports unavailable in a process where Sentry never started")
  func realEntryPointInTestProcess() throws {
    // The unit-test process does not run the app's launch, so no DSN and no started SDK.
    try #require(!SentrySDK.isEnabled)
    let draft = try #require(FeedbackDraft(message: "hi", email: ""))
    #expect(FeedbackReporter.send(draft) == .unavailable)
  }

  @Test("With Sentry running, exactly one report carries the message, the email and no name")
  func queuedCarriesDraft() throws {
    let draft = try #require(
      FeedbackDraft(message: "  it pasted twice in slack  ", email: " someone@example.com "))
    var captured: [SentryFeedback] = []
    let outcome = FeedbackReporter.send(draft, isEnabled: true, capture: { captured.append($0) })
    #expect(outcome == .queued)
    let feedback = try #require(captured.count == 1 ? captured.first : nil)
    let payload = feedback.serialize()
    #expect(payload["message"] as? String == "it pasted twice in slack")
    #expect(payload["contact_email"] as? String == "someone@example.com")
    #expect(payload["name"] == nil)
    #expect(payload["source"] as? String == "custom")
    #expect(payload["associated_event_id"] == nil)
  }

  @Test("No email means no contact_email field, not an empty one")
  func noEmailNoField() throws {
    let draft = try #require(FeedbackDraft(message: "love it", email: ""))
    var captured: [SentryFeedback] = []
    _ = FeedbackReporter.send(draft, isEnabled: true, capture: { captured.append($0) })
    let payload = try #require(captured.first).serialize()
    #expect(payload["contact_email"] == nil)
    #expect(payload["message"] as? String == "love it")
  }
}
