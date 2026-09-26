import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #3195 PR B: `afm_prewarm` rides `llm.polish_completed` for a completed live Apple
/// polish, and nowhere else. When these fail, the field report on whether the key-up
/// session was used is missing, or it lands on rows it does not describe.
@MainActor
@Suite("afm_prewarm on llm.polish_completed (#3195)", .tags(.observabilityContract))
struct AFMPrewarmTelemetryTests {

  #if DEBUG
    final class Box: @unchecked Sendable { var event: CapturedTelemetryEvent? }

    private static func transcript(provider: String, polished: String?) -> EnviousWisprCore.Transcript {
      EnviousWisprCore.Transcript(
        text: "hello there friend",
        polishedText: polished,
        llmProvider: provider,
        llmModel: "m",
        metrics: ExecutionMetrics(
          asrLatencySeconds: 0.2, llmLatencySeconds: 0.6, pasteTier: "cgevent",
          pasteLatencyMs: 5, e2eSeconds: 1.0))
    }

    private func polishCompleted(
      _ t: EnviousWisprCore.Transcript, takeID: String?, afmPrewarm: String?
    ) -> CapturedTelemetryEvent? {
      let box = Box()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated {
          if event.name == "llm.polish_completed" { box.event = event }
        }
      }
      defer { TelemetryService.shared.testEventHook = nil }
      TelemetryService.shared.reportDictationCompleted(
        transcript: t, inputMode: "ptt", takeID: takeID, afmPrewarm: afmPrewarm)
      return box.event
    }

    @Test(
      "a completed Apple polish carries the outcome it was given",
      arguments: ["hit", "miss_key", "none"])
    func appleSuccessCarriesTheOutcome(value: String) throws {
      let event = try #require(
        polishCompleted(
          Self.transcript(provider: "appleIntelligence", polished: "Hello there, friend."),
          takeID: "take-1", afmPrewarm: value))
      #expect(event.stringProps["result"] == "success")
      #expect(event.stringProps["afm_prewarm"] == value)
      #expect(event.stringProps["take_id"] == "take-1")
    }

    @Test("a skipped Apple polish, another provider, or no take never carries it")
    func absentOutsideACompletedLiveApplePolish() throws {
      let skipped = try #require(
        polishCompleted(
          Self.transcript(provider: "appleIntelligence", polished: nil),
          takeID: "take-1", afmPrewarm: "hit"))
      #expect(skipped.stringProps["result"] == "skipped")
      #expect(skipped.stringProps["afm_prewarm"] == nil)

      let other = try #require(
        polishCompleted(
          Self.transcript(provider: "egOne", polished: "Hello there, friend."),
          takeID: "take-1", afmPrewarm: "hit"))
      #expect(other.stringProps["afm_prewarm"] == nil)

      let noTake = try #require(
        polishCompleted(
          Self.transcript(provider: "appleIntelligence", polished: "Hello there, friend."),
          takeID: nil, afmPrewarm: "hit"))
      #expect(noTake.stringProps["afm_prewarm"] == nil)
    }
  #endif
}

#if canImport(FoundationModels)
  import FoundationModels

  private func appleModelAvailable() -> Bool {
    guard #available(macOS 26.0, *) else { return false }
    return SystemLanguageModel.default.availability == .available
  }

  /// The live chain end to end short of the kernel (skipped loudly without the on-device
  /// model): a session prepared for the take is used by the real runner, and the outcome
  /// lands on the finalization outcome under that take.
  @MainActor
  @Suite(
    "afm_prewarm through the real finalization chain (#3195)", .tags(.productOutcome),
    .serialized, .enabled(if: appleModelAvailable(), "needs the on-device Apple model"))
  struct AFMPrewarmFinalizationChainTests {
    private func wiring(
      _ outcome: KernelFinalizationOutcome, polish: LLMPolishStep, takeID: String
    ) -> KernelFinalizationWiring {
      let telemetry = KernelTelemetryState()
      telemetry.resetForNewSession(takeID: takeID, polishEnabled: true)
      return KernelFinalizationWiring(
        outcome: outcome,
        context: KernelSessionContext(),
        adapter: FakeEngine(behavior: .batchSuccess(text: "hi"), clock: FakeClock()),
        steps: LimbSteps(
          snippetExpansion: SnippetExpansionStep(),
          wordCorrection: WordCorrectionStep(),
          learnedWordCheck: LearnedWordCheckStep(),
          fillerRemoval: FillerRemovalStep(),
          emojiFormatter: EmojiFormatterStep(),
          inverseTextNormalization: InverseTextNormalizationStep(),
          englishSpelling: EnglishSpellingStep(target: .text),
          llmPolish: polish,
          englishSpellingAfterPolish: EnglishSpellingStep(target: .polishedText),
          emojiRestore: EmojiRestoreStep()),
        textProcessingRunner: TextProcessingRunner(),
        save: { _, _ in },
        deliverPaste: { _ in
          PasteDeliveryResult(
            tier: .cgEvent, durationMs: 1, outcome: .delivered(tier: .cgEvent, durationMs: 1))
        },
        pasteCompletionRegistry: nil,
        telemetryState: telemetry,
        copyToClipboard: { _ in })
    }

    private let raw = "so the invoice is still open I think and I was going to send it today"

    @Test("a session prepared for this take is used, and the outcome carries the take")
    func preparedTakeHits() async throws {
      let polish = LLMPolishStep(keychainManager: KeychainManager())
      polish.llmProvider = .appleIntelligence
      polish.llmModel = "apple-intelligence"
      polish.beginAFMPrewarm(takeID: "take-live", expectedDetectedLanguage: nil)
      await polish.afmPrewarmTask?.value
      let outcome = KernelFinalizationOutcome()
      _ = try await wiring(outcome, polish: polish, takeID: "take-live").processText(raw) {}
      #expect(outcome.afmPrewarmOutcome == .hit)
      #expect(outcome.afmPrewarmTakeID == "take-live")
    }

    @Test("without a prepared session the outcome is none")
    func nothingPreparedIsNone() async throws {
      let polish = LLMPolishStep(keychainManager: KeychainManager())
      polish.llmProvider = .appleIntelligence
      polish.llmModel = "apple-intelligence"
      let outcome = KernelFinalizationOutcome()
      _ = try await wiring(outcome, polish: polish, takeID: "take-live").processText(raw) {}
      #expect(outcome.afmPrewarmOutcome == AppleIntelligenceConnector.AFMPrewarmOutcome.none)
    }
  }
#endif
