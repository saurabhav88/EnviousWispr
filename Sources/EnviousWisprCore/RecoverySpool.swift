import Foundation

// MARK: - Crash-recovery audio spool: shared value types (#1063 PR0)
//
// A recording lives only in RAM until stop, so a crash / OS memory-kill /
// kernel panic / power loss mid-take loses everything. The crash-recovery limb
// streams captured samples to an encrypted, append-only file while recording,
// and replays it on the next launch. These value types are the contract shared
// across process and module boundaries:
//   - the directive the host hands the audio helper at capture start (XPC),
//   - the on-disk header,
//   - the record-time settings snapshot recovery must replay under,
//   - the decoded frame the store yields.
// The actual cipher + frame codec is `RecoverySpoolCipher`; the helper-side
// writer (`EnviousWisprAudio`) and host-side store (`EnviousWisprStorage`) both
// go through it, which is why these types and the codec live in Core (the only
// module both depend on).
//
// Everything here is a LIMB: nothing in this file is reachable from the heart
// path (capture -> ASR -> paste). A malformed directive, header, or frame is
// discarded, never fatal.

/// How a spool's frames (and its settings block) are protected at rest.
/// `aesGcm256` is the only mode shipped writers use (encryption is live from
/// PR1); `none` is a format affordance for a degraded writer that could not
/// obtain a key, and keeps the on-disk frame shape identical so turning
/// encryption on is never a format rewrite.
public enum RecoverySpoolCipherMode: String, Codable, Sendable {
  case none = "none"
  case aesGcm256 = "aes-gcm-256"
}

/// What a frame carries. Audio frames hold captured samples; a single terminal
/// marker frame records WHY writing stopped so the recovered entry can be
/// honest ("recording cut short, disk was full").
public enum RecoveryFrameKind: UInt8, Sendable {
  case audio = 0
  case marker = 1
}

/// Why a spool stopped being written. Encoded in the terminal marker frame.
public enum RecoverySpoolTerminationReason: UInt8, Codable, Sendable {
  /// The user stopped normally; the live transcript is being saved.
  case cleanFinalized = 0
  /// A write failed because the volume filled up mid-recording.
  case diskFull = 1
  /// Spooling stopped because free space crossed the low-disk watermark.
  case lowDiskWatermark = 2
  /// The helper is exiting (XPC invalidation / termination) and flushed.
  case interrupted = 3
}

/// The record-time settings recovery must replay under, NOT whatever the user
/// has set now. Replaying a Spanish dictation under English settings would
/// produce 45 minutes of hallucinations; this snapshot prevents that. Captured
/// at capture start, encrypted into the spool header, read back on recovery.
public struct RecordingSettingsSnapshot: Codable, Sendable, Equatable {
  /// The ASR engine the recording used (recovery replays through the neutral
  /// engine interface; this is metadata, never an identity branch).
  public let backendType: ASRBackendType
  /// Whether the recording's engine could detect language, captured at record
  /// time from `adapter.capabilities.supportsLanguageDetection` (a CAPABILITY,
  /// never an engine-identity literal). Recovery applies it to the inverse-text-
  /// normalization gate so a recovered take is processed exactly like the live
  /// one — a LID engine with unknown language skips ITN instead of rewriting
  /// possibly-non-English text.
  public let backendSupportsLanguageDetection: Bool
  /// The decode language the user had locked (or `.auto`).
  public let languageMode: LanguageMode
  public let wordCorrectionEnabled: Bool
  public let fillerRemovalEnabled: Bool
  public let emojiFormatterEnabled: Bool
  /// Version/hash of the custom-words vocabulary at record time, so recovery
  /// can note when the vocabulary has since changed. Nil when unknown.
  public let customWordsVersion: String?
  /// Polish provider/model identity at record time (e.g. "appleIntelligence").
  public let llmProvider: String
  public let llmModel: String
  /// Whether extended-thinking polish was on at record time. Recovery applies it
  /// so a reasoning-capable provider replays under the same setting the live
  /// dictation used, not the default off.
  public let useExtendedThinking: Bool
  /// Polish prompt version at record time. Nil for providers without one.
  public let polishPromptVersion: String?

  public init(
    backendType: ASRBackendType,
    backendSupportsLanguageDetection: Bool,
    languageMode: LanguageMode,
    wordCorrectionEnabled: Bool,
    fillerRemovalEnabled: Bool,
    emojiFormatterEnabled: Bool,
    customWordsVersion: String? = nil,
    llmProvider: String,
    llmModel: String,
    useExtendedThinking: Bool = false,
    polishPromptVersion: String? = nil
  ) {
    self.backendType = backendType
    self.backendSupportsLanguageDetection = backendSupportsLanguageDetection
    self.languageMode = languageMode
    self.wordCorrectionEnabled = wordCorrectionEnabled
    self.fillerRemovalEnabled = fillerRemovalEnabled
    self.emojiFormatterEnabled = emojiFormatterEnabled
    self.customWordsVersion = customWordsVersion
    self.llmProvider = llmProvider
    self.llmModel = llmModel
    self.useExtendedThinking = useExtendedThinking
    self.polishPromptVersion = polishPromptVersion
  }
}

