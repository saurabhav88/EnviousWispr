import Foundation
import Testing

@testable import EnviousWisprServices

/// #3252, plan 3.5 / T6: the two stored telemetry switches (#3269) are read before any
/// `SettingsManager` exists, when a bad-location launch asks the Move question first. When this
/// breaks, the early `initialize` starts PostHog or Sentry from a different answer than the person
/// gave, and that answer holds for the whole run. Expected values are typed here.
@MainActor
@Suite("Stored telemetry switches (#3252)", .tags(.productOutcome))
struct StoredTelemetrySwitchesTests {

  private static func freshSuite() throws -> UserDefaults {
    try #require(TestDefaults.suite("ew-3252-switches-\(UUID().uuidString)"))
  }

  @Test("Absent keys read ON for both switches, and the read writes nothing")
  func absentKeysReadOn() throws {
    let suite = try Self.freshSuite()
    let switches = SettingsManager.storedTelemetrySwitches(defaults: suite)
    #expect(switches.usageMetrics == true)
    #expect(switches.crashReports == true)
    #expect(suite.object(forKey: "shareUsageMetrics") == nil)
    #expect(suite.object(forKey: "sendCrashReports") == nil)
  }

  @Test(
    "Every explicit combination is read back as stored",
    arguments: [(true, true), (true, false), (false, true), (false, false)])
  func explicitCombinations(usage: Bool, crash: Bool) throws {
    let suite = try Self.freshSuite()
    suite.set(usage, forKey: "shareUsageMetrics")
    suite.set(crash, forKey: "sendCrashReports")
    let switches = SettingsManager.storedTelemetrySwitches(defaults: suite)
    #expect(switches.usageMetrics == usage)
    #expect(switches.crashReports == crash)
  }

  @Test("One explicit OFF leaves the other, absent, switch ON", arguments: [true, false])
  func oneKeyAloneDoesNotMoveTheOther(usageIsTheStoredOne: Bool) throws {
    let suite = try Self.freshSuite()
    suite.set(false, forKey: usageIsTheStoredOne ? "shareUsageMetrics" : "sendCrashReports")
    let switches = SettingsManager.storedTelemetrySwitches(defaults: suite)
    #expect(switches.usageMetrics == !usageIsTheStoredOne)
    #expect(switches.crashReports == usageIsTheStoredOne)
  }

  @Test("A stored value that is not a Bool reads as the shipped default, ON")
  func nonBoolValueReadsDefault() throws {
    let suite = try Self.freshSuite()
    suite.set("no", forKey: "shareUsageMetrics")
    suite.set("off", forKey: "sendCrashReports")
    let switches = SettingsManager.storedTelemetrySwitches(defaults: suite)
    // A String is not a Bool, so neither key counts as an answer.
    #expect(switches.usageMetrics == true)
    #expect(switches.crashReports == true)
  }

  @Test("The reader and a SettingsManager built on the same store agree for every combination")
  func readerAgreesWithTheManager() throws {
    for (usage, crash) in [(true, true), (true, false), (false, true), (false, false)] {
      let suite = try Self.freshSuite()
      suite.set(usage, forKey: "shareUsageMetrics")
      suite.set(crash, forKey: "sendCrashReports")
      let settings = SettingsManager(defaults: suite)
      #expect(settings.shareUsageMetrics == usage)
      #expect(settings.sendCrashReports == crash)
      let switches = SettingsManager.storedTelemetrySwitches(defaults: suite)
      #expect(switches.usageMetrics == settings.shareUsageMetrics)
      #expect(switches.crashReports == settings.sendCrashReports)
    }
  }

  @Test("A nil store resolves to SettingsDefaults.store, the authority the initializer uses")
  func nilStoreRoutesToTheSettingsStore() {
    // Read both keys straight from the store with the shipped default, not through the subject.
    let store = SettingsDefaults.store
    let expectedUsage = store.object(forKey: "shareUsageMetrics") as? Bool ?? true
    let expectedCrash = store.object(forKey: "sendCrashReports") as? Bool ?? true
    let switches = SettingsManager.storedTelemetrySwitches()
    #expect(switches.usageMetrics == expectedUsage)
    #expect(switches.crashReports == expectedCrash)
  }
}
