import EnviousWisprCore
import Foundation

/// Typed error for user-visible heart-path failures that reach Sentry.
///
/// Telemetry-only: no `do/catch` consumer in app code switches on this type for
/// control flow. Pipeline `state = .error(...)` continues to use plain strings
/// for the UI overlay. Exists so `SentryBreadcrumb.captureError` call sites are
/// self-documenting and `errorDescription` formatting is consistent.
///
/// Per-case classification (Failure / Fallback) is documented in the round-4
/// plan at `docs/feature-requests/issue-285-2026-04-14-heart-path-sentry-coverage.md`
/// §3.8.
/// Cases may be added or removed in any position: the Sentry identity of each is
/// pinned explicitly in the `StableSentryErrorIdentity` conformance below, not
/// inherited from its position in this list. The former APPEND-ONLY contract is
/// retired (#1524).
public enum HeartPathError: LocalizedError, Sendable {
  case audioCaptureStalled(sessionID: UInt64, ctx: CaptureStallContext)
  case noAudioCaptured(sessionID: UInt64, durationMs: Int, wasStreaming: Bool, route: String)
  case pasteCascadeClipboardFallback(
    tiersAttempted: [String], focusClassification: String, targetBundleID: String?)
  case pasteCGEventCreationFailed(accessibilityTrusted: Bool)
  case pasteAppleScriptFailed(
    errorCode: Int?, errorMessage: String?, targetBundleID: String?)
  case emptyAfterProcessing(route: String, wasPolishEnabled: Bool)
  case zombieEngineZeroPeak(sessionID: UInt64, durationMs: Int, route: String, sampleCount: Int)
  case audioEngineInterrupted(route: String, durationMs: Int)

  public var errorDescription: String? {
    switch self {
    case .audioCaptureStalled(let sessionID, _):
      return "Audio capture stalled: no buffers delivered (session \(sessionID))"
    case .noAudioCaptured(let sessionID, let durationMs, _, _):
      return "No audio captured after \(durationMs)ms (session \(sessionID))"
    case .pasteCascadeClipboardFallback(let tiers, _, _):
      return "Paste cascade fell back to clipboard after tiers: \(tiers.joined(separator: ","))"
    case .pasteCGEventCreationFailed(let trusted):
      return "Paste CGEvent creation failed (accessibility=\(trusted))"
    case .pasteAppleScriptFailed(let code, let message, _):
      return "Paste AppleScript failed (code=\(code.map(String.init) ?? "nil")): \(message ?? "")"
    case .emptyAfterProcessing(_, let wasPolishEnabled):
      return "Post-processing emptied the transcript (polish=\(wasPolishEnabled))"
    case .zombieEngineZeroPeak(let sessionID, let durationMs, let route, let sampleCount):
      return
        "Zombie engine: zero-peak \(sampleCount) samples over \(durationMs)ms (session \(sessionID), route=\(route))"
    case .audioEngineInterrupted(let route, let durationMs):
      return "Audio engine interrupted: recording lost after \(durationMs)ms (route=\(route))"
    }
  }
}

// MARK: - Sentry identity

/// Pins each case's Sentry grouping key to the exact string it has been sending
/// in production, so the identity survives any future add/remove of a case.
///
/// The descriptors below are NOT derived — they were MEASURED against shipping
/// code before this change and cross-checked against the live Sentry issue titles
/// (`docs/audits/2026-07-12-sentry-identity-preflight.md`). The `#N` suffix is now
/// a permanent serial number, not a position: `#2` is absent because the case that
/// held it (the capture-session interruption) was deleted with its backend, and
/// `#6`/`#7`/`#8` are absent because the boundary-failure cases that held them were
/// deleted with the audio-capture boundary collapse (#1543); no later case moves up.
///
/// NEVER change a shipped `sentryFingerprintDescriptor`: it would split that
/// error's existing Sentry issue in two. A NEW case gets a fresh unused string —
/// prefer the semantic form (`heartpath.<name>`) over another number. The switch
/// is exhaustive, so a new case cannot compile until it declares an identity.
extension HeartPathError: StableSentryErrorIdentity {
  private static let domain = "EnviousWisprServices.HeartPathError"

  public var sentryFingerprintDescriptor: String {
    switch self {
    case .audioCaptureStalled: return "\(Self.domain)#0"
    case .noAudioCaptured: return "\(Self.domain)#1"
    case .pasteCascadeClipboardFallback: return "\(Self.domain)#3"
    case .pasteCGEventCreationFailed: return "\(Self.domain)#4"
    case .pasteAppleScriptFailed: return "\(Self.domain)#5"
    case .emptyAfterProcessing: return "\(Self.domain)#9"
    case .zombieEngineZeroPeak: return "\(Self.domain)#10"
    case .audioEngineInterrupted: return "\(Self.domain)#11"
    }
  }

  public var sentrySemanticID: String {
    switch self {
    case .audioCaptureStalled: return "heartpath.audio_capture_stalled"
    case .noAudioCaptured: return "heartpath.no_audio_captured"
    case .pasteCascadeClipboardFallback: return "heartpath.paste_cascade_clipboard_fallback"
    case .pasteCGEventCreationFailed: return "heartpath.paste_cgevent_creation_failed"
    case .pasteAppleScriptFailed: return "heartpath.paste_applescript_failed"
    case .emptyAfterProcessing: return "heartpath.empty_after_processing"
    case .zombieEngineZeroPeak: return "heartpath.zombie_engine_zero_peak"
    case .audioEngineInterrupted: return "heartpath.audio_engine_interrupted"
    }
  }
}
