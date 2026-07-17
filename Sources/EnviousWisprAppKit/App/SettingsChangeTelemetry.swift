import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation

/// Telemetry Bible Phase 4 (#1173): the privacy projection shared by the
/// baseline `settings.snapshot` (its comprehensive `config` block) and the
/// per-change `settings.changed` deltas. ONE source of the projected value
/// vocabulary so the holistic per-user config reconstructs cleanly query-side
/// (baseline overlaid with subsequent deltas). No raw model strings, key codes,
/// or locked language codes ever leave memory.
enum SettingsProjection {
  /// Every user-facing logical setting that gets a `settings.changed` delta.
  /// Excludes the Phase-2-owned backend, dev-only knobs (debug mode/level),
  /// device overrides, the deprecated WhisperKit language, the uninstrumented
  /// `ollamaModel` mirror, the cold XPC knob, and lifecycle/onboarding state.
  enum Logical: String, CaseIterable {
    case recordingMode = "recording_mode"
    case llmProvider = "llm_provider"
    case llmModel = "llm_model"
    case autoCopy = "auto_copy"
    case hotkeyEnabled = "hotkey_enabled"
    case vadAutoStop = "vad_auto_stop"
    case vadSilenceTimeout = "vad_silence_timeout"
    case vadSensitivity = "vad_sensitivity"
    case vadEnergyGate = "vad_energy_gate"
    case modelUnloadPolicy = "model_unload_policy"
    case restoreClipboard = "restore_clipboard"
    case wordCorrection = "word_correction"
    case fillerRemoval = "filler_removal"
    case contactsSync = "contacts_sync"
    case emojiFormatter = "emoji_formatter"
    case crashRecovery = "crash_recovery"
    case useExtendedThinking = "use_extended_thinking"
    case languageMode = "language_mode"
    case streamingASR = "streaming_asr"
    case warmEnginePolicy = "warm_engine_policy"
    case appearance = "appearance"
    case overlayPillPosition = "overlay_pill_position"
    case toggleHotkeyShape = "toggle_hotkey_shape"
    case pushToTalkHotkeyShape = "push_to_talk_hotkey_shape"
    case cancelHotkeyShape = "cancel_hotkey_shape"
    case playRecordingSounds = "play_recording_sounds"
    case recordingSoundPairing = "recording_sound_pairing"
  }

  /// Logicals whose underlying control is a slider; they earn the longer
  /// debounce so a drag collapses to one bucketed delta.
  static let sliderLogicals: Set<Logical> = [.vadSilenceTimeout, .vadSensitivity]

  /// Map a raw `SettingKey` to its logical setting; nil = not instrumented.
  /// Each hotkey role groups its keyCode + modifiers keys into one shape logical
  /// (so a key+modifier reassignment is one delta, never two).
  static func logical(for key: SettingsManager.SettingKey) -> Logical? {
    switch key {
    case .recordingMode: return .recordingMode
    case .llmProvider: return .llmProvider
    // #1173: both the cloud `llmModel` and the local `ollamaModel` feed the one
    // `llm_model` logical — the projection reads the EFFECTIVE model
    // (`SettingsManager.effectiveLLMModel`, ollama→ollamaModel else llmModel), so
    // a mirror/discovery write to either field re-emits. Coalescing-by-logical
    // collapses a `.llmModel`+`.ollamaModel` pair (the Ollama mirror) into ONE
    // delta. (Codex r7 pivot.)
    case .llmModel, .ollamaModel: return .llmModel
    case .autoCopyToClipboard: return .autoCopy
    case .hotkeyEnabled: return .hotkeyEnabled
    case .vadAutoStop: return .vadAutoStop
    case .vadSilenceTimeout: return .vadSilenceTimeout
    case .vadSensitivity: return .vadSensitivity
    case .vadEnergyGate: return .vadEnergyGate
    case .modelUnloadPolicy: return .modelUnloadPolicy
    case .restoreClipboardAfterPaste: return .restoreClipboard
    case .wordCorrectionEnabled: return .wordCorrection
    case .fillerRemovalEnabled: return .fillerRemoval
    case .contactsSyncOnLaunchEnabled: return .contactsSync
    case .emojiFormatterEnabled: return .emojiFormatter
    case .crashRecoveryEnabled: return .crashRecovery
    case .useExtendedThinking: return .useExtendedThinking
    case .languageMode: return .languageMode
    case .useStreamingASR: return .streamingASR
    case .warmEnginePolicy: return .warmEnginePolicy
    case .appearance: return .appearance
    case .overlayPillPosition: return .overlayPillPosition
    case .toggleKeyCode, .toggleModifiers: return .toggleHotkeyShape
    case .pushToTalkKeyCode, .pushToTalkModifiers: return .pushToTalkHotkeyShape
    case .cancelKeyCode, .cancelModifiers: return .cancelHotkeyShape
    case .playRecordingSounds: return .playRecordingSounds
    case .recordingSoundPairing: return .recordingSoundPairing
    // Not instrumented.
    case .selectedBackend, .onboardingState, .hasCompletedOnboarding,
      .isDebugModeEnabled, .isDictationAudioArchiveEnabled, .debugLogLevel, .whisperKitLanguage,
      .selectedInputDeviceUID, .preferredInputDeviceIDOverride,
      // #1480: the popover's own lifecycle telemetry (`bt_awareness.*`) owns this
      // signal, incl. `suppressed_by_setting`; no separate settings.changed delta.
      .showBluetoothTips:
      return nil
    }
  }

