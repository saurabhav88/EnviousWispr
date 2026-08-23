import EnviousWisprCore
import EnviousWisprLLM
import Foundation

// MARK: - Recovery text-processing seam (#1063 PR0)
//
// Recovery must run the SAME post-ASR text chain a live dictation runs
// (word correction -> filler removal -> emoji -> inverse text normalization ->
// LLM polish -> emoji restore), but OUTSIDE the live kernel. The chain's runner
// and steps are internal to Pipeline and not reusable from the App layer, so
// this is the small PUBLIC seam that reuses the internal `TextProcessingRunner`
// + the same six step instances.
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

/// Runs the standard six-step post-ASR text chain on a recovered transcript.
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
    keychainManager: KeychainManager, outputClassifierHolder: OutputClassifierHolder? = nil,
    egOneRuntime: (any EGOneEndpointProviding)? = nil
  ) {
    let llmPolish = LLMPolishStep(keychainManager: keychainManager, telemetry: .silent())
    // Standalone (no live kernel attached): no streaming/lifecycle callbacks.
    llmPolish.onWillProcess = nil
    llmPolish.onToken = nil
    llmPolish.outputClassifierHolder = outputClassifierHolder
    // #1271: recovery polishes through the SAME EG-1 server as live dictation
    // (or silently skips when it is not ready) — never crashes on a nil handle.
    llmPolish.egOneRuntime = egOneRuntime
    // `emojiRestore` is the final limb (#761): always-on and data-driven, it
    // no-ops unless the recovered take polished under a RESTORING path (Apple
    // Intelligence, or local Ollama since #1948) and a glyph was dropped, so it
    // needs no settings from the snapshot.
    self.steps = LimbSteps(
      wordCorrection: WordCorrectionStep(),
      fillerRemoval: FillerRemovalStep(),
      emojiFormatter: EmojiFormatterStep(),
      inverseTextNormalization: InverseTextNormalizationStep(),
      llmPolish: llmPolish,
      emojiRestore: EmojiRestoreStep())
    // #945 / #1446 / #1461: crash recovery is invisible to live-polish
    // telemetry. The runner and LLMPolishStep each own separate emitter sets,
    // so recovery constructs both with their complete `.silent` presets.
    // Recovery's own coarse result reporting remains owned by its replay flow.
    self.runner = TextProcessingRunner(telemetry: .silent)
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
    // #1794: a legacy spool records no preference for this setting, absence is not an
    // affirmative opt-in, and the founder-directed default is OFF. Does NOT depend on
    // whether the take was ever delivered.
    steps.inverseTextNormalization.spokenPunctuationEnabled =
      snapshot.spokenPunctuationEnabled ?? false
    // Match the live ITN language gate: a LID engine with unknown language skips
    // ITN rather than rewriting possibly-non-English text. Sourced from the
    // record-time capability, never an engine-identity literal (Codex PR0 P2).
    steps.inverseTextNormalization.backendSupportsLID = snapshot.backendSupportsLanguageDetection
    steps.llmPolish.llmProvider = LLMProvider(rawValue: snapshot.llmProvider) ?? .none
    // #1770: replay the RECORDED model, except when the provider has since
    // withdrawn it. This is the second of exactly two production seams where a
    // user-selected model reaches `LLMPolishStep` (the other is the live frozen
    // config), and it bypasses `SettingsManager`'s sweep entirely because it
    // deliberately restores capture-time settings rather than current ones. A
    // spool captured while the user was pinned to a retired id would otherwise
    // replay against a dead model and return unpolished text.
    //
    // This does not violate the replay-original-settings contract: the original
    // model no longer exists, so the honest reproduction is the current default.
    steps.llmPolish.llmModel = LLMProvider.replacingRetiredModel(
      snapshot.llmModel, for: steps.llmPolish.llmProvider)
    steps.llmPolish.backend = snapshot.backendType
    // #1831 removed the record-time reasoning setting this used to replay. The
    // reason it existed still holds and is now satisfied structurally rather
    // than by carrying state: a recovered take must polish under the same
    // request shape the live dictation would have used, and that shape is now
    // determined entirely by provider + model, both of which ARE replayed from
    // the snapshot two lines above.
    // No persisted language-detection result for a recovered take; the planner
    // treats nil detection safely.
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

  /// Assign the CURRENT custom-words vocabulary, best-effort (#1063 PR2). The
  /// snapshot carries only the custom-words VERSION, not the terms, so recovery
  /// cannot replay the exact record-time vocabulary; it applies the user's
  /// current words instead. Recovery promises normal-quality, not byte-exact —
  /// without this, a power user's recovered transcript would skip word
  /// correction the live take had. Caller builds the two vocabularies from the
  /// live custom-words home (`CustomWordsVocabularySplit.split`).
  public func applyCustomWordsVocabulary(
    corrector: CorrectorVocabulary, polish: PolishVocabulary
  ) {
    steps.wordCorrection.correctorVocabulary = corrector
    steps.llmPolish.polishVocabulary = polish
  }

  /// Run the chain. Limb failures inside the chain (a step erroring or timing
  /// A blank polish is not a polish (#1948). Returns nil for nil, empty, or
  /// whitespace-only input so the caller delivers the deterministic floor instead.
  ///
  /// Named and tested rather than inlined because it encodes the same rule as live
  /// finalization's empty-output floor (`KernelFinalizationWiring` `:349`), which this
  /// replay path does not share. Without it a blank result is saved to History AS the
  /// polished text and reported `polishFellBack: false` (`RecoverySpoolReplayer` `:323`,
  /// `:383`) — telemetry claiming a polish succeeded when it produced nothing.
  static func usablePolish(_ polished: String?) -> String? {
    guard let polished,
      !polished.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return polished
  }

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
          steps.inverseTextNormalization, steps.llmPolish, steps.emojiRestore,
        ])
      // #1948: a BLANK polish is not a polish. Live finalization has an empty-output
      // recovery floor (`KernelFinalizationWiring` `:349`) that turns "" into the intact
      // deterministic text; this replay path has none, so a blank result would be saved to
      // History as the polished text AND reported as `polishFellBack: false`
      // (`RecoverySpoolReplayer` `:323`, `:383`) — telemetry claiming a polish succeeded
      // when it produced nothing. Reachable the same way as on the live path:
      // `OllamaConnector` accepts a whitespace response as success and trims it to "", and
      // `validatePolishOutput` has no empty guard below 10 input words.
      //
      // Normalising to nil here delivers `context.text`, the post-ITN deterministic floor,
      // which is what the live path's floor produces for the same input.
      return RecoveryTextOutcome(
        text: result.context.text,
        polishedText: Self.usablePolish(result.context.polishedText),
        polishError: result.polishError)
    } catch {
      return RecoveryTextOutcome(text: rawText, polishedText: nil, polishError: nil)
    }
  }
}
