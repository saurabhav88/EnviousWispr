import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation

/// Navigation state and workflow for the Custom Words import sheet
/// (#1657 PR-F1 shell, #1669 PR-F2c workflow; epic #1619).
///
/// Owns which screen the sheet shows, which method the user picked, the review
/// rows and their decisions, and the load → compare → review → commit
/// sequence. Real input sources arrive later (P1 paste, U1 upload, 4a smart
/// import); PR-P1 also inserts its enrichment stage between compare and
/// review by editing this model directly — no seam is pre-built for it here.
///
/// Invariant: `selectedMethod` is non-nil exactly while a method's flow is
/// active; returning to `.methodPicker` (via `goBack()` or `reset()`) clears it.
///
/// Cancellation is signal-based, never clock-based: every asynchronous stage
/// carries the generation it started in, and only the current generation may
/// publish. Dismiss, cancel, and a fresh comparison run each advance it, so a
/// late completion is discarded rather than applied to a screen that moved on.
@MainActor @Observable
final class CustomWordsImportFlowModel {
  /// The two collaborators the workflow needs, injected as narrow closures
  /// rather than a coordinator reference so tests drive the flow without
  /// constructing persistence (`di-narrow-homes`).
  struct Dependencies {
    /// The live word list, read fresh at each comparison so a stale-triggered
    /// rebuild compares against what is actually on disk now.
    var existingWords: @MainActor () -> [CustomWord]
    var commit:
      @MainActor (CustomWordsImportCommitPlan) ->
        CustomWordsCoordinator.CustomWordsImportCommitOutcome
    /// Classification, injected so the fuzzy policy this flow passes is
    /// observable in a test rather than sealed inside the model.
    var compare:
      @Sendable ([CustomWordsImportCandidate], [CustomWord], CustomWordsImportFuzzyPolicy)
        async throws -> [CustomWordsImportComparison]

    /// Production wiring: one compare engine for the sheet's lifetime.
    static func live(
      existingWords: @escaping @MainActor () -> [CustomWord],
      commit: @escaping @MainActor (CustomWordsImportCommitPlan) ->
        CustomWordsCoordinator.CustomWordsImportCommitOutcome
    ) -> Dependencies {
      let engine = CustomWordsImportCompareEngine()
      return Dependencies(
        existingWords: existingWords,
        commit: commit,
        compare: { candidates, existing, policy in
          try await engine.compare(
            candidates: candidates, against: existing, fuzzyPolicy: policy)
        }
      )
    }
  }

  enum Step: Equatable {
    case methodPicker
    case paste
    case upload
    case smartImportAppPicker
    case review
    case working(Work)
    case result(Result)
  }

  enum Work: Equatable {
    case loadingCandidates
    case comparing
    case committing
  }

  enum Result: Equatable {
    case completed(added: Int, replaced: Int)
    /// The source produced no candidates at all.
    case nothingFound
    /// Candidates were found and reviewed, but every one was skipped. Distinct
    /// from `.nothingFound` because "we found nothing" and "you kept nothing"
    /// are different things to tell someone.
    case nothingApproved
    case failed(message: String)
  }

  enum Method: String, CaseIterable, Identifiable, Sendable {
    case paste
    case upload
    case smartImport

    var id: Self { self }

    /// The input screen this method starts on.
    var inputStep: Step {
      switch self {
      case .paste: return .paste
      case .upload: return .upload
      case .smartImport: return .smartImportAppPicker
      }
    }
  }

  private(set) var step: Step = .methodPicker
  private(set) var selectedMethod: Method?
  private(set) var rows: [CustomWordsImportReviewRow] = []
  /// Set when a commit failed because the word list changed underneath an open
  /// review; cleared as soon as the user acts again.
  private(set) var staleNotice: String?
  /// Surfaced on the result screen when PR-F2b dropped colliding aliases.
  private(set) var droppedAliasCollisionCount = 0
  /// What the user typed on the Paste screen (#1681).
  ///
  /// Lives here rather than in the screen's own `@State` because the sheet
  /// rebuilds each screen on every step change: Back from Review would
  /// otherwise recreate the editor empty and silently discard a list the user
  /// may have spent real effort assembling. Back exists precisely so they can
  /// edit it, so the text has to outlive the screen.
  var pasteDraft = ""

  private let dependencies: Dependencies
  /// The library the open review was built against — PR-F2b re-validates it at
  /// commit time and refuses the write if it no longer matches.
  private var baseline = CustomWordsImportLibrarySnapshot(words: [])
  private var candidates: [CustomWordsImportCandidate] = []
  private var generation = 0
  private var activeTask: Task<Void, Never>?

  init(dependencies: Dependencies) {
    self.dependencies = dependencies
  }