  /// Project one logical to its privacy-safe emitted value, reading the current
  /// state from `settings`.
  @MainActor
  static func value(for logical: Logical, settings: SettingsManager) -> String {
    switch logical {
    case .recordingMode: return settings.recordingMode.rawValue
    case .llmProvider: return settings.llmProvider.rawValue
    case .llmModel: return model(settings)
    case .autoCopy: return onOff(settings.autoCopyToClipboard)
    case .hotkeyEnabled: return onOff(settings.hotkeyEnabled)
    case .vadAutoStop: return onOff(settings.vadAutoStop)
    case .vadSilenceTimeout: return silenceTimeout(settings.vadSilenceTimeout)
    case .vadSensitivity: return sensitivityBucket(settings.vadSensitivity)
    case .vadEnergyGate: return onOff(settings.vadEnergyGate)
    case .modelUnloadPolicy: return settings.modelUnloadPolicy.rawValue
    case .restoreClipboard: return onOff(settings.restoreClipboardAfterPaste)
    case .wordCorrection: return onOff(settings.wordCorrectionEnabled)
    case .fillerRemoval: return onOff(settings.fillerRemovalEnabled)
    case .contactsSync: return onOff(settings.contactsSyncOnLaunchEnabled)
    case .emojiFormatter: return onOff(settings.emojiFormatterEnabled)
    case .crashRecovery: return onOff(settings.crashRecoveryEnabled)
    case .useExtendedThinking: return onOff(settings.useExtendedThinking)
    case .languageMode: return languageModeLabel(settings.languageMode)
    case .streamingASR: return onOff(settings.useStreamingASR)
    case .warmEnginePolicy: return settings.warmEnginePolicy.rawValue
    case .appearance: return settings.appearancePreference.rawValue
    case .overlayPillPosition: return settings.overlayPillPosition.rawValue
    case .toggleHotkeyShape: return hotkeyShape(settings.toggleKeyCode)
    case .pushToTalkHotkeyShape: return hotkeyShape(settings.pushToTalkKeyCode)
    case .cancelHotkeyShape: return hotkeyShape(settings.cancelKeyCode)
    case .playRecordingSounds: return onOff(settings.playRecordingSounds)
    case .recordingSoundPairing: return settings.recordingSoundPairing.rawValue
    }
  }

