import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// #3853: the "Unload polish model after" choice persists, defaults to Never and does not share
/// storage with the speech model's unload choice. When one of these fails, a user's choice is lost
/// on relaunch, a new install frees its polish model without being asked, or changing one choice
/// silently changes the other.
@MainActor
@Suite("Polish model unload setting", .tags(.productOutcome))
struct LocalPolishUnloadPolicySettingTests {
  private static func freshSuite() -> UserDefaults {
    let name = "ew.local.polish.unload.\(UUID().uuidString)"
    let defaults = TestDefaults.suite(name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test("a fresh install and an unknown stored value both load as Never")
  func defaultsToNever() {
    #expect(SettingsManager(defaults: Self.freshSuite()).localPolishUnloadPolicy == .never)
    let garbage = Self.freshSuite()
    garbage.set("soon", forKey: "localPolishUnloadPolicy")
    #expect(SettingsManager(defaults: garbage).localPolishUnloadPolicy == .never)
  }

  @Test("every choice survives relaunch and fires its own change key")
  func everyChoicePersists() {
    for policy in ModelUnloadPolicy.allCases {
      let suite = Self.freshSuite()
      let settings = SettingsManager(defaults: suite)
      // Start from a different value so the write is a real change.
      settings.localPolishUnloadPolicy = policy == .never ? .immediately : .never
      var changed: [SettingsManager.SettingKey] = []
      settings.onChange = { changed.append($0) }
      settings.localPolishUnloadPolicy = policy
      #expect(changed == [.localPolishUnloadPolicy], "\(policy)")
      #expect(suite.string(forKey: "localPolishUnloadPolicy") == policy.rawValue)
      #expect(SettingsManager(defaults: suite).localPolishUnloadPolicy == policy)
    }
    #expect(SettingsManager.unifiedDefaultsKeys.filter { $0 == "localPolishUnloadPolicy" }.count == 1)
  }

  @Test("the polish choice and the speech choice are stored apart")
  func separateFromSpeechChoice() {
    let suite = Self.freshSuite()
    let settings = SettingsManager(defaults: suite)
    settings.localPolishUnloadPolicy = .twoMinutes
    #expect(settings.modelUnloadPolicy == .never)
    settings.modelUnloadPolicy = .sixtyMinutes
    #expect(settings.localPolishUnloadPolicy == .twoMinutes)
    let reloaded = SettingsManager(defaults: suite)
    #expect(reloaded.localPolishUnloadPolicy == .twoMinutes)
    #expect(reloaded.modelUnloadPolicy == .sixtyMinutes)
  }
}
