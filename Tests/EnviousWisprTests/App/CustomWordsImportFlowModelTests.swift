import Testing

@testable import EnviousWisprAppKit

/// Unit tests for `CustomWordsImportFlowModel` (#1657, epic #1619 PR-F1).
/// Pure navigation-state coverage: the model owns no work, no persistence,
/// and no DEBUG-only members, so Release test builds instantiate it directly.
@MainActor
@Suite("CustomWordsImportFlowModel")
struct CustomWordsImportFlowModelTests {
  typealias Model = CustomWordsImportFlowModel

  /// Navigation-only tests need no real collaborators, but the model requires
  /// them, so this double fails loudly rather than pretending to work: any
  /// navigation test that reaches the commit path is a test bug, not a pass.
  static func makeModel() -> Model {
    Model(
      dependencies: .init(
        existingWords: { [] },
        commit: { _ in .failed(message: "navigation-only test double") },
        compare: { _, _, _ in [] }
      )
    )
  }

  // Literal fixture arrays: `arguments:` collections are evaluated outside
  // actor isolation, so they must not touch MainActor-isolated statics
  // (swift-testing-patterns.md, mainactor-arguments rule).
  nonisolated static let methodCases: [(Model.Method, Model.Step)] = [
    (.paste, .paste),
    (.upload, .upload),
    (.smartImport, .smartImportAppPicker),
  ]
  nonisolated static let workCases: [Model.Work] = [
    .loadingCandidates, .comparing, .committing,
  ]

  @Test("initial step is the method picker with nothing selected")
  func initialStepIsMethodPicker() {
    let model = Self.makeModel()
    #expect(model.step == .methodPicker)
    #expect(model.selectedMethod == nil)
    #expect(model.canGoBack == false)
  }

  @Test("select moves to the method's input screen and records the method", arguments: methodCases)
  func selectMovesToInputAndRecordsMethod(method: Model.Method, inputStep: Model.Step) {
    let model = Self.makeModel()
    model.select(method)
    #expect(model.step == inputStep)
    #expect(model.selectedMethod == method)
    #expect(model.canGoBack == true)
  }

  @Test("select away from the picker is ignored")
  func selectAwayFromPickerIsIgnored() {
    let model = Self.makeModel()
    model.select(.paste)
    model.select(.upload)
    #expect(model.step == .paste)
    #expect(model.selectedMethod == .paste)
  }

  @Test("back from an input screen returns to the method picker", arguments: methodCases)
  func backFromInputReturnsToMethodPicker(method: Model.Method, inputStep: Model.Step) {
    let model = Self.makeModel()
    model.select(method)
    #expect(model.step == inputStep)
    model.goBack()
    #expect(model.step == .methodPicker)
    #expect(model.selectedMethod == nil)
  }

  @Test("back from review returns to the selected method's input screen", arguments: methodCases)
  func backFromReviewReturnsToSelectedInput(method: Model.Method, inputStep: Model.Step) {
    let model = Self.makeModel()
    model.select(method)
    model.showReview()
    #expect(model.step == .review)
    #expect(model.canGoBack == true)
    model.goBack()
    #expect(model.step == inputStep)
    #expect(model.selectedMethod == method)
  }

  @Test("back while working is ignored", arguments: workCases)
  func backWhileWorkingIsIgnored(work: Model.Work) {
    let model = Self.makeModel()
    model.select(.paste)
    model.beginWork(work)
    #expect(model.canGoBack == false)
    model.goBack()
    #expect(model.step == .working(work))
    #expect(model.selectedMethod == .paste)
  }

  @Test("back on a result is ignored: Done dismisses, there is no Back")
  func backOnResultIsIgnored() {
    let model = Self.makeModel()
    model.select(.paste)
    model.beginWork(.committing)
    model.showResult(.nothingFound)
    #expect(model.canGoBack == false)
    model.goBack()
    #expect(model.step == .result(.nothingFound))
  }

  @Test("reset clears the selected method and returns to the picker")
  func resetClearsSelectedMethodAndReturnsToPicker() {
    let model = Self.makeModel()
    model.select(.upload)
    model.showReview()
    model.reset()
    #expect(model.step == .methodPicker)
    #expect(model.selectedMethod == nil)
  }

  @Test("show review before any method is selected is ignored")
  func showReviewWithoutMethodIsIgnored() {
    let model = Self.makeModel()
    model.showReview()
    #expect(model.step == .methodPicker)
  }

