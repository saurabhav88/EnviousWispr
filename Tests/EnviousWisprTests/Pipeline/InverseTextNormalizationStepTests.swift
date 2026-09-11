import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - InverseTextNormalizationStepTests (#145)
//
// Unit coverage for the pipeline wrapper's NEW behavior: the always-on flag,
// the backend-aware language gate, and the per-run telemetry outcome. The
// engine's own correctness (byte-for-byte parity, no-corruption, idempotence)
// is locked by `InverseTextNormalizerParityTests`; this suite only proves the
// wrapper gates and reports correctly.

@MainActor
@Suite struct InverseTextNormalizationStepTests {

  private func ctx(_ text: String, language: String? = nil) -> TextProcessingContext {
    TextProcessingContext(text: text, language: language)
  }

  // MARK: Always-on

  @Test("the step is always enabled (founder Gate-1: ON for all, no toggle)")
  func alwaysEnabled() {
    #expect(InverseTextNormalizationStep().isEnabled == true)
  }

  // MARK: Language gate

  @Test("Parakeet-class (no LID) + no language → runs on English-or-unknown")
  func runsForNonLIDBackendWithNilLanguage() async throws {
    let step = InverseTextNormalizationStep()
    step.backendSupportsLID = false
    let out = try await step.process(ctx("the code is two zero three"))
    #expect(out.text == "the code is 203")
    #expect(step.lastRun?.ran == true)
    #expect(step.lastRun?.changed == true)
    #expect(step.lastRun?.skipReason == nil)
  }

  @Test("WhisperKit-class (LID) + nil language → defensively skips (low-confidence)")
  func skipsForLIDBackendWithNilLanguage() async throws {
    let step = InverseTextNormalizationStep()
    step.backendSupportsLID = true
    let out = try await step.process(ctx("the code is two zero three"))
    #expect(out.text == "the code is two zero three", "unchanged on skip")
    #expect(step.lastRun?.ran == false)
    #expect(step.lastRun?.skipReason == "lid_backend_nil")
  }

  // MARK: Where the localised address words actually reach a user (#2770)

  /// The direct-formatter suite calls `InverseTextNormalizer.normalize` and so cannot see this
  /// gate. These two rows are the ones that say where the localised at-words and dot-words reach
  /// a real dictation, and where they do not.
  @Test("a spoken address in the speaker's own words converts on a no-language take")
  func localisedAddressConvertsOnNilLanguageTake() async throws {
    let step = InverseTextNormalizationStep()
    step.backendSupportsLID = false
    let out = try await step.process(ctx("mandalo a marco arroba esempio punto com"))
    #expect(out.text.contains("marco@esempio.com"))
    #expect(step.lastRun?.ran == true)
  }

  /// The limit, as a test rather than a comment: a take the app KNOWS is Spanish skips this
  /// engine entirely, so the Spanish words never run on it. The localised words serve a take
  /// whose language is unknown (Parakeet reports none) or resolved as English. Routing them for
  /// a resolved non-English take is tracked separately.
  @Test("the same address does NOT convert on a take resolved as Spanish")
  func localisedAddressSkippedOnResolvedNonEnglishTake() async throws {
    let step = InverseTextNormalizationStep()
    step.backendSupportsLID = true
    let input = "mandalo a marco arroba esempio punto com"
    let out = try await step.process(ctx(input, language: "es"))
    #expect(out.text == input)
    #expect(step.lastRun?.skipReason == "non_english")
  }

  @Test("explicit non-English language → skips (non_english)")
  func skipsForNonEnglishLanguage() async throws {
    let step = InverseTextNormalizationStep()
    step.backendSupportsLID = true
    let out = try await step.process(ctx("the code is two zero three", language: "es"))
    #expect(out.text == "the code is two zero three")
    #expect(step.lastRun?.ran == false)
    #expect(step.lastRun?.skipReason == "non_english")
  }

  @Test("explicit English language → runs (even on a LID backend)")
  func runsForExplicitEnglish() async throws {
    let step = InverseTextNormalizationStep()
    step.backendSupportsLID = true
    let out = try await step.process(ctx("the code is two zero three", language: "en"))
    #expect(out.text == "the code is 203")
    #expect(step.lastRun?.skipReason == nil)
  }

  @Test("English region tag (en-US) is treated as English")
  func runsForEnglishRegionTag() async throws {
    let step = InverseTextNormalizationStep()
    step.backendSupportsLID = true
    let out = try await step.process(ctx("the code is two zero three", language: "en-US"))
    #expect(out.text == "the code is 203")
  }

  @Test("empty language string falls through to the backend gate")
  func emptyLanguageUsesBackendGate() async throws {
    let step = InverseTextNormalizationStep()
    step.backendSupportsLID = false
    let out = try await step.process(ctx("the code is two zero three", language: ""))
    #expect(out.text == "the code is 203", "empty == no language → Parakeet-class runs")
  }

  // MARK: No-corruption spot checks (oracle-verified outputs, run through the gate)

  @Test("oh→0 phone formats through the step")
  func ohZeroPhoneThroughStep() async throws {
    let step = InverseTextNormalizationStep()
    let out = try await step.process(
      ctx("my number is o five five five one two three four five six"))
    #expect(out.text == "my number is 055-512-3456")
  }

  @Test("prose with an emoji and no numbers is an untouched no-op")
  func emojiProseNoOp() async throws {
    let step = InverseTextNormalizationStep()
    let input = "great work everyone 🎉"
    let out = try await step.process(ctx(input))
    #expect(out.text == input)
    #expect(step.lastRun?.changed == false)
  }

  // MARK: Telemetry outcome

  @Test("lastRun records lengths on a real run and zero latency on a skip")
  func lastRunTelemetryShape() async throws {
    let step = InverseTextNormalizationStep()
    step.backendSupportsLID = false
    _ = try await step.process(ctx("the code is two zero three"))
    #expect(step.lastRun?.lenBefore == "the code is two zero three".count)
    #expect(step.lastRun?.lenAfter == "the code is 203".count)

    step.backendSupportsLID = true  // force a skip
    _ = try await step.process(ctx("the code is two zero three"))
    #expect(step.lastRun?.ran == false)
    #expect(step.lastRun?.latencyMs == 0)
  }
}
