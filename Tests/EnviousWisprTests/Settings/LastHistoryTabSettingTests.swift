import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// History opens on the tab the user left it on (#3147 §3.3). An absent or unknown value reads
/// as Dictations, and loading never writes the key.
@MainActor
/// Class: `.productOutcome` — the tab a person sees when History opens.
@Suite("Last History tab memory (#3147)", .tags(.productOutcome))
struct LastHistoryTabSettingTests {

  private static func freshSuite() -> UserDefaults {
    let name = "ew.lastHistoryTab.\(UUID().uuidString)"
    let defaults = TestDefaults.suite(name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test("absent reads Dictations and stays absent")
  func absentReadsDictations() {
    let suite = Self.freshSuite()
    #expect(SettingsManager(defaults: suite).lastHistoryTab == .dictations)
    #expect(suite.object(forKey: "lastHistoryTab") == nil)
  }

  @Test("a chosen tab survives reconstruction; an unknown value reads Dictations")
  func chosenTabSurvives() {
    let suite = Self.freshSuite()
    SettingsManager(defaults: suite).lastHistoryTab = .meetings
    #expect(SettingsManager(defaults: suite).lastHistoryTab == .meetings)
    suite.set("recordings", forKey: "lastHistoryTab")
    #expect(SettingsManager(defaults: suite).lastHistoryTab == .dictations)
  }

  @Test("the key is unified across builds")
  func inUnifiedKeySet() {
    #expect(SettingsManager.unifiedDefaultsKeys.filter { $0 == "lastHistoryTab" }.count == 1)
  }
}
