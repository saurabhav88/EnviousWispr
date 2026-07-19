import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// Review & Merge workflow tests (#1669, epic #1619 PR-F2c).
///
/// The v1 contract under test: only a genuinely new word can be added, every
/// match classification is Skip-only, the compare engine is always called with
/// fuzzy matching disabled, and a confirmed plan contains additions only.
///
/// All asynchrony is driven by explicit signals — a gate the test opens and a
/// spy the test reads — never by wall-clock sleeps.
@MainActor
@Suite("CustomWordsImportReviewFlow")
struct CustomWordsImportReviewFlowTests {
  typealias Model = CustomWordsImportFlowModel
  typealias Row = CustomWordsImportReviewRow

  // MARK: - Fakes

  /// Records what the flow asked for and returns what the test scripted.
  final class CompareSpy: @unchecked Sendable {
    // Single-touch handoff: the test writes before the flow runs, the flow
    // writes once during the run, and the test reads after it completes.
    var policies: [CustomWordsImportFuzzyPolicy] = []
    var existingSeen: [[CustomWord]] = []
    var results: [[CustomWordsImportComparison]] = []
    var callCount = 0
    /// Incremented after the gated call resumes and returns its result, so a
    /// cancellation test can prove the late completion really happened rather
    /// than passing because the work never ran at all.
    var completedCalls = 0
    /// When set, the compare call suspends until the test opens this gate.
    var gate: AsyncStream<Void>.Continuation?
    var gateStream: AsyncStream<Void>?

    func nextResult() -> [CustomWordsImportComparison] {
      defer { callCount += 1 }
      guard callCount < results.count else { return results.last ?? [] }
      return results[callCount]
    }
  }

  struct StubSource: CustomWordsImportSource {
    let candidates: [CustomWordsImportCandidate]
    func loadCandidates() async throws -> CustomWordsImportBatch {
      CustomWordsImportBatch(
        sourceID: "test", sourceDisplayName: "Test", candidates: candidates)
    }
  }

  final class CommitSpy: @unchecked Sendable {
    var plans: [CustomWordsImportCommitPlan] = []
    var outcomes: [CustomWordsCoordinator.CustomWordsImportCommitOutcome] = []
    var callCount = 0

    func record(_ plan: CustomWordsImportCommitPlan)
      -> CustomWordsCoordinator.CustomWordsImportCommitOutcome
    {
      plans.append(plan)
      defer { callCount += 1 }
      guard callCount < outcomes.count else {
        return outcomes.last ?? .failed(message: "unscripted commit")
      }
      return outcomes[callCount]
    }
  }

  // MARK: - Builders

  static func candidate(_ canonical: String) -> CustomWordsImportCandidate {
    CustomWordsImportCandidate(canonical: canonical)
  }

  static func comparison(
    _ canonical: String,
    _ classification: CustomWordsImportClassification,
    collisions: [CustomWordsImportAliasCollision] = []
  ) -> CustomWordsImportComparison {
    CustomWordsImportComparison(
      candidate: candidate(canonical),
      classification: classification,
      collidingAliases: collisions
    )
  }

  static func makeModel(
    existing: [CustomWord] = [],
    compare: CompareSpy,
    commit: CommitSpy
  ) -> Model {
    Model(
      dependencies: .init(
        existingWords: { existing },
        commit: { commit.record($0) },
        compare: { _, seen, policy in
          compare.policies.append(policy)
          compare.existingSeen.append(seen)
          if let stream = compare.gateStream {
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
          }
          let result = compare.nextResult()
          compare.completedCalls += 1
          return result
        }
      )
    )
  }

  /// Drive a source to the review screen. Returns once the flow settles.
  static func runToReview(
    _ model: Model, candidates: [CustomWordsImportCandidate]
  ) async {
    model.select(.paste)
    model.begin(with: StubSource(candidates: candidates))
    await Self.settle(model) { $0.step == .review || $0.step.isResult }
  }

