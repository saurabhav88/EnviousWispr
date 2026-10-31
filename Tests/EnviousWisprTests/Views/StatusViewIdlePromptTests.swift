import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #4257: with nothing selected on the Meetings tab, the right pane must not tell the user to
/// start dictating. When this fails, a user looking at their meetings is told to press record to
/// dictate.
@MainActor
@Suite(
  "History idle pane: dictation prompt only off the Meetings tab (#4257)", .tags(.productOutcome))
struct StatusViewIdlePromptTests {
  @Test("the Meetings tab never shows the dictation prompt")
  func meetingsTabHidesDictationPrompt() {
    #expect(StatusView.showsDictationPrompt(filter: .recordings) == false)
  }

  @Test("every other History tab keeps the dictation prompt")
  func otherTabsKeepDictationPrompt() {
    for filter in HistoryFilter.allCases where filter != .recordings {
      #expect(StatusView.showsDictationPrompt(filter: filter), "\(filter)")
    }
  }
}
