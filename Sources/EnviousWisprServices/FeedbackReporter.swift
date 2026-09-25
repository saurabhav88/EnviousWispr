import Foundation
import Sentry

/// One user-written feedback report (#3153): the message, and an email only if they want a reply.
///
/// `init?` is the only way to get one, so a draft that exists is always sendable.
public struct FeedbackDraft: Equatable, Sendable {
  /// Longest message accepted. Generous for a pasted log or a long description; Live UAT must
  /// read a 3,900-character report back from Sentry intact.
  public static let maxMessageLength = 4000

  public let message: String
  /// `nil` when the field was left empty; never an empty string.
  public let email: String?

  /// Why a draft cannot be sent yet, for the form to show.
  public enum Issue: Equatable, Sendable {
    case emptyMessage, messageTooLong, invalidEmail
  }

  /// Trims both fields; `nil` when `issue(message:email:)` finds a problem.
  public init?(message: String, email: String) {
    guard Self.issue(message: message, email: email) == nil else { return nil }
    self.message = message.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
    self.email = trimmedEmail.isEmpty ? nil : trimmedEmail
  }

  /// The single validity rule, shared by `init?` and the form.
  public static func issue(message: String, email: String) -> Issue? {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .emptyMessage }
    if trimmed.count > maxMessageLength { return .messageTooLong }
    let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedEmail.isEmpty,
      trimmedEmail.range(
        of: #"^[^@\s]+@([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$"#, options: .regularExpression) == nil
    {
      return .invalidEmail
    }
    return nil
  }
}

/// Sends a feedback report through the app's Sentry client (#3153).
///
/// The report rides the global scope like any other event: the install's `analytics.distinct_id`
/// tag, its Sentry `user.id`, OS and device contexts, and the recent pipeline breadcrumbs. Sentry
/// skips `beforeSend` for feedback, which is why every global-scope write is filtered where it is
/// written (`SentryBreadcrumb`, `ObservabilityBootstrap.writeStableTags`).
public enum FeedbackReporter {
  public enum Outcome: Equatable, Sendable {
    /// Handed to Sentry for sending. Not a delivery receipt: Sentry writes and sends in the
    /// background, and a rate limit, a failed write or a quit before the write can still lose it.
    case queued
    /// Sentry is not running in this process (no DSN), so nothing was sent.
    case unavailable
  }

  @MainActor @discardableResult
  public static func send(_ draft: FeedbackDraft) -> Outcome {
    send(draft, isEnabled: SentrySDK.isEnabled, capture: { SentrySDK.capture(feedback: $0) })
  }

  /// The decision and the report, with the SDK calls passed in so a test can observe exactly
  /// what would be sent without starting Sentry or sending anything.
  @MainActor
  static func send(
    _ draft: FeedbackDraft, isEnabled: Bool, capture: (SentryFeedback) -> Void
  ) -> Outcome {
    // Without a started SDK the hub has no client and the capture would silently do nothing.
    guard isEnabled else { return .unavailable }
    capture(
      SentryFeedback(message: draft.message, name: nil, email: draft.email, source: .custom))
    return .queued
  }
}
