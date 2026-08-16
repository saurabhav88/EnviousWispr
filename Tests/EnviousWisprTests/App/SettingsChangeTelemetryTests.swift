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

    @Test("Smart insertion emits one privacy-safe on-to-off delta")
    func smartInsertionDelta() {
      let (settings, telemetry, box, _) = makeHarness()
      defer { TelemetryService.shared.testEventHook = nil }

      settings.smartInsertion = false
      telemetry.flush()

      let d = deltas(box, setting: "smart_insertion")
      #expect(d.count == 1)
      #expect(d.first?.stringProps["from"] == "on")
      #expect(d.first?.stringProps["to"] == "off")
      #expect(d.first?.stringProps["source"] == "user")
      #expect(SettingsProjection.value(for: .smartInsertion, settings: settings) == "off")
    }

    // MARK: - #1987 toggle hotkey identity fan-out

    @Test("Binding the Globe key emits an identity delta while shape stays a no-op")
    func globeBindEmitsShapeAndIdentity() {
      let (settings, telemetry, box, _) = makeHarness()
      defer { TelemetryService.shared.testEventHook = nil }

      settings.toggleKeyCode = ModifierKeyCodes.globe
      telemetry.flush()

      let identity = deltas(box, setting: "toggle_hotkey_identity")
      #expect(identity.count == 1)
      #expect(identity.first?.stringProps["from"] == "right_option")
      #expect(identity.first?.stringProps["to"] == "globe")
      // Shape is unchanged: both keys are modifier-only. That is precisely why
      // identity had to exist, so assert the shape delta is SUPPRESSED as a no-op
      // rather than merely absent by accident.
      #expect(deltas(box, setting: "toggle_hotkey_shape").isEmpty)
    }

    /// The two logicals must coalesce and suppress independently. A chord bind
    /// changes both, so both must emit.
    @Test("Binding a chord key emits both shape and identity deltas")
    func chordBindEmitsBoth() {
      let (settings, telemetry, box, _) = makeHarness()
      defer { TelemetryService.shared.testEventHook = nil }

      settings.toggleKeyCode = 0  // 'A', a chord key
      telemetry.flush()

      let shape = deltas(box, setting: "toggle_hotkey_shape")
      let identity = deltas(box, setting: "toggle_hotkey_identity")
      #expect(shape.count == 1)
      #expect(shape.first?.stringProps["to"] == "chord")
      #expect(identity.count == 1)
      #expect(identity.first?.stringProps["to"] == "chord")
    }

    @Test("A→B→A on the toggle key is a net no-op for both logicals")
    func toggleKeyNetNoOpSuppressesBoth() {
      let (settings, telemetry, box, _) = makeHarness()
      defer { TelemetryService.shared.testEventHook = nil }

      settings.toggleKeyCode = ModifierKeyCodes.globe
      settings.toggleKeyCode = ModifierKeyCodes.rightOption  // back to the default
      telemetry.flush()

      #expect(deltas(box, setting: "toggle_hotkey_identity").isEmpty)
      #expect(deltas(box, setting: "toggle_hotkey_shape").isEmpty)
    }

    /// Guards the "shape-only" instruction: push-to-talk and cancel must NOT gain
    /// identity telemetry, so a fan-out written for the toggle key cannot leak.
    @Test("Push-to-talk and cancel hotkeys remain shape-only")
    func otherHotkeyRolesStayShapeOnly() {
      let (settings, telemetry, box, _) = makeHarness()
      defer { TelemetryService.shared.testEventHook = nil }

      settings.pushToTalkKeyCode = ModifierKeyCodes.globe
      settings.cancelKeyCode = 0
      telemetry.flush()

      #expect(box.all.allSatisfy { $0.stringProps["setting"] != "push_to_talk_hotkey_identity" })
      #expect(box.all.allSatisfy { $0.stringProps["setting"] != "cancel_hotkey_identity" })
      #expect(deltas(box, setting: "toggle_hotkey_identity").isEmpty)
    }

    /// The routing contract itself, asserted exactly. The grouped delta tests
    /// below pass even if `.toggleModifiers` silently loses identity, because a
    /// key-code write in the same window already enqueued it.
    @Test("Both toggle raw keys route to exactly shape and identity")
    func toggleKeysRouteToBothLogicals() {
      #expect(
        SettingsProjection.logicals(for: .toggleKeyCode)
          == [.toggleHotkeyShape, .toggleHotkeyIdentity])
      #expect(
        SettingsProjection.logicals(for: .toggleModifiers)
          == [.toggleHotkeyShape, .toggleHotkeyIdentity])
    }

    @Test("Other hotkey roles route to shape only, and uninstrumented keys to nothing")
    func otherKeysRoutingUnchanged() {
      #expect(SettingsProjection.logicals(for: .pushToTalkKeyCode) == [.pushToTalkHotkeyShape])
      #expect(SettingsProjection.logicals(for: .pushToTalkModifiers) == [.pushToTalkHotkeyShape])
      #expect(SettingsProjection.logicals(for: .cancelKeyCode) == [.cancelHotkeyShape])
      #expect(SettingsProjection.logicals(for: .cancelModifiers) == [.cancelHotkeyShape])
      #expect(SettingsProjection.logicals(for: .llmModel) == [.llmModel])
      #expect(SettingsProjection.logicals(for: .ollamaModel) == [.llmModel])
      #expect(SettingsProjection.logicals(for: .selectedBackend).isEmpty)
    }

    /// Discriminates the onboarding fan-out: the suppression branch must clear
    /// pending state and advance the baseline for EVERY returned logical. If that
    /// loop handled only the first, the stale second logical would emit here.
    @Test("Onboarding suppression clears pending state for both toggle logicals")
    func onboardingSuppressionClearsBothLogicals() {
      let (settings, telemetry, box, _) = makeHarness()
      defer { TelemetryService.shared.testEventHook = nil }

      // Create pending deltas on both toggle logicals while completed.
      settings.toggleKeyCode = 0  // chord: changes shape AND identity
      // Now drop back into onboarding and write a DIFFERENT identity.
      settings.onboardingState = .settingUp
      settings.toggleKeyCode = ModifierKeyCodes.globe
      telemetry.flush()

      #expect(deltas(box, setting: "toggle_hotkey_shape").isEmpty)
      #expect(deltas(box, setting: "toggle_hotkey_identity").isEmpty)
    }

    /// Snapshot proof through the REAL emit path, not a `snapshotConfig`
    /// reconstruction: `StandingSnapshotBuilder.emit()` -> `settingsSnapshot(...)`
    /// -> the DEBUG hook, whose projection is now derived from the same dictionary
    /// PostHog receives.
    @MainActor
    @Test("The real settings.snapshot carries toggle_hotkey_identity and no raw key code")
    func realSnapshotCarriesIdentity() {
      let suite = UserDefaults(suiteName: "SCT-snap-\(UUID().uuidString)")!
      let settings = SettingsManager(defaults: suite)
      let previousHook = TelemetryService.shared.testEventHook
      defer { TelemetryService.shared.testEventHook = previousHook }

      // The hook is `@Sendable`, so the capture cannot be a local `var`. A locked
      // box is the same shape `StandingSnapshotBuilderTests` already uses.
      final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: CapturedTelemetryEvent?
        func set(_ e: CapturedTelemetryEvent) { lock.withLock { stored = e } }
        var value: CapturedTelemetryEvent? { lock.withLock { stored } }
      }

      func emitSnapshot() -> CapturedTelemetryEvent? {
        let box = Box()
        TelemetryService.shared.testEventHook = { @Sendable event in
          if event.name == "settings.snapshot" { box.set(event) }
        }
        StandingSnapshotBuilder(
          settings: settings,
          keychainManager: KeychainManager(),
          customWordsCoordinator: CustomWordsCoordinator(),
          permissions: PermissionsService(accessibilityReader: { true })
        ).emit()
        return box.value
      }

      // Default install: the shipped default is Right Option, so a snapshot taken
      // before any bind must say so. Without this, a classifier that returned
      // `globe` unconditionally would still pass the Globe case below.
      let atDefault = emitSnapshot()
      #expect(atDefault?.stringProps["toggle_hotkey_identity"] == "right_option")

      settings.toggleKeyCode = ModifierKeyCodes.globe
      let afterBind = emitSnapshot()
      #expect(afterBind?.stringProps["toggle_hotkey_identity"] == "globe")
      #expect(afterBind?.stringProps["toggle_hotkey_shape"] == "modifier_only")

      // The privacy boundary needs EVERY bucket checked, not just one value and
      // not just the string bucket. Asserting "globe" has no digit would miss a
      // separate `toggle_key_code` property beside it, and checking only
      // `stringProps` would miss it too, because a raw key code is an Int and
      // lands in `intProps`.
      let allKeys =
        Set((afterBind?.stringProps ?? [:]).keys)
        .union((afterBind?.intProps ?? [:]).keys)
        .union((afterBind?.doubleProps ?? [:]).keys)
        .union((afterBind?.boolProps ?? [:]).keys)
      #expect(!allKeys.contains("key_code"))
      #expect(!allKeys.contains("toggle_key_code"))
      #expect(
        allKeys.allSatisfy { !$0.contains("key_code") },
        "no snapshot property in any bucket may carry a raw key code")
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

    @Test("overlay pill position emits a delta (#1341)")
    func overlayPillPositionDelta() {
      let (settings, telemetry, box, _) = makeHarness()
      defer { TelemetryService.shared.testEventHook = nil }
      settings.overlayPillPosition = .bottom
      telemetry.flush()
      let d = deltas(box, setting: "overlay_pill_position")
      #expect(d.count == 1)
      #expect(d.first?.stringProps["from"] == "top")
      #expect(d.first?.stringProps["to"] == "bottom")
    }

    @Test("recording sound settings emit deltas and project correctly (#1342)")
    func recordingSoundsDelta() {
      let (settings, telemetry, box, _) = makeHarness()
      defer { TelemetryService.shared.testEventHook = nil }
      settings.playRecordingSounds = true
      settings.recordingSoundPairing = .velvetTap
      telemetry.flush()

      let enabledDeltas = deltas(box, setting: "play_recording_sounds")
      #expect(enabledDeltas.count == 1)
      #expect(enabledDeltas.first?.stringProps["from"] == "off")
      #expect(enabledDeltas.first?.stringProps["to"] == "on")

      let pairingDeltas = deltas(box, setting: "recording_sound_pairing")
      #expect(pairingDeltas.count == 1)
      #expect(pairingDeltas.first?.stringProps["from"] == "whisperTick")
      #expect(pairingDeltas.first?.stringProps["to"] == "velvetTap")

      #expect(
        SettingsProjection.value(for: .playRecordingSounds, settings: settings) == "on")
      #expect(
        SettingsProjection.value(for: .recordingSoundPairing, settings: settings)
          == "velvetTap")
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
      // the default ollamaModel with no `.llmModel`/`.ollamaModel` fire.
      // committedBaseline[llm_model] would stay stale ("gpt-4o-mini") without the
      // completion re-seed.
      //
      // Read off the fresh harness rather than restated. It was hardcoded as "llama3.2",
      // and changing the shipped default (#1950) broke a test whose subject is the
      // RE-SEED, not the identity of the default — the value is incidental to everything
      // this case asserts. Taken from the settings object instead of the defaults enum
      // because that enum is internal to its module, and because the live value is what
      // the projection will actually read.
      let defaultOllamaModel = settings.ollamaModel
      #expect(!defaultOllamaModel.isEmpty, "the harness must start with a default model")
      settings.llmProvider = .openAI
      settings.llmProvider = .ollama
      // snapshot (llm_model = the default Ollama model) + re-seed
      settings.onboardingState = .completed
      box.clear()
      // Post-onboarding: back to OpenAI → effective model flips to gpt-4o-mini.
      // Must emit a real delta, NOT be skipped against a stale baseline.
      settings.llmProvider = .openAI
      telemetry.flush()
      let d = deltas(box, setting: "llm_model")
      #expect(d.count == 1)
      // re-seeded from the effective Ollama model
      #expect(d.first?.stringProps["from"] == defaultOllamaModel)
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
      settings.llmProvider = .ollama  // canonicalizes effective model → the default ollamaModel
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

    /// #1770: the allowlist stopped at Gemini 2.5, so every 3.x user's
    /// configured model reconstructed as `custom` and the generation was
    /// invisible in settings snapshots. Public model names only — this is
    /// cardinality, not content.
    @Test("Gemini 3.x ids are recognised, and unknown ids still collapse to custom")
    func geminiThreeIsRecognised() {
      func project(_ model: String) -> String? {
        let suite = UserDefaults(suiteName: "SCT-g3-\(UUID().uuidString)")!
        let settings = SettingsManager(defaults: suite)
        settings.llmProvider = .gemini
        settings.llmModel = model
        return SettingsProjection.value(for: .llmModel, settings: settings)
      }
      for id in [
        "gemini-3.6-flash", "gemini-3.5-flash", "gemini-3.5-flash-lite",
        "gemini-3.7-flash",
        "gemini-3.1-flash-lite", "gemini-3.1-flash-lite-preview",
        "gemini-3.1-pro-preview", "gemini-3.1-pro-preview-customtools",
        "gemini-3-flash-preview",
      ] {
        #expect(project(id) == id, "\(id) is offered by the picker and must not read as custom")
      }
      // The deny-by-default anchor still holds: anything unlisted is `custom`,
      // so no private or unknown string can leak through this dimension.
      #expect(project("gemini-4.0-flash-imaginary") == "custom")
      #expect(project("gemini-my-private-tune") == "custom")
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
        [
          LLMModelInfo(
            id: "mistral", displayName: "M", provider: .ollama, isAvailable: true,
            isRemote: false)
        ],
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
        [
          LLMModelInfo(
            id: "mistral", displayName: "M", provider: .ollama, isAvailable: true,
            isRemote: false)
        ],
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

    @Test(
      "Claude projection: compact-dated snapshot normalizes to base id, non-date suffix does not (#158)"
    )
    func claudeDatedSnapshotProjection() {
      let suite = UserDefaults(suiteName: "SCT-claude-\(UUID().uuidString)")!
      let settings = SettingsManager(defaults: suite)
      settings.llmProvider = .claude
      // A recognized public cloud id passes through verbatim.
      settings.llmModel = "claude-haiku-4-5"
      #expect(SettingsProjection.value(for: .llmModel, settings: settings) == "claude-haiku-4-5")
      // Anthropic's dated snapshot uses a COMPACT, undashed suffix (-YYYYMMDD),
      // a different shape from OpenAI/Gemini's dashed -YYYY-MM-DD — both forms
      // must normalize to the same allowlisted base id.
      settings.llmModel = "claude-haiku-4-5-20251001"
      #expect(SettingsProjection.value(for: .llmModel, settings: settings) == "claude-haiku-4-5")
      settings.llmModel = "claude-opus-4-1-20250805"
      #expect(SettingsProjection.value(for: .llmModel, settings: settings) == "claude-opus-4-1")
      // Negative: an ordinary non-date numeric segment must NOT be truncated —
      // widening the regex to match compact dates must not over-match.
      settings.llmModel = "claude-haiku-4-5-thinking"
      #expect(SettingsProjection.value(for: .llmModel, settings: settings) == "custom")
    }

    @Test("EG-1's fixed literal never leaks into a cloud provider's model")
    func egOneLiteralSweptOnProviderSwitch() {
      let suite = UserDefaults(suiteName: "SCT-eg1sweep-\(UUID().uuidString)")!
      let settings = SettingsManager(defaults: suite)
      // Apple Intelligence → EG-1 pins the fixed literal.
      settings.llmProvider = .appleIntelligence
      settings.llmProvider = .egOne
      #expect(settings.effectiveLLMModel == LLMProvider.egOneModelName)
      // Switching to a cloud provider must sweep the literal to that
      // provider's default (#1271 Codex r7: "eg-1" reached OpenAI as a
      // model name and every polish call failed until discovery repaired it).
      settings.llmProvider = .openAI
      #expect(settings.llmModel == "gpt-4o-mini")
      settings.llmProvider = .egOne
      settings.llmProvider = .gemini
      // #1770: deliberately the EXACT id, not `defaultModel(for:)`. An earlier
      // revision of this change replaced it with the constant to stop it
      // "rotting" — which made it `x == x`, a tautology that can never fail and
      // silently gave up the ability to catch a wrong shipped default. Breaking
      // when a shipped default moves is the POINT: it forces a human to look.
      // Moved 3.5 -> 3.7 on 2026-08-16. This assertion did exactly what the
      // note above says it is for: it broke when the default moved, and a human
      // checked. Evidence for the swap is on `LLMResult.defaultModel`.
      #expect(settings.llmModel == "gemini-3.7-flash")
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
