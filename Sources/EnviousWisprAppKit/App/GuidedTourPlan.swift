import EnviousWisprCore
import Foundation

/// #4565: one stop of the guided tour. The stop list is an allowlist: a page that is not a case
/// here is never a stop.
enum GuidedTourStop: String, CaseIterable, Equatable, Sendable {
  case keybinds
  case history
  case dictation
  case aiPolish
  case dictionary
  case snippets
  case transcribeFile
  case meetings
  case recordings

  /// The sidebar page the stop teaches. The card's title is this page's own label, so it reads
  /// the way the sidebar does in every language.
  var page: SettingsPage {
    switch self {
    case .keybinds: .keybinds
    case .history: .history
    case .dictation: .dictation
    case .aiPolish: .aiPolish
    case .dictionary: .dictionary
    case .snippets: .snippets
    case .transcribeFile: .transcribeFile
    case .meetings: .meetings
    case .recordings: .appSettings
    }
  }

  /// The card's title: the sidebar's own label for the page. Every tour page has one; the
  /// fallback is the stop's own name as a non-literal, so it is never a catalog key.
  var pageTitle: LocalizedStringResource {
    page.labelResource ?? LocalizedStringResource(String.LocalizationValue(rawValue))
  }

  /// The navigation the stop requests, through the same guarded path every other request takes.
  var intent: SettingsNavigationIntent {
    switch self {
    case .keybinds: .destination(.keybinds)
    case .history: .destination(.history)
    case .dictation: .destination(.dictation(.engine))
    case .aiPolish: .destination(.aiPolish)
    case .dictionary: .dictionaryTab(.yourWords)
    case .snippets: .destination(.snippets)
    case .transcribeFile: .destination(.transcribeFile)
    case .meetings: .destination(.meetings(.general))
    case .recordings: .destination(.appSettings(.recordings))
    }
  }

  /// Whether the stop's page, and the tab holding the control its sentence names, is what the
  /// window shows now. Dictation and the other page-level stops accept any tab of their page.
  func isShowing(in state: SettingsNavigationState, showingDictationsTab: Bool) -> Bool {
    switch self {
    case .history:
      state.selectedPage == .history && showingDictationsTab
    case .dictionary:
      state.isShowing(.dictionary, dictionaryTab: .yourWords)
    case .recordings:
      state.isShowing(.appSettings(.recordings), dictionaryTab: nil)
    case .keybinds, .dictation, .aiPolish, .snippets, .transcribeFile, .meetings:
      state.selectedPage == page
    }
  }

  /// The fixed value the analytics event carries for this stop.
  var telemetry: GuidedTourTelemetry.Stop {
    switch self {
    case .keybinds: .keybinds
    case .history: .history
    case .dictation: .dictation
    case .aiPolish: .aiPolish
    case .dictionary: .dictionary
    case .snippets: .snippets
    case .transcribeFile: .transcribeFile
    case .meetings: .meetings
    case .recordings: .recordings
    }
  }
}

/// #4565: the stops one run of the tour walks, in order, for the user's current settings. A stop
/// shows only when its page is visible to that user, so the progress count matches what is shown:
/// Recordings drops out when saving dictation recordings is off.
struct GuidedTourPlan: Equatable {
  let stops: [GuidedTourStop]

  init(recordingsOn: Bool) {
    stops = GuidedTourStop.allCases.filter { $0 != .recordings || recordingsOn }
  }

  var count: Int { stops.count }
  var first: GuidedTourStop { stops[0] }
  var last: GuidedTourStop { stops[stops.count - 1] }

  /// 1-based position for "n of N", or nil when the stop is not in this run.
  func position(of stop: GuidedTourStop) -> Int? {
    stops.firstIndex(of: stop).map { $0 + 1 }
  }

  func next(after stop: GuidedTourStop) -> GuidedTourStop? {
    guard let index = stops.firstIndex(of: stop), index + 1 < stops.count else { return nil }
    return stops[index + 1]
  }

  /// The stop to move to when `stop` is no longer in the run (saving turned off while Recordings
  /// was the target): the last stop that remains.
  func target(replacing stop: GuidedTourStop) -> GuidedTourStop {
    stops.contains(stop) ? stop : last
  }
}
