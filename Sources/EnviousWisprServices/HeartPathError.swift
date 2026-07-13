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
public enum HeartPathError: LocalizedError, Sendable {
  case audioCaptureStalled(sessionID: UInt64, ctx: CaptureStallContext)
  case noAudioCaptured(sessionID: UInt64, durationMs: Int, wasStreaming: Bool, route: String)
  case pasteCascadeClipboardFallback(
    tiersAttempted: [String], focusClassification: String, targetBundleID: String?)
  case pasteCGEventCreationFailed(accessibilityTrusted: Bool)
  case pasteAppleScriptFailed(
    errorCode: Int?, errorMessage: String?, targetBundleID: String?)
  case audioXPCInterrupted(handler: XPCHandlerKind, wasCapturing: Bool)
  case xpcReplyFailed(ctx: XPCReplyFailureContext)
  case xpcServerClientProxyNil(sessionID: UInt64?, consecutiveDrops: Int)
  case emptyAfterProcessing(route: String, wasPolishEnabled: Bool)
  case zombieEngineZeroPeak(sessionID: UInt64, durationMs: Int, route: String, sampleCount: Int)
  // APPEND-ONLY: handled Sentry errors are fingerprinted on the bridged NSError
  // `domain#code`, and a Swift enum's `_code` is its declaration ordinal — so
  // inserting a case mid-enum shifts every later case's code and SPLITS existing
  // Sentry issues. New cases go at the END (Codex #1174 PR-5b r1).
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
    case .audioXPCInterrupted(let handler, let wasCapturing):
      return "Audio XPC \(handler.rawValue) (capturing=\(wasCapturing))"
    case .xpcReplyFailed(let ctx):
      return "XPC reply failed at \(ctx.replyStage): \(ctx.errorDescription)"
    case .xpcServerClientProxyNil(_, let drops):
      return "XPC server observed nil clientProxy for \(drops) consecutive buffer sends"
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

/// Classifies the XPC handler origin for `HeartPathError.audioXPCInterrupted`.
public enum XPCHandlerKind: String, Sendable {
  case interrupt
  case invalidate
}
