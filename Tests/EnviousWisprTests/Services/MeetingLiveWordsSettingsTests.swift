import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// #4105: the stored live words engine and language.
///
/// **What the user sees when this fails:** a fresh install starts with an engine nobody chose,
/// a choice is lost on relaunch, clearing it leaves a stale value behind, or a bogus stored value
/// becomes a choice.
///
/// Stored values are written and read as literal strings, independent of the setting's own code.
@MainActor
@Suite("Meeting live words settings (#4105)", .tags(.productOutcome))
struct MeetingLiveWordsSettingsTests {

  private static func freshSuite() -> UserDefaults {
    let name = "ew.meeting.livewords.\(UUID().uuidString)"
    let defaults = TestDefaults.suite(name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test("A fresh install has no engine and no language, and writes nothing")
  func absentIsUnset() {
    let defaults = Self.freshSuite()
    let settings = SettingsManager(defaults: defaults)
    #expect(settings.meetingLiveWordsEngine == nil)
    #expect(settings.meetingLiveWordsLanguage == nil)
    #expect(defaults.object(forKey: "meetingLiveWordsEngine") == nil)
    #expect(defaults.object(forKey: "meetingLiveWordsLanguage") == nil)
  }

  @Test("A choice survives a relaunch, and clearing it removes it")
  func roundTripAndClear() {
    let defaults = Self.freshSuite()
    let settings = SettingsManager(defaults: defaults)
    settings.meetingLiveWordsEngine = .apple
    settings.meetingLiveWordsLanguage = "fr-CA"
    #expect(defaults.string(forKey: "meetingLiveWordsEngine") == "apple")
    #expect(defaults.string(forKey: "meetingLiveWordsLanguage") == "fr-CA")

    let relaunched = SettingsManager(defaults: defaults)
    #expect(relaunched.meetingLiveWordsEngine == .apple)
    #expect(relaunched.meetingLiveWordsLanguage == "fr-CA")

    relaunched.meetingLiveWordsEngine = nil
    relaunched.meetingLiveWordsLanguage = nil
    #expect(defaults.object(forKey: "meetingLiveWordsEngine") == nil)
    #expect(defaults.object(forKey: "meetingLiveWordsLanguage") == nil)
    #expect(SettingsManager(defaults: defaults).meetingLiveWordsEngine == nil)
  }

  @Test("An unknown or empty stored value loads as unset")
  func bogusValuesAreUnset() {
    let defaults = Self.freshSuite()
    defaults.set("dictation", forKey: "meetingLiveWordsEngine")
    defaults.set("", forKey: "meetingLiveWordsLanguage")
    let settings = SettingsManager(defaults: defaults)
    #expect(settings.meetingLiveWordsEngine == nil)
    #expect(settings.meetingLiveWordsLanguage == nil)
  }

  @Test("Every write advances the generation, even the same value")
  func generationAdvancesOnEveryWrite() {
    let settings = SettingsManager(defaults: Self.freshSuite())
    let start = settings.meetingLiveWordsChoiceGeneration
    settings.meetingLiveWordsEngine = .universal
    settings.meetingLiveWordsEngine = .universal
    settings.meetingLiveWordsLanguage = nil
    #expect(settings.meetingLiveWordsChoiceGeneration == start + 3)
  }

  @Test("Saving both together notifies only after both are written")
  func commitIsAtomicForObservers() {
    let settings = SettingsManager(defaults: Self.freshSuite())
    var seen: [(SettingsManager.SettingKey, LivePreviewEngineChoice?, String?)] = []
    settings.onChange = { key in
      seen.append((key, settings.meetingLiveWordsEngine, settings.meetingLiveWordsLanguage))
    }
    settings.commitMeetingLiveWordsChoice(engine: .apple, language: "en-US")
    #expect(seen.map(\.0) == [.meetingLiveWordsEngine, .meetingLiveWordsLanguage])
    #expect(seen.allSatisfy { $0.1 == .apple && $0.2 == "en-US" })
  }

  @Test("The keys are unified across builds")
  func keysAreUnified() {
    #expect(SettingsManager.unifiedDefaultsKeys.contains("meetingLiveWordsEngine"))
    #expect(SettingsManager.unifiedDefaultsKeys.contains("meetingLiveWordsLanguage"))
  }
}
