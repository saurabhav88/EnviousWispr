import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2997 — the Snippet Import sheet's workflow: load → compare → review → commit.
///
/// `.productOutcome`: when this fails a user sees a snippet they already have offered
/// again, a decision moved onto another row, a stale review committed over another
/// process's edit, an import that never reports, or a button that does nothing.
///
/// All asynchrony is driven by explicit signals (a gate the test opens, a spy the test
/// reads), never by wall-clock sleeps.
@MainActor
@Suite("Snippet import flow model (#2997)", .tags(.productOutcome))
struct SnippetImportFlowModelTests {
  typealias Model = SnippetImportFlowModel
  typealias Plan = SnippetsCoordinator.SnippetImportCommitPlan
  typealias Outcome = SnippetsCoordinator.SnippetImportCommitOutcome

  // MARK: - Fakes

  /// A source the test scripts: candidates, notices, an error, and an optional gate the
  /// load suspends on until the test opens it.
  final class StubSource: SnippetImportSource, @unchecked Sendable {
    let sourceID: String
    let candidates: [SnippetImportCandidate]
    let notices: [SnippetImportNotice]
    let error: (any Error)?
    let gate: AsyncStream<Void>?
    /// Incremented when a gated load resumes, so a cancellation test can prove the late
    /// completion really happened.
    let completed = Counter()

    init(
      sourceID: String = "paste", candidates: [SnippetImportCandidate],
      notices: [SnippetImportNotice] = [], error: (any Error)? = nil,
      gate: AsyncStream<Void>? = nil
    ) {
      self.sourceID = sourceID
      self.candidates = candidates
      self.notices = notices
      self.error = error
      self.gate = gate
    }

    func loadRawCandidates() async throws -> SnippetImportBatch {
      if let gate {
        for await _ in gate { break }
        completed.increment()
      }
      if let error { throw error }
      return SnippetImportBatch(
        sourceID: sourceID, sourceDisplayName: "Test", candidates: candidates,
        notices: notices)
    }
  }

