import EnviousWisprASR
import EnviousWisprCore
// `OllamaConnector.effectiveOllamaModel` is the canonical "which model will this
// provider actually ask for" resolution, and the eviction rule this pin feeds
// keys on exactly that value. Resolving it any other way here would compare two
// spellings of one model.
import EnviousWisprLLM
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
  /// Reads settings and nothing else.
  ///
  /// **#2772 replaced the reason this used to carry.** It said: "The wizard's Transcription
  /// and Polish steps WRITE these settings when the user picks, so by the time Start is
  /// pressed the user's choice IS the setting — there is no second copy to prefer, and no
  /// way for the two to disagree." That was true and it was the defect: the Polish step
  /// wrote DICTATION's polisher, so choosing an engine for one import silently changed
  /// what every later dictation used. There is now deliberately a second choice, and
  /// `effectiveFileImportLLMProvider` is the one authority on which one an import gets.
  ///
  /// The TRANSCRIPTION engine is still shared and still written by the wizard, on purpose
  /// (#2772 §3.2): there is one ASR slot and `EngineCoordinator` owns exactly one live
  /// target. The wizard now says so above its cards rather than changing it silently.
  ///
  /// **The polish model is resolved, not raw.** Reading `settings.llmModel` here was wrong
  /// for Ollama — the armed model is `ollamaModel`, and `applyDiscoveredModels`
  /// deliberately does not refill `llmModel` (#1305, #1914), so an Ollama import could
  /// freeze a cloud model id left over from another provider. #2772 §3.3.
  static func snapshot(settings: SettingsManager) -> RecordingSettingsSnapshot {
    RecordingSettingsSnapshot(
      backendType: settings.selectedBackend,
      // **Asked, not assumed.** Hardcoding false told the resolver to ignore
      // whatever WhisperKit reported, so an automatic-language import fell back
      // to identifying the language from the ASR text — the weakest source in
      // the ladder, on the text least safe to guess from. Found by cloud review.
      backendSupportsLanguageDetection: settings.selectedBackend == .whisperKit,
      languageMode: settings.languageMode,
      wordCorrectionEnabled: settings.wordCorrectionEnabled,
      fillerRemovalEnabled: settings.fillerRemovalEnabled,
      emojiFormatterEnabled: settings.emojiFormatterEnabled,
      spokenPunctuationEnabled: settings.spokenPunctuationEnabled,
      customWordsVersion: nil,
      llmProvider: settings.effectiveFileImportLLMProvider.rawValue,
      llmModel: settings.effectiveFileImportLLMModel,
      s1Control: settings.s1Control)
  }

  /// What the rest of the app must read INSTEAD of live settings once a run has
  /// started: where this run's text goes, and which bundled local server it
  /// depends on.
  ///
  /// Derived from the same snapshot the runner froze, so the page's privacy
  /// line and the engine reconciliation cannot disagree with what the parts are
  /// actually polished by.
  /// - Parameter ollamaModelIsRemote: whether THIS run's Ollama model is one the
  ///   daemon proxies to its own servers, or `nil` when the daemon has not been
  ///   asked. Passed in rather than looked up here so the value is taken once,
  ///   at Start, and cannot change under a document that has already been
  ///   polished. The `nil` case travels all the way to the disclosure, which
  ///   refuses to promise local processing on an unknown.
  static func configuration(
    for snapshot: RecordingSettingsSnapshot, ollamaModelIsRemote: Bool?
  ) -> FileImportCoordinator.RunConfiguration {
    let provider = LLMProvider(rawValue: snapshot.llmProvider) ?? .none
    return FileImportCoordinator.RunConfiguration(
      polishIsCloud: TranscribeFileView.isCloud(
        provider, ollamaModelIsRemote: ollamaModelIsRemote),
      // Only the BUNDLED servers are pinnable: Ollama is the user's own process
      // and the cloud providers have nothing on this Mac to tear down.
      localPolishProvider: (provider == .egOne || provider == .s1Mini) ? provider : nil,
      polishProvider: provider,
      // Only a LOCAL Ollama model has weights on this Mac for the eviction rule
      // to unload, so a remote one is deliberately nil: pinning it would defer
      // an eviction that was never going to happen and leave the tracker asking
      // the same question on every later settings change.
      // A KNOWN-local model only. Unknown is not pinned: the eviction rule
      // deliberately evicts an unknown model, and deferring that on a guess
      // would leave its tracker asking the same question forever.
      ollamaModel: (provider == .ollama && ollamaModelIsRemote == false)
        ? OllamaConnector.effectiveOllamaModel(provider: provider, model: snapshot.llmModel)
        : nil)
  }
}
