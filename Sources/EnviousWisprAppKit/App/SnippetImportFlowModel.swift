import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation

/// Navigation state and workflow for the Snippet Import sheet (#2997).
///
/// Drives one import from source choice to committed result: which screen the sheet shows,
/// the review rows and their decisions, and the load → compare → review → commit sequence
/// shared by Paste and Open a file (and, from PR-B, another app). A snippet-shaped twin of
/// `CustomWordsImportFlowModel`, kept separate on purpose: it needs none of the word
/// features (aliases, enrichment, fuzzy matching, Replace) and has its own comparison key.
///
/// Invariant: `selectedMethod` is non-nil exactly while a method's flow is active; returning
/// to `.methodPicker` (via `goBack()` or `reset()`) clears it.
///
/// Cancellation is signal-based, never clock-based: every asynchronous stage carries the
/// generation it started in, and only the current generation may publish. Dismiss, cancel,
/// and a fresh comparison run each advance it, so a late completion is discarded rather than
/// applied to a screen that moved on. Once a commit has started nothing rolls it back; the
/// generation only decides whether the RESULT is shown, and the attempt is still reported.
@MainActor @Observable
final class SnippetImportFlowModel {
  /// The collaborators the workflow needs, injected as narrow closures rather than a
  /// coordinator reference so tests drive the flow without constructing persistence.
  struct Dependencies {
    /// The live list, read FROM DISK at each comparison so a stale-triggered rebuild sees
    /// what another process wrote (`SnippetsCoordinator.refreshFromDisk`).
    var existingSnippets: @MainActor () -> [Snippet]
    var commit:
      @MainActor (SnippetsCoordinator.SnippetImportCommitPlan) async ->
        SnippetsCoordinator.SnippetImportCommitOutcome
    /// One row per attempt (plan §3d B). The reporter latches per attempt id.
    var report: @MainActor (UUID, SnippetImportAttemptReport) -> Void
    /// The one app-owned Sentry shape (plan §3d C): approved count, baseline count.
    var fileReviewCommitMismatch: @MainActor (Int, Int) -> Void

    /// Production wiring: one reporter for the sheet's lifetime.
    @MainActor static func live(
      existingSnippets: @escaping @MainActor () -> [Snippet],
      commit: @escaping @MainActor (SnippetsCoordinator.SnippetImportCommitPlan) async ->
        SnippetsCoordinator.SnippetImportCommitOutcome
    ) -> Dependencies {
      let reporter = SnippetImportReporter.live()
      return Dependencies(
        existingSnippets: existingSnippets,
        commit: commit,
        report: { attempt, report in reporter.report(attempt: attempt, report) },
        fileReviewCommitMismatch: { approved, baseline in
          reporter.fileReviewCommitMismatch(approved: approved, baseline: baseline)
        })
    }
  }

  enum Step: Equatable {
    case methodPicker
    case paste
    case file
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
    case completed(added: Int)
    /// The source produced no candidates at all, and had nothing to refuse.
    case nothingFound
    /// The source held entries and every one was deliberately refused (a rival app's
    /// disabled rows; a file whose every line lacked a separator).
    case nothingCompatible(found: Int)
    /// Candidates were found and reviewed, and every one was skipped.
    case nothingApproved
    case failed(message: String)
  }

  enum Method: String, CaseIterable, Identifiable, Sendable {
    case paste
    case file

    var id: Self { self }

    var inputStep: Step {
      switch self {
      case .paste: return .paste
      case .file: return .file
      }
    }
  }

  private(set) var step: Step = .methodPicker
  private(set) var selectedMethod: Method?
  private(set) var rows: [SnippetImportReviewRow] = []
  /// The source's count notices, shown beside the rows that did come across.
  private(set) var notices: [SnippetImportNotice] = []
  /// Set when a commit was refused because the list changed underneath an open review;
  /// cleared as soon as the user acts again.
  private(set) var staleNotice: String?
  /// What the user typed on the Paste screen. Lives here rather than in the screen's own
  /// state because the sheet rebuilds each screen on every step change: Back from Review
  /// would otherwise recreate the editor empty.
  var pasteDraft = ""
  /// The "Read as" choice for an ambiguous paste (plan §3.2). Survives Back for the same
  /// reason as the draft.
  var pasteFormat: SnippetPasteFormat = .auto

