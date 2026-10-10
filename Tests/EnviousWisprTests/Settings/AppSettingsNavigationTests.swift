import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// C2's host preserves shell-owned selection. C4 owns destination/reducer integration.
@MainActor
@Suite("App Settings binding contract (#3385)", .tags(.driftGuard))
struct AppSettingsNavigationTests {

  @Test("App Settings destinations override and remember each tab independently", arguments: AppSettingsTab.allCases)
  func destinations(tab: AppSettingsTab) {
    var state = SettingsNavigationState()
    #expect(state.appSettingsTab == .appearance)
    state.apply(.dictation(.chimes))
    state.apply(.appSettings(.privacy))
    state.apply(.appSettings(tab))
    #expect(state.selectedPage == .appSettings)
    #expect(state.appSettingsTab == tab)
    state.selectSidebar(.history)
    state.selectSidebar(.appSettings)
    #expect(state.appSettingsTab == tab)
    state.selectSidebar(.dictation)
    #expect(state.dictationTab == .chimes)
    #expect(SettingsDestination.appSettings(tab).page == .appSettings)
  }

}
