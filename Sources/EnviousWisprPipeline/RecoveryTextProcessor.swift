import EnviousWisprCore
import EnviousWisprLLM
import Foundation

// MARK: - Recovery text-processing seam (#1063 PR0)
//
// Recovery must run the SAME post-ASR text chain a live dictation runs
// (word correction -> filler removal -> emoji -> inverse text normalization ->
// LLM polish), but OUTSIDE the live kernel. The chain's runner and steps are
// internal to Pipeline and `TranscriptPolishService` only runs the polish step,
// so neither is reusable from the App layer. This is the small PUBLIC seam that
// reuses the internal `TextProcessingRunner` + the same five step instances.
//
// It is a limb of a limb: a recovered transcript that fails to polish lands as
// raw text (the raw-fallback contract), exactly like a live dictation whose
// polish limb fails.

/// The outcome of running the recovery text chain on a recovered transcript.
public struct RecoveryTextOutcome: Sendable {
  /// The deterministic text after the non-polish steps (the raw-fallback floor).
  public let text: String
  /// The polished text, or nil when polish was disabled / failed / skipped.
  public let polishedText: String?
  /// A user-surfacable polish error, or nil. Recovery still saves `text`.
  public let polishError: String?

  public init(text: String, polishedText: String?, polishError: String?) {
    self.text = text
    self.polishedText = polishedText
    self.polishError = polishError
  }

  /// What History should show — polished if available, else the raw floor.
  public var displayText: String { polishedText ?? text }
}

/// Runs the standard five-step post-ASR text chain on a recovered transcript.
@MainActor
public final class RecoveryTextProcessor {
  private let steps: LimbSteps
  private let runner: TextProcessingRunner
  /// The recording's locked decode language (or nil for auto), applied from the
  /// snapshot. Recovery replays under the ORIGINAL language exactly as the live
  /// path derives the runner language from the frozen session config — never a
  /// caller-supplied or re-detected language (Codex PR0 P2).
  private var recordedLanguage: String?

  public init(
    keychainManager: KeychainManager, outputClassifierHolder: OutputClassifierHolder? = nil
  ) {
    let llmPolish = LLMPolishStep(keychainManager: keychainManager)
    // Standalone, like TranscriptPolishService: no live-pipeline callbacks.
    llmPolish.onWillProcess = nil
    llmPolish.onToken = nil
    llmPolish.outputClassifierHolder = outputClassifierHolder
    self.steps = LimbSteps(
      wordCorrection: WordCorrectionStep(),
      fillerRemoval: FillerRemovalStep(),
      emojiFormatter: EmojiFormatterStep(),
      inverseTextNormalization: InverseTextNormalizationStep(),
      llmPolish: llmPolish)
    self.runner = TextProcessingRunner()
  }

  /// Apply the recording's record-time settings snapshot so recovery replays
  /// under the ORIGINAL settings (engine, language, polish provider/model, limb
  /// toggles), NOT the user's current ones — preventing the "recorded in
  /// Spanish, recovered under English" failure. The custom-words VOCABULARY is
  /// not in the snapshot (only its version); PR2 reconstructs and assigns it via
  /// `wordCorrectionStep.correctorVocabulary` separately.
  public func applySettings(_ snapshot: RecordingSettingsSnapshot) {
    steps.wordCorrection.wordCorrectionEnabled = snapshot.wordCorrectionEnabled
    steps.fillerRemoval.fillerRemovalEnabled = snapshot.fillerRemovalEnabled
    steps.emojiFormatter.emojiFormatterEnabled = snapshot.emojiFormatterEnabled
    // Match the live ITN language gate: a LID engine with unknown language skips
    // ITN rather than rewriting possibly-non-English text. Sourced from the
    // record-time capability, never an engine-identity literal (Codex PR0 P2).
    steps.inverseTextNormalization.backendSupportsLID = snapshot.backendSupportsLanguageDetection
    steps.llmPolish.llmProvider = LLMProvider(rawValue: snapshot.llmProvider) ?? .none
    steps.llmPolish.llmModel = snapshot.llmModel
    steps.llmPolish.backend = snapshot.backendType
    // Reasoning setting at record time, so a reasoning-capable provider replays
    // under the same setting the live dictation used (Codex PR0 P2).
    steps.llmPolish.useExtendedThinking = snapshot.useExtendedThinking
    // No persisted language-detection result for a recovered take (mirrors
    // TranscriptPolishService); the planner treats nil detection safely.
    steps.llmPolish.languageDetection = nil
    // `polishInstructions` is intentionally left at the step default: the live
    // value (`SettingsManager.activePolishInstructions`) is the constant
    // `.default` since the preset axis was removed (#614), so there is nothing
    // per-recording to restore. The custom-words VOCABULARY (`correctorVocabulary`
    // / `polishVocabulary`) is also not in the snapshot (only its version); PR2
    // reconstructs and assigns it separately.
    // Replay under the recording's locked decode language (or nil for auto),
    // exactly as the live path derives the runner language from the frozen
    // session config's languageMode. Using a caller-supplied or re-detected
    // language instead could rewrite a locked non-English take as English
    // (Codex PR0 P2).
    if case .locked(let code) = snapshot.languageMode {
      recordedLanguage = code
    } else {
      recordedLanguage = nil
    }
  }

  /// Run the chain. Limb failures inside the chain (a step erroring or timing
  /// out) are absorbed by the runner and surface as a raw-fallback outcome;
  /// only cancellation propagates, and that too falls back to raw.
  public func process(rawText: String, targetAppName: String? = nil) async
    -> RecoveryTextOutcome
  {
    do {
      let result = try await runner.run(
        rawText: rawText,
        language: recordedLanguage,
        targetAppName: targetAppName,
        steps: [
          steps.wordCorrection, steps.fillerRemoval, steps.emojiFormatter,
          steps.inverseTextNormalization, steps.llmPolish,
        ])
      return RecoveryTextOutcome(
        text: result.context.text,
        polishedText: result.context.polishedText,
        polishError: result.polishError)
    } catch {
      return RecoveryTextOutcome(text: rawText, polishedText: nil, polishError: nil)
    }
  }
}
