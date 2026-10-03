import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// C2's host preserves shell-owned selection. C4 owns destination/reducer integration.
@MainActor
@Suite("App Settings binding contract (#3385)", .tags(.driftGuard))
struct AppSettingsNavigationTests {
  @Test("The host binding writes through to its owner", arguments: AppSettingsTab.allCases)
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

  @Test("The host binding reads its owner's changes")
  func explicitSelection() {
    var remembered = AppSettingsTab.appearance
    let host = AppSettingsView(selection: Binding(get: { remembered }, set: { remembered = $0 }))
    remembered = .permissions
    #expect(host.selection == .permissions)
    host.selection = .privacy
    #expect(remembered == .privacy)
  }
}