  /// True exactly where `goBack()` does something — the three input screens
  /// and review. The sheet's Back button reads this instead of keeping its
  /// own copy of the per-screen table.
  var canGoBack: Bool {
    switch step {
    case .paste, .upload, .smartImportAppPicker, .review: return true
    case .methodPicker, .working, .result: return false
    }
  }

  /// The rows the user has chosen to add. The screen reads this for its
  /// summary line and to decide whether Confirm does anything.
  var approvedRows: [CustomWordsImportReviewRow] {
    rows.filter { $0.decision == .add }
  }

  // MARK: - Navigation (PR-F1)

  /// Method picker → the picked method's input screen. Ignored anywhere else:
  /// picking a method is only meaningful on the picker.
  func select(_ method: Method) {
    guard step == .methodPicker else { return }
    selectedMethod = method
    step = method.inputStep
  }

  /// An input screen or an in-flight working step → review. Ignored until a
  /// method is selected, so `.review` can always answer "back to where?".
  func showReview() {
    guard selectedMethod != nil else { return }
    switch step {
    case .paste, .upload, .smartImportAppPicker, .working:
      step = .review
    case .methodPicker, .review, .result:
      break
    }
  }

  /// An input screen, review, or another working phase → `.working(work)`.
  /// Ignored on the picker (no method context) and on a result (terminal).
  func beginWork(_ work: Work) {
    switch step {
    case .paste, .upload, .smartImportAppPicker, .review, .working:
      step = .working(work)
    case .methodPicker, .result:
      break
    }
  }

  /// A working step → its terminal result. Results only ever come out of
  /// work, so this is ignored on every other screen.
  func showResult(_ result: Result) {
    guard case .working = step else { return }
    step = .result(result)
  }

  /// Explicit per-screen table (adopted plan, PR-F1):
  /// input screens → `.methodPicker`; `.review` → the selected method's input
  /// screen; `.working` → no-op (Back is disabled); `.result` → no-op (no
  /// Back, Done dismisses); `.methodPicker` → no-op.
  ///
  /// Leaving review abandons the comparison: the decisions on screen belong to
  /// a run the user just walked away from, and silently reusing them against a
  /// later run is exactly the stale-decision replay PR-F2b refuses.
  func goBack() {
    switch step {
    case .paste, .upload, .smartImportAppPicker:
      selectedMethod = nil
      step = .methodPicker
    case .review:
      abandonWork()
      rows = []
      staleNotice = nil
      // `showReview()` guarantees a selected method, but stay deterministic
      // rather than trap if a future caller breaks that assumption.
      step = selectedMethod?.inputStep ?? .methodPicker
    case .methodPicker, .working, .result:
      break
    }
  }

  /// Fresh model state: back to the picker with no method selected.
  func reset() {
    abandonWork()
    rows = []
    staleNotice = nil
    droppedAliasCollisionCount = 0
    pasteDraft = ""
    selectedMethod = nil
    step = .methodPicker
  }

  /// Sheet dismissal. Nothing is written on the way out; any in-flight stage
  /// is cancelled and can no longer publish. Clears the draft so a confirmed
  /// discard is final and idempotent, whether this runs from an explicit
  /// discard action or from `.onDisappear`'s unconditional cleanup.
  func cancel() {
    abandonWork()
    pasteDraft = ""
  }

