import Foundation

/// The invocation surface that initiated this dictation session.
///
/// Distinct from `RecordingMode` (pushToTalk vs toggle): `RecordingMode` is the
/// user's configured recording behavior, while `TriggerSource` is the surface
/// the request arrived through. PostHog `dictation.invoked` events carry both:
/// `input_mode` (configured behavior) and `trigger_source` (invoking surface),
/// so analyst funnels can separate "user pressed PTT" from "user clicked the
/// toolbar Record button while configured for toggle."
///
/// Raw values are snake-case to match the PostHog property convention.
public enum TriggerSource: String, Sendable, CaseIterable {
  /// PTT hotkey held down (key-down → start). Distinct from `toggleHotkey`.
  case pttHotkey = "ptt_hotkey"
  /// Discrete toggle hotkey (Carbon-registered, e.g. F5). Distinct from `pttHotkey`.
  case toggleHotkey = "toggle_hotkey"
  /// Record/Stop button inside the main window (toolbar or in-window control).
  case toolbar = "toolbar"
  /// macOS menu bar item (system menu bar at top of screen, NOT a status bar tray).
  case menuBar = "menu_bar"
  /// First-run onboarding triggered the dictation. Forward-compatible; no
  /// production caller today (OnboardingV2View's `recording` method is hotkey
  /// capture, not dictation).
  case onboarding = "onboarding"
  /// Internal / test / future automation. Reserve value. Used by
  /// `DictationSessionConfig.testDefault()`; do NOT use from production UI code.
  case programmatic = "programmatic"
}

/// Per-recording configuration snapshot. Captured at `startRecording`; immutable for the
/// duration of the recording. Settings mutated mid-recording apply to the NEXT recording.
///
/// Contains only values that must be frozen per recording. Live-mutable settings
/// (hotkey registration, `wordCorrectionEnabled`, `fillerRemovalEnabled`, custom-words
/// dictionary, Ollama RAM eviction side-effects) stay in `PipelineSettingsSync`.
public struct DictationSessionConfig: Sendable {
  // MARK: Paste / clipboard

  public let autoCopyToClipboard: Bool
  /// Input mode active when the recording request was accepted. Configured
  /// recording behavior (pushToTalk vs toggle). NOT the invoking surface; see
  /// `triggerSource`.
  public let inputMode: RecordingMode
  /// Invocation surface that initiated this dictation session. Distinct from
  /// `inputMode`: a user configured for `toggle` who clicks the toolbar Record
  /// button has `inputMode == .toggle` and `triggerSource == .toolbar`.
  /// Issue #723.
  public let triggerSource: TriggerSource
  /// Input-mode-derived at `startRecording`. True when the user triggered via hotkey
  /// or push-to-talk with accessibility permission available; false for menu-triggered
  /// recordings or when the paste target cannot be resolved. Consolidates the previously
  /// scattered writes to `pipeline.autoPasteToActiveApp` in the former root state.
  public let autoPasteToActiveApp: Bool
  public let restoreClipboardAfterPaste: Bool

  // MARK: VAD

  public let vadAutoStop: Bool
  public let vadSilenceTimeout: Double
  public let vadSensitivity: Float
  public let vadEnergyGate: Bool

  // MARK: ASR

  /// Single source of truth for language selection. Pipelines derive
  /// `TranscriptionOptions` from this at session start.
  public let languageMode: LanguageMode
  /// Parakeet-only. Committed at start — there is no mid-record reconfiguration path
  /// in the dictation kernel.
  public let useStreamingASR: Bool
  public let modelUnloadPolicy: ModelUnloadPolicy

  // MARK: LLM polish

  public let llmProvider: LLMProvider
  /// Resolved model ID: `"apple-intelligence"` for Apple, `ollamaModel` for Ollama,
  /// `llmModel` for cloud. Construction-time resolution avoids cascading-didSet
  /// races inside `SettingsManager`.
  public let llmModel: String
  public let polishInstructions: PolishInstructions
  public let useExtendedThinking: Bool

  // MARK: Audio device selection

  /// Already de-facto frozen — `AudioCaptureManager` reads device UIDs at source
  /// construction, and the source is rebuilt between recordings. Including here
  /// makes the contract explicit.
  public let selectedInputDeviceUID: String
  public let preferredInputDeviceIDOverride: String

  public init(
    autoCopyToClipboard: Bool,
    inputMode: RecordingMode,
    triggerSource: TriggerSource,
    autoPasteToActiveApp: Bool,
    restoreClipboardAfterPaste: Bool,
    vadAutoStop: Bool,
    vadSilenceTimeout: Double,
    vadSensitivity: Float,
    vadEnergyGate: Bool,
    languageMode: LanguageMode,
    useStreamingASR: Bool,
    modelUnloadPolicy: ModelUnloadPolicy,
    llmProvider: LLMProvider,
    llmModel: String,
    polishInstructions: PolishInstructions,
    useExtendedThinking: Bool,
    selectedInputDeviceUID: String,
    preferredInputDeviceIDOverride: String
  ) {
    self.autoCopyToClipboard = autoCopyToClipboard
    self.inputMode = inputMode
    self.triggerSource = triggerSource
    self.autoPasteToActiveApp = autoPasteToActiveApp
    self.restoreClipboardAfterPaste = restoreClipboardAfterPaste
    self.vadAutoStop = vadAutoStop
    self.vadSilenceTimeout = vadSilenceTimeout
    self.vadSensitivity = vadSensitivity
    self.vadEnergyGate = vadEnergyGate
    self.languageMode = languageMode
    self.useStreamingASR = useStreamingASR
    self.modelUnloadPolicy = modelUnloadPolicy
    self.llmProvider = llmProvider
    self.llmModel = llmModel
    self.polishInstructions = polishInstructions
    self.useExtendedThinking = useExtendedThinking
    self.selectedInputDeviceUID = selectedInputDeviceUID
    self.preferredInputDeviceIDOverride = preferredInputDeviceIDOverride
  }
}
