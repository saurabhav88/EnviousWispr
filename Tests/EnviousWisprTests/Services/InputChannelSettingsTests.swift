import AppKit
import Foundation
import Testing

@testable import EnviousWisprServices

/// #2664: the per-device "Microphone socket" choice must survive a relaunch and
/// must never take the app down when the stored blob is unreadable. When this
/// fails, the user sees their chosen socket forgotten after a restart, or every
/// device silently back on Input 1. Every case uses an ephemeral suite so nothing
/// touches the real store.
@MainActor
@Suite("SettingsManager inputChannelByDeviceUID — #2664", .tags(.productOutcome))
struct InputChannelSettingsTests {
  init() { _ = NSApplication.shared }  // @MainActor AppKit-touching SUT (swift-patterns)

  private static func freshSuite() -> UserDefaults {
    let name = "ew.inputChannelTest." + UUID().uuidString
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
  }

  @Test("a fresh install has no socket choices: every device records from Input 1")
  func freshInstallIsEmpty() {
    let settings = SettingsManager(defaults: Self.freshSuite())
    #expect(settings.inputChannelByDeviceUID == [:])
    #expect(settings.inputChannelByDeviceUID == SettingsDefaultValues.inputChannelByDeviceUID)
  }

  @Test("a saved map survives relaunch, keyed by device UID")
  func savedMapSurvivesRelaunch() {
    let suite = Self.freshSuite()
    let first = SettingsManager(defaults: suite)
    first.inputChannelByDeviceUID = ["scarlett-2i2-uid": 1, "six-input-uid": 4]

    // The write lands as JSON Data under the one key, in the injected store.
    let stored = suite.data(forKey: "inputChannelByDeviceUID")
    #expect(stored != nil)

    let relaunched = SettingsManager(defaults: suite)
    #expect(relaunched.inputChannelByDeviceUID == ["scarlett-2i2-uid": 1, "six-input-uid": 4])
  }

  @Test("an undecodable stored blob loads as an empty map, never a crash or a stale value")
  func undecodableBlobLoadsEmpty() {
    let suite = Self.freshSuite()
    suite.set(Data("not json at all".utf8), forKey: "inputChannelByDeviceUID")
    let settings = SettingsManager(defaults: suite)
    #expect(settings.inputChannelByDeviceUID == [:])

    // A JSON value of the wrong SHAPE is undecodable too.
    suite.set(Data("[1, 2, 3]".utf8), forKey: "inputChannelByDeviceUID")
    #expect(SettingsManager(defaults: suite).inputChannelByDeviceUID == [:])
  }

  @Test("changing the map emits its own SettingKey exactly once")
  func changeEmitsKeyOnce() {
    let settings = SettingsManager(defaults: Self.freshSuite())
    var seen: [SettingsManager.SettingKey] = []
    settings.onChange = { seen.append($0) }
    settings.inputChannelByDeviceUID = ["scarlett-2i2-uid": 1]
    #expect(seen.filter { $0 == .inputChannelByDeviceUID }.count == 1)
  }

  @Test("the key belongs to the unified defaults set exactly once")
  func keyIsUnified() {
    #expect(
      SettingsManager.unifiedDefaultsKeys.filter { $0 == "inputChannelByDeviceUID" }.count == 1)
  }
}
