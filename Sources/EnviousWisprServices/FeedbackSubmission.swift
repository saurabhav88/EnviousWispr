import Foundation
import Observation

/// The one Send-in-progress state every opening of the feedback form shares (#3269).
///
/// A popover can close and reopen while a report is still saving. Each opening is a fresh view,
/// so a flag kept in the view would let the reopened form Send the same words again as a second
/// report (new id), during the save or after it. This owner outlives the view: while a save runs
/// no opening can submit, and when it finishes every other opening reloads the saved draft (cleared
/// if unchanged, or holding words typed meanwhile).
@MainActor
@Observable
public final class FeedbackSubmission {
  public static let shared: FeedbackSubmission = makeShared()

  private static func makeShared() -> FeedbackSubmission {
    FeedbackSubmission(
      store: FeedbackDraftStore(),
      save: { draft, diagnostics, helpOutcome in
        await FeedbackReporter.send(draft, diagnostics: diagnostics, helpOutcome: helpOutcome)
      })
  }

  /// What the form on screen shows when a save finishes.
  public struct FormState: Sendable {
    public let presentation: UUID
    public let message: String
    public let email: String
    public init(presentation: UUID, message: String, email: String) {
      self.presentation = presentation
      self.message = message
      self.email = email
    }
  }

  public typealias Save =
    @MainActor (FeedbackDraft, FeedbackDiagnosticsSnapshot?, FeedbackHelpOutcome?) async ->
      FeedbackReporter.Outcome

  /// True from Send until the save has an outcome and the draft is settled.
  public private(set) var isSaving = false
  /// Bumped once per finished save, so an opening that did not send can reconcile.
  public private(set) var completions = 0
  /// The opening whose Send is running or ran last.
  public private(set) var sender: UUID?

  public let store: FeedbackDraftStore
  private let save: Save

  public init(store: FeedbackDraftStore, save: @escaping Save) {
    self.store = store
    self.save = save
  }

  /// Saves one report. `current` is read when the save finishes: the opening on screen then and
  /// its words. Returns the outcome for the sending opening, or nil when that opening has closed
  /// (another opening reconciles through `completions`). Nil also when a save is already running.
  /// `helpOutcome` is frozen into the report as passed; nil when no help check ran (#3275).
  public func submit(
    _ draft: FeedbackDraft, diagnostics: FeedbackDiagnosticsSnapshot?,
    helpOutcome: FeedbackHelpOutcome? = nil,
    from presentation: UUID, sent: (message: String, email: String),
    current: @MainActor () -> FormState
  ) async -> FeedbackReporter.Outcome? {
    guard !isSaving else { return nil }
    isSaving = true
    sender = presentation
    let outcome = await save(draft, diagnostics, helpOutcome)
    let now = current()
    let saved: Bool
    if case .saved = outcome { saved = true } else { saved = false }
    let onScreen = store.settleAfterSave(
      saved: saved, isSendingFormOnScreen: now.presentation == presentation,
      form: (now.message, now.email), sent: sent)
    isSaving = false
    completions += 1
    return onScreen ? outcome : nil
  }

  /// The form's edit path: every keystroke of the message or email is saved to the draft at once,
  /// so a save finishing mid-edit settles against the words already typed.
  public func recordEdit(message: String, email: String) {
    store.save(message: message, email: email)
  }

  /// For an opening that did not send: the words to show once a save finished, from the saved
  /// draft. Nil for the sending opening, which already has its outcome.
  public func reconciledDraft(for presentation: UUID) -> (message: String, email: String)? {
    guard !isSaving, sender != presentation else { return nil }
    return (store.message, store.email)
  }
}
