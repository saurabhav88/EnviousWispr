import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit

#if DEBUG

  /// Telemetry Bible Phase 4 (#1173): coalescing, source classification,
  /// projection, and the onboarding-completion baseline of `SettingsChangeTelemetry`.
  /// The debounce delay is bypassed by calling `flush()` directly — it is not a
  /// SUT measurement, so no clock seam is needed (`tests-no-real-time-scheduling-precision`).
  /// Body is synchronous (set hook → mutate → flush → read → restore), so the
  /// process-global `testEventHook` is flake-immune (suite is `.serialized`).
  @MainActor
  @Suite("Settings change telemetry", .serialized)
  struct SettingsChangeTelemetryTests {

    /// Collects every `settings.changed` event the hook sees, in order.
    final class DeltaBox: @unchecked Sendable {
      private let lock = NSLock()
      private var stored: [CapturedTelemetryEvent] = []
      func add(_ e: CapturedTelemetryEvent) { lock.withLock { stored.append(e) } }
      func clear() { lock.withLock { stored.removeAll() } }
      var all: [CapturedTelemetryEvent] { lock.withLock { stored } }
    }

    final class BaselineSpy: @unchecked Sendable {
      private let lock = NSLock()
      private var n = 0
      func bump() { lock.withLock { n += 1 } }
      var count: Int { lock.withLock { n } }
    }

    /// Build a settings manager + wired observer + a captured-delta box.
    /// `onboarding` defaults to `.completed` so changes are NOT suppressed.
    private func makeHarness(
      onboarding: OnboardingState = .completed
    ) -> (SettingsManager, SettingsChangeTelemetry, DeltaBox, BaselineSpy) {
      let suite = UserDefaults(suiteName: "SCT-\(UUID().uuidString)")!
      let settings = SettingsManager(defaults: suite)
      settings.onboardingState = onboarding
      let spy = BaselineSpy()
      let telemetry = SettingsChangeTelemetry(
        settings: settings, emitBaseline: { spy.bump() })
      settings.onChange = { [weak telemetry] key in telemetry?.handle(key) }
      let box = DeltaBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        if event.name == "settings.changed" { box.add(event) }
      }
      return (settings, telemetry, box, spy)
    }

    private func deltas(_ box: DeltaBox, setting: String) -> [CapturedTelemetryEvent] {
      box.all.filter { $0.stringProps["setting"] == setting }
    }

    @Test("A→B→A net no-op emits nothing")
    func noOpBurst() {
      let (settings, telemetry, box, _) = makeHarness()
      defer { TelemetryService.shared.testEventHook = nil }
      settings.recordingMode = .toggle
      settings.recordingMode = .pushToTalk  // back to launch default
      telemetry.flush()
      #expect(deltas(box, setting: "recording_mode").isEmpty)
    }

    @Test("A→B→C coalesces to one delta from A to C")
    func coalesceToSingle() {
      let (settings, telemetry, box, _) = makeHarness()
      defer { TelemetryService.shared.testEventHook = nil }
      // appearance has three values; default is .system.
      settings.appearancePreference = .light
      settings.appearancePreference = .dark
      telemetry.flush()
      let d = deltas(box, setting: "appearance")
      #expect(d.count == 1)
      #expect(d.first?.stringProps["from"] == "system")
      #expect(d.first?.stringProps["to"] == "dark")
      #expect(d.first?.stringProps["source"] == "user")
    }

    @Test("Two settings in one window emit two deltas")
    func twoSettingsTwoDeltas() {
      let (settings, telemetry, box, _) = makeHarness()
      defer { TelemetryService.shared.testEventHook = nil }
      settings.recordingMode = .toggle
      settings.autoCopyToClipboard = false
      telemetry.flush()
      #expect(deltas(box, setting: "recording_mode").count == 1)
      #expect(deltas(box, setting: "auto_copy").count == 1)
      #expect(deltas(box, setting: "auto_copy").first?.stringProps["to"] == "off")
    }

    @Test("Hotkey keyCode-only change within the same shape emits nothing")
    func hotkeySameShapeNoOp() {
      let (settings, telemetry, box, _) = makeHarness()
      defer { TelemetryService.shared.testEventHook = nil }
      // Default toggle keyCode is right Option (modifier-only). Switch to left
      // Option (also modifier-only) — the projected shape is unchanged.
      settings.toggleKeyCode = ModifierKeyCodes.leftOption
      telemetry.flush()
      #expect(deltas(box, setting: "toggle_hotkey_shape").isEmpty)
    }

    @Test("Hotkey shape transition emits one shape-only delta")
    func hotkeyShapeTransition() {
      let (settings, telemetry, box, _) = makeHarness()
      defer { TelemetryService.shared.testEventHook = nil }
      settings.toggleKeyCode = 49  // Space — a regular key → chord
      telemetry.flush()
      let d = deltas(box, setting: "toggle_hotkey_shape")
      #expect(d.count == 1)
      #expect(d.first?.stringProps["from"] == "modifier_only")
      #expect(d.first?.stringProps["to"] == "chord")
    }

    @Test("Hotkey keyCode + modifiers in one edit emit one grouped delta")
    func hotkeyGroupedKeyAndModifiers() {
      let (settings, telemetry, box, _) = makeHarness()
      defer { TelemetryService.shared.testEventHook = nil }
      settings.toggleKeyCode = 49  // Space
      settings.toggleModifiers = .option
      telemetry.flush()
      #expect(deltas(box, setting: "toggle_hotkey_shape").count == 1)
    }

    @Test("System model auto-correction is tagged source=system, not suppressed")
    func systemWriteTagged() {
      let (settings, telemetry, box, _) = makeHarness()
      defer { TelemetryService.shared.testEventHook = nil }
      settings.llmProvider = .openAI
      telemetry.flush()
      box.clear()  // drop the provider-switch deltas; isolate the discovery write
      // Empty discovery → applyDiscoveredModels resets to the provider default
      // under the isApplyingSystemWrite flag.
      settings.llmModel = "gpt-4o"  // a user-ish divergence first
      telemetry.flush()
      box.clear()
      settings.applyDiscoveredModels([], for: .openAI)  // → "gpt-4o-mini", system
      telemetry.flush()
      let d = deltas(box, setting: "llm_model")
      #expect(d.count == 1)
      #expect(d.first?.stringProps["source"] == "system")
      #expect(d.first?.stringProps["to"] == "gpt-4o-mini")
    }

    @Test("Onboarding-time writes are suppressed but advance the baseline")
    func onboardingSuppressedThenBaseline() {
      let (settings, telemetry, box, _) = makeHarness(onboarding: .needsPermissions)
      defer { TelemetryService.shared.testEventHook = nil }
      settings.recordingMode = .toggle  // onboarding write → suppressed
      telemetry.flush()
      #expect(deltas(box, setting: "recording_mode").isEmpty)
      // Complete onboarding, then a real change emits from the suppressed value.
      settings.onboardingState = .completed
      settings.recordingMode = .pushToTalk
      telemetry.flush()
      let d = deltas(box, setting: "recording_mode")
      #expect(d.count == 1)
      #expect(d.first?.stringProps["from"] == "toggle")  // baseline advanced
      #expect(d.first?.stringProps["to"] == "pushToTalk")
    }

    @Test("Onboarding completion re-seeds baseline for a derived projection")
    func onboardingCompletionReseedsDerivedProjection() {
      let (settings, telemetry, box, _) = makeHarness(onboarding: .needsPermissions)
      defer { TelemetryService.shared.testEventHook = nil }
      // During onboarding: OpenAI (model canonicalizes → gpt-4o-mini), then Ollama
      // — the latter does NOT rewrite llmModel, but the EFFECTIVE model flips to
      // ollamaModel ("llama3.2") with no `.llmModel`/`.ollamaModel` fire.
      // committedBaseline[llm_model] would stay stale ("gpt-4o-mini") without the
      // completion re-seed.
      settings.llmProvider = .openAI
      settings.llmProvider = .ollama
      settings.onboardingState = .completed  // snapshot (llm_model=llama3.2) + re-seed
      box.clear()
      // Post-onboarding: back to OpenAI → effective model llama3.2 → gpt-4o-mini.
      // Must emit a real delta, NOT be skipped against a stale baseline.
      settings.llmProvider = .openAI
      telemetry.flush()
      let d = deltas(box, setting: "llm_model")
      #expect(d.count == 1)
      #expect(d.first?.stringProps["from"] == "llama3.2")  // re-seeded from effective Ollama model
      #expect(d.first?.stringProps["to"] == "gpt-4o-mini")
    }

    @Test("Onboarding completion emits the baseline exactly once")
    func onboardingCompletionBaselineOnce() {
      // Bind `telemetry`: the onChange closure captures it weakly, so the
      // observer must be held for the duration (as the bootstrapper holds it).
      let (settings, telemetry, _, spy) = makeHarness(onboarding: .needsPermissions)
      defer { TelemetryService.shared.testEventHook = nil }
      settings.onboardingState = .completed
      #expect(spy.count == 1)
      // A later unrelated change does not re-fire the baseline.
      settings.recordingMode = .toggle
      #expect(spy.count == 1)
      _ = telemetry  // keep alive past the final assertion
    }

    @Test("Ollama pick: the llm_model + ollamaModel mirror coalesce to one delta")
    func ollamaMirrorCoalescesToOneDelta() {
      let (settings, telemetry, box, _) = makeHarness()
      defer { TelemetryService.shared.testEventHook = nil }
      settings.llmProvider = .ollama  // canonicalizes effective model → default "llama3.2"
      telemetry.flush()
      box.clear()
      // Reproduce the production mirror: the picker writes llmModel, then
      // PipelineSettingsSync mirrors it into ollamaModel. Both map to the one
      // `llm_model` logical → exactly ONE coalesced delta to the effective model.
      settings.llmModel = "mistral"  // a DIFFERENT shipped-catalog id
      settings.ollamaModel = "mistral"  // the mirror (now instrumented, coalesced)
      telemetry.flush()
      let d = deltas(box, setting: "llm_model")
      #expect(d.count == 1)
      #expect(d.first?.stringProps["to"] == "mistral")
    }

    @Test("Ollama projection reads the effective ollamaModel, not a stale llmModel")
    func ollamaReadsEffectiveModel() {
      let suite = UserDefaults(suiteName: "SCT-eff-\(UUID().uuidString)")!
      let settings = SettingsManager(defaults: suite)
      settings.llmProvider = .ollama
      // Simulate the lag: llmModel still holds a cloud id, ollamaModel is the real one.
      settings.llmModel = "gpt-4o-mini"
      settings.ollamaModel = "llama3.2"
      #expect(SettingsProjection.value(for: .llmModel, settings: settings) == "llama3.2")
    }

    @Test("EG-1 projection: published verbatim, lookalikes get the fixed variant label (#1269)")
    func egOneProjectionTiers() {
      func project(_ model: String) -> String? {
        let suite = UserDefaults(suiteName: "SCT-eg1-\(UUID().uuidString)")!
        let settings = SettingsManager(defaults: suite)
        settings.llmProvider = .ollama
        settings.ollamaModel = model
        return SettingsProjection.value(for: .llmModel, settings: settings)
      }
      // Published first-party name: verbatim (canonicalized).
      #expect(project("eg-1") == "eg-1")
      #expect(project("eg-1:latest") == "eg-1")
      // First-party TAG (ours, but the tagged form isn't a published catalog name):
      // fixed literal, never the raw tag string.
      #expect(project("eg-1:q4") == "eg-1-variant")
      // User-controlled lookalikes are NOT first-party (cloud review r3): custom,
      // never verbatim, never the family label.
      #expect(project("eg-1-q4") == "custom")
      #expect(project("eg-1-acme-client") == "custom")
      #expect(project("eg-10") == "custom")
      // Everything else: custom.
      #expect(project("someones-finetune") == "custom")
    }

    @Test("Ollama discovery correction emits one source=system delta")
    func ollamaDiscoveryIsSystem() {
      let (settings, telemetry, box, _) = makeHarness()
      defer { TelemetryService.shared.testEventHook = nil }
      settings.llmProvider = .ollama
      telemetry.flush()
      box.clear()
      // Discovery finds the current model unavailable and swaps it (writes both
      // llmModel and ollamaModel under the system flag) — one coalesced delta.
      settings.applyDiscoveredModels(
        [LLMModelInfo(id: "mistral", displayName: "M", provider: .ollama, isAvailable: true)],
        for: .ollama)
      telemetry.flush()
      let d = deltas(box, setting: "llm_model")
      #expect(d.count == 1)
      #expect(d.first?.stringProps["to"] == "mistral")
      #expect(d.first?.stringProps["source"] == "system")
    }

    @Test("Turning polish off refreshes llm_model to `none` (provider-derived)")
    func providerOffRefreshesModel() {
      let (settings, telemetry, box, _) = makeHarness()
      defer { TelemetryService.shared.testEventHook = nil }
      settings.llmProvider = .openAI  // canonicalizes model → gpt-4o-mini
      telemetry.flush()
      box.clear()
      settings.llmProvider = LLMProvider.none  // no llmModel write, but projection → none
      telemetry.flush()
      let d = deltas(box, setting: "llm_model")
      #expect(d.count == 1)
      #expect(d.first?.stringProps["to"] == "none")
      #expect(d.first?.stringProps["source"] == "user")
    }

    @Test("Provider-switch model canonicalization is tagged user, not system")
    func providerSwitchCanonicalizationIsUser() {
      let (settings, telemetry, box, _) = makeHarness()
      defer { TelemetryService.shared.testEventHook = nil }
      settings.llmProvider = .openAI
      telemetry.flush()
      box.clear()
      settings.llmProvider = .appleIntelligence  // canonicalizes llmModel → apple-intelligence
      telemetry.flush()
      let d = deltas(box, setting: "llm_model")
      #expect(d.count == 1)
      #expect(d.first?.stringProps["to"] == "apple-intelligence")
      // A provider switch is a user gesture — its model canonicalization reads
      // `user`, consistent with the OpenAI→None turn-off path (Codex r5). Only
      // async `applyDiscoveredModels` is `system`.
      #expect(d.first?.stringProps["source"] == "user")
    }

    @Test("System discovery inside a provider-switch window wins the source (last-writer)")
    func discoveryWithinProviderWindowIsSystem() {
      let (settings, telemetry, box, _) = makeHarness()
      defer { TelemetryService.shared.testEventHook = nil }
      settings.llmProvider = .openAI
      telemetry.flush()
      box.clear()
      // User switches provider (enqueues llm_model=user via the derived refresh),
      // then fast async discovery corrects the model to "mistral" WITHIN the same
      // 500 ms debounce window. The final value came from the system write.
      settings.llmProvider = .ollama
      settings.applyDiscoveredModels(
        [LLMModelInfo(id: "mistral", displayName: "M", provider: .ollama, isAvailable: true)],
        for: .ollama)
      telemetry.flush()
      let d = deltas(box, setting: "llm_model")
      #expect(d.count == 1)
      #expect(d.first?.stringProps["to"] == "mistral")
      #expect(d.first?.stringProps["source"] == "system")  // last writer = discovery
    }

    @Test("A custom local Ollama model collapses to `custom`")
    func customModelProjection() {
      let (settings, telemetry, box, _) = makeHarness()
      defer { TelemetryService.shared.testEventHook = nil }
      settings.llmProvider = .ollama
      telemetry.flush()
      box.clear()
      settings.ollamaModel = "my-private-finetune"  // the effective Ollama model
      telemetry.flush()
      #expect(deltas(box, setting: "llm_model").first?.stringProps["to"] == "custom")
    }

    @Test("A `:latest` Ollama tag canonicalizes to its catalog name, not custom")
    func ollamaLatestTagCanonicalizes() {
      let suite = UserDefaults(suiteName: "SCT-canon-\(UUID().uuidString)")!
      let settings = SettingsManager(defaults: suite)
      settings.llmProvider = .ollama
      settings.ollamaModel = "llama3.2:latest"  // standard install tag
      // Canonicalizes to the catalog's "llama3.2" — NOT reported as "custom".
      #expect(SettingsProjection.value(for: .llmModel, settings: settings) == "llama3.2")
      // A non-catalog private pull still collapses to custom.
      settings.ollamaModel = "my-private:latest"
      #expect(SettingsProjection.value(for: .llmModel, settings: settings) == "custom")
    }

    @Test("Cloud projection is deny-by-default: stale/private id → custom, known id passes")
    func cloudDenyByDefault() {
      let suite = UserDefaults(suiteName: "SCT-cloud-\(UUID().uuidString)")!
      let settings = SettingsManager(defaults: suite)
      settings.llmProvider = .openAI
      // P1 leak scenario: a private Ollama name carried over before discovery
      // corrects llmModel. It is NOT on the cloud allowlist → custom, never raw.
      settings.llmModel = "acme-internal-finetune"
      #expect(SettingsProjection.value(for: .llmModel, settings: settings) == "custom")
      // A recognized public cloud id passes through.
      settings.llmModel = "gpt-4o-mini"
      #expect(SettingsProjection.value(for: .llmModel, settings: settings) == "gpt-4o-mini")
      // A dated snapshot of a known model normalizes to its base id.
      settings.llmModel = "gpt-5-mini-2025-08-07"
      #expect(SettingsProjection.value(for: .llmModel, settings: settings) == "gpt-5-mini")
    }

    @Test("Language lock projects to mode only, never the code")
    func languageModeProjection() {
      let (settings, telemetry, box, _) = makeHarness()
      defer { TelemetryService.shared.testEventHook = nil }
      settings.languageMode = .locked("de")
      telemetry.flush()
      let d = deltas(box, setting: "language_mode")
      #expect(d.first?.stringProps["from"] == "auto")
      #expect(d.first?.stringProps["to"] == "locked")  // no "de"
    }

    @Test("Sensitivity slider projects to a bucket")
    func sensitivityBucketProjection() {
      let (settings, telemetry, box, _) = makeHarness()
      defer { TelemetryService.shared.testEventHook = nil }
      settings.vadSensitivity = 0.9
      telemetry.flush()
      let d = deltas(box, setting: "vad_sensitivity")
      #expect(d.first?.stringProps["from"] == "medium")  // 0.5 default
      #expect(d.first?.stringProps["to"] == "high")
    }

    @Test("A non-instrumented key (selected_backend) emits no delta")
    func adversarialNonInstrumented() {
      let (settings, telemetry, box, _) = makeHarness()
      defer { TelemetryService.shared.testEventHook = nil }
      settings.selectedBackend = settings.selectedBackend == .parakeet ? .whisperKit : .parakeet
      telemetry.flush()
      #expect(box.all.isEmpty)
    }

    @Test("Observer keeps emitting while strongly held (retention)")
    func strongRetentionEmits() {
      let (settings, telemetry, box, _) = makeHarness()
      defer { TelemetryService.shared.testEventHook = nil }
      // `telemetry` is held by this scope (as the bootstrapper holds it). The
      // onChange closure captures it weakly; emission must still happen.
      settings.wordCorrectionEnabled = false
      telemetry.flush()
      #expect(deltas(box, setting: "word_correction").count == 1)
    }
  }

#endif