  final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
  }

  /// Records the plans the flow committed and returns what the test scripted.
  @MainActor
  final class CommitSpy {
    var plans: [Plan] = []
    var results: [Outcome] = []
    var completedCalls = 0
    var gate: AsyncStream<Void>?

    func commit(_ plan: Plan) async -> Outcome {
      plans.append(plan)
      if let gate { for await _ in gate { break } }
      completedCalls += 1
      let index = plans.count - 1
      return index < results.count ? results[index] : (results.last ?? .stale)
    }
  }

  @MainActor
  final class ReportSpy {
    var reports: [(UUID, SnippetImportAttemptReport)] = []
    var mismatches: [(Int, Int)] = []
  }

  /// The "disk": what `existingSnippets` returns, mutable so a test can stage another
  /// process's edit between review and confirm.
  @MainActor
  final class Disk {
    var snippets: [Snippet]
    init(_ snippets: [Snippet]) { self.snippets = snippets }
  }

  static func makeModel(
    disk: Disk = Disk([]), commit: CommitSpy = CommitSpy(), report: ReportSpy = ReportSpy()
  ) -> Model {
    Model(
      dependencies: .init(
        existingSnippets: { disk.snippets },
        commit: { await commit.commit($0) },
        report: { attempt, r in report.reports.append((attempt, r)) },
        fileReviewCommitMismatch: { a, b in report.mismatches.append((a, b)) }))
  }

  static func candidate(_ trigger: String, _ expansion: String = "text") -> SnippetImportCandidate {
    SnippetImportCandidate(trigger: trigger, expansion: expansion)
  }

  /// Signal-based settle: yield until the model reaches the state, or FAIL. A helper that
  /// times out silently would turn "the flow never got there" into a pass.
  static func settle(
    _ label: String, sourceLocation: SourceLocation = #_sourceLocation,
    until condition: () -> Bool
  ) async {
    for _ in 0..<2_000 {
      if condition() { return }
      await Task.yield()
    }
    Issue.record("Timed out waiting for \(label).", sourceLocation: sourceLocation)
  }

  static func reachReview(_ model: Model, source: StubSource) async {
    model.select(.paste)
    model.begin(with: source)
    await settle("the review or result screen") {
      if case .result = model.step { return true }
      return model.step == .review
    }
  }

  // MARK: - Navigation

  nonisolated static let methodCases: [(Model.Method, Model.Step)] = [
    (.paste, .paste), (.file, .file), (.app, .appPicker),
  ]

  @Test("Initial step is the method picker with nothing selected")
  func initialStep() {
    let model = Self.makeModel()
    #expect(model.step == .methodPicker)
    #expect(model.selectedMethod == nil)
    #expect(model.canGoBack == false)
  }

  @Test("select moves to the method's input screen; Back returns to the picker", arguments: methodCases)
  func selectAndBack(method: Model.Method, inputStep: Model.Step) {
    let model = Self.makeModel()
    model.select(method)
    #expect(model.step == inputStep)
    #expect(model.selectedMethod == method)
    #expect(model.canGoBack)
    model.goBack()
    #expect(model.step == .methodPicker)
    #expect(model.selectedMethod == nil)
  }

  @Test("Review, work and result are only reachable in order")
  func guardedTransitions() {
    let model = Self.makeModel()
    model.showReview()
    #expect(model.step == .methodPicker, "no method selected yet")
    model.showResult(.nothingFound)
    #expect(model.step == .methodPicker, "a result only ever comes out of work")
    model.select(.file)
    model.beginWork(.loadingCandidates)
    #expect(model.step == .working(.loadingCandidates))
    #expect(model.canGoBack == false)
    model.showReview()
    #expect(model.step == .review)
    model.goBack()
    #expect(model.step == .file, "Back from review returns to the selected input screen")
    model.reset()
    #expect(model.step == .methodPicker)
    #expect(model.selectedMethod == nil)
  }

  // MARK: - Rows and decisions

  @Test("Rows are new, existing, or a duplicate of an earlier row, and only new rows can be added")
  func rowStatusesAndDecisions() async {
    let disk = Disk([Snippet(trigger: "my email", expansion: "sam@example.com")])
    let model = Self.makeModel(disk: disk)
    let source = StubSource(candidates: [
      Self.candidate("My   Email!"), Self.candidate("sig"), Self.candidate("Sig"),
    ])
    await Self.reachReview(model, source: source)

    #expect(model.step == .review)
    #expect(model.rows.map(\.status) == [.existing(trigger: "my email"), .new, .duplicateInBatch])
    #expect(model.rows.map(\.decision) == [.skip, .add, .skip])
    #expect(model.rows[0].statusNote == "You have this, as \u{201C}my email\u{201D}.")

    model.setDecision(.add, forRow: model.rows[0].id)
    model.setDecision(.add, forRow: model.rows[2].id)
    #expect(model.rows.map(\.decision) == [.skip, .add, .skip], "skip-only rows refuse Add")
    model.setDecision(.skip, forRow: model.rows[1].id)
    #expect(model.rows[1].decision == .skip)
    model.setDecision(.add, forRow: model.rows[1].id)
    #expect(model.rows[1].decision == .add)
    #expect(model.approvedRows.map(\.trigger) == ["sig"])
  }

  @Test("Confirm commits a plan built from the approved rows against the list the review saw")
  func confirmBuildsPlanWithBaseline() async {
    let existing = Snippet(trigger: "my email", expansion: "sam@example.com")
    let disk = Disk([existing])
    let commit = CommitSpy()
    let report = ReportSpy()
    let model = Self.makeModel(disk: disk, commit: commit, report: report)
    await Self.reachReview(
      model,
      source: StubSource(candidates: [
        Self.candidate("sig", "Best,\nSam"), Self.candidate("skip me"),
        Self.candidate("my email", "other"),
      ]))
    model.setDecision(.skip, forRow: model.rows[1].id)
    let added = Snippet(trigger: "sig", expansion: "Best,\nSam")
    commit.results = [
      .committed(
        SnippetImportReceipt(
          vocabulary: SnippetVocabulary(
            snippets: [added, existing], keyword: "backslash", generation: 2),
          addedIDs: [added.id]))
    ]

    model.confirm()
    await Self.settle("the result screen") { if case .result = model.step { return true }; return false }

    #expect(commit.plans.count == 1)
    #expect(commit.plans.first?.baseline == [existing])
    #expect(commit.plans.first?.additions.map(\.trigger) == ["sig"])
    #expect(commit.plans.first?.additions.map(\.expansion) == ["Best,\nSam"])
    #expect(model.step == .result(.completed(added: 1)))
    let last = report.reports.last?.1
    #expect(last?.outcome == .completed)
    #expect(last?.candidates == 3)
    #expect(last?.added == 1)
    #expect(last?.skippedExisting == 1)
    #expect(last?.skippedUnticked == 1)
  }

  @Test("A stale commit recompares against the list on disk, resets decisions, and the reconfirm succeeds")
  func staleCommitRecomparesFromDisk() async {
    let existing = Snippet(trigger: "my email", expansion: "sam@example.com")
    let disk = Disk([existing])
    let commit = CommitSpy()
    let report = ReportSpy()
    let model = Self.makeModel(disk: disk, commit: commit, report: report)
    await Self.reachReview(
      model, source: StubSource(candidates: [Self.candidate("sig"), Self.candidate("address")]))
    model.setDecision(.skip, forRow: model.rows[1].id)

    // Another process adds "sig" between review and confirm; the store refuses.
    let elsewhere = Snippet(trigger: "SIG", expansion: "theirs")
    disk.snippets = [elsewhere, existing]
    commit.results = [.stale]
    model.confirm()
    await Self.settle("the refreshed review") {
      model.step == .review && model.staleNotice != nil
    }

    #expect(commit.plans.count == 1)
    #expect(model.rows.map(\.status) == [.existing(trigger: "SIG"), .new])
    #expect(model.rows.map(\.decision) == [.skip, .add], "decisions reset on the refreshed review")
    #expect(model.staleNotice?.contains("Nothing was imported") == true)
    #expect(report.reports.map(\.1.outcome) == [.stale])

    commit.results = [
      .stale,
      .committed(
        SnippetImportReceipt(
          vocabulary: SnippetVocabulary(snippets: [], keyword: "backslash", generation: 3),
          addedIDs: [UUID()])),
    ]
    model.confirm()
    await Self.settle("the result screen") { if case .result = model.step { return true }; return false }

    #expect(commit.plans.count == 2)
    #expect(commit.plans[1].baseline == [elsewhere, existing], "the reconfirm carries the DISK list")
    #expect(commit.plans[1].additions.map(\.trigger) == ["address"])
    #expect(model.step == .result(.completed(added: 1)))
    #expect(report.reports.map(\.1.outcome) == [.stale, .completed])
    #expect(report.reports[0].0 != report.reports[1].0, "a reconfirmation is a new attempt")
  }

  @Test("Confirming with nothing approved never calls commit")
  func emptyApprovalNeverCommits() async {
    let commit = CommitSpy()
    let report = ReportSpy()
    let model = Self.makeModel(commit: commit, report: report)
    await Self.reachReview(model, source: StubSource(candidates: [Self.candidate("sig")]))
    model.setDecision(.skip, forRow: model.rows[0].id)

    model.confirm()

    #expect(model.step == .result(.nothingApproved))
    #expect(commit.plans.isEmpty)
    #expect(report.reports.map(\.1.outcome) == [.nothingApproved])
    #expect(report.reports.first?.1.skippedUnticked == 1)
  }

  // MARK: - Terminals without review

  @Test("An empty source is 'nothing found'; a source whose rows were all refused is 'nothing compatible'")
  func emptyAndRefusedSources() async {
    let report = ReportSpy()
    let empty = Self.makeModel(report: report)
    await Self.reachReview(empty, source: StubSource(candidates: []))
    #expect(empty.step == .result(.nothingFound))

    let refused = Self.makeModel(report: report)
    await Self.reachReview(
      refused,
      source: StubSource(candidates: [], notices: [.incompatibleSourceEntriesExcluded(count: 3)]))
    #expect(refused.step == .result(.nothingCompatible(found: 3)))

    let skippedLines = Self.makeModel(report: report)
    await Self.reachReview(
      skippedLines, source: StubSource(candidates: [], notices: [.linesSkipped(count: 2)]))
    #expect(skippedLines.step == .result(.nothingCompatible(found: 2)))

    #expect(report.reports.map(\.1.outcome) == [.nothingFound, .nothingCompatible, .nothingCompatible])
    #expect(report.reports.map(\.1.excluded) == [0, 3, 2])
  }

  @Test("A source that cannot be read lands on the failure screen with its own sentence")
  func loadFailure() async {
    let report = ReportSpy()
    let model = Self.makeModel(report: report)
    await Self.reachReview(
      model,
      source: StubSource(
        sourceID: "file_json", candidates: [],
        error: SnippetImportSourceError.exportedSnippets(.notAnEnviousWisprSnippetsFile)))
    #expect(
      model.step
        == .result(
          .failed(
            message: SnippetImportSourceError.exportedSnippets(.notAnEnviousWisprSnippetsFile)
              .localizedDescription)))
    #expect(report.reports.count == 1)
    #expect(report.reports.first?.1.source == .fileJSON)
    #expect(report.reports.first?.1.failure == .notOurs)
  }

  @Test("Notices ride to the review screen beside the rows")
  func noticesReachReview() async {
    let model = Self.makeModel()
    await Self.reachReview(
      model, source: StubSource(candidates: [Self.candidate("sig")], notices: [.linesSkipped(count: 2)]))
    #expect(model.notices == [.linesSkipped(count: 2)])
  }

  // MARK: - Cancellation

  /// Both shapes, because a non-empty batch goes on to the comparison while an empty one
  /// reaches a terminal at once: only the empty variant proves the generation guard on the
  /// load itself (a removed guard would report `nothing_found` for the dismissed run).
  @Test("Dismissing during the load discards the late completion", arguments: [false, true])
  func dismissDuringLoadDropsLateCompletion(empty: Bool) async {
    let (stream, gate) = AsyncStream<Void>.makeStream()
    let source = StubSource(candidates: empty ? [] : [Self.candidate("sig")], gate: stream)
    let commit = CommitSpy()
    let report = ReportSpy()
    let model = Self.makeModel(commit: commit, report: report)
    model.select(.paste)
    model.begin(with: source)
    #expect(model.step == .working(.loadingCandidates))

    model.cancel()
    gate.yield()
    gate.finish()
    await Self.settle("the gated load to finish") { source.completed.value == 1 }
    for _ in 0..<50 { await Task.yield() }

    #expect(model.rows.isEmpty)
    #expect(model.step != .review)
    #expect(commit.plans.isEmpty)
    #expect(report.reports.isEmpty, "an abandoned attempt is unobserved, not reported")
  }

  @Test("Cancel before confirm writes nothing, and a confirm after cancel has nothing to commit")
  func cancelBeforeConfirmWritesNothing() async {
    let commit = CommitSpy()
    let report = ReportSpy()
    let model = Self.makeModel(commit: commit, report: report)
    await Self.reachReview(model, source: StubSource(candidates: [Self.candidate("sig")]))
    model.cancel()
    #expect(model.rows.isEmpty)
    #expect(model.step == .methodPicker)
    model.confirm()
    for _ in 0..<50 { await Task.yield() }
    #expect(commit.plans.isEmpty)
    #expect(report.reports.isEmpty, "a confirm after cancel reports nothing")
    if case .result = model.step { Issue.record("a confirm after cancel must show nothing") }
  }

  @Test("A load superseded by a new run reports nothing, even when it later fails")
  func supersededLoadReportsNothing() async {
    let (stream, gate) = AsyncStream<Void>.makeStream()
    let slow = StubSource(
      sourceID: "file_csv", candidates: [], error: SnippetImportSourceError.unreadable, gate: stream)
    let report = ReportSpy()
    let model = Self.makeModel(report: report)
    model.select(.file)
    model.begin(with: slow)
    // A second run replaces the first before it finishes.
    model.begin(with: StubSource(sourceID: "paste", candidates: [Self.candidate("sig")]))
    await Self.settle("the second run's review") { model.step == .review }
    gate.yield()
    gate.finish()
    await Self.settle("the superseded load to finish") { slow.completed.value == 1 }
    for _ in 0..<50 { await Task.yield() }

    #expect(report.reports.isEmpty, "the abandoned load must not report under the new run's identity")
    #expect(model.step == .review)
    model.setDecision(.skip, forRow: model.rows[0].id)
    model.confirm()
    #expect(report.reports.map(\.1.outcome) == [.nothingApproved])
    #expect(report.reports.first?.1.source == .paste, "the live run keeps its own source")
  }

  @Test("A new run starts from nothing: counts from a review the user backed out of do not ride along")
  func newRunClearsPreviousCounts() async {
    let report = ReportSpy()
    let model = Self.makeModel(report: report)
    await Self.reachReview(
      model,
      source: StubSource(candidates: (0..<5).map { Self.candidate("t\($0)") }, notices: [.linesSkipped(count: 2)]))
    #expect(model.rows.count == 5)
    model.goBack()
    model.goBack()
    model.select(.file)
    model.begin(with: StubSource(sourceID: "file_text", candidates: []))
    await Self.settle("the result") { if case .result = model.step { return true }; return false }

    #expect(model.step == .result(.nothingFound))
    #expect(report.reports.count == 1)
    #expect(report.reports[0].1.candidates == 0)
    #expect(report.reports[0].1.excluded == 0)
    #expect(report.reports[0].1.skippedUnticked == 0)
  }

  @Test("A commit outlives the model that started it: dropping the sheet's model still reports the write")
  func commitOutlivesModel() async {
    let (stream, gate) = AsyncStream<Void>.makeStream()
    let commit = CommitSpy()
    commit.gate = stream
    commit.results = [
      .committed(
        SnippetImportReceipt(
          vocabulary: SnippetVocabulary(snippets: [], keyword: "backslash", generation: 1),
          addedIDs: [UUID()]))
    ]
    let report = ReportSpy()
    var model: Model? = Self.makeModel(commit: commit, report: report)
    await Self.reachReview(model!, source: StubSource(candidates: [Self.candidate("sig")]))
    model?.confirm()
    await Self.settle("the commit to start") { commit.plans.count == 1 }
    model?.cancel()
    model = nil
    gate.yield()
    gate.finish()
    await Self.settle("the gated commit to finish") { commit.completedCalls == 1 }
    for _ in 0..<50 { await Task.yield() }

    #expect(report.reports.map(\.1.outcome) == [.completed])
    #expect(report.reports.first?.1.candidates == 1, "the counts were captured before the await")
  }

  @Test("Against a real store: an edit by another process makes the commit stale, the review refreshes from disk, and the reconfirm lands")
  func staleAgainstRealStore() async throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-snippets-flow-\(UUID().uuidString)", isDirectory: true)
    let manager = SnippetsManager(fileURL: dir.appendingPathComponent("snippets.json"))
    let coordinator = SnippetsCoordinator(manager: manager)
    for starter in coordinator.snippets { coordinator.delete(starter) }
    var published: [SnippetVocabulary] = []
    coordinator.onVocabularyChanged = { published.append($0) }
    let report = ReportSpy()
    let model = Model(
      dependencies: .init(
        existingSnippets: { coordinator.refreshFromDisk().snippets },
        commit: { await coordinator.commitImport($0) },
        report: { attempt, r in report.reports.append((attempt, r)) },
        fileReviewCommitMismatch: { a, b in report.mismatches.append((a, b)) }))
    await Self.reachReview(
      model, source: StubSource(candidates: [Self.candidate("sig", "mine"), Self.candidate("address")]))
    #expect(model.rows.map(\.status) == [.new, .new])

    // Another EnviousWispr process writes between review and confirm.
    let other = SnippetsManager(fileURL: manager.storageURL)
    let theirs = Snippet(trigger: "Sig", expansion: "theirs")
    try other.upsert(theirs)

    model.confirm()
    await Self.settle("the refreshed review") { model.step == .review && model.staleNotice != nil }
    #expect(model.rows.map(\.status) == [.existing(trigger: "Sig"), .new])
    #expect(coordinator.snippets.map(\.id) == [theirs.id], "the refresh adopted the disk list")

    model.confirm()
    await Self.settle("the result") { if case .result = model.step { return true }; return false }
    #expect(model.step == .result(.completed(added: 1)))
    let onDisk = manager.load().snippets
    #expect(onDisk.map(\.trigger) == ["address", "Sig"])
    #expect(coordinator.snippets.map(\.trigger) == ["address", "Sig"])
    #expect(published.last?.snippets.map(\.trigger) == ["address", "Sig"])
    #expect(report.reports.map(\.1.outcome) == [.stale, .completed])
    #expect(report.mismatches.isEmpty)
  }

  @Test("Cancel during a commit does not roll it back: the write completes and is reported, only the result screen is dropped")
  func cancelDuringCommitStillReports() async {
    let (stream, gate) = AsyncStream<Void>.makeStream()
    let commit = CommitSpy()
    commit.gate = stream
    commit.results = [
      .committed(
        SnippetImportReceipt(
          vocabulary: SnippetVocabulary(snippets: [], keyword: "backslash", generation: 1),
          addedIDs: [UUID()]))
    ]
    let report = ReportSpy()
    let model = Self.makeModel(commit: commit, report: report)
    await Self.reachReview(model, source: StubSource(candidates: [Self.candidate("sig")]))

    model.confirm()
    await Self.settle("the commit to start") { commit.plans.count == 1 }
    #expect(model.step == .working(.committing))
    model.cancel()
    gate.yield()
    gate.finish()
    await Self.settle("the gated commit to finish") { commit.completedCalls == 1 }
    for _ in 0..<50 { await Task.yield() }

    #expect(report.reports.map(\.1.outcome) == [.completed])
    if case .result = model.step { Issue.record("the result is not shown to a dismissed sheet") }
  }

  // MARK: - Drafts and copy

  @Test("A typed paste draft is protected until it is committed")
  func discardableDraft() {
    let model = Self.makeModel()
    #expect(model.hasDiscardableDraft == false)
    model.select(.paste)
    model.pasteDraft = "sig = hi"
    #expect(model.hasDiscardableDraft)
    model.goBack()
    model.select(.file)
    #expect(model.hasDiscardableDraft, "an abandoned paste draft is still at risk from the file screen")
    model.cancel()
    #expect(model.pasteDraft.isEmpty)
    #expect(model.hasDiscardableDraft == false)
    #expect(model.step == .methodPicker)
  }

  @Test("Result copy names the outcome in the user's words")
  func resultCopy() {
    #expect(
      SnippetImportResultCopy.message(for: .completed(added: 1))
        == "Added 1 snippet. Say your keyword, then the trigger, and it's pasted.")
    #expect(
      SnippetImportResultCopy.message(for: .completed(added: 3))
        == "Added 3 snippets. Say your keyword, then the trigger, and it's pasted.")
    #expect(
      SnippetImportResultCopy.message(for: .nothingFound)
        == "No snippets were found, and nothing was changed.")
    #expect(
      SnippetImportResultCopy.message(for: .nothingCompatible(found: 2))
        == "Found 2 entries, but none could be imported. Nothing was changed.")
    #expect(
      SnippetImportResultCopy.message(for: .nothingApproved)
        == "You skipped everything, so nothing was changed.")
    #expect(SnippetImportResultCopy.message(for: .failed(message: "why")) == "why")
    #expect(SnippetImportResultCopy.reviewSummary(new: 2, existing: 1, duplicates: 0) == "2 new snippets, 1 you already have.")
    #expect(SnippetImportResultCopy.reviewSummary(new: 0, existing: 0, duplicates: 0) == "Nothing to review.")
  }
}

