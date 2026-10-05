import AppKit
import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprServices

/// #2450: how the spoken-punctuation setting is stored, loaded and changed.
///
/// **Product Outcome.** When these fail a user loses the start word they chose, or a bad value left in
/// their preferences breaks the setting or switches it off, or the switch they already turned on stops
/// being on after an update. Every test uses an ephemeral suite, so nothing touches the real store.
/// Expectations are literal; the rules tables supply only the forms the validator already uses.
@MainActor
@Suite("Spoken punctuation settings (#2450)", .tags(.productOutcome))
struct SpokenPunctuationSettingsPersistenceTests {

  init() { _ = NSApplication.shared }

  private static func freshSuite() -> UserDefaults {
    let name = "ew.spokenPunctuationSettingsTest." + UUID().uuidString
    let defaults = TestDefaults.suite(name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  private static func scalars(_ text: String) -> [UInt32] { text.unicodeScalars.map(\.value) }

  // MARK: - Defaults and migration

  @Test("A fresh install is off with nothing customised")
  func freshInstall() {
    let settings = SettingsManager(defaults: Self.freshSuite())
    #expect(settings.spokenPunctuation == SpokenPunctuationSettings.off)
    #expect(settings.spokenPunctuation.enabled == false)
    #expect(settings.spokenPunctuation.startWordOverrides.isEmpty)
  }

  @Test("The switch a user already turned on survives, with no overrides")
  func existingBoolKeyMigrates() {
    let suite = Self.freshSuite()
    suite.set(true, forKey: "spokenPunctuationEnabled")
    let settings = SettingsManager(defaults: suite)
    #expect(settings.spokenPunctuation.enabled == true)
    #expect(settings.spokenPunctuation.startWordOverrides.isEmpty)
  }

  @Test("Both persisted keys are in the unified defaults inventory")
  func unifiedKeys() {
    #expect(SettingsManager.unifiedDefaultsKeys.contains("spokenPunctuationEnabled"))
    #expect(SettingsManager.unifiedDefaultsKeys.contains("spokenPunctuationStartWords"))
  }

  // MARK: - Round trips

  @Test("The switch and a custom start word round-trip through the store")
  func roundTrip() {
    let suite = Self.freshSuite()
    let settings = SettingsManager(defaults: suite)
    settings.spokenPunctuation.enabled = true
    let outcome = settings.commitSpokenPunctuationStartWord("Diktiere", language: "de")
    #expect(outcome == .accepted("Diktiere"))

    #expect(suite.object(forKey: "spokenPunctuationEnabled") as? Bool == true)
    #expect(
      suite.dictionary(forKey: "spokenPunctuationStartWords") as? [String: String] == [
        "de": "Diktiere"
      ])

    let reloaded = SettingsManager(defaults: suite)
    #expect(reloaded.spokenPunctuation.enabled == true)
    #expect(reloaded.spokenPunctuation.startWordOverrides == ["de": "Diktiere"])
  }

  @Test("Resetting a language removes its override, and the key when none is left")
  func resetRemovesTheOverride() {
    let suite = Self.freshSuite()
    let settings = SettingsManager(defaults: suite)
    settings.commitSpokenPunctuationStartWord("Diktiere", language: "de")
    settings.commitSpokenPunctuationStartWord("mets-moi", language: "fr")
    #expect(settings.spokenPunctuation.startWordOverrides == ["de": "Diktiere", "fr": "mets-moi"])

    settings.resetSpokenPunctuationStartWord(language: "de")
    #expect(settings.spokenPunctuation.startWordOverrides == ["fr": "mets-moi"])
    #expect(
      suite.dictionary(forKey: "spokenPunctuationStartWords") as? [String: String] == [
        "fr": "mets-moi"
      ])

    settings.resetSpokenPunctuationStartWord(language: "fr")
    #expect(settings.spokenPunctuation.startWordOverrides.isEmpty)
    #expect(suite.object(forKey: "spokenPunctuationStartWords") == nil)
  }