  /// True iff closing the sheet right now, by any path, would silently throw
  /// away words the user already typed (#1700). Excludes `.working(.committing)`
  /// — an active write in flight is not "a draft." Includes `.result(.nothingFound)`
  /// and `.result(.failed)`, since neither committed anything and the pasted
  /// text is still sitting, uncommitted, in `pasteDraft`.
  ///
  /// `.result(.completed)`/`.result(.nothingApproved)` are only genuinely
  /// nothing-to-lose when THIS result's own method was paste — that's the
  /// only case where `pasteDraft`'s content is guaranteed to be exactly what
  /// was just committed. If the user typed a paste draft, went Back, and
  /// completed a DIFFERENT method's import instead, `pasteDraft` still holds
  /// that abandoned, never-committed text (Codex code-diff review, #1700).
  var hasDiscardableDraft: Bool {
    switch step {
    case .working(.committing):
      return false
    case .result(.completed), .result(.nothingApproved):
      guard selectedMethod != .paste else { return false }
      return !pasteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .methodPicker, .paste, .upload, .smartImportAppPicker, .review,
      .working(.loadingCandidates), .working(.comparing),
      .result(.nothingFound), .result(.failed):
      return !pasteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  /// "Keep editing" from a confirmation dialog (#1700). No `.result` case has
  /// a Back button, so any terminal result `hasDiscardableDraft` judged worth
  /// protecting — `.nothingFound`/`.failed` always, or `.completed`/
  /// `.nothingApproved` when they're guarding an abandoned draft from a
  /// different, already-finished method (Codex code-diff review) — actively
  /// returns to Paste with the draft intact. Everywhere else there is nothing
  /// to do: the user is already looking at their editable draft, or the guard
  /// above already ruled out there being anything to protect.
  func keepEditingDiscardableDraft() {
    guard hasDiscardableDraft else { return }
    switch step {
    case .result:
      abandonWork()
      rows = []
      staleNotice = nil
      droppedAliasCollisionCount = 0
      selectedMethod = .paste
      step = .paste
    case .methodPicker, .paste, .upload, .smartImportAppPicker, .review, .working:
      break
    }
  }

  // MARK: - Workflow (PR-F2c)

  /// Run a source end to end: load its candidates, compare them against the
  /// current word list, and land on Review.
  func begin(with source: any CustomWordsImportSource) {
    guard selectedMethod != nil else { return }
    let runGeneration = abandonWork()
    staleNotice = nil
    droppedAliasCollisionCount = 0
    rows = []
    beginWork(.loadingCandidates)

    activeTask = Task { [weak self] in
      await self?.load(from: source, generation: runGeneration)
    }
  }

  /// Apply the current decisions in one atomic write.
  ///
  /// The plan is additions-only by construction: `.add` is reachable for
  /// `.new` rows alone, so no decision in v1 can produce a replacement.
  func confirm() {
    guard step == .review else { return }
    let additions = approvedRows.map(\.comparison.candidate)
    guard !additions.isEmpty else {
      beginWork(.committing)
      showResult(.nothingApproved)
      return
    }

    staleNotice = nil
    beginWork(.committing)
    let plan = CustomWordsImportCommitPlan(
      baseline: baseline, additions: additions, replacements: [])

    switch dependencies.commit(plan) {
    case .committed(let receipt):
      droppedAliasCollisionCount = receipt.droppedAliasCollisions.count
      showResult(
        .completed(added: receipt.addedIDs.count, replaced: receipt.replacedIDs.count))
    case .stale:
      recompareAfterStaleCommit()
    case .failed(let message):
      showResult(.failed(message: message))
    }
  }

  func setDecision(_ decision: CustomWordsImportDecision, forRow id: UUID) {
    guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
    // The screen only renders allowed decisions, but the model is the
    // authority: an action persistence would refuse must not become state.
    guard rows[index].allowedDecisions.contains(decision) else { return }
    rows[index].decision = decision
  }

  // MARK: - Workflow internals

  private func load(from source: any CustomWordsImportSource, generation: Int) async {
    do {
      let batch = try await source.loadCandidates()
      guard isCurrent(generation) else { return }
      guard !batch.candidates.isEmpty else {
        showResult(.nothingFound)
        return
      }
      candidates = batch.candidates
      beginWork(.comparing)
      await compare(candidates: batch.candidates, generation: generation)
    } catch is CancellationError {
      return
    } catch {
      guard isCurrent(generation) else { return }
      showResult(.failed(message: error.localizedDescription))
    }
  }

  private func compare(
    candidates: [CustomWordsImportCandidate], generation: Int
  ) async {
    let existing = dependencies.existingWords()
    do {
      // Fuzzy matching is OFF in v1 (founder, 2026-07-18). With Replace gone a
      // similarity match can no longer offer anything — it can only withhold
      // Add — so a false positive would silently refuse a legitimately
      // different word with no recourse. The engine keeps the capability; this
      // caller declines to arm it.
      let comparisons = try await dependencies.compare(candidates, existing, .disabled)
      guard isCurrent(generation) else { return }
      baseline = CustomWordsImportLibrarySnapshot(words: existing)
      rows = CustomWordsImportReviewRow.rows(from: comparisons, existingWords: existing)
      showReview()
    } catch is CancellationError {
      return
    } catch {
      guard isCurrent(generation) else { return }
      showResult(.failed(message: error.localizedDescription))
    }
  }

  /// The word list changed while Review was open. Nothing was written. Rebuild
  /// the comparison against the current list and return to Review with every
  /// decision reset — old decisions belong to matches that may no longer exist,
  /// and replaying them is precisely what PR-F2b's staleness check prevents.
  private func recompareAfterStaleCommit() {
    let runGeneration = advanceGeneration()
    let pending = candidates
    staleNotice =
      "Your word list changed while you were reviewing. "
      + "Nothing was imported — here are the updated matches."
    beginWork(.comparing)

    activeTask = Task { [weak self] in
      await self?.compare(candidates: pending, generation: runGeneration)
    }
  }

  /// Cancel any in-flight stage and make its completion unpublishable.
  /// Returns the new generation so a caller starting fresh work can carry it.
  @discardableResult
  private func abandonWork() -> Int {
    activeTask?.cancel()
    activeTask = nil
    return advanceGeneration()
  }

  private func advanceGeneration() -> Int {
    generation += 1
    return generation
  }

  private func isCurrent(_ candidateGeneration: Int) -> Bool {
    candidateGeneration == generation
  }
}
