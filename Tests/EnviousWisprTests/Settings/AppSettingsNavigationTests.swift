import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// C2's host preserves shell-owned selection. C4 owns destination/reducer integration.
@MainActor
@Suite("App Settings selection (#3385)", .tags(.productOutcome))
struct AppSettingsNavigationTests {
  @Test("Returning to App Settings keeps the shell's selected tab", arguments: AppSettingsTab.allCases)
  func rememberedTab(tab: AppSettingsTab) {
    var remembered = tab
    let binding = Binding(get: { remembered }, set: { remembered = $0 })
    let firstVisit = AppSettingsView(selection: binding)
    #expect(firstVisit.selection == tab)
    firstVisit.selection = .licenses
    let returned = AppSettingsView(selection: binding)
    #expect(remembered == .licenses)
    #expect(returned.selection == .licenses)
  }

  @Test("An explicit shell selection overrides the tab the host was given")
  func explicitSelection() {
    var remembered = AppSettingsTab.appearance
    let host = AppSettingsView(selection: Binding(get: { remembered }, set: { remembered = $0 }))
    remembered = .permissions
    #expect(host.selection == .permissions)
    host.selection = .privacy
    #expect(remembered == .privacy)
  }
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