  /// The comprehensive `config` block for `settings.snapshot` — every instrumented
  /// logical EXCEPT the three already emitted as dedicated typed snapshot fields
  /// (`recording_mode`, `llm_provider`, `filler_removal`), so keys never collide.
  @MainActor
  static func snapshotConfig(_ settings: SettingsManager) -> [String: String] {
    let typed: Set<Logical> = [.recordingMode, .llmProvider, .fillerRemoval]
    var out: [String: String] = [:]
    for logical in Logical.allCases where !typed.contains(logical) {
      out[logical.rawValue] = value(for: logical, settings: settings)
    }
    return out
  }

  // MARK: - Field projections

  private static func onOff(_ v: Bool) -> String { v ? "on" : "off" }

  /// Project the EFFECTIVE model (`SettingsManager.effectiveLLMModel` — the same
  /// value the runtime uses) DENY-BY-DEFAULT: a model id is emitted only when it
  /// is on a known-safe allowlist, otherwise `custom`. This makes a private local
  /// model name impossible to leak regardless of the brief provider/model lag
  /// after a switch (Codex r7 pivot):
  /// - Ollama: verbatim names come ONLY from strings we published — the SHIPPED
  ///   catalog + the curated-private first-party catalog (EG-1, #1269). A model
  ///   that merely LOOKS first-party (user names their own model `eg-1-something`;
  ///   `isFirstPartyModel` prefix match) emits the fixed literal `eg-1-variant`,
  ///   never the raw string. Everything else collapses to `custom`. No
  ///   user-authored name can ever be emitted (#1269 cloud review r2).
  /// - OpenAI / Gemini: a curated set of known public cloud ids (date-snapshot
  ///   suffix normalized away). A stale local id carried over before discovery
  ///   corrects `llmModel` is not on this list → `custom`, never the raw name.
  @MainActor
  private static func model(_ settings: SettingsManager) -> String {
    let id = settings.effectiveLLMModel
    switch settings.llmProvider {
    case .appleIntelligence: return "apple-intelligence"
    // #1271: native EG-1 — the model id is OUR fixed literal from the
    // manifest contract (`effectiveLLMModel` returns `eg-1`), never user
    // input, so verbatim is safe by construction.
    case .egOne: return LLMProvider.egOneModelName
    case .none: return "none"
    case .ollama:
      let canonical = OllamaSetupService.canonicalModelName(id)
      // Verbatim ONLY for published names (shipped catalog + curated-private).
      let published = Set(
        (OllamaSetupService.modelCatalog + OllamaSetupService.curatedPrivateCatalog)
          .map { OllamaSetupService.canonicalModelName($0.name) })
      if published.contains(canonical) { return canonical }
      // First-party-prefixed but unpublished (a future EG variant we haven't
      // cataloged, or a user-named eg-1* model): fixed literal, never the raw
      // string — routing may treat it as ours, telemetry must not leak the name.
      if OllamaSetupService.isFirstPartyModel(id) { return "eg-1-variant" }
      return "custom"
    case .openAI, .gemini:
      let base = stripDateSnapshotSuffix(id)
      return cloudModelAllowlist.contains(base) ? base : "custom"
    }
  }

  /// Curated known PUBLIC cloud model ids (OpenAI + Gemini). Deny-by-default
  /// anchor: anything not here is `custom`, so no private/unknown string leaks.
  /// Trade-off: a brand-new public model not yet listed reads `custom` until
  /// added (itself a useful "on an unrecognized model" signal). Seeded from the
  /// shipped defaults + the families the discovery filters accept
  /// (`LLMModelDiscovery`: gpt-/o1/o3/o4, gemini-).
  private static let cloudModelAllowlist: Set<String> = [
    // OpenAI
    "gpt-4o", "gpt-4o-mini", "gpt-4-turbo", "gpt-4", "gpt-4.1", "gpt-4.1-mini",
    "gpt-4.1-nano", "gpt-5", "gpt-5-mini", "gpt-5-nano", "gpt-5-pro",
    "o1", "o1-mini", "o1-preview", "o3", "o3-mini", "o4-mini", "chatgpt-4o-latest",
    // Gemini
    "gemini-1.5-pro", "gemini-1.5-flash", "gemini-1.5-flash-8b",
    "gemini-2.0-flash", "gemini-2.0-flash-lite",
    "gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.5-flash-lite",
  ]

