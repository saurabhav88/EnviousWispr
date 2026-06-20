import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprPipeline
import Foundation
import Testing

/// The public recovery text-processing seam (#1063 PR0) must run the SAME chain
/// a live dictation runs, configured by the recording's settings snapshot. With
/// polish disabled (provider `.none`) the deterministic steps are observable, so
/// these tests prove the chain actually runs and honors the snapshot toggles.
@MainActor
@Suite("Recovery text processor (#1063)")
struct RecoveryTextProcessorTests {

  private func snapshot(
    fillerRemoval: Bool, provider: String = "none",
    backendType: ASRBackendType = .parakeet, lidCapable: Bool = false,
    languageMode: LanguageMode = .auto
  ) -> RecordingSettingsSnapshot {
    RecordingSettingsSnapshot(
      backendType: backendType,
      backendSupportsLanguageDetection: lidCapable,
      languageMode: languageMode,
      wordCorrectionEnabled: false,
      fillerRemovalEnabled: fillerRemoval,
      emojiFormatterEnabled: false,
      customWordsVersion: nil,
      llmProvider: provider,
      llmModel: "none",
      polishPromptVersion: nil)
  }

  @Test("the recovery chain runs the standard steps end to end, polish disabled")
  func chainRunsEndToEnd() async {
    // Inverse text normalization is the robust observable transform here (its
    // 2s runner budget tolerates CPU-saturated parallel runs, unlike filler
    // removal's 50ms budget — `tests-no-real-time-scheduling-precision`). A
    // non-LID engine with auto language runs ITN. Proves the seam executes the
    // chain and keeps polish off under provider .none.
    let processor = RecoveryTextProcessor(keychainManager: KeychainManager())
    processor.applySettings(snapshot(fillerRemoval: true))
    let outcome = await processor.process(rawText: "the code is two zero three")
    #expect(outcome.text.contains("203"))  // the chain demonstrably transformed the text
    #expect(outcome.polishedText == nil)  // provider .none ⇒ no polish
    #expect(outcome.polishError == nil)
  }

  @Test("disabling filler removal in the snapshot leaves the text untouched")
  func snapshotTogglesThreadThrough() async {
    let input = "um hello uh there world"
    let processor = RecoveryTextProcessor(keychainManager: KeychainManager())
    processor.applySettings(snapshot(fillerRemoval: false))
    let outcome = await processor.process(rawText: input)
    #expect(outcome.text == input)
    #expect(outcome.polishedText == nil)
  }

  /// The recovered take must hit the SAME inverse-text-normalization language
  /// gate the live pipeline does (Codex PR0 P2). For a LID engine with unknown
  /// language, ITN must skip rather than rewrite possibly-non-English numbers.
  @Test("the ITN language gate matches the live pipeline for the recorded engine")
  func itnLanguageGateMatchesLiveEngine() async {
    let spoken = "call me at two zero three"

    // Non-LID engine (Parakeet-class): unknown language runs ITN → digits.
    let parakeet = RecoveryTextProcessor(keychainManager: KeychainManager())
    parakeet.applySettings(
      snapshot(fillerRemoval: false, backendType: .parakeet, lidCapable: false))
    let parakeetOut = await parakeet.process(rawText: spoken)
    #expect(parakeetOut.text.contains("203"))

    // LID engine (WhisperKit) with unknown language: ITN skips → text untouched.
    let whisperKit = RecoveryTextProcessor(keychainManager: KeychainManager())
    whisperKit.applySettings(
      snapshot(fillerRemoval: false, backendType: .whisperKit, lidCapable: true))
    let whisperKitOut = await whisperKit.process(rawText: spoken)
    #expect(whisperKitOut.text == spoken)
  }

  /// A take recorded with a LOCKED non-English language must replay under THAT
  /// language, derived from the snapshot — not nil/auto — so the chain never
  /// rewrites it as English (Codex PR0 P2). With Spanish locked, the English-
  /// only ITN must skip, leaving the spoken-form numbers intact.
  @Test("a locked non-English snapshot replays under its own language")
  func lockedLanguageReplaysUnderSnapshot() async {
    let spoken = "llamame al dos cero tres two zero three"
    let processor = RecoveryTextProcessor(keychainManager: KeychainManager())
    // Non-LID engine: were the locked language NOT applied, language would be
    // nil and ITN would run (non-LID + nil) and rewrite "two zero three" → 203.
    processor.applySettings(
      snapshot(
        fillerRemoval: false, backendType: .parakeet, lidCapable: false,
        languageMode: .locked("es")))
    let outcome = await processor.process(rawText: spoken)
    #expect(outcome.text == spoken)  // Spanish locked ⇒ English ITN skipped
  }
}