  @Test("Typing the default word back stores no override, ignoring case")
  func defaultWordIsNotAnOverride() {
    let settings = SettingsManager(defaults: Self.freshSuite())
    settings.commitSpokenPunctuationStartWord("Diktiere", language: "de")
    #expect(settings.spokenPunctuation.startWordOverrides == ["de": "Diktiere"])
    #expect(
      settings.commitSpokenPunctuationStartWord("setze", language: "de") == .accepted("setze"))
    #expect(settings.spokenPunctuation.startWordOverrides.isEmpty)
  }

  @Test("An accepted word is stored trimmed and in NFC, compared as scalars")
  func acceptedWordIsStoredNFC() throws {
    let settings = SettingsManager(defaults: Self.freshSuite())
    settings.commitSpokenPunctuationStartWord("  Dis-mo\u{0301}i  ", language: "fr")
    let stored = try #require(settings.spokenPunctuation.startWordOverrides["fr"])
    #expect(Self.scalars(stored) == Self.scalars("Dis-m\u{00F3}i"))
  }

  @Test("A regional language tag commits under the base code")
  func regionalTagCommitsUnderBaseCode() {
    let settings = SettingsManager(defaults: Self.freshSuite())
    settings.commitSpokenPunctuationStartWord("Diktiere", language: "de-DE")
    #expect(settings.spokenPunctuation.startWordOverrides == ["de": "Diktiere"])
  }

  // MARK: - Refusals leave the stored value alone

  @Test(
    "A refused word returns the reason and changes nothing",
    arguments: [
      ("", "de", SpokenPunctuationStartWord.Refusal.empty),
      ("zwei Worte", "de", .notOneToken),
      ("set3", "de", .invalidCharacters),
      ("x", "de", .tooShort),
      (String(repeating: "a", count: 21), "de", .tooLong),
      ("Punkt", "de", .collidesWithCommand),
      ("point", "fr", .collidesWithCommand),
      ("Diktiere", "nl", .unsupportedLanguage),
      ("Diktiere", "en", .unsupportedLanguage),
    ])
  func refusalsChangeNothing(
    raw: String, language: String, reason: SpokenPunctuationStartWord.Refusal
  ) {
    let suite = Self.freshSuite()
    let settings = SettingsManager(defaults: suite)
    settings.commitSpokenPunctuationStartWord("Sprich", language: "de")
    var changes = 0
    settings.onChange = { _ in changes += 1 }
    let before = settings.spokenPunctuation

    #expect(settings.commitSpokenPunctuationStartWord(raw, language: language) == .refused(reason))
    #expect(settings.spokenPunctuation == before)
    #expect(changes == 0)
    #expect(
      suite.dictionary(forKey: "spokenPunctuationStartWords") as? [String: String] == [
        "de": "Sprich"
      ])
  }

  // MARK: - Every write reaches the sync funnel exactly once

  @Test("Each change to either half fires one spokenPunctuation notification, a no-op fires none")
  func onChangeFiresOncePerChange() {
    let settings = SettingsManager(defaults: Self.freshSuite())
    var keys: [SettingsManager.SettingKey] = []
    settings.onChange = { keys.append($0) }

    settings.spokenPunctuation.enabled = true
    #expect(keys == [.spokenPunctuation])
    settings.commitSpokenPunctuationStartWord("Diktiere", language: "de")
    #expect(keys == [.spokenPunctuation, .spokenPunctuation])
    settings.commitSpokenPunctuationStartWord("Diktiere", language: "de")
    #expect(keys.count == 2, "the same word again is a no-op")
    settings.resetSpokenPunctuationStartWord(language: "de")
    #expect(keys.count == 3)
    settings.resetSpokenPunctuationStartWord(language: "de")
    #expect(keys.count == 3, "resetting what is not set is a no-op")
  }

  // MARK: - Malformed persisted data

  @Test("One bad stored entry never discards a good one, or the switch")
  func malformedEntriesAreDroppedIndependently() {
    let suite = Self.freshSuite()
    suite.set(true, forKey: "spokenPunctuationEnabled")
    suite.set(
      [
        "de": "Diktiere",  // valid
        "fr": "mets-moi",  // valid, hyphen inside
        "es": "punto",  // collides with a Spanish command form
        "it": "",  // empty
        "nl": "Dikteer",  // no table for this language
        "xx": "Wort",  // not a language
        "pl": 42,  // not a string
      ] as [String: Any], forKey: "spokenPunctuationStartWords")
    let settings = SettingsManager(defaults: suite)

    #expect(settings.spokenPunctuation.enabled == true)
    #expect(settings.spokenPunctuation.startWordOverrides == ["de": "Diktiere", "fr": "mets-moi"])
  }

  @Test("Stored words are re-validated: two tokens, a digit and a long word are all dropped")
  func invalidStoredWordsAreDropped() {
    let suite = Self.freshSuite()
    suite.set(
      [
        "de": "zwei Worte", "fr": "mots3", "es": String(repeating: "a", count: 21), "it": "Pronto",
      ], forKey: "spokenPunctuationStartWords")
    let settings = SettingsManager(defaults: suite)
    #expect(settings.spokenPunctuation.startWordOverrides == ["it": "Pronto"])
  }

  @Test("A stored value that is not a dictionary is ignored and the switch is kept")
  func nonDictionaryIsIgnored() {
    let suite = Self.freshSuite()
    suite.set(true, forKey: "spokenPunctuationEnabled")
    suite.set("garbage", forKey: "spokenPunctuationStartWords")
    let settings = SettingsManager(defaults: suite)
    #expect(
      settings.spokenPunctuation
        == SpokenPunctuationSettings(enabled: true, startWordOverrides: [:]))
  }

  @Test("A stored word equal to the default is dropped, so the file stays sparse")
  func storedDefaultIsDropped() {
    let suite = Self.freshSuite()
    suite.set(["de": "setze", "fr": "Diktiere"], forKey: "spokenPunctuationStartWords")
    let settings = SettingsManager(defaults: suite)
    #expect(settings.spokenPunctuation.startWordOverrides == ["fr": "Diktiere"])
  }

  @Test("A stored regional key loads under the base code, and an accented word is kept")
  func storedRegionalKeyAndAccents() throws {
    let suite = Self.freshSuite()
    suite.set(["de-DE": "Schreibe", "fr": "Dis-moi"], forKey: "spokenPunctuationStartWords")
    let settings = SettingsManager(defaults: suite)
    #expect(settings.spokenPunctuation.startWordOverrides == ["de": "Schreibe", "fr": "Dis-moi"])

    suite.set(["fr": "Pr\u{00E9}cise"], forKey: "spokenPunctuationStartWords")
    let accented = SettingsManager(defaults: suite)
    let stored = try #require(accented.spokenPunctuation.startWordOverrides["fr"])
    #expect(Self.scalars(stored) == Self.scalars("Pr\u{00E9}cise"))
  }

  // MARK: - Effective words come from one owner

  @Test("Effective words are the override else the default, for exactly the four languages")
  func effectiveWords() {
    #expect(
      SpokenPunctuationRules.effectiveStartWords(overrides: [:])
        == ["de": "Setze", "fr": "Insère", "es": "Pon", "it": "Metti"])
    #expect(
      SpokenPunctuationRules.effectiveStartWords(overrides: ["de": "Diktiere", "nl": "Dikteer"])
        == ["de": "Diktiere", "fr": "Insère", "es": "Pon", "it": "Metti"])
  }

  @Test("A snapshot keeps an effective word even when it equals today's default")
  func snapshotValidationKeepsDefaults() {
    let words = ["de": "Setze", "fr": "Diktiere", "es": "punto", "xx": "Wort"]
    #expect(
      SpokenPunctuationRules.validatedStartWords(words, dropDefaults: false)
        == ["de": "Setze", "fr": "Diktiere"])
    #expect(
      SpokenPunctuationRules.validatedStartWords(words, dropDefaults: true) == ["fr": "Diktiere"])
  }
}
