import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// #3034 — the "Switching from another dictation app?" card opens the import on the app picker
/// without scanning the Mac.
///
/// `.productOutcome`: when this fails the card opens the wrong screen, names the wrong apps, or
/// the Mac is searched for installed apps before the user asked to see that list.
@MainActor
@Suite("Switching from another app card (#3034)", .tags(.productOutcome))
struct SwitchingFromAnotherAppTests {

  /// Counts calls to the injected installed-app check.
  final class DetectSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func detect() -> [String] {
      lock.withLock { count += 1 }
      return []
    }
    var calls: Int { lock.withLock { count } }
  }

  static func wordsDependencies(_ spy: DetectSpy)
    -> CustomWordsImportFlowModel.Dependencies
  {
    CustomWordsImportFlowModel.Dependencies(
      existingWords: { [] },
      commit: { _ in .stale },
      compare: { _, _, _ in [] },
      report: { _ in },
      detectInstalled: { spy.detect() })
  }

  static func snippetDependencies(_ spy: DetectSpy)
    -> SnippetImportFlowModel.Dependencies
  {
    SnippetImportFlowModel.Dependencies(
      existingSnippets: { [] },
      commit: { _ in .stale },
      report: { _, _ in },
      fileReviewCommitMismatch: { _, _ in },
      detectInstalled: { spy.detect() })
  }

  // MARK: - Direct entry

  @Test("The words flow starts on the app picker, and Back returns to the method picker")
  func wordsStartOnAppPicker() {
    let spy = DetectSpy()
    for _ in 0..<2 {  // a second presentation starts at the picker too
      let model = CustomWordsImportFlowModel.starting(
        at: .smartImport, dependencies: Self.wordsDependencies(spy))
      #expect(model.step == .smartImportAppPicker)
      #expect(model.selectedMethod == .smartImport)
      model.goBack()
      #expect(model.step == .methodPicker)
    }
  }

  @Test("The snippets flow starts on the app picker, and Back returns to the method picker")
  func snippetsStartOnAppPicker() {
    let spy = DetectSpy()
    for _ in 0..<2 {
      let model = SnippetImportFlowModel.starting(
        at: .app, dependencies: Self.snippetDependencies(spy))
      #expect(model.step == .appPicker)
      #expect(model.selectedMethod == .app)
      model.goBack()
      #expect(model.step == .methodPicker)
    }
  }

  @Test("The ordinary Import button still opens the method picker")
  func plainInitStartsOnMethodPicker() {
    let spy = DetectSpy()
    #expect(
      CustomWordsImportFlowModel(dependencies: Self.wordsDependencies(spy)).step == .methodPicker)
    #expect(
      SnippetImportFlowModel(dependencies: Self.snippetDependencies(spy)).step == .methodPicker)
  }

  // MARK: - No scan

  @Test("Opening the picker flow does not check the Mac; only the picker's own call does")
  func entryDoesNotScan() {
    let spy = DetectSpy()
    let words = CustomWordsImportFlowModel.starting(
      at: .smartImport, dependencies: Self.wordsDependencies(spy))
    let snippets = SnippetImportFlowModel.starting(
      at: .app, dependencies: Self.snippetDependencies(spy))
    #expect(spy.calls == 0, "starting on the app picker must not search the Mac")

    // Positive control: the closure the picker screens run is this spy, so a count of 0 above
    // means "not called", not "not wired".
    _ = words.detectInstalledApps()
    _ = snippets.detectInstalledApps()
    #expect(spy.calls == 2)
  }

  /// What this proves and what it does not: the card's only inputs are a line of text and an
  /// action, so it cannot reach a detector; a scan added to its body would not be caught here.
  /// The scan-on-picker-only behaviour is bound by `entryDoesNotScan` (the flow models) and
  /// checked live in the running app.
  @Test("The card renders from a line of text and an action alone")
  func cardRendersFromTextAndActionOnly() {
    let card = SwitchingFromAnotherAppCard(subtitle: "Bring your words across from Vox.") {}
    let host = NSHostingView(rootView: card.frame(width: 600))
    host.layoutSubtreeIfNeeded()
    #expect(host.fittingSize.height > 0)
  }

  // MARK: - Copy and routes

  @Test("The Dictionary line names every app the words import reads")
  func wordsLineNamesEveryApp() {
    let names = SmartImportRegistry.v1.displayNames
    let line = SwitchingFromAnotherAppCopy.wordsSubtitle(names: names)
    for literal in [
      "Wispr Flow", "FluidVoice", "Superwhisper", "Vox", "TypeWhisper", "Spokenly", "Juno", "Handy",
    ] {
      #expect(line.contains(literal), "Dictionary card omits \(literal)")
    }
  }

  @Test("The Snippets line names only the apps the snippets import reads")
  func snippetsLineNamesOnlySnippetApps() {
    let line = SwitchingFromAnotherAppCopy.snippetsSubtitle(
      names: SnippetImportAppRegistry.v1.displayNames)
    #expect(line.contains("Wispr Flow"))
    #expect(line.contains("TypeWhisper"))
    for other in ["Superwhisper", "FluidVoice", "Vox", "Spokenly", "Juno", "Handy"] {
      #expect(line.contains(other) == false, "Snippets card names \(other), which it cannot read")
    }
  }

  @Test("The card's snippet route is its own presentation; the Import button route is unchanged")
  func snippetRouteIdentities() {
    #expect(SnippetsSheetRoute.importSnippets.id == "import")
    #expect(SnippetsSheetRoute.importSnippetsFromApp.id == "import-from-app")
    #expect(SnippetsSheetRoute.importSnippetsFromApp.id != SnippetsSheetRoute.importSnippets.id)
  }
}
