import Testing

@testable import EnviousWisprASR

/// #1678: the language lock on the fast engine.
///
/// The set of lockable languages is the one thing here a user can see being
/// wrong: offering a language the engine cannot honour is a SILENT failure —
/// the mapping returns nil, the decoder falls back to Auto, and the user sees a
/// lock they set and are not getting. So the set is frozen against NVIDIA's
/// model card rather than against whatever the vendor enum happens to contain.
@Suite("Parakeet language lock")
struct ParakeetLanguageLockTests {

  /// The 25 European languages NVIDIA's `parakeet-tdt-0.6b-v3` model card
  /// claims. Written out rather than derived, deliberately: deriving it from
  /// the vendor enum would make this test agree with any future vendor change
  /// by construction, which is the one thing it exists to prevent.
  static let modelCardLanguages: Set<String> = [
    "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu",
    "it", "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
  ]

  @Test("We offer exactly the model card's 25 languages")
  func offersExactlyTheModelCard() {
    #expect(Self.modelCardLanguages.count == 25)
    #expect(ParakeetBackend.lockableLanguageCodes == Self.modelCardLanguages)
  }

  /// The vendor enum carries three languages the model card does not claim.
  /// If a vendor bump adds or removes a case, the test above fails and someone
  /// has to decide whether we claim it — which is the intended outcome. This
  /// one names why the three are excluded so the failure is diagnosable.
  @Test("The three vendor languages the model card does not claim are refused")
  func refusesLanguagesTheModelDoesNotClaim() {
    for code in ["bs", "be", "sr"] {
      #expect(
        ParakeetBackend.fluidLanguage(for: code) == nil,
        "\(code) is in the vendor's script filter but is not claimed by the model card")
      #expect(ParakeetBackend.lockableLanguageCodes.contains(code) == false)
    }
  }

  @Test("A claimed language maps to the vendor value")
  func mapsClaimedLanguages() {
    #expect(ParakeetBackend.fluidLanguage(for: "de") == .german)
    #expect(ParakeetBackend.fluidLanguage(for: "el") == .greek)
    #expect(ParakeetBackend.fluidLanguage(for: "ru") == .russian)
    #expect(ParakeetBackend.fluidLanguage(for: "en") == .english)
  }

  /// The catalog stores bare codes today, but a locked value can arrive from a
  /// settings migration or a suggestion as a full BCP-47 tag. Mapping it to nil
  /// would silently drop a lock the user set.
  @Test("Region tags and case are normalised to the base code")
  func normalisesRegionTags() {
    #expect(ParakeetBackend.fluidLanguage(for: "de-DE") == .german)
    #expect(ParakeetBackend.fluidLanguage(for: "de_AT") == .german)
    #expect(ParakeetBackend.fluidLanguage(for: "DE") == .german)
    #expect(ParakeetBackend.fluidLanguage(for: "pt-BR") == .portuguese)
  }

  /// Auto. nil disables language conditioning in the decoder entirely, which is
  /// the shipped default and must stay reachable.
  @Test("Absent or empty means Auto, not a guess")
  func absentMeansAuto() {
    #expect(ParakeetBackend.fluidLanguage(for: nil) == nil)
    #expect(ParakeetBackend.fluidLanguage(for: "") == nil)
    #expect(ParakeetBackend.fluidLanguage(for: "   ") == nil)
  }

  /// A language the engine has never claimed — Japanese is the obvious one, and
  /// it is exactly what a user migrating from the multilingual engine could
  /// still have stored. Falling back to Auto is safer than forcing a script the
  /// model was never declared to handle.
  @Test("An unsupported or malformed code falls back to Auto rather than guessing")
  func unsupportedFallsBackToAuto() {
    for code in ["ja", "zh", "ko", "ar", "he", "th", "hi", "xx", "not-a-language"] {
      #expect(
        ParakeetBackend.fluidLanguage(for: code) == nil,
        "\(code) must fall back to Auto rather than mapping to some other language")
    }
  }

  /// Guards the property the picker depends on: every code we offer must map to
  /// a real vendor value. Without this, the two could drift and the picker would
  /// list a language the decode call silently ignores.
  @Test("Every offered code maps to a vendor language")
  func everyOfferedCodeResolves() {
    for code in ParakeetBackend.lockableLanguageCodes {
      #expect(
        ParakeetBackend.fluidLanguage(for: code) != nil,
        "\(code) is offered in the picker but does not resolve to a vendor language")
    }
  }
}
