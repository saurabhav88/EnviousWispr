/// Classifies why the audio-capture `onEngineInterrupted` callback fired, so a
/// downstream telemetry consumer can route the lost-dictation capture without
/// double-counting causes that already have an owner.
///
/// This is a CLASSIFICATION value, not heart-path control flow: the kernel still
/// resets / stops identically for every case. Only the telemetry capture gate
/// reads it (issue #1174 A3). The cause's job is to SUPPRESS the three causes
/// already accounted for elsewhere and CAPTURE everything else — every other
/// recording-losing interruption is a genuine lost dictation with no other owner.
public enum EngineInterruptionCause: String, Sendable, Equatable, CaseIterable {
  /// A recording-losing audio interruption with no other owner — the gap A3
  /// closes. Set by `AVAudioEngineSource` device disconnects (direct mode) and
  /// by the XPC service relay (`AudioCaptureProxy.engineInterrupted(cause:)`),
  /// which funnels ALL service-side interruptions through one channel because the
  /// XPC client protocol has no capture-session callback. CAPTURED.
  case engineLost = "engine_lost"

  /// A DIRECT-mode `AVCaptureSession` interruption. Already captured by
  /// `captureSessionInterrupted` → `.audioCaptureFailed`, so A3 does NOT
  /// re-capture. (In XPC mode this path does not exist — see `.engineLost`.)
  case captureSessionLost = "capture_session_lost"

  /// An audio XPC connection break (interrupt / invalidate handler). Already
  /// captured by `onXPCServiceError` → `.xpcServiceError`. NOT re-captured.
  case xpcConnectionLost = "xpc_connection_lost"

  /// Direct-mode 60-minute max-duration cap (a normal auto-stop, not a loss).
  /// NOT captured.
  case maxDurationReached = "max_duration_reached"
}

extension EngineInterruptionCause {
  /// Maps a cause RELAYED across the XPC boundary (its raw value) to the cause the
  /// host should fire. Across XPC there is no capture-session relay, so every loss
  /// cause collapses to `.engineLost` — on the host side it has no other owner, so
  /// it must be captured. Only the non-loss `.maxDurationReached` cap is preserved
  /// so the host suppresses it exactly as direct mode does. Unknown / legacy raw
  /// values default to `.engineLost` (fail toward visibility). Issue #1174 A3.
  public static func hostCause(forRelayedRawValue raw: String) -> EngineInterruptionCause {
    let relayed = EngineInterruptionCause(rawValue: raw) ?? .engineLost
    return relayed == .maxDurationReached ? .maxDurationReached : .engineLost
  }
}