  /// The immutable facts of one attempt, captured when it starts and carried through every
  /// await, so a superseded or abandoned run can never report under a later run's identity.
  private struct Attempt {
    let id: UUID
    let source: SnippetImportTelemetrySource
  }

  private let dependencies: Dependencies
  /// The list the open review was built against; the store refuses the write if disk no
  /// longer matches it.
  private var baseline: [Snippet] = []
  private var candidates: [SnippetImportCandidate] = []
  private var excludedForTelemetry = 0
  /// The attempt a report belongs to: minted per `begin`, and again per recompare after a
  /// stale refusal, so a reconfirmation is its own row.
  private var attempt = Attempt(id: UUID(), source: .paste)
  private var generation = 0
  private var activeTask: Task<Void, Never>?

  init(dependencies: Dependencies) {
    self.dependencies = dependencies
  }

  /// True exactly where `goBack()` does something: the input screens and review.
  var canGoBack: Bool {
    switch step {
    case .paste, .file, .review: return true
    case .methodPicker, .working, .result: return false
    }
  }

  var approvedRows: [SnippetImportReviewRow] { rows.filter { $0.decision == .add } }

  // MARK: - Navigation

  func select(_ method: Method) {
    guard step == .methodPicker else { return }
    selectedMethod = method
    step = method.inputStep
  }

  /// An input screen or an in-flight working step → review. Ignored until a method is
  /// selected, so `.review` can always answer "back to where?".
  func showReview() {
    guard selectedMethod != nil else { return }
    switch step {
    case .paste, .file, .working:
      step = .review
    case .methodPicker, .review, .result:
      break
    }
  }

  func beginWork(_ work: Work) {
    switch step {
    case .paste, .file, .review, .working:
      step = .working(work)
    case .methodPicker, .result:
      break
    }
  }

  /// A working step → its terminal result. Results only ever come out of work.
  func showResult(_ result: Result) {
    guard case .working = step else { return }
    step = .result(result)
  }

  /// Input screens → the picker; review → the selected method's input screen; working and
  /// result → no-op. Leaving review abandons the comparison: the decisions on screen belong
  /// to a run the user just walked away from.
  func goBack() {
    switch step {
    case .paste, .file:
      selectedMethod = nil
      step = .methodPicker
    case .review:
      abandonWork()
      rows = []
      notices = []
      staleNotice = nil
      step = selectedMethod?.inputStep ?? .methodPicker
    case .methodPicker, .working, .result:
      break
    }
  }

  func reset() {
    abandonWork()
    clearRun()
    pasteDraft = ""
    pasteFormat = .auto
    selectedMethod = nil
    step = .methodPicker
  }

  /// Sheet dismissal. Nothing is written on the way out; an in-flight load or comparison is
  /// cancelled and can no longer publish. A commit already started still completes and is
  /// still reported; only its result screen is dropped.
  func cancel() {
    abandonWork()
    // The sheet is on its way out: the run is forgotten and the model returns to the picker,
    // so a `confirm()` that lands after this has no review to act on, reports nothing, and
    // shows nothing. A commit already started keeps its captured context and still reports.
    clearRun()
    pasteDraft = ""
    selectedMethod = nil
    step = .methodPicker
  }

  /// Forget the current run's rows, candidates and baseline. Never called by a stale
  /// recompare, which deliberately keeps the candidates.
  private func clearRun() {
    rows = []
    notices = []
    staleNotice = nil
    candidates = []
    baseline = []
    excludedForTelemetry = 0
  }

  /// True iff closing the sheet right now would silently throw away text the user typed.
  /// Mirrors `CustomWordsImportFlowModel.hasDiscardableDraft`: a commit in flight is not a
  /// draft; a failed or empty result still holds the uncommitted paste; a completed or
  /// nothing-approved result is nothing-to-lose only when THIS result's method was paste.
  var hasDiscardableDraft: Bool {
    switch step {
    case .working(.committing):
      return false
    case .result(.completed), .result(.nothingApproved):
      guard selectedMethod != .paste else { return false }
      return hasNonWhitespacePasteDraft
    case .methodPicker, .paste, .file, .review,
      .working(.loadingCandidates), .working(.comparing),
      .result(.nothingFound), .result(.nothingCompatible), .result(.failed):
      return hasNonWhitespacePasteDraft
    }
  }

