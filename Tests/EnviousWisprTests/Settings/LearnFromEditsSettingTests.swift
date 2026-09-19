import Foundation
import Testing

@testable import EnviousWisprServices

/// The `learnFromEdits` setting (#996 §3.9): ON by default, written to the store
/// only when the key is absent, and an explicit choice survives reconstruction
/// in both directions.
@MainActor
@Suite("Learn-from-edits setting (#996)", .tags(.productOutcome))
struct LearnFromEditsSettingTests {

  private static func freshSuite() -> UserDefaults {
    let name = "ew.learn.settings.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test(
    "a fresh install is ON, and the absent key is written so a later default flip cannot change it")
  func absentKeyIsWrittenOn() {
    let suite = Self.freshSuite()
    #expect(suite.object(forKey: "learnFromEdits") == nil, "precondition: absent")
    let settings = SettingsManager(defaults: suite)
    #expect(settings.learnFromEdits)
    #expect(suite.object(forKey: "learnFromEdits") as? Bool == true)
  }

  @Test("an explicit OFF survives reconstruction and is never rewritten to the default")
  func explicitFalseSurvives() {
    let suite = Self.freshSuite()
    suite.set(false, forKey: "learnFromEdits")
    #expect(SettingsManager(defaults: suite).learnFromEdits == false)
    #expect(suite.object(forKey: "learnFromEdits") as? Bool == false)
    let settings = SettingsManager(defaults: suite)
    settings.learnFromEdits = true
    #expect(SettingsManager(defaults: suite).learnFromEdits)
  }

  @Test("an explicit ON stays ON, and turning it off persists and fires the change key")
  func explicitTrueAndChange() {
    let suite = Self.freshSuite()
    suite.set(true, forKey: "learnFromEdits")
    let settings = SettingsManager(defaults: suite)
    #expect(settings.learnFromEdits)
    var changed: [SettingsManager.SettingKey] = []
    settings.onChange = { changed.append($0) }
    settings.learnFromEdits = false
    #expect(changed == [.learnFromEdits])
    #expect(SettingsManager(defaults: suite).learnFromEdits == false)
  }

  @Test("the key is unified across builds")
  func inUnifiedKeySet() {
    #expect(SettingsManager.unifiedDefaultsKeys.contains("learnFromEdits"))
    #expect(SettingsManager.unifiedDefaultsKeys.filter { $0 == "learnFromEdits" }.count == 1)
  }
}
