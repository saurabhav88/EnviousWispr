@preconcurrency import AVFoundation
import EnviousWisprCore

/// Handles audio format conversion and buffer processing.
enum AudioBufferProcessor {
  /// Calculate RMS audio level from a buffer (0.0 - 1.0).
  static func calculateRMS(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let channelData = buffer.floatChannelData,
      buffer.frameLength > 0
    else { return 0 }

    let frames = Int(buffer.frameLength)
    let data = channelData[0]

    var sum: Float = 0
    for i in 0..<frames {
      sum += data[i] * data[i]
    }

    let rms = sqrt(sum / Float(frames))
    // Decibel-based scaling: map -60dB..0dB → 0..1 for perceptually correct levels
    let dBFS = 20 * log10(max(rms, 1e-6))
    let normalized = max(0, (dBFS + 60) / 60)
    return min(normalized, 1.0)
  }
}

/// Errors that can occur during audio operations.
public enum AudioError: LocalizedError, CustomNSError, Sendable {
  /// `osStatus` is the `OSStatus` the failing Core Audio call returned (#1851),
  /// or nil when the step has none (a nil component, format or converter) or
  /// the call succeeded. It is diagnostic only: `errorCode` stays 1, so the
  /// Sentry fingerprint (`AudioError#1`), the title and `localizedDescription`
  /// are identical with and without it.
  case formatCreationFailed(source: String = "unknown", osStatus: OSStatus? = nil)
  case alreadyCapturing
  case noBuiltInMicrophoneFound

  public static let errorDomain = "EnviousWisprAudio.AudioError"

  public var errorCode: Int {
    switch self {
    case .formatCreationFailed: return 1
    case .alreadyCapturing: return 2
    case .noBuiltInMicrophoneFound: return 3
    }
  }

  public var errorDescription: String? {
    switch self {
    case .formatCreationFailed: return "Failed to create audio format."
    case .alreadyCapturing: return "Audio capture is already active."
    // #1558: diagnostic-only text. The customer sentence ("No microphone
    // found. Please connect one.") lives ONLY in `DictationNarrator`;
    // this description is Sentry / diagnostic copy, never shown on a pill.
    case .noBuiltInMicrophoneFound: return "No usable microphone device was found."
    }
  }

  public var diagnosticSource: String? {
    switch self {
    case .formatCreationFailed(let source, _):
      return source
    case .alreadyCapturing, .noBuiltInMicrophoneFound:
      return nil
    }
  }

  /// #1851: the Mac's own answer for the step named by `diagnosticSource`.
  /// Nil means NOT KNOWN, never zero.
  public var diagnosticOSStatus: OSStatus? {
    switch self {
    case .formatCreationFailed(_, let osStatus):
      return osStatus
    case .alreadyCapturing, .noBuiltInMicrophoneFound:
      return nil
    }
  }
}

/// #1851: how a failing Core Audio `OSStatus` is written down for telemetry.
public enum AudioStatusFormatting {
  /// The status to RECORD for a failed setup step: nil when the call returned
  /// `noErr`. A guard such as `status == noErr, let unit` also fails on a nil
  /// result with a zero status, and a zero must never name a successful call as
  /// the failure.
  public static func failingStatus(_ status: OSStatus) -> OSStatus? {
    status == noErr ? nil : status
  }

  /// The four-character form of a status (`'stop'`, `'what'`, `'!dev'`), or nil
  /// when any of its four bytes is not printable ASCII (0x20 to 0x7E). Negative
  /// numeric codes such as -10851 have no printable form and return nil, so the
  /// caller sends the number alone.
  public static func fourCharacterCode(_ status: OSStatus) -> String? {
    let bits = UInt32(bitPattern: status)
    let bytes = [
      UInt8((bits >> 24) & 0xFF), UInt8((bits >> 16) & 0xFF),
      UInt8((bits >> 8) & 0xFF), UInt8(bits & 0xFF),
    ]
    guard bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else { return nil }
    return String(decoding: bytes, as: UTF8.self)
  }
}

// MARK: - Sentry identity

/// Adds explicit Sentry identity using the EXISTING `CustomNSError`
/// `errorDomain` and exhaustive `errorCode` switch. `AudioError`'s NSError
/// bridge, localized behavior, Sentry title, and grouping fingerprint remain
/// unchanged. The only new Sentry wire field is the readable `error.identity`
/// metadata tag required by PR J's future compile-time guard.
extension AudioError: StableSentryErrorIdentity {
  public var sentryFingerprintDescriptor: String {
    "\(Self.errorDomain)#\(errorCode)"
  }

  public var sentrySemanticID: String {
    switch self {
    case .formatCreationFailed: return "audio.format_creation_failed"
    case .alreadyCapturing: return "audio.already_capturing"
    case .noBuiltInMicrophoneFound: return "audio.no_built_in_microphone_found"
    }
  }
}
