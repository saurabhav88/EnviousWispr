import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// #3973 (decision 16): EnviousMeet's own language setting. When one of these fails, a meeting
/// transcribes in a language the user picked for dictation, a bad stored value locks meetings into
/// a language that does not exist, or changing the meeting language changes dictation.
///
/// Stored values are written and checked as literal JSON, independent of `LanguageMode`'s coder.
@MainActor
@Suite("EnviousMeet language setting (#3973)", .tags(.productOutcome))
struct MeetingLanguageSettingTests {

  private static let key = "meetingLanguageMode"

  private static func freshSuite() -> UserDefaults {
    let name = "ew.meeting.language.\(UUID().uuidString)"
    let defaults = TestDefaults.suite(name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  private static func store(_ json: String, in defaults: UserDefaults, key: String = key) {
    defaults.set(Data(json.utf8), forKey: key)
  }

  /// The stored value as a plain dictionary, or nil when absent or not a JSON object.
  private static func stored(_ defaults: UserDefaults, key: String = key) -> [String: String]? {
    guard let data = defaults.data(forKey: key),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
    else { return nil }
    return object
  }

  @Test("a fresh install loads Auto and writes nothing")
  func absentIsAuto() {
    let defaults = Self.freshSuite()
    #expect(SettingsManager(defaults: defaults).meetingLanguageMode == .auto)
    #expect(defaults.object(forKey: Self.key) == nil, "loading never seeds the key")
  }

  @Test("a locked language is stored in the shared shape and survives relaunch")
  func lockedRoundTrips() {
    let defaults = Self.freshSuite()
    SettingsManager(defaults: defaults).meetingLanguageMode = .locked("de")
    #expect(Self.stored(defaults) == ["mode": "locked", "code": "de"])
    #expect(SettingsManager(defaults: defaults).meetingLanguageMode == .locked("de"))
    // A stored code in another case loads normalized.
    Self.store(#"{"mode":"locked","code":"JA"}"#, in: defaults)
    #expect(SettingsManager(defaults: defaults).meetingLanguageMode == .locked("ja"))
  }

  @Test("choosing Auto again is stored and survives relaunch")
  func autoRoundTrips() {
    let defaults = Self.freshSuite()
    Self.store(#"{"mode":"locked","code":"hi"}"#, in: defaults)
    let settings = SettingsManager(defaults: defaults)
    #expect(settings.meetingLanguageMode == .locked("hi"))
    settings.meetingLanguageMode = .auto
    #expect(Self.stored(defaults) == ["mode": "auto"])
    #expect(SettingsManager(defaults: defaults).meetingLanguageMode == .auto)
  }

  @Test("an undecodable stored value loads as Auto and is left as it was")
  func malformedIsAuto() {
    let cases: [(String, (UserDefaults) -> Void)] = [
      ("bytes", { $0.set(Data([0xFF, 0x00, 0x7B]), forKey: Self.key) }),
      ("a string, not data", { $0.set("auto", forKey: Self.key) }),
      ("an unknown mode", { Self.store(#"{"mode":"sometimes"}"#, in: $0) }),
      ("locked without a code", { Self.store(#"{"mode":"locked"}"#, in: $0) }),
    ]
    for (label, write) in cases {
      let defaults = Self.freshSuite()
      write(defaults)
      let before = defaults.object(forKey: Self.key) as? NSObject
      #expect(SettingsManager(defaults: defaults).meetingLanguageMode == .auto, "\(label)")
      #expect(defaults.object(forKey: Self.key) as? NSObject == before, "\(label): not rewritten")
    }
  }

  @Test("an empty or unsupported language code loads as Auto")
  func unsupportedIsAuto() {
    for code in ["", "xx", "klingon", "en-GB"] {
      let defaults = Self.freshSuite()
      Self.store(#"{"mode":"locked","code":"\#(code)"}"#, in: defaults)
      #expect(SettingsManager(defaults: defaults).meetingLanguageMode == .auto, "\(code)")
    }
  }

  @Test("dictation's language and spelling never populate the meeting language")
  func dictationDoesNotPopulate() {
    let defaults = Self.freshSuite()
    Self.store(#"{"mode":"locked","code":"de"}"#, in: defaults, key: "languageMode")
    defaults.set("british", forKey: "englishSpelling")
    let settings = SettingsManager(defaults: defaults)
    #expect(settings.languageMode == .locked("de"), "control: dictation's language loaded")
    #expect(settings.meetingLanguageMode == .auto)
    #expect(defaults.object(forKey: Self.key) == nil)
  }

  @Test("the legacy Whisper language migrates dictation's setting only")
  func legacyLanguageDoesNotPopulate() {
    let defaults = Self.freshSuite()
    defaults.set("ta", forKey: "whisperKitLanguage")
    let settings = SettingsManager(defaults: defaults)
    #expect(settings.languageMode == .locked("ta"), "control: dictation's migration ran")
    #expect(settings.meetingLanguageMode == .auto)
    #expect(defaults.object(forKey: Self.key) == nil)
  }

  @Test("changing the meeting language leaves every dictation language value as it was")
  func meetingChangeLeavesDictation() {
    let defaults = Self.freshSuite()
    Self.store(#"{"mode":"locked","code":"fr"}"#, in: defaults, key: "languageMode")
    defaults.set("fr", forKey: "whisperKitLanguage")
    defaults.set("british", forKey: "englishSpelling")
    let settings = SettingsManager(defaults: defaults)
    settings.meetingLanguageMode = .locked("hi")
    #expect(settings.languageMode == .locked("fr"))
    #expect(settings.whisperKitLanguage == "fr")
    #expect(settings.englishSpelling == .british)
    #expect(Self.stored(defaults, key: "languageMode") == ["mode": "locked", "code": "fr"])
    #expect(defaults.string(forKey: "whisperKitLanguage") == "fr")
    #expect(defaults.string(forKey: "englishSpelling") == "british")
    // And the other way: dictation changes leave the meeting language alone.
    settings.languageMode = .locked("ja")
    #expect(settings.meetingLanguageMode == .locked("hi"))
    #expect(Self.stored(defaults) == ["mode": "locked", "code": "hi"])
  }

  @Test("a change fires its own key once, after the value is stored")
  func changeFiresAfterPersisting() {
    let defaults = Self.freshSuite()
    let settings = SettingsManager(defaults: defaults)
    var fired: [SettingsManager.SettingKey] = []
    var storedAtNotice: [[String: String]?] = []
    settings.onChange = { key in
      fired.append(key)
      storedAtNotice.append(Self.stored(defaults))
    }
    settings.meetingLanguageMode = .locked("es")
    #expect(fired == [.meetingLanguageMode])
    #expect(storedAtNotice == [["mode": "locked", "code": "es"]])
  }

  @Test("the key unifies across builds like every other setting")
  func unifiedKey() {
    #expect(SettingsManager.unifiedDefaultsKeys.filter { $0 == Self.key }.count == 1)
    #expect(SettingsDefaultValues.meetingLanguageMode == .auto)
  }
}
