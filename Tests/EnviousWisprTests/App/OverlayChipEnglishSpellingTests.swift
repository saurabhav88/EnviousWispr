import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// #3124: accepting the language chip's "English" suggestion locks the engine to "en" and keeps
/// the stored spelling, so a user who chose English (UK) before gets it back. When this fails, the
/// chip silently switches a British user to American spelling.
///
/// The chip's `language.manual_lock_used` goes straight to `PostHogSDK.capture` (no test seam), so
/// its values are asserted through the one function the chip and the sheet both call,
/// `LanguageLockOptions.telemetryCode`, rather than by capturing the event.
@MainActor
@Suite("Language chip and English spelling", .tags(.productOutcome))
struct OverlayChipEnglishSpellingTests {

  private static func settings(spelling: EnglishSpelling) -> SettingsManager {
    let name = "ew.chip.spelling.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    let settings = SettingsManager(defaults: defaults)
    settings.englishSpelling = spelling
    return settings
  }

  @Test("a stored British choice comes back when the chip locks English")
  func chipRestoresBritish() {
    let settings = Self.settings(spelling: .british)
    OverlayChipWiring.acceptedLanguage(settings: settings)("en")
    #expect(settings.languageMode == .locked("en"), "the engine is handed plain en")
    #expect(settings.englishSpelling == .british)
    #expect(
      EnglishSpelling.effective(
        languageMode: settings.languageMode, stored: settings.englishSpelling)
        == .british)
    #expect(LanguageLockOptions.telemetryCode(settings.languageMode, stored: .british) == "en-GB")
  }

  @Test("American stays American, and another language keeps the stored preference untouched")
  func chipAmericanAndOther() {
    let american = Self.settings(spelling: .american)
    OverlayChipWiring.acceptedLanguage(settings: american)("en")
    #expect(american.languageMode == .locked("en"))
    #expect(LanguageLockOptions.telemetryCode(american.languageMode, stored: .american) == "en")

    let french = Self.settings(spelling: .british)
    OverlayChipWiring.acceptedLanguage(settings: french)("fr")
    #expect(french.languageMode == .locked("fr"))
    #expect(french.englishSpelling == .british)
    #expect(LanguageLockOptions.telemetryCode(french.languageMode, stored: .british) == "fr")
  }
}