/// Plan §3a: the review build at the ceiling, from the PRODUCTION entry point on the main
/// actor, with a main-actor ping required to complete while it runs. Dev machine only; the
/// bound is for THIS Mac.
@MainActor
@Suite("Snippet import review at the ceiling (#2997)", .tags(.harnessContract))
struct SnippetImportReviewCeilingTests {
  nonisolated static var runsOnThisMachine: Bool {
    (ProcessInfo.processInfo.environment["CI"] ?? "").isEmpty
  }

  private static func maximal(_ count: Int, prefix: String) -> [String] {
    (0..<count).map {
      let head = "\(prefix)\(String(format: "%06d", $0)) "
      return head
        + String(
          repeating: "a", count: SnippetImportLimits.maximumTriggerScalars - head.unicodeScalars.count)
    }
  }

  @Test(
    "5,000 maximal candidates review against 50,000 existing snippets without blocking the main actor",
    .enabled(if: SnippetImportReviewCeilingTests.runsOnThisMachine))
  func reviewBuildsAtCeiling() async {
    let existing = Self.maximal(50_000, prefix: "e").map { Snippet(trigger: $0, expansion: "x") }
    let candidates = Self.maximal(SnippetImportLimits.maximumCandidates, prefix: "n").map {
      SnippetImportCandidate(trigger: $0, expansion: "x")
    }
    let model = SnippetImportFlowModel(
      dependencies: .init(
        existingSnippets: { existing }, commit: { _ in .stale },
        report: { _, _ in }, fileReviewCommitMismatch: { _, _ in }))
    model.select(.paste)
    let started = ContinuousClock.now
    model.begin(with: SnippetImportFlowModelTests.StubSource(candidates: candidates))

    // Main-actor pings must keep completing WHILE the build runs off it: each poll below is
    // itself a main-actor turn, and the longest gap between two of them is the longest the
    // main actor was blocked. Real work, so a yield-count settle would give up first: poll
    // on a short sleep, bounded by the same 10 s the elapsed assertion allows.
    var longestGap = Duration.zero
    var lastTurn = ContinuousClock.now
    var turns = 0
    let deadline = ContinuousClock.now + .seconds(10)
    while model.step != .review && ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(5))
      let now = ContinuousClock.now
      longestGap = max(longestGap, now - lastTurn)
      lastTurn = now
      turns += 1
    }
    let elapsed = ContinuousClock.now - started
    #expect(turns >= 10, "the build must have run long enough for the pings to mean anything (\(turns) turns)")
    #expect(longestGap < .milliseconds(250), "a main-actor turn waited \(longestGap) during the build")
    print("reviewBuildsAtCeiling existing=50000 elapsed=\(elapsed)")
    #expect(model.rows.count == SnippetImportLimits.maximumCandidates)
    #expect(model.rows.allSatisfy { $0.status == .new })
    #expect(elapsed < .seconds(10))
  }
}
