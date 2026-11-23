import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore

/// #4565 guided tour: when these fail, a user is walked through a page in the wrong order, is
/// told "3 of 9" when only 8 stops show, is told to use a control the screen is not showing, or
/// is left on a stop whose page no longer exists for them.
@Suite("Guided tour plan", .tags(.productOutcome))
struct GuidedTourPlanTests {
  @Test(
    "all nine stops run in the order a new user works, and Recordings drops out when saving is off")
  func orderAndFiltering() {
    let on = GuidedTourPlan(recordingsOn: true)
    #expect(
      on.stops == [
        .keybinds, .history, .dictation, .aiPolish, .dictionary, .snippets, .transcribeFile,
        .meetings, .recordings,
      ])
    #expect(on.count == 9)
    #expect(on.position(of: .dictionary) == 5)

    let off = GuidedTourPlan(recordingsOn: false)
    #expect(off.count == 8, "the progress count matches the stops actually shown")
    #expect(off.stops.last == .meetings)
    #expect(off.position(of: .recordings) == nil)
    #expect(off.next(after: .meetings) == nil, "EnviousMeet is the last stop with saving off")
    #expect(on.next(after: .meetings) == .recordings)
    #expect(on.next(after: .recordings) == nil)
  }

  @Test("a Recordings target moves back to the last remaining stop when saving turns off")
  func targetFollowsTheRun() {
    let off = GuidedTourPlan(recordingsOn: false)
    #expect(off.target(replacing: .recordings) == .meetings)
    #expect(off.target(replacing: .snippets) == .snippets)
  }

  @Test("a stop counts as shown only when the page and the tab with its named control are showing")
  func showingNeedsThePageAndTheTab() {
    var state = SettingsNavigationState()
    state.apply(.dictionary)
    state.dictionaryTab = .vocabularyPacks
    #expect(!GuidedTourStop.dictionary.isShowing(in: state, showingDictationsTab: false))
    state.dictionaryTab = .yourWords
    #expect(GuidedTourStop.dictionary.isShowing(in: state, showingDictationsTab: false))

    state.apply(.dictation(.clipboard))
    #expect(
      GuidedTourStop.dictation.isShowing(in: state, showingDictationsTab: false),
      "Dictation Settings is a page overview: any tab of the page counts")

    state.apply(.appSettings(.appearance))
    #expect(!GuidedTourStop.recordings.isShowing(in: state, showingDictationsTab: false))
    state.apply(.appSettings(.recordings))
    #expect(GuidedTourStop.recordings.isShowing(in: state, showingDictationsTab: false))

    state.apply(.history)
    #expect(!GuidedTourStop.history.isShowing(in: state, showingDictationsTab: false))
    #expect(GuidedTourStop.history.isShowing(in: state, showingDictationsTab: true))
  }

  @Test("the Dictionary stop opens the Your Words tab even when another tab was open")
  func dictionaryStopOpensYourWords() {
    var state = SettingsNavigationState()
    state.apply(.dictionary)
    state.dictionaryTab = .learnFrom
    state.perform(GuidedTourStop.dictionary.intent)
    #expect(state.selectedPage == .dictionary)
    #expect(state.dictionaryTab == .yourWords)
    #expect(GuidedTourStop.dictionary.isShowing(in: state, showingDictationsTab: false))
  }

  @Test("every stop names a fixed analytics value and a sidebar page")
  func everyStopHasFixedNames() {
    let names = GuidedTourStop.allCases.map(\.telemetry.rawValue)
    #expect(Set(names).count == names.count, "each stop has its own name")
    #expect(
      Set(names) == [
        "keybinds", "history", "dictation", "ai_polish", "dictionary", "snippets",
        "transcribe_file", "meetings", "recordings",
      ])
    for stop in GuidedTourStop.allCases {
      var state = SettingsNavigationState()
      state.perform(stop.intent)
      #expect(state.selectedPage == stop.page, "\(stop) lands on its own page")
    }
  }
}