  /// Strip a trailing `-YYYY-MM-DD` provider date-snapshot suffix so dated
  /// variants (`gpt-5-mini-2025-08-07`) match their base allowlist entry. The
  /// suffix is public/non-sensitive; this only collapses cardinality.
  private static func stripDateSnapshotSuffix(_ id: String) -> String {
    guard
      let r = id.range(
        of: "-[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression)
    else { return id }
    return String(id[..<r.lowerBound])
  }

  private static func languageModeLabel(_ mode: LanguageMode) -> String {
    switch mode {
    case .auto: return "auto"
    case .locked: return "locked"  // mode only, never the language code
    }
  }

  /// Modifier-only trigger (e.g. right Option alone) vs a regular-key chord.
  /// Never the keys themselves — a chord→chord reassignment is a projected no-op.
  private static func hotkeyShape(_ keyCode: UInt16) -> String {
    ModifierKeyCodes.isModifierOnly(keyCode) ? "modifier_only" : "chord"
  }

  private static func sensitivityBucket(_ v: Float) -> String {
    switch v {
    case ..<0.34: return "low"
    case ..<0.67: return "medium"
    default: return "high"
    }
  }

  /// Already low-cardinality (0.5–3.0, stepped by 0.25); emit the stepped value.
  private static func silenceTimeout(_ v: Double) -> String {
    String(format: "%.2f", v)
  }
}

/// Telemetry Bible Phase 4 (#1173): observes the single `SettingsManager.onChange`
/// funnel, classifies each change's source, coalesces a burst into one truthful
/// delta per logical setting, and emits `settings.changed`. Also fires the
/// comprehensive baseline at onboarding-completion (the first-run gap). A limb:
/// it never throws or awaits in the setter path; the debounce is emission
/// coalescing on an already-observed change, not a watcher. Held as an
/// app-lifetime `let` on `WisprBootstrapper` (a weak-only hold would dealloc and
/// silently stop emitting).
@MainActor
final class SettingsChangeTelemetry {
  private let settings: SettingsManager
  private let emitBaseline: @MainActor () -> Void
  private let toggleWindow: Duration
  private let sliderWindow: Duration

  /// Last emitted (or seeded) projected value per logical — the `from` source.
  private var committedBaseline: [SettingsProjection.Logical: String] = [:]
  /// Value at the start of the in-flight burst, set once per window per logical.
  private var pendingOriginal: [SettingsProjection.Logical: String] = [:]
  /// Burst source per logical (system iff every contributing write was system).
  private var pendingSource: [SettingsProjection.Logical: Source] = [:]
  private var settleTask: Task<Void, Never>?

  enum Source: String { case user, system }

  init(
    settings: SettingsManager,
    emitBaseline: @escaping @MainActor () -> Void,
    toggleWindow: Duration = .milliseconds(500),
    sliderWindow: Duration = .seconds(1)
  ) {
    self.settings = settings
    self.emitBaseline = emitBaseline
    self.toggleWindow = toggleWindow
    self.sliderWindow = sliderWindow
    // Seed the committed baseline so the first post-launch change emits a
    // truthful `from`. Constructed after `SettingsManager.init` (whose writes
    // fire before the funnel is wired), so these reads are the launch state.
    seedBaseline()
  }

  /// Snapshot every logical's current projected value into `committedBaseline`.
  /// Used at construction (launch) and after the onboarding-completion baseline
  /// so the committed `from` always matches the most recently emitted snapshot.
  private func seedBaseline() {
    for logical in SettingsProjection.Logical.allCases {
      committedBaseline[logical] = SettingsProjection.value(for: logical, settings: settings)
    }
  }

