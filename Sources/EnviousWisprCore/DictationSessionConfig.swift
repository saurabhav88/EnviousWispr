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
/// (hotkey registration, `wordCorrectionEnabled`, `fillerRemovalEnabled`,
/// `spokenPunctuationEnabled`, custom-words dictionary, Ollama RAM eviction
/// side-effects) stay in `PipelineSettingsSync`.
///
/// #1794 note: the live-mutable Cleanup toggles are ALSO frozen into
/// `RecordingSettingsSnapshot` at capture start, so flipping one mid-recording can make
/// the live take and a later recovered replay of that same take disagree. That is
/// pre-existing and shared by all four Cleanup toggles, deliberately not fixed for one
/// of them alone; fixing it means moving all four here, as one change.
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
  /// Adjust spacing and capitalisation to the text around the caret.
  ///
  /// FROZEN at recording start, like `restoreClipboardAfterPaste` above. A
  /// change made mid-dictation governs the NEXT recording, never the one in
  /// flight — otherwise flipping the switch would silently rewrite text the
  /// user is still speaking.
  public let smartInsertion: Bool

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

  // MARK: Audio device selection

  /// Already de-facto frozen — `AudioCaptureManager` reads device UIDs at source
  /// construction, and the source is rebuilt between recordings. Including here
  /// makes the contract explicit.
  public let selectedInputDeviceUID: String
  public let preferredInputDeviceIDOverride: String

  // MARK: Crash recovery (#1063 PR1)

  /// Durable per-recording id minted host-side when the crash-recovery limb is
  /// armed (nil when recovery is off or could not arm). Stamped onto the saved
  /// `Transcript.recoverySessionID` so the host can delete this session's spool
  /// after the transcript is durably saved. NOT the kernel's internal
  /// `SessionID` — recovery only needs a durable id shared between the spool and
  /// its transcript, and the host mints it before the kernel starts.
  public let recoverySessionID: String?
  /// Opaque encoded `RecoverySpoolDirective` the kernel forwards to the audio
  /// helper at `beginCapturePhase`. The kernel never interprets it (recovery is
  /// a limb the kernel is unaware of); nil ⇒ the helper behaves exactly as today.
  public let recoveryPayload: Data?

  // MARK: Escape Recovery (#2087)

  /// Was Escape Recovery on when THIS recording started?
  ///
  /// Frozen here, and the kernel never reads live `SettingsManager` state, so
  /// toggling mid-dictation governs the NEXT recording rather than the one in
  /// flight. Same classification as every other per-recording setting.
  ///
  /// The contract is predictability, not protection: a recording ends under the
  /// rules it began under, so pressing the cancel shortcut does what it would
  /// have done when the user started speaking.
  ///
  /// Be precise about the direction of the trade, because it is easy to state
  /// backwards. Freezing means a user who turns the feature OFF mid-recording
  /// still gets THIS recording kept — the live-read alternative is what would
  /// destroy it. Neither is a safety win over the other; the reason to freeze is
  /// that a setting changed for the next dictation must not silently rewrite the
  /// one already in progress.
  ///
  /// Defaults to `false` so a construction site that forgets it gets today's
  /// behaviour — an immediate discard — rather than silently retaining a
  /// cancelled dictation the user never opted into.
  public let escapeRecoveryEnabled: Bool

  public init(
    autoCopyToClipboard: Bool,
    inputMode: RecordingMode,
    triggerSource: TriggerSource,
    autoPasteToActiveApp: Bool,
    restoreClipboardAfterPaste: Bool,
    smartInsertion: Bool,
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
    selectedInputDeviceUID: String,
    preferredInputDeviceIDOverride: String,
    recoverySessionID: String? = nil,
    recoveryPayload: Data? = nil,
    escapeRecoveryEnabled: Bool = false
  ) {
    self.autoCopyToClipboard = autoCopyToClipboard
    self.inputMode = inputMode
    self.triggerSource = triggerSource
    self.autoPasteToActiveApp = autoPasteToActiveApp
    self.restoreClipboardAfterPaste = restoreClipboardAfterPaste
    self.smartInsertion = smartInsertion
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
    self.selectedInputDeviceUID = selectedInputDeviceUID
    self.preferredInputDeviceIDOverride = preferredInputDeviceIDOverride
    self.recoverySessionID = recoverySessionID
    self.recoveryPayload = recoveryPayload
    self.escapeRecoveryEnabled = escapeRecoveryEnabled
  }

  /// The user's locked dictation language, or nil on Auto-detect. Single authority
  /// for "what language is THIS dictation locked to" — every reader of
  /// `languageMode` that wants the locked code, not the mode itself, uses this
  /// so the extraction cannot drift between call sites (issue #2259).
  public var lockedLanguageCode: String? {
    if case .locked(let code) = languageMode { return code }
    return nil
  }
}