  @Test("begin work is ignored on the picker and on a result")
  func beginWorkIgnoredOnPickerAndResult() {
    let model = Self.makeModel()
    model.beginWork(.loadingCandidates)
    #expect(model.step == .methodPicker)

    model.select(.paste)
    model.beginWork(.committing)
    model.showResult(.nothingFound)
    model.beginWork(.loadingCandidates)
    #expect(model.step == .result(.nothingFound))
  }

  @Test("show result outside a working step is ignored")
  func showResultOutsideWorkingIsIgnored() {
    let model = Self.makeModel()
    model.select(.paste)
    model.showResult(.nothingFound)
    #expect(model.step == .paste)
  }

  @Test("a completed result carries the added and replaced counts")
  func resultCarriesAddedAndReplacedCounts() {
    let model = Self.makeModel()
    model.select(.paste)
    model.beginWork(.committing)
    model.showResult(.completed(added: 3, replaced: 1))
    #expect(model.step == .result(.completed(added: 3, replaced: 1)))
    #expect(model.step != .result(.completed(added: 1, replaced: 3)))
  }

  @Test("nothing-found and failure remain distinct results")
  func nothingFoundAndFailureRemainDistinctResults() {
    let nothingFound = Self.makeModel()
    nothingFound.select(.paste)
    nothingFound.beginWork(.loadingCandidates)
    nothingFound.showResult(.nothingFound)

    let failed = Self.makeModel()
    failed.select(.paste)
    failed.beginWork(.loadingCandidates)
    failed.showResult(.failed(message: "could not read the file"))

    #expect(nothingFound.step == .result(.nothingFound))
    #expect(failed.step == .result(.failed(message: "could not read the file")))
    #expect(nothingFound.step != failed.step)
  }

  // MARK: - Paste draft (#1681)

  @Test("the pasted draft survives going back from review")
  func pasteDraftSurvivesBackFromReview() {
    // Back from Review exists so the user can EDIT what they pasted. Holding
    // the draft in the screen's own state meant the sheet rebuilt an empty
    // editor and silently discarded the list (code review r1).
    let model = Self.makeModel()
    model.select(.paste)
    model.pasteDraft = "Kubernetes\nAnthropic"
    model.beginWork(.comparing)
    model.showReview()
    #expect(model.step == .review)

    model.goBack()

    #expect(model.step == .paste)
    #expect(model.pasteDraft == "Kubernetes\nAnthropic")
  }

  @Test("resetting the sheet clears the pasted draft")
  func resetClearsThePasteDraft() {
    let model = Self.makeModel()
    model.select(.paste)
    model.pasteDraft = "Kubernetes"
    model.reset()
    #expect(model.pasteDraft.isEmpty)
    #expect(model.step == .methodPicker)
  }

  // MARK: - Discardable draft confirmation (#1700)

  @Test("an empty draft has nothing discardable")
  func hasDiscardableDraftIsFalseForEmptyDraft() {
    let model = Self.makeModel()
    model.select(.paste)
    #expect(model.hasDiscardableDraft == false)
  }

  @Test("a whitespace-only draft has nothing discardable")
  func hasDiscardableDraftIsFalseForWhitespaceOnlyDraft() {
    let model = Self.makeModel()
    model.select(.paste)
    model.pasteDraft = "   \n\t "
    #expect(model.hasDiscardableDraft == false)
  }

  @Test("a non-empty draft on the paste screen is discardable")
  func hasDiscardableDraftIsTrueOnPasteStep() {
    let model = Self.makeModel()
    model.select(.paste)
    model.pasteDraft = "Threadripper"
    #expect(model.hasDiscardableDraft == true)
  }

  @Test("a non-empty draft carried into review is still discardable")
  func hasDiscardableDraftIsTrueOnReviewStep() {
    let model = Self.makeModel()
    model.select(.paste)
    model.pasteDraft = "Threadripper"
    model.beginWork(.comparing)
    model.showReview()
    #expect(model.step == .review)
    #expect(model.hasDiscardableDraft == true)
  }

  @Test(
    "an abandoned paste draft is still discardable after completing a DIFFERENT method's import"
  )
  func hasDiscardableDraftIsTrueForAbandonedDraftAfterOtherMethodCompletes() {
    // Codex code-diff review: pasting a draft, backing out to try a different
    // method, and completing THAT method's import must not let the earlier,
    // never-committed paste draft be silently wiped by "nothing to lose"
    // reasoning that only actually applies to the flow that just finished.
    let model = Self.makeModel()
    model.select(.paste)
    model.pasteDraft = "Threadripper"
    model.goBack()
    #expect(model.step == .methodPicker)
    #expect(model.pasteDraft == "Threadripper")

    model.select(.upload)
    model.beginWork(.committing)
    model.showResult(.completed(added: 1, replaced: 0))

    #expect(model.selectedMethod == .upload)
    #expect(model.hasDiscardableDraft == true)
  }