  /// Signal-based settle: yield until the model reaches the state the caller
  /// is waiting for. No clock is involved, so a slow CI host cannot flake it.
  static func settle(_ model: Model, until condition: (Model) -> Bool) async {
    for _ in 0..<1000 {
      if condition(model) { return }
      await Task.yield()
    }
  }

  // MARK: - Decision gating

  @Test("a new word offers Add and Skip, and defaults to Add")
  func newClassificationOffersAddAndSkipAndDefaultsToAdd() {
    #expect(Row.allowedDecisions(for: .new) == [.add, .skip])
    #expect(Row.defaultDecision(for: .new) == .add)
  }

  @Test("an exact match is Skip-only and defaults to Skip")
  func exactClassificationOffersOnlySkip() {
    let existing = CustomWord(canonical: "GitHub")
    #expect(Row.allowedDecisions(for: .exact(existing: existing)) == [.skip])
    #expect(Row.defaultDecision(for: .exact(existing: existing)) == .skip)
  }

  @Test("a variant match is Skip-only and defaults to Skip")
  func variantClassificationOffersOnlySkip() {
    let existing = CustomWord(canonical: "GitHub", aliases: ["github"])
    let classification = CustomWordsImportClassification.variant(
      existing: existing, matchedAlias: "github")
    #expect(Row.allowedDecisions(for: classification) == [.skip])
    #expect(Row.defaultDecision(for: classification) == .skip)
  }

  @Test("an ambiguous match is Skip-only and defaults to Skip")
  func ambiguousClassificationOffersOnlySkip() {
    let classification = CustomWordsImportClassification.ambiguous(matches: [
      CustomWordsImportAmbiguousMatch(existing: CustomWord(canonical: "Anand"), kind: .exact),
      CustomWordsImportAmbiguousMatch(existing: CustomWord(canonical: "Ananda"), kind: .exact),
    ])
    #expect(Row.allowedDecisions(for: classification) == [.skip])
    #expect(Row.defaultDecision(for: classification) == .skip)
  }

  @Test("a fuzzy match is handled as Skip-only even though v1 never produces one")
  func fuzzyClassificationOffersOnlySkipEvenThoughV1NeverProducesIt() {
    // Exhaustiveness freeze: v1 disables fuzzy matching, but the row type must
    // still handle the case rather than trap, so a future caller that arms the
    // policy cannot produce an unhandled row.
    let classification = CustomWordsImportClassification.fuzzy(
      existing: CustomWord(canonical: "Anand"), distance: 1)
    #expect(Row.allowedDecisions(for: classification) == [.skip])
    #expect(Row.defaultDecision(for: classification) == .skip)
  }

  @Test("a decision persistence would refuse is never accepted onto a row")
  func setDecisionRejectsADisallowedDecision() async {
    let compare = CompareSpy()
    let commit = CommitSpy()
    compare.results = [
      [Self.comparison("GitHub", .exact(existing: CustomWord(canonical: "GitHub")))]
    ]
    let model = Self.makeModel(compare: compare, commit: commit)
    await Self.runToReview(model, candidates: [Self.candidate("GitHub")])

    let rowID = try! #require(model.rows.first).id
    model.setDecision(.add, forRow: rowID)

    #expect(model.rows[0].decision == .skip)
    #expect(model.approvedRows.isEmpty)
  }

  // MARK: - Fuzzy is off

  @Test("the flow always compares with the fuzzy policy disabled")
  func flowPassesDisabledFuzzyPolicyToTheCompareEngine() async {
    // Founder decision 2026-07-18, frozen here against silent re-arming: with
    // Replace gone a similarity match can only withhold Add, so a false
    // positive would refuse a legitimately different word with no recourse.
    let compare = CompareSpy()
    let commit = CommitSpy()
    compare.results = [[Self.comparison("Ananda", .new)]]
    let model = Self.makeModel(
      existing: [CustomWord(canonical: "Anand")], compare: compare, commit: commit)

    await Self.runToReview(model, candidates: [Self.candidate("Ananda")])

    #expect(compare.policies == [.disabled])
  }

  // MARK: - Commit shape

