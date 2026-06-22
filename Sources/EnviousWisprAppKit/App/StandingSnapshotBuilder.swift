import EnviousWisprLLM
import EnviousWisprServices

/// Telemetry Bible Phase 0 (#1169): the single home that builds and emits the
/// standing settings/permission snapshot.
///
/// Today it emits the launch-time `settings.snapshot` — a behavior-preserving
/// extraction of the former inline block in `AppLifecycleCoordinator`
/// (identical event, identical seven fields, identical launch timing). Phase 3
/// (#1172) extends it with microphone / Accessibility posture; Phase 4 (#1173)
/// adds the debounced change-driven re-emit. Telemetry is a limb: this never
/// throws and must not block launch — Keychain reads stay `try?`-guarded so a
/// read failure degrades to `hasApiKeys = false` exactly as before.
@MainActor
struct StandingSnapshotBuilder {
  private let settings: SettingsManager
  private let keychainManager: KeychainManager
  private let customWordsCoordinator: CustomWordsCoordinator

  init(
    settings: SettingsManager,
    keychainManager: KeychainManager,
    customWordsCoordinator: CustomWordsCoordinator
  ) {
    self.settings = settings
    self.keychainManager = keychainManager
    self.customWordsCoordinator = customWordsCoordinator
  }

  /// Build the current snapshot values and emit `settings.snapshot`.
  func emit() {
    let s = settings
    let hasKeys =
      (try? keychainManager.retrieve(key: KeychainManager.openAIKeyID)) != nil
      || (try? keychainManager.retrieve(key: KeychainManager.geminiKeyID)) != nil
    TelemetryService.shared.settingsSnapshot(
      asrBackend: s.selectedBackend.rawValue,
      llmProvider: s.llmProvider.rawValue,
      recordingMode: s.recordingMode.rawValue,
      fillerRemoval: s.fillerRemovalEnabled,
      customWordsCount: customWordsCoordinator.customWords.count,
      hasApiKeys: hasKeys,
      noiseSuppression: s.noiseSuppression
    )
  }
}