  private var hasNonWhitespacePasteDraft: Bool {
    pasteDraft.contains { !$0.isWhitespace }
  }

  /// "Keep editing" from a discard dialog: a terminal result returns to Paste with the
  /// draft intact; everywhere else the user is already looking at their draft.
  func keepEditingDiscardableDraft() {
    guard hasDiscardableDraft else { return }
    switch step {
    case .result:
      abandonWork()
      clearRun()
      selectedMethod = .paste
      step = .paste
    case .methodPicker, .paste, .file, .review, .working:
      break
    }
  }

  // MARK: - Workflow

  /// Run a source end to end: load its candidates, compare them against the current list,
  /// and land on Review.
  func begin(with source: any SnippetImportSource) {
    guard selectedMethod != nil else { return }
    let runGeneration = abandonWork()
    // A fresh run starts from nothing: counts from a review the user backed out of must not
    // ride into this attempt's report.
    clearRun()
    attempt = Attempt(
      id: UUID(), source: SnippetImportTelemetrySource(rawValue: source.sourceID) ?? .fileOther)
    let run = attempt
    beginWork(.loadingCandidates)

    activeTask = Task { [weak self] in
      await self?.load(from: source, run: run, generation: runGeneration)
    }
  }

  /// Apply the current decisions in one atomic write. With nothing approved, no commit is
  /// invoked at all (the store's own empty no-op is the second boundary).
  func confirm() {
    guard step == .review else { return }
    let approved = approvedRows
    guard !approved.isEmpty else {
      beginWork(.committing)
      reportNonCommitTerminal(.nothingApproved, run: attempt)
      showResult(.nothingApproved)
      return
    }
    staleNotice = nil
    beginWork(.committing)
    let plan = SnippetsCoordinator.SnippetImportCommitPlan(
      baseline: baseline,
      additions: approved.map { Snippet(trigger: $0.trigger, expansion: $0.expansion) })
    // Captured BEFORE the await: a cancel or a new run while the store writes must not
    // change what this commit reports, and clearing the rows must not erase its counts.
    let run = attempt
    let report = attemptReport(outcome: .completed)
    let runGeneration = abandonWork()
    activeTask = Task { [weak self] in
      await self?.commit(plan, run: run, report: report, generation: runGeneration)
    }
  }

  func setDecision(_ decision: SnippetImportDecision, forRow id: UUID) {
    guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
    // The screen only renders allowed decisions, but the model is the authority.
    guard rows[index].allowedDecisions.contains(decision) else { return }
    rows[index].decision = decision
  }

  // MARK: - Workflow internals

  private func load(
    from source: any SnippetImportSource, run: Attempt, generation: Int
  ) async {
    do {
      let batch = try await source.loadCandidates()
      guard isCurrent(generation) else { return }
      excludedForTelemetry = batch.notices.reduce(into: 0) { count, notice in
        switch notice {
        case .incompatibleSourceEntriesExcluded(let n), .linesSkipped(let n): count += n
        }
      }
      guard !batch.candidates.isEmpty else {
        let result: Result =
          excludedForTelemetry > 0 ? .nothingCompatible(found: excludedForTelemetry) : .nothingFound
        reportNonCommitTerminal(result, run: run)
        showResult(result)
        return
      }
      candidates = batch.candidates
      notices = batch.notices
      beginWork(.comparing)
      await compare(candidates: batch.candidates, run: run, generation: generation)
    } catch is CancellationError {
      return
    } catch {
      // A superseded or dismissed load is UNOBSERVED, not failed: it reports nothing, so it
      // can neither wear a later run's identity nor spend that run's once-only report.
      guard isCurrent(generation) else { return }
      dependencies.report(
        run.id,
        SnippetImportAttemptReport(
          source: run.source, outcome: .failed,
          failure: SnippetImportTelemetryFailure.forLoadError(error)))
      showResult(.failed(message: error.localizedDescription))
    }
  }