  @Test("confirm builds an additions-only plan with no replacements")
  func confirmBuildsAdditionsOnlyPlanWithNoReplacements() async {
    let compare = CompareSpy()
    let commit = CommitSpy()
    let existingWord = CustomWord(canonical: "GitHub")
    compare.results = [
      [
        Self.comparison("Kubernetes", .new),
        Self.comparison("GitHub", .exact(existing: existingWord)),
      ]
    ]
    commit.outcomes = [
      .committed(
        CustomWordsImportCommitReceipt(
          addedIDs: [UUID()], replacedIDs: [], droppedAliasCollisions: []))
    ]
    let model = Self.makeModel(existing: [existingWord], compare: compare, commit: commit)
    await Self.runToReview(
      model, candidates: [Self.candidate("Kubernetes"), Self.candidate("GitHub")])

    model.confirm()

    let plan = try! #require(commit.plans.first)
    #expect(plan.replacements.isEmpty)
    #expect(plan.additions.map(\.canonical) == ["Kubernetes"])
    #expect(model.step == .result(.completed(added: 1, replaced: 0)))
  }

  @Test("confirm with everything skipped writes nothing")
  func confirmWithAllSkippedWritesNothing() async {
    let compare = CompareSpy()
    let commit = CommitSpy()
    compare.results = [
      [Self.comparison("GitHub", .exact(existing: CustomWord(canonical: "GitHub")))]
    ]
    let model = Self.makeModel(compare: compare, commit: commit)
    await Self.runToReview(model, candidates: [Self.candidate("GitHub")])

    model.confirm()

    #expect(commit.plans.isEmpty)
    #expect(model.step == .result(.nothingApproved))
  }

  @Test("a second confirm while committing is ignored")
  func secondConfirmWhileCommittingIsIgnored() async {
    let compare = CompareSpy()
    let commit = CommitSpy()
    compare.results = [[Self.comparison("Kubernetes", .new)]]
    commit.outcomes = [
      .committed(
        CustomWordsImportCommitReceipt(
          addedIDs: [UUID()], replacedIDs: [], droppedAliasCollisions: []))
    ]
    let model = Self.makeModel(compare: compare, commit: commit)
    await Self.runToReview(model, candidates: [Self.candidate("Kubernetes")])

    model.confirm()
    model.confirm()

    #expect(commit.plans.count == 1)
  }

  // MARK: - Staleness

  @Test("a stale commit re-compares against the current list and resets decisions")
  func staleCommitRecomparesAndResetsDecisions() async {
    let compare = CompareSpy()
    let commit = CommitSpy()
    let nowExisting = CustomWord(canonical: "Kubernetes")
    // First run: the word is new. After the stale rejection the library has
    // gained it, so the rebuild must classify it as an existing match.
    compare.results = [
      [Self.comparison("Kubernetes", .new)],
      [Self.comparison("Kubernetes", .exact(existing: nowExisting))],
    ]
    commit.outcomes = [.stale]
    let model = Self.makeModel(
      existing: [nowExisting], compare: compare, commit: commit)
    await Self.runToReview(model, candidates: [Self.candidate("Kubernetes")])
    #expect(model.rows[0].decision == .add)

    model.confirm()
    await Self.settle(model) { $0.step == .review }

    #expect(model.rows.count == 1)
    #expect(model.rows[0].decision == .skip, "the rebuilt row must not inherit the old Add")
    #expect(model.approvedRows.isEmpty)
    #expect(model.staleNotice != nil)
    #expect(compare.callCount == 2)
  }

  // MARK: - Cancellation

