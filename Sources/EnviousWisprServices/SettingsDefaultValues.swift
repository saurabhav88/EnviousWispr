import AppKit
import EnviousWisprCore

/// Canonical shipped defaults — the single source of truth for what a fresh
/// install (or any uncustomized key) resolves to. Founder-ratified 2026-05-30
/// (#923). `SettingsManager.init` reads every simple-literal fallback from here;
/// logic-bearing fallbacks (legacy-key migrations, languageMode validation,
/// What's-New nil-handling) stay as code in the initializer.
///
/// Human-readable enumeration of the full set lives in the canonical-defaults
/// knowledge doc; this enum is the machine source. Keep the two in sync.
enum SettingsDefaultValues {
  static let selectedBackend: ASRBackendType = .parakeet
  static let recordingMode: RecordingMode = .pushToTalk

  /// Default appearance follows the macOS system setting.
  static let appearancePreference: AppearancePreference = .system

  // #923: AI polish is ON by default, Apple Intelligence. Previously the cold
  // fallback was `.none` and onboarding wrote `.appleIntelligence` separately,
  // which made the real default ambiguous. Apple Intelligence is on-device; on
  // machines without it the polish limb degrades to raw text (heart path safe).
  static let llmProvider: LLMProvider = .appleIntelligence
  // The engine restored when the AI Polish on/off toggle is turned back on and
  // no engine was ever remembered (#1285). Mirrors the default engine so a
  // fresh install that toggles off then on lands on Apple Intelligence.
  static let lastLLMProvider: LLMProvider = llmProvider
  static let ollamaModel = "llama3.2"

  static let autoCopyToClipboard = true
  static let hotkeyEnabled = true

  static let vadAutoStop = false
  static let vadSilenceTimeout: Double = 1.5
  static let vadSensitivity: Float = 0.5
  static let vadEnergyGate = true

  static let cancelKeyCode: Int = 53  // Escape
  static let cancelModifiersRaw: UInt = 0
  static let toggleKeyCode: Int = Int(ModifierKeyCodes.rightOption)
  static let toggleModifiersRaw: UInt = 0
  static let pushToTalkKeyCode: Int = 49  // Space
  static let pushToTalkModifiersRaw: UInt = NSEvent.ModifierFlags.option.rawValue

  static let modelUnloadPolicy: ModelUnloadPolicy = .never
  static let restoreClipboardAfterPaste = true

  static let wordCorrectionEnabled = true
  static let fillerRemovalEnabled = true
  // #636: opt-in launch re-scan of Contacts (add-only). Default OFF — the
  // feature only runs when the user enables both import and this sub-toggle.
  static let contactsSyncOnLaunchEnabled = false
  // #923: spoken-emoji conversion ON by default. Safe — the formatter fires
  // ONLY on explicit "<phrase> emoji" triggers; it never infers emoji from
  // sentiment (personas.md emoji-control-current), so uncustomized users see no
  // surprise emoji, just gain the explicit-trigger capability.
  static let emojiFormatterEnabled = true

  // #1063: crash-recovery audio safety copy. Default ON — every recording is
  // protected by an encrypted, auto-deleted-on-success spool. Off means never
  // persist audio (the privacy-strict choice).
  static let crashRecoveryEnabled = true

  static let isDebugModeEnabled = false
  // #1247: off by default, matching the privacy-strict rationale above — local
  // mic-audio retention is opt-in only, never silently on.
  static let isDictationAudioArchiveEnabled = false
  static let debugLogLevel: DebugLogLevel = .info
  static let useExtendedThinking = false

  static let whisperKitLanguage = "en"

  static let selectedInputDeviceUID = ""
  static let preferredInputDeviceIDOverride = ""

  static let useStreamingASR = false
  static let warmEnginePolicy: WarmEnginePolicy = .seconds30

  // #1480: show the once-per-launch Bluetooth cold-start education popover when
  // the configured input is a Bluetooth mic. Default ON — it is light, dismissable,
  // and only appears for Bluetooth users; the toggle is the annoyance escape hatch.
  // The permanent Microphone-settings guide stays regardless of this flag.
  static let showBluetoothTips = true
}
