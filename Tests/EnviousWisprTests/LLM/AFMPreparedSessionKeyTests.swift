import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM

/// #3195 PR B: a session prepared at key-up is reused only when everything that shapes
/// it equals what polish would build now. When these fail, a user's dictation is
/// polished by a session built for a different language, prompt, model or OS.
@Suite("Apple prepared-session reuse key (#3195)", .tags(.productOutcome))
struct AFMPreparedSessionKeyTests {
  private typealias C = AppleIntelligenceConnector

  private static func key(
    instructions: String = C.assembledInstructions(
      base: C.onDeviceInstructionsV56ForTests, detectedLanguage: nil),
    exampleTurns: [C.OnDeviceExampleTurn] = C.onDeviceExampleTurnsV56ForTests,
    trailer: String = C.onDevicePromptTrailerV56,
    guardrails: String = "permissiveContentTransformations",
    modelIdentity: String = "stock",
    osMajor: Int = 27
  ) -> C.AFMSessionKey {
    C.AFMSessionKey(
      instructions: instructions, exampleTurns: exampleTurns, trailer: trailer,
      guardrails: guardrails, modelIdentity: modelIdentity, osMajor: osMajor)
  }

  @Test("identical inputs reuse the prepared session")
  func identicalKeyReuses() {
    #expect(C.reusesPrepared(Self.key(), for: Self.key()))
  }

  @Test("a difference in any one field builds fresh")
  func everyFieldMismatchBuildsFresh() {
    let base = Self.key()
    let variants: [(String, C.AFMSessionKey)] = [
      (
        "language clause",
        Self.key(
          instructions: C.assembledInstructions(
            base: C.onDeviceInstructionsV56ForTests, detectedLanguage: "de"))
      ),
      ("instructions", Self.key(instructions: "CANDIDATE")),
      (
        "example turns", Self.key(exampleTurns: Array(C.onDeviceExampleTurnsV56ForTests.dropLast()))
      ),
      ("trailer", Self.key(trailer: "")),
      ("guardrails", Self.key(guardrails: "default")),
      ("adapter versus stock", Self.key(modelIdentity: C.adapterModelIdentity())),
      ("OS major", Self.key(osMajor: 26)),
    ]
    for (field, variant) in variants {
      #expect(!C.reusesPrepared(variant, for: base), "a different \(field) must not reuse")
    }
    #expect(variants.count == 7)
  }

  @Test("the language clause and the trailer arming follow the detected language")
  func languageShapesTheKeyInputs() {
    let english = C.assembledInstructions(base: "BASE", detectedLanguage: "en")
    let none = C.assembledInstructions(base: "BASE", detectedLanguage: nil)
    let german = C.assembledInstructions(base: "BASE", detectedLanguage: "de")
    #expect(english == "BASE")
    #expect(none == "BASE")
    #expect(german.hasPrefix("Input language: German (de).\n"))
    #expect(german.hasSuffix("\n\nBASE"))
    #expect(C.armedTrailer("T", detectedLanguage: "de").isEmpty)
    #expect(C.armedTrailer("T", detectedLanguage: nil) == "T")
  }

  @Test("a DEBUG adapter session is never reused, even at the same adapter path")
  func adapterIdentityIsNeverReused() {
    let first = Self.key(modelIdentity: C.adapterModelIdentity())
    let second = Self.key(modelIdentity: C.adapterModelIdentity())
    #expect(first.modelIdentity.hasPrefix("adapter-unverified:"))
    #expect(!C.reusesPrepared(first, for: second))
    #expect(C.reusesPrepared(Self.key(), for: Self.key()), "control: stock keys still match")
  }

  @Test("the prepared instruction count is used on a hit and never recounted")
  func cachedCountSkipsTheEstimate() async throws {
    var calls = 0
    let tokens = try await C.promptTokens(cached: 812) {
      calls += 1
      return 999
    }
    #expect(tokens == 812)
    #expect(calls == 0)
  }

  @Test("without a cached count polish counts as before")
  func noCachedCountEstimates() async throws {
    var calls = 0
    let tokens = try await C.promptTokens(cached: nil) {
      calls += 1
      return 999
    }
    #expect(tokens == 999)
    #expect(calls == 1)
  }

  @Test("the outcome labels match the telemetry values")
  func outcomeLabels() {
    #expect(C.AFMPrewarmOutcome.hit.rawValue == "hit")
    #expect(C.AFMPrewarmOutcome.missKey.rawValue == "miss_key")
    #expect(C.AFMPrewarmOutcome.none.rawValue == "none")
  }
}

#if canImport(FoundationModels)
  import FoundationModels

  private func appleModelAvailable() -> Bool {
    guard #available(macOS 26.0, *) else { return false }
    return SystemLanguageModel.default.availability == .available
  }

  /// The real connector path, on a Mac with the on-device model (skipped loudly elsewhere,
  /// including hosted CI): a prepared session is used on a hit, refused on a key mismatch,
  /// and absent when none is offered.
  @Suite(
    "Apple prepared session through the real connector (#3195)", .tags(.productOutcome),
    .serialized, .enabled(if: appleModelAvailable(), "needs the on-device Apple model"))
  struct AFMPreparedSessionConnectorTests {
    private let text = "so the invoice is still open I think and I was going to send it today"

    private func config(_ language: String?) -> LLMProviderConfig {
      LLMProviderConfig(
        model: "apple-intelligence", apiKeyKeychainId: nil, outputTokens: .capped(500),
        temperature: 0, thinking: nil, detectedLanguage: language)
    }

    @Test("a session prepared for this polish is used")
    func preparedSessionHits() async throws {
      guard #available(macOS 26.0, *) else { return }
      let connector = AppleIntelligenceConnector()
      let prepared = try await connector.prepareSession(detectedLanguage: nil)
      #expect(prepared.key.trailer == AppleIntelligenceConnector.onDevicePromptTrailerV56)
      let out = try await connector.polish(
        text: text, instructions: .default, config: config(nil), onToken: nil, prepared: prepared)
      #expect(out.prewarm == .hit)
      #expect(!out.result.polishedText.isEmpty)
    }

    @Test("a session prepared for another language is refused and polish builds fresh")
    func mismatchedLanguageBuildsFresh() async throws {
      guard #available(macOS 26.0, *) else { return }
      let connector = AppleIntelligenceConnector()
      let prepared = try await connector.prepareSession(detectedLanguage: "de")
      #expect(prepared.key.trailer.isEmpty)
      let out = try await connector.polish(
        text: text, instructions: .default, config: config(nil), onToken: nil, prepared: prepared)
      #expect(out.prewarm == .missKey)
      #expect(!out.result.polishedText.isEmpty)
    }

    @Test("a cancelled preparation throws instead of returning a session")
    func cancelledPreparationThrows() async throws {
      guard #available(macOS 26.0, *) else { return }
      let connector = AppleIntelligenceConnector()
      let task = Task { () async throws -> AppleIntelligenceConnector.AFMPreparedSession in
        withUnsafeCurrentTask { $0?.cancel() }
        return try await connector.prepareSession(detectedLanguage: nil)
      }
      await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test("with nothing offered the outcome is none")
    func nothingOffered() async throws {
      guard #available(macOS 26.0, *) else { return }
      let out = try await AppleIntelligenceConnector().polish(
        text: text, instructions: .default, config: config(nil), onToken: nil, prepared: nil)
      #expect(out.prewarm == .none)
    }
  }
#endif