  @Test("dismissing during comparison discards the late completion")
  func dismissDuringComparisonIgnoresLateCompletion() async {
    let compare = CompareSpy()
    let commit = CommitSpy()
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    compare.gateStream = stream
    compare.gate = continuation
    compare.results = [[Self.comparison("Kubernetes", .new)]]
    let model = Self.makeModel(compare: compare, commit: commit)

    model.select(.paste)
    model.begin(with: StubSource(candidates: [Self.candidate("Kubernetes")]))
    // Wait for the flow to actually reach the gated compare call, so the
    // cancellation lands mid-flight rather than before the work started.
    await Self.settle(model) { _ in compare.policies.isEmpty == false }

    model.cancel()
    continuation.yield()
    continuation.finish()
    // Wait for the gated call to actually finish. Without this the assertions
    // below could pass because the work never ran, which is indistinguishable
    // from working cancellation and would make this test worthless.
    await Self.settle(model) { _ in compare.completedCalls == 1 }
    // Then give the completed task every chance to publish; it must not.
    for _ in 0..<50 { await Task.yield() }

    #expect(compare.completedCalls == 1, "the late completion must really have happened")
    #expect(model.rows.isEmpty, "a cancelled run must never publish review rows")
    #expect(model.step != .review)
  }

  // MARK: - Disclosure

  @Test("a row whose aliases collide shows the note naming the owner")
  func rowWithCollidingAliasesShowsNote() {
    let owner = CustomWord(canonical: "Anika", aliases: ["annie"])
    let rows = Row.rows(
      from: [
        Self.comparison(
          "Zed", .new,
          collisions: [CustomWordsImportAliasCollision(alias: "Annie", heldBy: owner.id)])
      ],
      existingWords: [owner]
    )

    let note = try! #require(rows[0].collisionNote)
    #expect(note.contains("Annie"))
    #expect(note.contains("Anika"))
    // Conditional by design: whether the alias actually lands depends on which
    // rows are approved, and the commit receipt reports what was really
    // dropped. Asserting the wording freezes that honesty (code review r1).
    #expect(note.contains("may not be added"))
    // Informational only: it must not change what the user may do.
    #expect(rows[0].allowedDecisions == [.add, .skip])
    #expect(rows[0].decision == .add)
  }

  @Test("a row with no collision has no note")
  func rowWithoutCollisionHasNoNote() {
    let rows = Row.rows(from: [Self.comparison("Zed", .new)], existingWords: [])
    #expect(rows[0].collisionNote == nil)
  }

  @Test("the result screen surfaces the dropped-collision count")
  func resultScreenSurfacesDroppedAliasCollisionCount() async {
    let compare = CompareSpy()
    let commit = CommitSpy()
    compare.results = [[Self.comparison("Kubernetes", .new)]]
    commit.outcomes = [
      .committed(
        CustomWordsImportCommitReceipt(
          addedIDs: [UUID()],
          replacedIDs: [],
          droppedAliasCollisions: [
            CustomWordsImportAliasCollision(alias: "k8s", heldBy: UUID())
          ]))
    ]
    let model = Self.makeModel(compare: compare, commit: commit)
    await Self.runToReview(model, candidates: [Self.candidate("Kubernetes")])

    model.confirm()

    #expect(model.droppedAliasCollisionCount == 1)
    #expect(
      CustomWordsImportResultCopy.droppedCollisionMessage(count: 1).contains("1 alternate"))
  }

  @Test("the result copy omits the replaced count when nothing was replaced")
  func resultScreenOmitsReplacedCountWhenZero() {
    let v1 = CustomWordsImportResultCopy.message(for: .completed(added: 3, replaced: 0))
    #expect(v1 == "Added 3 words. Your words are ready to use.")
    #expect(!v1.contains("Replaced"))

    // A later flow (backup restore) can replace, and then it is reported.
    let later = CustomWordsImportResultCopy.message(for: .completed(added: 1, replaced: 2))
    #expect(later.contains("Replaced 2"))
  }

  @Test("finding no candidates and approving none are different outcomes")
  func nothingFoundAndNothingApprovedAreDistinct() async {
    let compare = CompareSpy()
    let commit = CommitSpy()
    let model = Self.makeModel(compare: compare, commit: commit)

    model.select(.paste)
    model.begin(with: StubSource(candidates: []))
    await Self.settle(model) { $0.step.isResult }

    #expect(model.step == .result(.nothingFound))
    #expect(compare.callCount == 0, "an empty batch must not reach the compare engine")
  }
}

extension CustomWordsImportFlowModel.Step {
  fileprivate var isResult: Bool {
    if case .result = self { return true }
    return false
  }
}
