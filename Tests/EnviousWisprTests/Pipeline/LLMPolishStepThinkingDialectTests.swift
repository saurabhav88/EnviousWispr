import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #1770: the thinking value that actually reaches the provider.
///
/// Chunk-1 review caught that asserting on `LLMModelCapabilities` alone proves
/// only that the TABLE is right — it cannot detect a broken resolver or a
/// broken config handoff, which is where the shipped defect lived. These tests
/// drive the real `LLMPolishStep.process()` path and capture what the polisher
/// is actually handed, with no production test seam added.
///
/// The defect being pinned: with Deep reasoning OFF (the default, used by 570
/// of 571 users) we sent `thinkingBudget: 0` to every Gemini 2.5/3 model. Gemini
/// 3 answers that with HTTP 400, so five of the eleven offered models failed
/// every polish attempt.
@MainActor
@Suite("LLMPolishStep thinking dialect reaches the provider (#1770)")
struct LLMPolishStepThinkingDialectTests {

  /// Box for the resolved thinking value handed to the polisher. `@unchecked
  /// Sendable` mirrors the established fixture in
  /// `LLMPolishStepLanguageFallbackTests`: written once inside the polisher
  /// call, read only after `process()` has fully awaited.
  private final class ThinkingCapture: @unchecked Sendable {
    var thinking: ResolvedThinking?
    var sawCall = false
  }

  private struct CapturingPolisher: TranscriptPolisher {
    let capture: ThinkingCapture
    let result: String

    func polish(
      text: String,
      instructions: PolishInstructions,
      config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
      capture.thinking = config.thinking
      capture.sawCall = true
      return LLMResult(polishedText: result)
    }
  }

  private static let input =
    "so um i was thinking maybe we could move the meeting to tuesday instead of monday"
  private static let polished =
    "I was thinking maybe we could move the meeting to Tuesday instead of Monday."

  private func capturedThinking(
    model: String, extendedThinking: Bool
  ) async throws -> (value: ResolvedThinking?, sawCall: Bool) {
    let step = LLMPolishStep(keychainManager: KeychainManager())
    step.llmProvider = .gemini
    step.llmModel = model
    step.useExtendedThinking = extendedThinking

    let capture = ThinkingCapture()
    step.makePolisher = { _, _, _ in
      CapturingPolisher(capture: capture, result: Self.polished)
    }

    _ = try await step.process(TextProcessingContext(text: Self.input, language: "en"))
    return (capture.thinking, capture.sawCall)
  }

  /// THE REGRESSION. Before this change a Gemini 3 model with the toggle off
  /// received `.budget(0)`, which Google rejects with HTTP 400.
  @Test("Gemini 3, Deep reasoning OFF → thinkingLevel minimal, never budget 0")
  func geminiThreeToggleOffSendsLevel() async throws {
    for model in ["gemini-3.6-flash", "gemini-3.5-flash-lite"] {
      let (thinking, sawCall) = try await capturedThinking(
        model: model, extendedThinking: false)
      #expect(sawCall, "\(model): the polisher was never reached, so this proves nothing")
      #expect(
        thinking == .level("minimal"),
        "\(model) must receive .level(\"minimal\"); .budget(0) is HTTP 400")
    }
  }

  /// 3.7 Flash is the first Flash-tier id whose off-state is NOT `minimal`:
  /// Google rejects minimal on it with HTTP 400, so `low` is its floor. It is
  /// also the shipped Gemini default as of 2026-08-16, which makes this the
  /// dialect most users receive.
  ///
  /// Deliberately a separate test rather than another entry in the loop above.
  /// Adding it there would have required weakening that assertion to accept
  /// either level, which would stop it catching a 3.6 that regressed to `low`
  /// — one test covering two contracts checks neither.
  @Test("Gemini 3.7 Flash, Deep reasoning OFF → thinkingLevel low, never minimal")
  func geminiThreeSevenToggleOffSendsLow() async throws {
    let (thinking, sawCall) = try await capturedThinking(
      model: "gemini-3.7-flash", extendedThinking: false)
    #expect(sawCall, "the polisher was never reached, so this proves nothing")
    #expect(
      thinking == .level("low"),
      "gemini-3.7-flash must receive .level(\"low\"); minimal is HTTP 400 on it")
  }

  /// The opposite direction: an unrecognised model must reach the provider with
  /// NO thinking field at all. Asserted positively — a fallback that silently
  /// sent something would pass a mere "did not crash" check.
  @Test("unknown Gemini model, Deep reasoning ON → no thinking field at all")
  func unknownModelSendsNothingEvenWithToggleOn() async throws {
    let (thinking, sawCall) = try await capturedThinking(
      model: "gemini-4.0-flash-imaginary", extendedThinking: true)
    #expect(sawCall)
    #expect(
      thinking == nil,
      "an untested model must not inherit a deep value merely because the toggle is on")
  }

  /// Gemini 2.5 keeps the integer dialect; the two generations must not blur.
  @Test("Gemini 2.5, Deep reasoning OFF → thinkingBudget 0, not a level")
  func geminiTwoFiveKeepsBudgetDialect() async throws {
    let (thinking, sawCall) = try await capturedThinking(
      model: "gemini-2.5-flash", extendedThinking: false)
    #expect(sawCall)
    #expect(thinking == .budget(0), "2.5 rejects thinkingLevel with HTTP 400")
  }

  /// The toggle still does something on a model that supports it.
  @Test("Deep reasoning ON selects the deep value")
  func toggleOnSelectsDeepValue() async throws {
    let (thinking, _) = try await capturedThinking(
      model: "gemini-3.6-flash", extendedThinking: true)
    #expect(thinking == .level("high"))
  }

  // MARK: - Codable contract

  /// `LLMProviderConfig` is `Codable` and this change altered its stored shape,
  /// replacing two optionals with one. Two things must hold: previously-encoded
  /// JSON (carrying the now-deleted keys) must still decode rather than throw,
  /// and a live value must survive a round trip.
  @Test("legacy encoded config decodes with no thinking value")
  func legacyJSONDecodesWithNilThinking() throws {
    let legacy = """
      {"model":"gemini-2.5-flash","outputTokens":{"providerDefault":{}},
       "temperature":0,"thinkingBudget":0,"reasoningEffort":"low"}
      """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(LLMProviderConfig.self, from: legacy)
    #expect(decoded.thinking == nil, "unknown legacy keys must not throw, and must not be guessed")
    #expect(decoded.model == "gemini-2.5-flash")
  }

  @Test("a resolved thinking value survives a Codable round trip")
  func thinkingRoundTrips() throws {
    for value: ResolvedThinking in [.level("minimal"), .budget(8192), .effort("low")] {
      let config = LLMProviderConfig(
        model: "gemini-3.6-flash", apiKeyKeychainId: nil,
        outputTokens: .providerDefault, temperature: 0, thinking: value)
      let restored = try JSONDecoder().decode(
        LLMProviderConfig.self, from: JSONEncoder().encode(config))
      #expect(restored.thinking == value)
    }
  }
}
