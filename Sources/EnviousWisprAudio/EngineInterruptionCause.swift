/// Classifies why the audio-capture `onEngineInterrupted` callback fired, so a
/// downstream telemetry consumer can route the lost-dictation capture without
/// double-counting causes that already have an owner.
///
/// This is a CLASSIFICATION value, not heart-path control flow: the kernel still
/// resets / stops identically for every case. Only the telemetry capture gate
/// reads it (issue #1174 A3). The cause's job is to SUPPRESS the two causes
/// already accounted for elsewhere and CAPTURE everything else — every other
/// recording-losing interruption is a genuine lost dictation with no other owner.
public enum EngineInterruptionCause: String, Sendable, Equatable, CaseIterable {
  /// #1408. The user's input device is VERIFIED GONE: `CoreAudioDeviceLiveness`
  /// classified it `.removed` — the device reported itself dead, or its object
  /// no longer resolves at all. A Bluetooth headset that walks out of range, a
  /// USB mic unplugged mid-sentence.
  ///
  /// This is the ONLY cause that entitles us to tell the user their microphone
  /// disconnected. It was split out of `.engineLost`, which had come to mean both
  /// "the device vanished" and "the engine could not recover" — a conflation that
  /// would have put a permanent crossed-out-microphone badge on a recording whose
  /// microphone never left. CAPTURED (a recording-losing interruption with no
  /// other owner, exactly like `.engineLost`).
  case deviceRemoved = "device_removed"

  /// The capture engine died or failed to recover, with the device still attached
  /// as far as we can tell: a format-stabilization timeout during codec-switch
  /// recovery, a failed engine restart, or a config change with no resolvable
  /// device id. Also the catch-all the XPC relay collapses unknown causes into.
  /// A recording-losing interruption with no other owner — the gap #1174 A3
  /// closes. CAPTURED.
  ///
  /// Does NOT mean the microphone went away. Use `.deviceRemoved` for that.
  case engineLost = "engine_lost"

  /// An audio XPC connection break (interrupt / invalidate handler). Already
  /// captured by `onXPCServiceError` → `.xpcServiceError`. NOT re-captured.
  case xpcConnectionLost = "xpc_connection_lost"

  // `.maxDurationReached` was DELETED (#1408 A3): the hard duration cap is a
  // normal auto-stop, not an engine interruption. It now signals through
  // `onMaxDurationReached` → `CaptureVADSignalSource.noteMaxDurationReached()`
  // → the kernel's typed `.maxDuration` exit — the same route the graceful
  // wall-clock cap has always used. Every case left here is a genuine
  // capture-losing interruption.
}

extension EngineInterruptionCause {
  /// #1408. Does the capture manager still hold `capturedSamples` after this
  /// interruption — i.e. can the recording be transcribed rather than thrown away?
  ///
  /// `.xpcConnectionLost` is the only cause whose sample owner is gone; every
  /// other cause leaves the manager alive and still holding audio.
  ///
  /// The single authority for that question: the kernel's salvage guard and
  /// `KernelLifecycleTelemetrySink`'s `salvage_attempted` both read it, so the
  /// switch is never copied. Exhaustive on purpose — a new cause must fail to
  /// compile rather than silently default to "recoverable."
  public var hasRecoverableAudio: Bool {
    switch self {
    case .deviceRemoved, .engineLost: true
    case .xpcConnectionLost: false
    }
  }

  /// #1408. Did the user's INPUT DEVICE go away — the event the "Microphone
  /// disconnected" pill and the History "Interrupted" badge describe?
  ///
  /// A THIRD question, distinct from both `hasRecoverableAudio` and the
  /// telemetry-capture set above. `.engineLost` also interrupts capture and is
  /// also salvaged, but no microphone is known to
  /// have disconnected. Showing that user a disconnect notice, or badging
  /// their transcript with a crossed-out microphone, would be a lie. The salvage
  /// still happens; only the microphone claim is withheld, and telemetry still
  /// carries the real cause in `interrupted_by`.
  ///
  /// Exactly one cause earns it, and every exclusion is a claim we cannot back:
  /// - `.engineLost` also covers a recovery timeout and a failed engine restart,
  ///   with the device still attached.
  /// - `.xpcConnectionLost` means OUR helper process died.
  ///
  /// Only `.deviceRemoved` is backed by evidence — a `CoreAudioDeviceLiveness`
  /// classification of `.removed`. So it is the only cause allowed to say
  /// "Microphone disconnected" or to leave a permanent crossed-out-microphone
  /// badge on a transcript. A liveness read that merely FAILED is `.unverified`
  /// there and arrives here as `.engineLost`, precisely so a transient Core
  /// Audio error cannot manufacture a disconnect.
  ///
  /// Drives user-facing surfaces ONLY. Never gate salvage on this: every cause
  /// above except `.xpcConnectionLost` still has its audio and is still salvaged.
  public var isDeviceLoss: Bool {
    switch self {
    case .deviceRemoved: true
    case .engineLost, .xpcConnectionLost: false
    }
  }

  /// Maps a cause RELAYED across the XPC boundary (its raw value) to the cause the
  /// host should fire. Unknown / legacy raw values default to `.engineLost` (fail
  /// toward visibility). Issue #1174 A3.
  ///
  /// One cause survives the crossing intact:
  /// - `.deviceRemoved` (#1408), because the helper ran the liveness check and
  ///   the host cannot re-run it — the device is already gone. Collapsing it
  ///   would throw away the ONE piece of evidence that entitles the app to tell
  ///   the user their microphone disconnected. The helper's capture backend IS
  ///   the shipping one (`useXPCAudioService` defaults true), so this is the path
  ///   a real Bluetooth disconnect actually takes.
  ///
  /// (`max_duration_reached` no longer exists as a cause (#1408 A3); a legacy
  /// raw value from a stale helper maps to `.engineLost` like every other
  /// unknown — helper and host ship in one bundle, so skew cannot happen in
  /// practice.)
  ///
  /// Everything else collapses to `.engineLost`: on the host side those have no
  /// other owner and must still be captured. The retired `capture_session_lost`
  /// wire value (#1524) is now an UNKNOWN raw value and lands on the same
  /// `?? .engineLost` fallback — behaviour is unchanged, and the assertion that
  /// proves it lives in `EngineInterruptionCauseTests`. Do not "clean up" that
  /// nil-coalescing: retiring the case INCREASED its load.
  public static func hostCause(forRelayedRawValue raw: String) -> EngineInterruptionCause {
    let relayed = EngineInterruptionCause(rawValue: raw) ?? .engineLost
    switch relayed {
    case .deviceRemoved: return relayed
    case .engineLost, .xpcConnectionLost: return .engineLost
    }
  }
}
