import Foundation
import Testing

@testable import EnviousWisprServices

/// The `crashRecoveryEnabled` setting (#1063 PR0): default ON, persists to the
/// injected store, and is part of the unified cross-build key set.
@MainActor
@Suite("Crash-recovery setting (#1063)")
struct SettingsManagerCrashRecoveryTests {

  private static func freshSuite() -> UserDefaults {
    let name = "ew.recovery.settings.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test("a fresh install defaults crash recovery ON")
  func defaultsOn() {
    let settings = SettingsManager(defaults: Self.freshSuite())
    #expect(settings.crashRecoveryEnabled)
  }

  @Test("turning it off persists to the injected store")
  func persistsWhenChanged() {
    let suite = Self.freshSuite()
    let settings = SettingsManager(defaults: suite)
    settings.crashRecoveryEnabled = false
    #expect(SettingsManager(defaults: suite).crashRecoveryEnabled == false)
  }

  @Test("the setting is unified across builds")
  func inUnifiedKeySet() {
    #expect(SettingsManager.unifiedDefaultsKeys.contains("crashRecoveryEnabled"))
  }
}
