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
}
