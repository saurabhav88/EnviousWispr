import EnviousWisprCore
import Testing

@testable import EnviousWisprAppKit

/// #1678: the Auto-detect toggle is the one place a lock is created WITHOUT the
/// user choosing from the filtered picker, so it is the one place the picker's
/// restriction can be bypassed. Codex review r1 found exactly that: turning Auto
/// off on the fast engine could restore a legacy `whisperKitLanguage` such as
/// Japanese, producing a lock the decoder maps straight back to auto-detect —
/// the user asks for a lock, the UI shows a lock, and there is no lock.
@Suite("Language lock default code")
struct LanguageLockDefaultCodeTests {

  /// The fast engine's set. Small stand-in for the real 25; what matters is that
  /// it excludes `ja`, which is the legacy code a WhisperKit user can carry.
  static let fastEngine: Set<String> = ["en", "de", "fr", "es", "el"]

  @Test("An unsupported legacy code is NOT resurrected by the toggle")
  func unsupportedLegacyCodeIsNotResurrected() {
    let code = SpeechEngineSettingsView.defaultLockCode(
      currentMode: .auto, migratedCode: "ja", lockableCodes: Self.fastEngine)
    #expect(code == "en", "Japanese is not lockable on this engine, so it must not be chosen")
  }

  @Test("An unsupported CURRENT lock is not carried forward either")
  func unsupportedCurrentLockIsNotCarriedForward() {
    // Reachable by locking Japanese on the multilingual engine, switching to the
    // fast one, toggling Auto on and then off again.
    let code = SpeechEngineSettingsView.defaultLockCode(
      currentMode: .locked("ja"), migratedCode: "ja", lockableCodes: Self.fastEngine)
    #expect(code == "en")
  }

  @Test("A supported legacy code IS honoured — the fix must not discard valid choices")
  func supportedLegacyCodeIsHonoured() {
    let code = SpeechEngineSettingsView.defaultLockCode(
      currentMode: .auto, migratedCode: "de", lockableCodes: Self.fastEngine)
    #expect(code == "de")
  }

  @Test("A supported current lock is preserved")
  func supportedCurrentLockIsPreserved() {
    let code = SpeechEngineSettingsView.defaultLockCode(
      currentMode: .locked("fr"), migratedCode: "de", lockableCodes: Self.fastEngine)
    #expect(code == "fr")
  }

  /// The two-way control. nil means the multilingual engine, where every
  /// Whisper language is lockable — the pre-#1678 behaviour, which this change
  /// must leave exactly as it was. Without this, a fix that simply always
  /// returned "en" would pass every assertion above.
  @Test("With no restriction, behaviour is unchanged from before the fix")
  func noRestrictionPreservesOldBehaviour() {
    #expect(
      SpeechEngineSettingsView.defaultLockCode(
        currentMode: .auto, migratedCode: "ja", lockableCodes: nil) == "ja")
    #expect(
      SpeechEngineSettingsView.defaultLockCode(
        currentMode: .locked("ja"), migratedCode: "en", lockableCodes: nil) == "ja")
  }

  @Test("A migrated code that is not a real language falls back to English")
  func malformedMigratedCodeFallsBack() {
    #expect(
      SpeechEngineSettingsView.defaultLockCode(
        currentMode: .auto, migratedCode: "", lockableCodes: Self.fastEngine) == "en")
    #expect(
      SpeechEngineSettingsView.defaultLockCode(
        currentMode: .auto, migratedCode: "not-a-language", lockableCodes: nil) == "en")
  }

  /// Whatever this returns must itself be lockable, or the toggle creates the
  /// silent failure by a route the cases above did not enumerate.
  @Test("Every result is a code the active engine can honour")
  func everyResultIsHonourable() {
    for migrated in ["ja", "de", "", "zh", "not-a-language", "en"] {
      for mode in [LanguageMode.auto, .locked("ja"), .locked("de")] {
        let code = SpeechEngineSettingsView.defaultLockCode(
          currentMode: mode, migratedCode: migrated, lockableCodes: Self.fastEngine)
        #expect(
          Self.fastEngine.contains(code),
          "toggle produced '\(code)', which this engine cannot lock to")
      }
    }
  }
}