  @Test(
    "an abandoned paste draft is still discardable after a DIFFERENT method's import approves nothing"
  )
  func hasDiscardableDraftIsTrueForAbandonedDraftAfterOtherMethodApprovesNothing() {
    let model = Self.makeModel()
    model.select(.paste)
    model.pasteDraft = "Threadripper"
    model.goBack()

    model.select(.smartImport)
    model.beginWork(.committing)
    model.showResult(.nothingApproved)

    #expect(model.selectedMethod == .smartImport)
    #expect(model.hasDiscardableDraft == true)
  }

  @Test("a completed result has nothing left to discard")
  func hasDiscardableDraftIsFalseWhenCompleted() {
    let model = Self.makeModel()
    model.select(.paste)
    model.pasteDraft = "Threadripper"
    model.beginWork(.committing)
    model.showResult(.completed(added: 1, replaced: 0))
    #expect(model.hasDiscardableDraft == false)
  }

  @Test("a nothing-approved result has nothing left to discard")
  func hasDiscardableDraftIsFalseWhenNothingApproved() {
    let model = Self.makeModel()
    model.select(.paste)
    model.pasteDraft = "Threadripper"
    model.beginWork(.committing)
    model.showResult(.nothingApproved)
    #expect(model.hasDiscardableDraft == false)
  }

  @Test("a failed result still holds an uncommitted draft")
  func failedResultKeepsDraftDiscardable() {
    let model = Self.makeModel()
    model.select(.paste)
    model.pasteDraft = "Threadripper"
    model.beginWork(.committing)
    model.showResult(.failed(message: "Couldn't save"))
    #expect(model.hasDiscardableDraft == true)
  }

  @Test("a nothing-found result still holds an uncommitted draft")
  func nothingFoundResultKeepsDraftDiscardable() {
    let model = Self.makeModel()
    model.select(.paste)
    model.pasteDraft = "Threadripper"
    model.beginWork(.loadingCandidates)
    model.showResult(.nothingFound)
    #expect(model.hasDiscardableDraft == true)
  }

  @Test("an active commit has nothing framed as a discardable draft")
  func hasDiscardableDraftIsFalseDuringCommit() {
    let model = Self.makeModel()
    model.select(.paste)
    model.pasteDraft = "Threadripper"
    model.beginWork(.committing)
    #expect(model.hasDiscardableDraft == false)
  }

  @Test(
    "loading or comparing candidates still counts as a discardable draft",
    arguments: [
      Model.Work.loadingCandidates, .comparing,
    ])
  func hasDiscardableDraftIsTrueDuringLoadOrCompare(work: Model.Work) {
    let model = Self.makeModel()
    model.select(.paste)
    model.pasteDraft = "Threadripper"
    model.beginWork(work)
    #expect(model.hasDiscardableDraft == true)
  }

  @Test("cancel clears the draft and its own predicate")
  func cancelClearsDraftAndItsOwnPredicate() {
    let model = Self.makeModel()
    model.select(.paste)
    model.pasteDraft = "Threadripper"
    model.cancel()
    #expect(model.pasteDraft.isEmpty)
    #expect(model.hasDiscardableDraft == false)
  }

  @Test("going back still preserves a non-empty draft after the cancel() change")
  func goBackStillPreservesDraftAfterCancelChange() {
    let model = Self.makeModel()
    model.select(.paste)
    model.pasteDraft = "Threadripper"
    model.beginWork(.comparing)
    model.showReview()
    model.goBack()
    #expect(model.step == .paste)
    #expect(model.pasteDraft == "Threadripper")
  }

  @Test(
    "keeping a discardable result reopens the pasted draft",
    arguments: [
      Model.Result.nothingFound,
      .failed(message: "Couldn't import"),
    ])
  func keepingDiscardableResultReopensPasteDraft(result: Model.Result) {
    let model = Self.makeModel()
    model.select(.paste)
    model.pasteDraft = "Threadripper"
    model.beginWork(.loadingCandidates)
    model.showResult(result)

    model.keepEditingDiscardableDraft()

    #expect(model.step == .paste)
    #expect(model.selectedMethod == .paste)
    #expect(model.pasteDraft == "Threadripper")
  }
}