  /// The funnel entry: every `SettingsManager.onChange(key)` routes here.
  func handle(_ key: SettingsManager.SettingKey) {
    // Onboarding completion → emit the comprehensive baseline once. Fixes the
    // first-run gap: a fresh user who finishes setup and keeps the app open has
    // no launch snapshot until the next relaunch. `onboardingState` is otherwise
    // not an instrumented setting.
    if key == .onboardingState {
      if settings.onboardingState == .completed {
        emitBaseline()
        // Re-sync to the just-emitted snapshot. Onboarding suppression updates
        // committedBaseline only for the logical whose key fired — a DERIVED
        // projection (e.g. `llm_model` after an onboarding provider switch with
        // no model write) would otherwise stay stale and make a later real
        // delta look like a no-op, drifting reconstruction off the snapshot
        // (Codex r4). Clear any straggler and re-seed every logical.
        settleTask?.cancel()
        settleTask = nil
        pendingOriginal.removeAll()
        pendingSource.removeAll()
        seedBaseline()
      }
      return
    }
    guard let logical = SettingsProjection.logical(for: key) else { return }

    // Suppress onboarding-time writes (the onboarding-completion baseline
    // captures the final state); keep the committed baseline current so the
    // first real post-onboarding change has a truthful `from`.
    if settings.onboardingState != .completed {
      committedBaseline[logical] = SettingsProjection.value(for: logical, settings: settings)
      pendingOriginal[logical] = nil
      pendingSource[logical] = nil
      return
    }

    let source: Source = settings.isApplyingSystemWrite ? .system : .user
    enqueue(logical, source: source)
    // `llm_model`'s projection also depends on `llmProvider` (cloud id vs Ollama
    // catalog vs `none`/`apple-intelligence`), so a provider change can alter the
    // projected model even with NO `llmModel` write — e.g. turning polish off →
    // `none`. Refresh it so reconstruction never holds a stale model. The flush
    // no-op check drops it when the projection is unchanged (e.g. OpenAI → Gemini
    // keeping a cloud id). The provider switch is a user gesture, so this enqueues
    // `user`; if async discovery then corrects the model inside the same window,
    // last-writer-wins re-stamps it `system` (Codex r6).
    if logical == .llmProvider {
      enqueue(.llmModel, source: source)
    }
    scheduleSettle()
  }

  /// Stage a pending delta for `logical`. The burst ORIGIN (committed baseline)
  /// is fixed once per window; the SOURCE is last-writer-wins — it always tracks
  /// the most recent write, so a coalesced delta reports the provenance of the
  /// FINAL value in `to`. This is the unifying rule for `llm_model`, whose value
  /// can be set in one window by a user pick, a provider-switch canonicalization
  /// (user gesture), or an async `applyDiscoveredModels` correction (system):
  /// whichever wrote last owns the source (Codex r5/r6).
  private func enqueue(_ logical: SettingsProjection.Logical, source: Source) {
    if pendingOriginal[logical] == nil {
      pendingOriginal[logical] =
        committedBaseline[logical] ?? SettingsProjection.value(for: logical, settings: settings)
    }
    pendingSource[logical] = source
  }

  /// Emit one coalesced delta per pending logical (net no-op bursts skipped) and
  /// advance the committed baseline. Invoked by the debounce timer in production;
  /// tests call it directly — the debounce delay is not a SUT measurement, so no
  /// clock seam is needed (`tests-no-real-time-scheduling-precision`).
  func flush() {
    settleTask?.cancel()
    settleTask = nil
    let pending = pendingOriginal
    let sources = pendingSource
    pendingOriginal.removeAll()
    pendingSource.removeAll()
    for (logical, original) in pending {
      let latest = SettingsProjection.value(for: logical, settings: settings)
      guard latest != original else { continue }  // net no-op (A→B→A)
      TelemetryService.shared.settingsChanged(
        setting: logical.rawValue, from: original, to: latest,
        source: (sources[logical] ?? .user).rawValue)
      committedBaseline[logical] = latest
    }
  }

  private func scheduleSettle() {
    settleTask?.cancel()
    let hasSlider = pendingOriginal.keys.contains { SettingsProjection.sliderLogicals.contains($0) }
    let window = hasSlider ? sliderWindow : toggleWindow
    settleTask = Task { [weak self] in
      try? await Task.sleep(for: window)
      guard !Task.isCancelled else { return }
      self?.flush()
    }
  }
}
