import Foundation
import Testing

@testable import EnviousWisprPipeline

/// Issue #2259: `FillerRemovalStep` unconditionally stripped `um|umm|uh|uhh|hmm|mm|mhm|mmm|ah|er`
/// with no language awareness. "er" (he) and "um" (at [time] / in order to) are real, common
/// words in German; "er" is also real in Dutch (there), Danish and Norwegian (is). These tests
/// bind that a LOCKED language in that set protects only the colliding tokens, every other
/// language and every other token keep today's exact behavior, and the fix reaches every step
/// that reads `TextProcessingContext.language`.
@MainActor
@Suite(.tags(.productOutcome))
struct FillerRemovalLanguageProtectionTests {

  private func makeContext(text: String, language: String?) -> TextProcessingContext {
    TextProcessingContext(text: text, language: language)
  }

  private func process(_ text: String, language: String?) async throws -> String {
    let step = FillerRemovalStep()
    step.fillerRemovalEnabled = true
    let result = try await step.process(makeContext(text: text, language: language))
    return result.text
  }

  // MARK: German

  @Test("German: \"er\" (he) survives mid-sentence")
  func germanErSurvivesMidSentence() async throws {
    let out = try await process("Ich glaube er kommt morgen", language: "de")
    #expect(out == "Ich glaube er kommt morgen")
  }

  @Test("German: \"um\" (at [time]) survives")
  func germanUmSurvivesTime() async throws {
    let out = try await process("Wir treffen uns um drei Uhr", language: "de")
    #expect(out == "Wir treffen uns um drei Uhr")
  }

  @Test("German: \"um\" (in order to) survives")
  func germanUmSurvivesPurpose() async throws {
    let out = try await process("Ich rufe an um zu fragen", language: "de")
    #expect(out == "Ich rufe an um zu fragen")
  }

  @Test("German: both \"um\" and \"er\" survive in one sentence")
  func germanBothTokensSurvive() async throws {
    let out = try await process(
      "Wir treffen uns um drei Uhr er kommt auch", language: "de")
    #expect(out == "Wir treffen uns um drei Uhr er kommt auch")
  }

  @Test("German: a genuine filler is still stripped, proving this is per-token, not a step skip")
  func germanGenuineFillerStillStripped() async throws {
    let out = try await process("Ah, ich glaube er kommt", language: "de")
    #expect(out == "ich glaube er kommt")
  }

  // MARK: Dutch, Danish, Norwegian — "er"

  @Test("Dutch: \"er\" (there) survives")
  func dutchErSurvives() async throws {
    let out = try await process("Er is een probleem", language: "nl")
    #expect(out == "Er is een probleem")
  }

  @Test("Danish: \"er\" (is) survives")
  func danishErSurvives() async throws {
    let out = try await process("Han er glad", language: "da")
    #expect(out == "Han er glad")
  }

  @Test(
    "Norwegian: \"er\" (is) survives under the settings-exposed codes, not just the Apple alias",
    arguments: ["no", "nn", "nb"])
  func norwegianErSurvives(code: String) async throws {
    let out = try await process("Han er glad", language: code)
    #expect(out == "Han er glad")
  }

  // MARK: Non-protected languages and Auto-detect are unaffected

  @Test("Untabled language: \"ah\" and \"er\" both removed exactly as before")
  func untabledLanguageUnaffected() async throws {
    let out = try await process("Ah, er kommt", language: "fr")
    #expect(out == "kommt")
  }

  @Test("Auto-detect (nil language): \"ah\" and \"er\" both removed exactly as before")
  func autoDetectUnaffected() async throws {
    let out = try await process("Ah, er kommt", language: nil)
    #expect(out == "kommt")
  }
}
