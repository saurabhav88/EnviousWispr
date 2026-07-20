import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprLLM

#if DEBUG

  /// Telemetry Bible Phase 0 (#1169): the `StandingSnapshotBuilder` seam is a
  /// behavior-preserving extraction of the former inline launch emission. This
  /// pins that `emit()` sends `settings.snapshot` with the current settings
  /// values, so a later Phase-3/4 extension can't silently change the launch
  /// payload. Body is synchronous (set hook -> emit -> read -> restore, no
  /// await), so the process-global `testEventHook` is flake-immune per
  /// swift-patterns RULE: tests-no-process-global-mutable-delegate.
  @Suite("Standing snapshot builder", .serialized)
  struct StandingSnapshotBuilderTests {
    final class EventBox: @unchecked Sendable {
      private let lock = NSLock()
      private var stored: CapturedTelemetryEvent?
      func set(_ event: CapturedTelemetryEvent) { lock.withLock { stored = event } }
      var value: CapturedTelemetryEvent? { lock.withLock { stored } }
    }

    @MainActor
    @Test("emit() sends settings.snapshot carrying the current settings values")
    func emitSendsSnapshotWithCurrentValues() {
      let suite = UserDefaults(suiteName: "StandingSnapshotBuilderTests-\(UUID().uuidString)")!
      let settings = SettingsManager(defaults: suite)
      let customWords = CustomWordsCoordinator()
      // Phase 3 (#1172): inject a granted Accessibility reader so the posture
      // field is deterministic; microphone status is the machine's real value.
      let permissions = PermissionsService(accessibilityReader: { true })
      let builder = StandingSnapshotBuilder(
        settings: settings,
        keychainManager: KeychainManager(),
        customWordsCoordinator: customWords,
        permissions: permissions
      )

      let box = EventBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        if event.name == "settings.snapshot" { box.set(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      builder.emit()

      guard let event = box.value else {
        Issue.record("Expected settings.snapshot event")
        return
      }
      #expect(event.stringProps["asr_backend"] == settings.selectedBackend.rawValue)
      #expect(event.stringProps["llm_provider"] == settings.llmProvider.rawValue)
      #expect(event.stringProps["recording_mode"] == settings.recordingMode.rawValue)
      #expect(event.boolProps["filler_removal"] == settings.fillerRemovalEnabled)
      #expect(event.intProps["custom_words_count"] == customWords.customWords.count)
      // has_api_keys depends on the machine's Keychain/file backend, so assert
      // presence (not a fixed truth value) to stay deterministic across runs.
      #expect(event.boolProps["has_api_keys"] != nil)
      // Phase 3 (#1172): permission posture fields.
      #expect(event.stringProps["accessibility_status"] == "granted")
      // microphone_status is the machine's real authorization, so assert
      // presence rather than a fixed value.
      #expect(event.stringProps["microphone_status"] != nil)
      #expect(event.boolProps["accessibility_warning_dismissed"] != nil)
    }

    /// A per-key-id in-memory store standing in for the real legacy-file
    /// backend, so `has_api_keys` can be tested deterministically instead of
    /// asserting mere presence against the machine's real Keychain state.
    private final class SingleKeyStore: LegacyKeyFileStorage, @unchecked Sendable {
      let key: String
      let value: String
      init(key: String, value: String) {
        self.key = key
        self.value = value
      }
      func store(key: String, value: String) throws {}
      func retrieve(key: String) throws -> String {
        guard key == self.key else { throw KeyStoreError.retrieveFailed(errSecItemNotFound) }
        return value
      }
      func delete(key: String) throws {}
    }

    @MainActor
    @Test("A Claude-only saved key makes has_api_keys true (#158)")
    func claudeOnlyKeyMakesHasApiKeysTrue() {
      let suite = UserDefaults(suiteName: "StandingSnapshotBuilderTests-\(UUID().uuidString)")!
      let settings = SettingsManager(defaults: suite)
      let keychain = KeychainManager(
        backend: .legacyFiles,
        legacyStore: SingleKeyStore(key: KeychainManager.claudeKeyID, value: "sk-ant-test"))
      let builder = StandingSnapshotBuilder(
        settings: settings,
        keychainManager: keychain,
        customWordsCoordinator: CustomWordsCoordinator(),
        permissions: PermissionsService(accessibilityReader: { true })
      )

      let box = EventBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        if event.name == "settings.snapshot" { box.set(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      builder.emit()

      guard let event = box.value else {
        Issue.record("Expected settings.snapshot event")
        return
      }
      #expect(event.boolProps["has_api_keys"] == true)
    }
  }

#endif
