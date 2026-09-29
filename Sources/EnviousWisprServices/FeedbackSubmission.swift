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
  /// The in-app help check (#3275), when this Mac runs one; nil sends directly.
  public var helpCheck: HelpCheck?

  public init(store: FeedbackDraftStore, save: @escaping Save, helpCheck: HelpCheck? = nil) {
    self.store = store
    self.save = save
    self.helpCheck = helpCheck
  }

  // MARK: - Help check (#3275)

  /// Where the help check stands. Shared by every opening, like `isSaving`.
  public enum HelpPhase: Equatable, Sendable {
    case idle
    /// Send was pressed and the check is running; nothing is sent yet.
    case checking
    /// Cards are on offer; the report waits for the user.
    case suggestions(HelpCheckSuggestions)
  }

  public private(set) var helpPhase: HelpPhase = .idle
  /// The check the cards on screen belong to. An action from an older check is ignored.
  public var helpGeneration: UUID? { frozen?.generation }

  /// What Send did.
  public enum SendStep: Equatable, Sendable {
    /// The report was saved (or not); the outcome, or nil when the sending opening closed.
    /// `splitFailure` is why the on-device split was skipped, when it was (for counting).
    case sent(FeedbackReporter.Outcome?, splitFailure: FeedbackHelpOutcome.FailureReason? = nil)
    /// Cards are on offer; call `finishSuggestions` or `endWithAllSolved`.
    case suggestions(HelpCheckSuggestions)
    /// A check or save is already running; nothing happened.
    case busy
  }

  /// The report frozen at Send: the words, email and diagnostics exactly as sent. Later edits go
  /// to the draft through `recordEdit` and never reach this report.
  private struct Frozen {
    let draft: FeedbackDraft
    let diagnostics: FeedbackDiagnosticsSnapshot?
    let sent: (message: String, email: String)
    let generation: UUID
  }
  private var frozen: Frozen?

  /// Send with the help check when one is set, else save directly. A check that fails, times out
  /// or has nothing to show saves the report as written.
  public func send(
    _ draft: FeedbackDraft, diagnostics: FeedbackDiagnosticsSnapshot?,
    from presentation: UUID, sent: (message: String, email: String),
    current: @MainActor () -> FormState
  ) async -> SendStep {
    guard !isSaving, helpPhase == .idle else { return .busy }
    guard let helpCheck else {
      return .sent(
        await submit(draft, diagnostics: diagnostics, from: presentation, sent: sent, current: current))
    }
    let generation = UUID()
    frozen = Frozen(draft: draft, diagnostics: diagnostics, sent: sent, generation: generation)
    sender = presentation
    helpPhase = .checking
    let conclusion = await helpCheck.run(draft.message)
    // Only this generation's result may move the state; anything else is stale.
    guard let held = frozen, held.generation == generation, helpPhase == .checking else {
      return .busy
    }
    switch conclusion {
    case .suggestions(let suggestions):
      helpPhase = .suggestions(suggestions)
      return .suggestions(suggestions)
    case .send(let outcome, let splitFailure):
      helpPhase = .idle
      frozen = nil
      return .sent(
        await saveFrozen(held, outcome: outcome, from: presentation, current: current),
        splitFailure: splitFailure)
    }
  }

  /// Whether an action comes from the cards now on screen: this check, from the opening that is
  /// showing them. A press from an older check or a closed opening changes nothing.
  private func isCurrent(generation: UUID, from presentation: UUID, current: FormState) -> Bool {
    frozen?.generation == generation && current.presentation == presentation
  }

  /// The user pressed Send on the cards: `solved` holds the concerns they marked solved (the rest
  /// are still happening), and the report is saved as frozen at Send.
  public func finishSuggestions(
    solved: Set<String>, generation: UUID, from presentation: UUID,
    current: @MainActor () -> FormState
  ) async -> FeedbackReporter.Outcome? {
    guard case .suggestions(let suggestions) = helpPhase, let held = frozen,
      isCurrent(generation: generation, from: presentation, current: current())
    else { return nil }
    helpPhase = .idle
    frozen = nil
    return await saveFrozen(
      held, outcome: suggestions.outcome(solved: solved), from: presentation,
      current: current)
  }

  /// The user closed the cards without sending: nothing is saved and the draft stays as it is, to
  /// edit or send again. Returns whether the cards were closed.
  @discardableResult
  public func dismissSuggestions(
    generation: UUID, from presentation: UUID, current: @MainActor () -> FormState
  ) -> Bool {
    guard case .suggestions = helpPhase,
      isCurrent(generation: generation, from: presentation, current: current())
    else { return false }
    helpPhase = .idle
    frozen = nil
    return true
  }

  /// The user confirmed every concern solved: nothing is sent and the draft is settled as if
  /// saved. Refused (false) unless the check allows it, `confirmed` names every concern, each can
  /// be marked solved, and `generation` is the current check's.
  @discardableResult
  public func endWithAllSolved(
    confirmed: Set<String>, generation: UUID, from presentation: UUID,
    current: @MainActor () -> FormState
  ) -> Bool {
    let now = current()
    guard case .suggestions(let suggestions) = helpPhase, suggestions.suppressionAllowed,
      let held = frozen, isCurrent(generation: generation, from: presentation, current: now),
      confirmed == suggestions.issueIDs, confirmed.allSatisfy(suggestions.canMarkSolved)
    else { return false }
    helpPhase = .idle
    frozen = nil
    store.settleAfterSave(
      saved: true, isSendingFormOnScreen: now.presentation == presentation,
      form: (now.message, now.email), sent: held.sent)
    completions += 1
    return true
  }

  private func saveFrozen(
    _ held: Frozen, outcome: FeedbackHelpOutcome, from presentation: UUID,
    current: @MainActor () -> FormState
  ) async -> FeedbackReporter.Outcome? {
    await submit(
      held.draft, diagnostics: held.diagnostics, helpOutcome: outcome, from: presentation,
      sent: held.sent, current: current)
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
    guard !isSaving, helpPhase == .idle else { return nil }
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