/// The limb configuration the host hands the audio helper at capture start.
/// Crosses the XPC boundary as `Data` (an `@objc` protocol cannot take a Swift
/// struct), so it is `Codable`. `enabled == false` (or a nil/garbage payload)
/// means the helper behaves exactly as it does today — no spool, no key use.
public struct RecoverySpoolDirective: Codable, Sendable, Equatable {
  public let enabled: Bool
  /// The durable session key shared by the spool and its History entry. This is
  /// the recording kernel's `SessionID`, NOT a per-XPC-call operation id, so a
  /// crash in the save->delete window cannot duplicate a recovered transcript.
  public let recoverySessionID: String
  /// Absolute path to the `.ewrec` file the writer appends to.
  public let spoolPath: String
  /// The 32-byte AES-256 key bytes, generated host-side and persisted in the
  /// Keychain so it survives a crash. Nil ⇒ `cipher == .none` / disabled.
  public let keyData: Data?
  /// Record-time settings recovery replays under.
  public let settingsSnapshot: RecordingSettingsSnapshot

  public init(
    enabled: Bool,
    recoverySessionID: String,
    spoolPath: String,
    keyData: Data?,
    settingsSnapshot: RecordingSettingsSnapshot
  ) {
    self.enabled = enabled
    self.recoverySessionID = recoverySessionID
    self.spoolPath = spoolPath
    self.keyData = keyData
    self.settingsSnapshot = settingsSnapshot
  }

  public var cipherMode: RecoverySpoolCipherMode {
    keyData == nil ? .none : .aesGcm256
  }
}

/// The fixed, mostly-plaintext header at the top of a `.ewrec` file. The audio
/// format is uniform across every engine (16 kHz mono Float32), so recovery can
/// read frames even if this header is damaged — it carries provenance plus the
/// ENCRYPTED settings block, not anything required to decode audio. The session
/// key is keyed in the Keychain by `recoverySessionID` (also the filename), so
/// the header never holds key material.
public struct RecoverySpoolHeader: Codable, Sendable, Equatable {
  public let formatVersion: Int
  public let cipher: RecoverySpoolCipherMode
  public let sampleRate: Double
  public let channels: Int
  public let recoverySessionID: String
  public let createdAt: Date
  public let appVersion: String
  /// The `RecordingSettingsSnapshot` sealed with the session key (combined
  /// nonce||ciphertext||tag). Nil when `cipher == .none`.
  public let encryptedSettings: Data?

  public init(
    formatVersion: Int = RecoveryConstants.formatVersion,
    cipher: RecoverySpoolCipherMode,
    sampleRate: Double = AudioConstants.sampleRate,
    channels: Int = AudioConstants.channels,
    recoverySessionID: String,
    createdAt: Date,
    appVersion: String,
    encryptedSettings: Data?
  ) {
    self.formatVersion = formatVersion
    self.cipher = cipher
    self.sampleRate = sampleRate
    self.channels = channels
    self.recoverySessionID = recoverySessionID
    self.createdAt = createdAt
    self.appVersion = appVersion
    self.encryptedSettings = encryptedSettings
  }
}

/// A single decoded frame the store yields while reconstructing the valid
/// continuous prefix. Audio frames carry `samples`; the terminal marker frame
/// carries `terminationReason`.
public struct RecoveryFrame: Sendable, Equatable {
  public let kind: RecoveryFrameKind
  public let chunkIndex: UInt32
  /// Index of this chunk's first sample within the whole session.
  public let startSample: UInt64
  public let sampleCount: UInt32
  public let nonceCounter: UInt64
  /// Decoded audio samples for an `.audio` frame; empty for a marker.
  public let samples: [Float]
  /// Termination reason for a `.marker` frame; nil for audio.
  public let terminationReason: RecoverySpoolTerminationReason?

  public init(
    kind: RecoveryFrameKind,
    chunkIndex: UInt32,
    startSample: UInt64,
    sampleCount: UInt32,
    nonceCounter: UInt64,
    samples: [Float],
    terminationReason: RecoverySpoolTerminationReason?
  ) {
    self.kind = kind
    self.chunkIndex = chunkIndex
    self.startSample = startSample
    self.sampleCount = sampleCount
    self.nonceCounter = nonceCounter
    self.samples = samples
    self.terminationReason = terminationReason
  }
}
