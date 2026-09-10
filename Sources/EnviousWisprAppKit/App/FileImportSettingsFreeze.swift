import EnviousWisprASR
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
  /// `backend` and `polish` come from the WIZARD, not from settings: the user
  /// chose them for this file on their own screens, and a run that ignored them
  /// would make those screens decorative.
  static func snapshot(
    settings: SettingsManager, backend: ASRBackendType, polish: LLMProvider
  ) -> RecordingSettingsSnapshot {
    RecordingSettingsSnapshot(
      backendType: backend,
      backendSupportsLanguageDetection: false,
      languageMode: settings.languageMode,
      wordCorrectionEnabled: settings.wordCorrectionEnabled,
      fillerRemovalEnabled: settings.fillerRemovalEnabled,
      emojiFormatterEnabled: settings.emojiFormatterEnabled,
      spokenPunctuationEnabled: settings.spokenPunctuationEnabled,
      customWordsVersion: nil,
      llmProvider: polish.rawValue,
      llmModel: settings.llmModel,
      s1Control: settings.s1Control)
  }

  /// What the rest of the app must read INSTEAD of live settings once a run has
  /// started: where this run's text goes, and which bundled local server it
  /// depends on.
  ///
  /// Derived from the same snapshot the runner froze, so the page's privacy
  /// line and the engine reconciliation cannot disagree with what the parts are
  /// actually polished by.
  static func configuration(for snapshot: RecordingSettingsSnapshot)
    -> FileImportCoordinator.RunConfiguration
  {
    let provider = LLMProvider(rawValue: snapshot.llmProvider) ?? .none
    return FileImportCoordinator.RunConfiguration(
      polishIsCloud: TranscribeFileView.isCloud(provider),
      // Only the BUNDLED servers are pinnable: Ollama is the user's own process
      // and the cloud providers have nothing on this Mac to tear down.
      localPolishProvider: (provider == .egOne || provider == .s1Mini) ? provider : nil)
  }
}
