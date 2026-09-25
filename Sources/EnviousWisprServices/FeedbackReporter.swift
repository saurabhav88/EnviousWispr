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

  /// A plausible reply address: a typo guard, not a delivery check. A dot-atom local part (no
  /// leading, trailing or doubled dot) and dot-separated domain labels that start and end with a
  /// letter or digit, ending in a letters-only or `xn--` label. Letters from any script are
  /// accepted (`josé@example.com`, `a@bücher.de`); quoted local parts, IP literals and length
  /// limits are not checked.
  static let emailPattern =
    #"^[A-Za-z0-9!#$%&'*+/=?^_`{|}~\p{L}\p{M}\p{Nd}-]+(\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~\p{L}\p{M}\p{Nd}-]+)*@([A-Za-z0-9\p{L}\p{Nd}]([A-Za-z0-9\p{L}\p{M}\p{Nd}-]*[A-Za-z0-9\p{L}\p{M}\p{Nd}])?\.)+([A-Za-z\p{L}][A-Za-z\p{L}\p{M}]+|[Xx][Nn]--[A-Za-z0-9-]+[A-Za-z0-9])$"#

  /// The single validity rule, shared by `init?` and the form.
  public static func issue(message: String, email: String) -> Issue? {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .emptyMessage }
    if trimmed.count > maxMessageLength { return .messageTooLong }
    let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedEmail.isEmpty,
      trimmedEmail.range(of: emailPattern, options: .regularExpression) == nil
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

/// The unsent feedback text, kept on this Mac so closing the popover, the window or the app does
/// not lose it (founder, 2026-09-25). Cleared only once a report is handed to Sentry. Local
/// storage of the user's own words is inside the privacy boundary: nothing here leaves the Mac.
public struct FeedbackDraftStore: Sendable {
  static let messageKey = "feedback.draft.message"
  static let emailKey = "feedback.draft.email"

  private let defaults: @Sendable () -> UserDefaults

  public init() { self.defaults = { .standard } }

  /// For tests: a store over an isolated suite.
  init(defaults: @escaping @Sendable () -> UserDefaults) { self.defaults = defaults }

  public var message: String { defaults().string(forKey: Self.messageKey) ?? "" }
  public var email: String { defaults().string(forKey: Self.emailKey) ?? "" }

  /// Saves both fields; an empty field removes its key rather than storing "".
  public func save(message: String, email: String) {
    let store = defaults()
    for (key, value) in [(Self.messageKey, message), (Self.emailKey, email)] {
      if value.isEmpty { store.removeObject(forKey: key) } else { store.set(value, forKey: key) }
    }
  }

  public func clear() { save(message: "", email: "") }
}
