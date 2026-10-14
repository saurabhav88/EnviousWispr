import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// #3737 Casual mode: the switch reaches the snapshots and the settings telemetry. When one of these
/// fails, an imported recording loses its final full stop, or adoption of the switch cannot be counted.
@MainActor
@Suite("Casual mode setting (#3737)", .tags(.productOutcome))
struct CasualModeSettingTests {

  private static func freshSuite() -> UserDefaults {
    let name = "ew.casual.mode.\(UUID().uuidString)"
    let defaults = TestDefaults.suite(name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test("a file import never runs Casual mode, even with the switch on")
  func fileImportFreezesOff() {
    let settings = SettingsManager(defaults: Self.freshSuite())
    settings.casualModeEnabled = true
    #expect(FileImportSettingsFreeze.snapshot(settings: settings).casualModeEnabled == false)
  }

  @Test("the settings telemetry reports the switch as on or off")
  func settingsTelemetryProjection() {
    let settings = SettingsManager(defaults: Self.freshSuite())
    #expect(SettingsProjection.logicals(for: .casualModeEnabled) == [.casualMode])
    #expect(SettingsProjection.Logical.casualMode.rawValue == "casual_mode")
    #expect(SettingsProjection.snapshotConfig(settings)["casual_mode"] == "off")
    settings.casualModeEnabled = true
    #expect(SettingsProjection.snapshotConfig(settings)["casual_mode"] == "on")
  }
}
