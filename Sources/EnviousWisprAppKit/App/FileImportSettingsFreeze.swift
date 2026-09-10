import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices

/// #2648 — the user's current settings, frozen for one import.
///
/// **One import, one configuration** (founder, 2026-09-04). A user who changes
/// their polisher halfway through a 40-minute file must not get a document
/// polished two different ways, so the run takes a copy at Start and every part
/// reads that copy.
///
/// Reuses `RecordingSettingsSnapshot` rather than declaring a parallel type. It
/// is already the single authority for "the settings a text-processing run
/// needs", it is what the crash-recovery replay reads, and a second type would
/// be a second thing to keep in step every time a limb gains a setting.
@MainActor
enum FileImportSettingsFreeze {
  static func snapshot(settings: SettingsManager) -> RecordingSettingsSnapshot {
    RecordingSettingsSnapshot(
      backendType: settings.selectedBackend,
      backendSupportsLanguageDetection: false,
      languageMode: settings.languageMode,
      wordCorrectionEnabled: settings.wordCorrectionEnabled,
      fillerRemovalEnabled: settings.fillerRemovalEnabled,
      emojiFormatterEnabled: settings.emojiFormatterEnabled,
      spokenPunctuationEnabled: settings.spokenPunctuationEnabled,
      customWordsVersion: nil,
      llmProvider: settings.llmProvider.rawValue,
      llmModel: settings.llmModel,
      s1Control: settings.s1Control)
  }
}
