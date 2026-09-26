import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #3142 Phase 5B: the Settings > Appearance language choice, against a private defaults suite
/// (never the test host's own domain, which is the app's).
@Suite("App language preference", .tags(.productOutcome))
struct AppLanguagePreferenceTests {
  private static func preference(shipped: [String] = ["Base", "de", "en"]) -> (
    AppLanguagePreference, UserDefaults, String
  ) {
    let suite = "AppLanguagePreferenceTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    return (
      AppLanguagePreference(defaults: defaults, domain: suite, shipped: shipped), defaults, suite
    )
  }

  @Test("Offers what the bundle ships, English first, never Base")
  func offersShippedLanguages() {
    let (preference, _, suite) = Self.preference()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    #expect(preference.languages == ["en", "de"])
  }

  @Test("Nothing chosen reads as System default")
  func nothingChosenIsSystemDefault() {
    let (preference, _, suite) = Self.preference()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    #expect(preference.choice == nil)
  }

  @Test("Choosing German writes the app's own language list, and reads back")
  func choosingGermanWritesAndReadsBack() {
    let (preference, defaults, suite) = Self.preference()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    preference.choose("de")
    #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] as? [String] == ["de"])
    #expect(preference.choice == "de")
  }

  @Test("System default removes the override")
  func systemDefaultRemovesTheOverride() {
    let (preference, defaults, suite) = Self.preference()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    preference.choose("de")
    preference.choose(nil)
    #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] == nil)
    #expect(preference.choice == nil)
  }

  @Test("A language the bundle does not ship is never written, and changes nothing")
  func unshippedLanguageChangesNothing() {
    let (preference, defaults, suite) = Self.preference()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    preference.choose("de")
    preference.choose("fr")
    #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] as? [String] == ["de"])
    #expect(preference.choice == "de")
  }

  @Test("A stored language the bundle no longer ships reads as System default and is forgotten")
  func storedUnshippedLanguageReadsAsSystemDefault() {
    let (preference, defaults, suite) = Self.preference()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    defaults.set(["fr"], forKey: "AppleLanguages")
    #expect(preference.choice == nil)
    preference.forgetUnshippedOverride()
    #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] == nil)
  }

  @Test("Forgetting unshipped overrides keeps shipped and regional ones")
  func forgetKeepsShippedOverrides() {
    let (preference, defaults, suite) = Self.preference()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    for stored in [["de"], ["de-AT"]] {
      defaults.set(stored, forKey: "AppleLanguages")
      preference.forgetUnshippedOverride()
      #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] as? [String] == stored)
    }
  }

  @Test("The next launch's language: the override, else the Mac's first shipped language, else English")
  func languageAtNextLaunch() {
    let (preference, _, suite) = Self.preference()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    #expect(preference.languageAtNextLaunch(systemPreferences: ["de-DE", "en-US"]) == "de")
    #expect(preference.languageAtNextLaunch(systemPreferences: ["fr-FR", "en-US"]) == "en")
    #expect(preference.languageAtNextLaunch(systemPreferences: ["fr-FR"]) == "en")
    preference.choose("de")
    #expect(preference.languageAtNextLaunch(systemPreferences: ["en-US"]) == "de")
    // The picker's own selection, before anything is saved.
    #expect(preference.language(forChoice: nil, systemPreferences: ["en-US"]) == "en")
    #expect(preference.language(forChoice: "fr", systemPreferences: ["de-DE"]) == "de")
  }

  @Test(
    "A regional override from System Settings reads as its shipped language",
    arguments: [["de-DE"], ["de_DE"], ["de-Latn-DE"], ["de-AT", "en-US"]])
  func regionalOverrideReadsAsShippedLanguage(stored: [String]) {
    let (preference, defaults, suite) = Self.preference()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    defaults.set(stored, forKey: "AppleLanguages")
    #expect(preference.choice == "de")
    #expect(preference.languageAtNextLaunch(systemPreferences: ["en-US"]) == "de")
  }

  @Test("Each language is named in its own language")
  func languagesAreNamedInTheirOwnLanguage() {
    #expect(AppLanguagePreference.name(of: "de") == "Deutsch")
    #expect(AppLanguagePreference.name(of: "en") == "English")
  }
}