  private func compare(
    candidates: [SnippetImportCandidate], run: Attempt, generation: Int
  ) async {
    let existing = dependencies.existingSnippets()
    do {
      let built = try await SnippetImportRowBuilder.rows(candidates: candidates, existing: existing)
      guard isCurrent(generation) else { return }
      baseline = existing
      rows = built
      showReview()
    } catch is CancellationError {
      return
    } catch {
      // The row builder throws only on cancellation today; a future throw is still a
      // terminal, and a terminal is reported.
      guard isCurrent(generation) else { return }
      dependencies.report(
        run.id,
        SnippetImportAttemptReport(
          source: run.source, outcome: .failed,
          failure: SnippetImportTelemetryFailure.forLoadError(error)))
      showResult(.failed(message: error.localizedDescription))
    }
  }

  private func commit(
    _ plan: SnippetsCoordinator.SnippetImportCommitPlan, run: Attempt,
    report captured: SnippetImportAttemptReport, generation: Int
  ) async {
    let outcome = await dependencies.commit(plan)
    // Reported from the CAPTURED context when the store call returns, whether or not the
    // sheet still exists or the rows are still there: a sheet closed during a successful
    // commit never reaches `showResult`, and a cancel clears the rows.
    var report = captured
    switch outcome {
    case .committed(let receipt):
      report.outcome = .completed
      report.added = receipt.addedIDs.count
      dependencies.report(run.id, report)
      guard isCurrent(generation) else { return }
      showResult(.completed(added: receipt.addedIDs.count))
    case .stale:
      report.outcome = .stale
      dependencies.report(run.id, report)
      guard isCurrent(generation) else { return }
      recompareAfterStaleCommit()
    case .failed(let error):
      report.outcome = .failed
      report.failure = SnippetImportTelemetryFailure.forCommitError(error)
      dependencies.report(run.id, report)
      if case .validation(.duplicateTrigger) = error {
        // Exactly one shape files the app-owned error: the locked baseline matched the
        // review's list and the store still refused an approved row as a duplicate, so our
        // row builder and our commit disagree. Gated on the error itself, never on the
        // telemetry classification.
        dependencies.fileReviewCommitMismatch(plan.additions.count, plan.baseline.count)
      }
      guard isCurrent(generation) else { return }
      showResult(.failed(message: error.message))
    }
  }

  /// The list changed while Review was open. Nothing was written. Rebuild the comparison
  /// against the current list (read from disk by `existingSnippets`) and return to Review
  /// with every decision reset. The reconfirmation is a new attempt.
  private func recompareAfterStaleCommit() {
    let runGeneration = advanceGeneration()
    attempt = Attempt(id: UUID(), source: attempt.source)
    let run = attempt
    let pending = candidates
    staleNotice =
      "Your snippets changed while you were reviewing. "
      + "Nothing was imported. Here is the updated list."
    beginWork(.comparing)

    activeTask = Task { [weak self] in
      await self?.compare(candidates: pending, run: run, generation: runGeneration)
    }
  }

  private func reportNonCommitTerminal(_ result: Result, run: Attempt) {
    let outcome: SnippetImportTelemetryOutcome
    switch result {
    case .nothingFound: outcome = .nothingFound
    case .nothingCompatible: outcome = .nothingCompatible
    case .nothingApproved: outcome = .nothingApproved
    case .completed, .failed: return  // reported by their own paths
    }
    dependencies.report(run.id, attemptReport(outcome: outcome))
  }

  /// The count-only facts of the current attempt, from the rows as they stand.
  private func attemptReport(
    outcome: SnippetImportTelemetryOutcome, added: Int = 0,
    failure: SnippetImportTelemetryFailure? = nil
  ) -> SnippetImportAttemptReport {
    var report = SnippetImportAttemptReport(source: attempt.source, outcome: outcome)
    report.candidates = candidates.count
    report.added = added
    report.excluded = excludedForTelemetry
    for row in rows {
      switch row.status {
      case .existing: report.skippedExisting += 1
      case .duplicateInBatch: report.skippedDuplicateBatch += 1
      case .new: if row.decision == .skip { report.skippedUnticked += 1 }
      }
    }
    report.failure = failure
    return report
  }

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
