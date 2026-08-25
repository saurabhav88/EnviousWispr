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

  // #1341: recording pill / status notices default to the top of the screen,
  // matching the fixed position every existing install already sees.
  static let overlayPillPosition: OverlayPillPosition = .top

  // #923: AI polish is ON by default, Apple Intelligence. Previously the cold
  // fallback was `.none` and onboarding wrote `.appleIntelligence` separately,
  // which made the real default ambiguous. Apple Intelligence is on-device; on
  // machines without it the polish limb degrades to raw text (heart path safe).
  static let llmProvider: LLMProvider = .appleIntelligence
  // The engine restored when the AI Polish on/off toggle is turned back on and
  // no engine was ever remembered (#1285). Mirrors the default engine so a
  // fresh install that toggles off then on lands on Apple Intelligence.
  static let lastLLMProvider: LLMProvider = llmProvider
  // #1950: the measured local-model default. This applies only when no choice is stored;
  // SettingsManager preserves an existing ollamaModel value.
  static let ollamaModel = "qwen2.5:3b"

  static let autoCopyToClipboard = true
  static let hotkeyEnabled = true

  static let vadAutoStop = false
  static let vadSilenceTimeout: Double = 1.5
  static let vadSensitivity: Float = 0.5
  static let vadEnergyGate = true

  // The three shortcut defaults are OWNED by `ShortcutRole.defaultBinding` and read here, rather
  // than written here and repeated in the service and in each Settings row. See that extension for
  // why: three unlinked copies of one value, whose drift symptom is a Reset button that takes the
  // user somewhere no fresh install goes.
  static let cancelKeyCode: Int = Int(ShortcutRole.cancel.defaultKeyCode)
  static let cancelModifiersRaw: UInt = ShortcutRole.cancel.defaultModifiers.rawValue
  static let quickAddKeyCode: Int = Int(ShortcutRole.quickAdd.defaultKeyCode)
  static let quickAddModifiersRaw: UInt = ShortcutRole.quickAdd.defaultModifiers.rawValue
  static let toggleKeyCode: Int = Int(ShortcutRole.record.defaultKeyCode)
  static let toggleModifiersRaw: UInt = ShortcutRole.record.defaultModifiers.rawValue
  static let pushToTalkKeyCode: Int = 49  // Space
  static let pushToTalkModifiersRaw: UInt = NSEvent.ModifierFlags.option.rawValue

  static let modelUnloadPolicy: ModelUnloadPolicy = .never
  static let restoreClipboardAfterPaste = true
  /// Smart insertion: adjust spacing and capitalisation to the text around the
  /// caret. Default ON — the repair only ever fires where it is positively safe,
  /// and an unrecognised word simply keeps today's behaviour.
  static let smartInsertion = true

  /// Escape Recovery (#2087): keep a dictation the user cancelled with their
  /// cancel shortcut, instead of discarding it. Default OFF, and that default is
  /// the product decision, not a cautious rollout — persona review put every
  /// persona at "off" and one at "on", so the feature is opt-in by consensus.
  ///
  /// It is off because ON changes what a cancel MEANS. Escape stops being
  /// destructive, the transcription engine runs on text the user tried to throw
  /// away, a new recording cannot start until that finishes, and a BYOK user
  /// pays their provider for the polish. Every one of those is defensible when
  /// chosen and indefensible when imposed.
  static let escapeRecoveryEnabled = false

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
  // #1794: spoken-punctuation commands ("comma" -> ",") OFF by default — the only
  // Text-cleanup toggle that ships off. These rules shipped always-on as a rider on
  // #145 and #1367 measured them: they fight the punctuation both recognizers already
  // add, and they fire on content words ("the grace period expires"). Founder
  // direction 2026-07-25: off for everyone, opt in from Settings.
  static let spokenPunctuationEnabled = false

  // #1063: crash-recovery audio safety copy. Default ON — every recording is
  // protected by an encrypted, auto-deleted-on-success spool. Off means never
  // persist audio (the privacy-strict choice).
  static let crashRecoveryEnabled = true

  static let isDebugModeEnabled = false
  // #1247: off by default, matching the privacy-strict rationale above — local
  // mic-audio retention is opt-in only, never silently on.
  static let isDictationAudioArchiveEnabled = false
  static let debugLogLevel: DebugLogLevel = .info

  static let whisperKitLanguage = "en"

  static let selectedInputDeviceUID = ""
  static let preferredInputDeviceIDOverride = ""

  static let useStreamingASR = false
  static let warmEnginePolicy: WarmEnginePolicy = .seconds30

  // #1988: show the words in the recording pill while the user is still speaking.
  // OFF by default. It costs screen attention some users explicitly do not want
  // (the Reddit request that prompted it asked for it to be toggleable for exactly
  // that reason), and it needs macOS 26, so a default-on toggle would read as
  // broken on every older Mac. Display only: the pasted text never comes from it.
  static let livePreviewEnabled = false
  /// #2123: Apple first. The universal engine is opt-in, never a default toll.
  static let livePreviewEngine: LivePreviewEngineChoice = .apple

  // #1480: show the once-per-launch Bluetooth cold-start education popover when
  // the configured input is a Bluetooth mic. Default ON — it is light, dismissable,
  // and only appears for Bluetooth users; the toggle is the annoyance escape hatch.
  // The permanent Microphone-settings guide stays regardless of this flag.
  static let showBluetoothTips = true

  // Recording start/stop sounds default OFF — silent for every existing user
  // until they opt in. The pairing default only matters once the toggle is
  // on; Whisper Tick is the fresh-install choice (#1618). No migration for
  // users who enabled sounds under the prior Air Glint default: no tagged
  // release has ever shipped recording sound cues (v2.3.1 predates #1342
  // merging), so no installed base has an implicit old default to protect —
  // #1342 and #1618 ship together, for the first time, in the same release.
  static let playRecordingSounds = false
  static let recordingSoundPairing: RecordingSoundPairing = .whisperTick
}
