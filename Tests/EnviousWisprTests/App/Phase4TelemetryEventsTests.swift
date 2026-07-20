import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprLLM

#if DEBUG

  /// Telemetry Bible Phase 4 (#1173): the new event facades, the comprehensive
  /// snapshot `config` block, and the validation-guard contract. Synchronous
  /// set-hook → act → read → restore (serialized for the process-global hook).
  @MainActor
  @Suite("Phase 4 telemetry events", .serialized)
  struct Phase4TelemetryEventsTests {

    final class Box: @unchecked Sendable {
      private let lock = NSLock()
      private var stored: [CapturedTelemetryEvent] = []
      func add(_ e: CapturedTelemetryEvent) { lock.withLock { stored.append(e) } }
      var all: [CapturedTelemetryEvent] { lock.withLock { stored } }
      func named(_ n: String) -> [CapturedTelemetryEvent] { all.filter { $0.name == n } }
    }

    private func capture(_ body: () -> Void) -> Box {
      let box = Box()
      TelemetryService.shared.testEventHook = { @Sendable e in box.add(e) }
      defer { TelemetryService.shared.testEventHook = nil }
      body()
      return box
    }

    @Test("settingsChanged carries setting/from/to/source")
    func settingsChangedFacade() {
      let box = capture {
        TelemetryService.shared.settingsChanged(
          setting: "recording_mode", from: "pushToTalk", to: "toggle", source: "user")
      }
      let e = box.named("settings.changed").first
      #expect(e?.stringProps["setting"] == "recording_mode")
      #expect(e?.stringProps["from"] == "pushToTalk")
      #expect(e?.stringProps["to"] == "toggle")
      #expect(e?.stringProps["source"] == "user")
    }

    @Test("apiKeyChanged carries provider/action/result, never key material")
    func apiKeyChangedFacade() {
      let box = capture {
        TelemetryService.shared.apiKeyChanged(
          provider: "openAI", action: "save", result: "success")
      }
      let e = box.named("api_key.changed").first
      #expect(e?.stringProps["provider"] == "openAI")
      #expect(e?.stringProps["action"] == "save")
      #expect(e?.stringProps["result"] == "success")
    }

    @Test("apiKeyValidationCompleted carries provider/result/source")
    func apiKeyValidationFacade() {
      let box = capture {
        TelemetryService.shared.apiKeyValidationCompleted(
          provider: "gemini", result: "invalid", source: "save")
      }
      let e = box.named("api_key.validation_completed").first
      #expect(e?.stringProps["provider"] == "gemini")
      #expect(e?.stringProps["result"] == "invalid")
      #expect(e?.stringProps["source"] == "save")
    }

    @Test(
      "apiKeyValidationCompleted with modelCount/discoveryOutcome distinguishes a healthy zero-model result from an unhealthy one (#158)"
    )
    func apiKeyValidationFacadeWithDiscoveryOutcome() {
      let box = capture {
        TelemetryService.shared.apiKeyValidationCompleted(
          provider: "claude", result: "valid", source: "save",
          modelCount: 0, discoveryOutcome: "zero_models")
      }
      let e = box.named("api_key.validation_completed").first
      #expect(e?.stringProps["provider"] == "claude")
      #expect(e?.stringProps["result"] == "valid")
      #expect(e?.stringProps["discovery_outcome"] == "zero_models")
      #expect(e?.intProps["model_count"] == 0)
    }

    @Test(
      "apiKeyValidationCompleted's new params are optional — existing 3-arg callers stay source-compatible"
    )
    func apiKeyValidationFacadeBackwardCompatible() {
      let box = capture {
        TelemetryService.shared.apiKeyValidationCompleted(
          provider: "openAI", result: "valid", source: "model_discovery")
      }
      let e = box.named("api_key.validation_completed").first
      #expect(e?.stringProps["provider"] == "openAI")
      #expect(e?.stringProps["discovery_outcome"] == nil)
      #expect(e?.intProps["model_count"] == nil)
    }

    @Test("ApiKeyValidationSource rawValues match the wire vocabulary")
    func validationSourceRawValues() {
      #expect(ApiKeyValidationSource.save.rawValue == "save")
      #expect(ApiKeyValidationSource.modelDiscovery.rawValue == "model_discovery")
    }

    @Test("Comprehensive snapshot includes the projected config block")
    func snapshotConfigBlock() {
      let suite = UserDefaults(suiteName: "P4Snap-\(UUID().uuidString)")!
      let settings = SettingsManager(defaults: suite)
      let permissions = PermissionsService(accessibilityReader: { true })
      let builder = StandingSnapshotBuilder(
        settings: settings,
        keychainManager: KeychainManager(),
        customWordsCoordinator: CustomWordsCoordinator(),
        permissions: permissions)
      let box = capture { builder.emit() }
      let snap = box.named("settings.snapshot").first
      // New comprehensive fields ride alongside the ten legacy fields.
      #expect(snap?.stringProps["llm_model"] != nil)
      #expect(snap?.stringProps["crash_recovery"] == "on")  // default ON
      #expect(snap?.stringProps["toggle_hotkey_shape"] == "modifier_only")  // default rightOption
      #expect(snap?.stringProps["language_mode"] == "auto")
      // The legacy typed fields are still present and unchanged.
      #expect(snap?.stringProps["recording_mode"] == settings.recordingMode.rawValue)
      // The three typed fields never duplicate into the config block.
      #expect(snap?.boolProps["filler_removal"] != nil)
    }

    @Test("Snapshot never leaks a stale private model name under a cloud provider")
    func snapshotStaleCloudCarryoverIsCustom() {
      let suite = UserDefaults(suiteName: "P4Stale-\(UUID().uuidString)")!
      let settings = SettingsManager(defaults: suite)
      // P1: provider is a cloud one but llmModel still holds a private local id
      // (carried over from a prior Ollama selection, before discovery corrected it).
      settings.llmProvider = .openAI
      settings.llmModel = "acme-private-tuned"
      let builder = StandingSnapshotBuilder(
        settings: settings,
        keychainManager: KeychainManager(),
        customWordsCoordinator: CustomWordsCoordinator(),
        permissions: PermissionsService(accessibilityReader: { true }))
      let snap = capture { builder.emit() }.named("settings.snapshot").first
      #expect(snap?.stringProps["llm_model"] == "custom")  // deny-by-default, never the raw name
    }

    @Test("flushTelemetry drains a pending settings delta before flushing (onBeforeFlush)")
    func flushDrainsPendingSettingsDelta() {
      let suite = UserDefaults(suiteName: "P4Flush-\(UUID().uuidString)")!
      let settings = SettingsManager(defaults: suite)
      settings.onboardingState = .completed
      let telemetry = SettingsChangeTelemetry(settings: settings, emitBaseline: {})
      settings.onChange = { [weak telemetry] key in telemetry?.handle(key) }
      TelemetryService.shared.flushContextProvider = nil
      TelemetryService.shared.onBeforeFlush = { [weak telemetry] in telemetry?.flush() }
      defer { TelemetryService.shared.onBeforeFlush = nil }
      let box = Box()
      TelemetryService.shared.testEventHook = { @Sendable e in box.add(e) }
      defer { TelemetryService.shared.testEventHook = nil }
      // Change a setting but DO NOT flush() — it sits pending in the debounce
      // window, exactly as it would if the user quit immediately after.
      settings.recordingMode = .toggle
      #expect(box.named("settings.changed").isEmpty)  // still pending
      // A terminate/update flush must drain it first.
      TelemetryService.shared.flushTelemetry(reason: .appTerminate)
      #expect(
        box.named("settings.changed").contains {
          $0.stringProps["setting"] == "recording_mode" && $0.stringProps["to"] == "toggle"
        })
      _ = telemetry  // keep alive past the flush
    }

    @Test("Missing-key validation guard emits NO validation_completed event")
    func missingKeyNoValidationEvent() async {
      // Isolated EMPTY key store in a temp dir — never touch the developer's or
      // CI's real `~/.enviouswispr-keys` (Codex r1). With no key present, the
      // guard returns before any validation runs.
      let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("P4Guard-\(UUID().uuidString)", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: dir) }
      let keychain = KeychainManager(
        backend: .legacyFiles, legacyStore: FileLegacyKeyStore(storageDirectory: dir))
      let coordinator = LLMModelDiscoveryCoordinator(keychainManager: keychain)
      let suite = UserDefaults(suiteName: "P4Guard-\(UUID().uuidString)")!
      let settings = SettingsManager(defaults: suite)
      let box = Box()
      TelemetryService.shared.testEventHook = { @Sendable e in box.add(e) }
      defer { TelemetryService.shared.testEventHook = nil }
      await coordinator.validateKeyAndDiscoverModels(provider: .openAI, settings: settings)
      #expect(box.named("api_key.validation_completed").isEmpty)
    }
  }

#endif
