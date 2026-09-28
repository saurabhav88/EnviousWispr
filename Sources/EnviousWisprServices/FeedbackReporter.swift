import Foundation

/// One user-written feedback report (#3153): the message, and an email only if they want a reply.
///
/// `init?` is the only way to get one, so a draft that exists is always sendable.
public struct FeedbackDraft: Equatable, Sendable {
  /// Longest message accepted. Generous for a pasted log or a long description; Live UAT must
  /// read a 3,900-character report back from Sentry intact.
  public static let maxMessageLength = 4000
  /// Sentry's own feedback message limit, in Unicode code points.
  static let maxMessageCodePoints = 4096

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
    // Sentry's feedback limit counts Unicode code points (4,096); the form's counts characters.
    // An emoji-heavy message can pass one and not the other, so both apply and nothing is cut.
    if trimmed.count > maxMessageLength || trimmed.unicodeScalars.count > maxMessageCodePoints {
      return .messageTooLong
    }
    let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedEmail.isEmpty,
      trimmedEmail.range(of: emailPattern, options: .regularExpression) == nil
    {
      return .invalidEmail
    }
    return nil
  }
}

/// Submits a bug report (#3153) into the app-owned outbox (#3269), which delivers it to Sentry
/// on its own, independent of both privacy switches (founder, 2026-09-28: bug reports are their
/// own lane). The report is frozen here: the message, the optional email, basic app and macOS
/// versions, and the diagnostics file only when the user ticked "Include diagnostics", exactly as
/// previewed. It carries no Sentry scope: no user id, tags, breadcrumbs or install join outside
/// that file.
public enum FeedbackReporter {
  public enum Outcome: Equatable, Sendable {
    /// Saved on this Mac for delivery. `offline` is true when there was no network at Send.
    /// Not a delivery receipt: the outbox sends when it can and retries until Sentry accepts.
    case saved(offline: Bool)
    /// Too many reports are already waiting; nothing was saved and the draft is kept.
    case full
    /// The report could not be saved; nothing was saved and the draft is kept.
    case unavailable
  }

  /// Saves the report. `diagnostics` is the file the user previewed and chose to include; nil
  /// saves the message alone.
  public static func send(
    _ draft: FeedbackDraft, diagnostics: FeedbackDiagnosticsSnapshot? = nil
  ) async -> Outcome {
    await send(draft, diagnostics: diagnostics, outbox: .shared, now: Date(), id: UUID())
  }

  static func send(
    _ draft: FeedbackDraft, diagnostics: FeedbackDiagnosticsSnapshot?, outbox: FeedbackOutbox,
    now: Date, id: UUID, context: FeedbackRecord.Context = .current
  ) async -> Outcome {
    let record = FeedbackRecord(
      id: id, submittedAt: now, message: draft.message, email: draft.email,
      attachment: diagnostics?.data, context: context, attempts: 0, nextAttemptAt: nil,
      state: .pending, rejectedStatus: nil)
    switch await outbox.enqueue(record) {
    case .saved(let offline): return .saved(offline: offline)
    case .full: return .full
    case .unavailable: return .unavailable
    }
  }

  /// Launch: start delivering saved reports and watching the network. Whatever the privacy
  /// switches say: bug reports are their own lane.
  public static func startDelivery() async {
    await FeedbackOutbox.shared.start()
  }

  /// Quit: stop the scheduled retry and the network watcher. Saved reports stay on disk.
  public static func stopDelivery() async {
    await FeedbackOutbox.shared.stop()
  }

  /// Whether a saved report stays unsent on this Mac without help: refused by Sentry, or
  /// waiting behind a configuration failure.
  public static func hasUndeliverableReports() async -> Bool {
    await FeedbackOutbox.shared.hasUndeliverableReports()
  }
}

extension FeedbackRecord.Context {
  /// This build's versions at the moment of Send.
  static var current: Self {
    let bundle = Bundle.main
    let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    let os = ProcessInfo.processInfo.operatingSystemVersion
    return Self(
      appVersion: version ?? "unknown", appBuild: build ?? "unknown",
      release: "com.enviouswispr.app@\(version ?? "unknown")",
      environment: ObservabilityBootstrap.currentEnvironment,
      osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
      osBuild: Self.osBuild)
  }

  private static var osBuild: String {
    var size = 0
    sysctlbyname("kern.osversion", nil, &size, nil, 0)
    var buffer = [CChar](repeating: 0, count: max(size, 1))
    guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return "unknown" }
    return String(cString: buffer)
  }
}

/// The unsent feedback text, kept on this Mac so closing the popover, the window or the app does
/// not lose it (founder, 2026-09-25). Cleared only once a report is saved to the outbox. Local
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

  /// Clears only when the saved draft still holds what was sent, so a later edit (in this form
  /// or one reopened while the report was saving) is kept. Returns whether it cleared.
  @discardableResult
  public func clear(ifStill message: String, email: String) -> Bool {
    guard self.message == message, self.email == email else { return false }
    clear()
    return true
  }
}
