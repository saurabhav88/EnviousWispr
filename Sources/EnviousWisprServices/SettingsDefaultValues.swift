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
  /// #2376: which recording pill a user sees when the machine cannot show words
  /// as they speak. The shipped capsule, so nobody's pill changes on upgrade.
  static let recordingPillDesignWithoutWords: RecordingPillDesign = .classic
  /// #2376: and when it can. The reading well, likewise unchanged.
  ///
  /// **These two are asserted to equal `PillDesignSelections.shipped`**, which is
  /// the frozen pair every overlay test measures against. One production
  /// authority, one frozen reference, and a test saying they agree — rather than
  /// two constants that happen to match on the day they were written.
  static let recordingPillDesignWithWords: RecordingPillDesign = .readingWell

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
  /// #2649: S1-mini's control-line picks. The type's own default IS the shipped
  /// value set, read here rather than restated so the two cannot drift.
  static let s1Control: S1ControlSettings = .default

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
  /// Quick Add's clipboard fallback (#2465). Default ON, because the whole point is that the
  /// feature stops silently failing in the apps people actually chat in, and a fallback nobody
  /// turns on is a fallback that does not exist.
  static let quickAddClipboardFallback = true
  /// Smart insertion: adjust spacing and capitalisation to the text around the
  /// caret. Default ON — the repair only ever fires where it is positively safe,
  /// and an unrecognised word simply keeps today's behaviour.
  static let smartInsertion = true

  /// Escape Recovery (#2087): keep a dictation the user cancelled with their
  /// cancel shortcut, instead of discarding it. Default ON (founder, 2026-09-01),
  /// superseding the opt-in-by-persona-consensus default this key shipped with.
  ///
  /// The cost of ON is unchanged and is accepted rather than unrecognised: a
  /// cancel stops being destructive, the transcription engine runs on text the
  /// user tried to throw away, a new recording cannot start until that finishes,
  /// and a BYOK user pays their provider for the polish. The founder's reading is
  /// that losing a dictation you meant to keep is the more expensive mistake, and
  /// the pill offers the recovery rather than performing it.
  static let escapeRecoveryEnabled = true

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
  // ON by default (founder, 2026-09-01), superseding the shipped OFF.
  //
  // The older-Mac objection that argued for OFF is answered by machinery that did
  // not exist when this key was written: `LivePreviewCoordinator` resolves an
  // EFFECTIVE enabled value per recording, so where no engine can run the app
  // behaves exactly as if the switch were off — ordinary pill, no message, nothing
  // to escape from. That is the only exception to this default, and it is
  // automatic rather than a second stored value.
  //
  // The screen-attention objection stands and is answered by the toggle. Display
  // only: the pasted text never comes from the preview.
  static let livePreviewEnabled = true
  /// #2123: Apple first. The universal engine is opt-in, never a default toll.
  static let livePreviewEngine: LivePreviewEngineChoice = .apple

  // #1480: show the once-per-launch Bluetooth cold-start education popover when
  // the configured input is a Bluetooth mic. Default ON — it is light, dismissable,
  // and only appears for Bluetooth users; the toggle is the annoyance escape hatch.
  // The permanent Microphone-settings guide stays regardless of this flag.
  static let showBluetoothTips = true

  // Recording start/stop sounds default ON, paired to Whisper Tick (founder,
  // 2026-09-01), superseding the shipped OFF. Start and stop are the two moments
  // a user most needs confirmed without looking at the pill. Whisper Tick was
  // already the fresh-install pairing (#1618) and is unchanged here; only the
  // on/off default moved. The toggle is the escape hatch for anyone in a shared
  // room. No migration is owed to the prior Air Glint pairing default: no
  // tagged release has ever shipped recording sound cues (v2.3.1 predates #1342
  // merging), so no installed base has an implicit old pairing to protect.
  static let playRecordingSounds = true
  static let recordingSoundPairing: RecordingSoundPairing = .whisperTick
}
