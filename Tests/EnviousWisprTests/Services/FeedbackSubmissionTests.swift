import Foundation
import Testing

@testable import EnviousWisprServices

/// #3269: a report still saving when the popover closes and reopens can never be sent a second
/// time from the reopened form, and the user's words are never lost. The save is held open by a
/// continuation so each step happens at a known point.
@Suite("Feedback submission across popover openings (#3269)", .tags(.productOutcome))
@MainActor
struct FeedbackSubmissionTests {

  /// Holds the save until `finish` is called with an outcome.
  @MainActor
  final class HeldSave {
    private var continuation: CheckedContinuation<FeedbackReporter.Outcome, Never>?
    private(set) var calls = 0
    var isHeld: Bool { continuation != nil }

    func save(_: FeedbackDraft, _: FeedbackDiagnosticsSnapshot?) async -> FeedbackReporter.Outcome {
      calls += 1
      return await withCheckedContinuation { continuation = $0 }
    }

    func finish(_ outcome: FeedbackReporter.Outcome) {
      continuation?.resume(returning: outcome)
      continuation = nil
    }
  }

  /// The words and opening on screen, as the view would report them.
  final class Screen {
    var presentation = UUID()
    var message = ""
    var email = ""
    var state: FeedbackSubmission.FormState {
      .init(presentation: presentation, message: message, email: email)
    }
  }

  static func makeStore() -> (FeedbackDraftStore, String) {
    let suite = "FeedbackSubmissionTests.\(UUID().uuidString)"
    return (FeedbackDraftStore(defaults: { UserDefaults(suiteName: suite)! }), suite)
  }

  /// Sends from opening A, then closes and reopens (opening B) while the save is held.
  static func sendThenReopen(
    _ submission: FeedbackSubmission, _ held: HeldSave, _ screen: Screen, words: String
  ) async -> (sender: UUID, task: Task<FeedbackReporter.Outcome?, Never>) {
    let draft = FeedbackDraft(message: words, email: "")!
    let sender = screen.presentation
    let task = Task { @MainActor in
      await submission.submit(
        draft, diagnostics: nil, from: sender, sent: (words, ""), current: { screen.state })
    }
    while !held.isHeld { await Task.yield() }
    screen.presentation = UUID()  // closed and reopened: a new opening
    return (sender, task)
  }

  @Test("Saved while the form was reopened: the reopened form cannot send the same words again")
  func unchangedDraftCannotBeResent() async throws {
    let (store, suite) = Self.makeStore()
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let held = HeldSave()
    let submission = FeedbackSubmission(store: store, save: held.save)
    let screen = Screen()
    store.save(message: "it pasted twice", email: "")
    screen.message = "it pasted twice"

    let (sender, task) = await Self.sendThenReopen(
      submission, held, screen, words: "it pasted twice")
    // The reopened form loaded the saved draft, but a save is running: no second submit.
    #expect(submission.isSaving == true)
    let second = await submission.submit(
      FeedbackDraft(message: "it pasted twice", email: "")!, diagnostics: nil,
      from: screen.presentation, sent: ("it pasted twice", ""), current: { screen.state })
    #expect(second == nil)
    #expect(held.calls == 1)

    held.finish(.saved(offline: false))
    #expect(await task.value == nil)  // the sending opening closed
    #expect(submission.isSaving == false)
    #expect(submission.completions == 1)
    #expect(submission.sender == sender)
    // The reopened form reconciles to the cleared draft: nothing left to send twice.
    let words = try #require(submission.reconciledDraft(for: screen.presentation))
    #expect(words.message == "")
    #expect(store.message == "")
    #expect(held.calls == 1)
  }

  @Test("Words typed in the reopened form while saving are kept")
  func newerEditsKept() async throws {
    let (store, suite) = Self.makeStore()
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let held = HeldSave()
    let submission = FeedbackSubmission(store: store, save: held.save)
    let screen = Screen()
    store.save(message: "first report", email: "")

    let (_, task) = await Self.sendThenReopen(submission, held, screen, words: "first report")
    // The reopened form's production edit path, then the save completes at once.
    screen.message = "a second thought"
    submission.recordEdit(message: "a second thought", email: "")

    held.finish(.saved(offline: false))
    _ = await task.value
    let words = try #require(submission.reconciledDraft(for: screen.presentation))
    #expect(words.message == "a second thought")
    #expect(store.message == "a second thought")
  }

  @Test("An email typed in the reopened form while saving is kept")
  func newerEmailKept() async throws {
    let (store, suite) = Self.makeStore()
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let held = HeldSave()
    let submission = FeedbackSubmission(store: store, save: held.save)
    let screen = Screen()
    store.save(message: "first report", email: "")

    let (_, task) = await Self.sendThenReopen(submission, held, screen, words: "first report")
    screen.message = "first report"
    screen.email = "me@example.com"
    submission.recordEdit(message: "first report", email: "me@example.com")

    held.finish(.saved(offline: false))
    _ = await task.value
    let words = try #require(submission.reconciledDraft(for: screen.presentation))
    #expect(words.message == "first report")
    #expect(words.email == "me@example.com")
  }

  @Test("A failed save keeps the words for the reopened form")
  func failedSaveKeepsWords() async throws {
    let (store, suite) = Self.makeStore()
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let held = HeldSave()
    let submission = FeedbackSubmission(store: store, save: held.save)
    let screen = Screen()
    store.save(message: "please keep me", email: "a@b.co")

    let (_, task) = await Self.sendThenReopen(submission, held, screen, words: "please keep me")
    held.finish(.unavailable)
    #expect(await task.value == nil)
    let words = try #require(submission.reconciledDraft(for: screen.presentation))
    #expect(words.message == "please keep me")
    #expect(words.email == "a@b.co")
  }

  @Test("The opening that sent and stayed open gets its outcome and no reconcile")
  func senderGetsOutcome() async throws {
    let (store, suite) = Self.makeStore()
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let held = HeldSave()
    let submission = FeedbackSubmission(store: store, save: held.save)
    let screen = Screen()
    store.save(message: "hello", email: "")
    screen.message = "hello"
    let sender = screen.presentation
    let task = Task { @MainActor in
      await submission.submit(
        FeedbackDraft(message: "hello", email: "")!, diagnostics: nil, from: sender,
        sent: ("hello", ""), current: { screen.state })
    }
    while !held.isHeld { await Task.yield() }
    held.finish(.saved(offline: true))
    #expect(await task.value == .saved(offline: true))
    #expect(submission.reconciledDraft(for: sender) == nil)
    #expect(store.message == "")
  }
}
