import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// #4866: it checks the animation each sheet hands to its one container `.animation`, for both
/// settings. The "on" checks failing means a person with macOS Reduce Motion on would see the Snippet
/// or Custom Words import sheet animate a screen change again; the "off" checks failing means the
/// normal look changed. The screen transition itself is not comparable in a unit test, so the live
/// Reduce Motion look stays a founder step on the issue.
@MainActor
@Suite("Import sheets honor Reduce Motion (#4866)", .tags(.productOutcome))
struct ImportSheetReduceMotionTests {

  @Test("Snippet import sheet: no step animation with Reduce Motion on, one with it off")
  func snippetSheetStepAnimation() {
    #expect(SnippetImportSheet.stepAnimation(reduceMotion: true) == nil)
    #expect(SnippetImportSheet.stepAnimation(reduceMotion: false) == .easeInOut(duration: 0.25))
  }

  @Test("Custom Words import sheet: no step animation with Reduce Motion on, one with it off")
  func customWordsSheetStepAnimation() {
    #expect(CustomWordsImportSheet.stepAnimation(reduceMotion: true) == nil)
    #expect(CustomWordsImportSheet.stepAnimation(reduceMotion: false) == .easeInOut(duration: 0.25))
  }
}
