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
  /// device id. The catch-all every non-device-removed loss collapses into.
  /// A recording-losing interruption with no other owner — the gap #1174 A3
  /// closes. CAPTURED.
  ///
  /// Does NOT mean the microphone went away. Use `.deviceRemoved` for that.
  case engineLost = "engine_lost"

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
  /// In-process capture (#1543) keeps the manager and its `capturedSamples`
  /// alive through every interruption cause, so both surviving causes are
  /// recoverable. Kept as a computed property (not a constant) because the
  /// kernel's salvage guard and `KernelLifecycleTelemetrySink`'s
  /// `salvage_attempted` both read it, and a future cause must decide its own
  /// answer at the exhaustive switch rather than inherit a default.
  public var hasRecoverableAudio: Bool {
    switch self {
    case .deviceRemoved, .engineLost: true
    }
  }

  /// #1408. Did the user's INPUT DEVICE go away — the event the "Microphone
  /// disconnected" pill and the History "Interrupted" badge describe?
  ///
  /// A question distinct from `hasRecoverableAudio`. `.engineLost` also
  /// interrupts capture and is also salvaged, but no microphone is known to have
  /// disconnected. Showing that user a disconnect notice, or badging their
  /// transcript with a crossed-out microphone, would be a lie. The salvage still
  /// happens; only the microphone claim is withheld, and telemetry still carries
  /// the real cause in `interrupted_by`.
  ///
  /// Only `.deviceRemoved` is backed by evidence — a `CoreAudioDeviceLiveness`
  /// classification of `.removed`. So it is the only cause allowed to say
  /// "Microphone disconnected" or to leave a permanent crossed-out-microphone
  /// badge on a transcript. A liveness read that merely FAILED is `.unverified`
  /// there and arrives here as `.engineLost`, precisely so a transient Core
  /// Audio error cannot manufacture a disconnect.
  ///
  /// Drives user-facing surfaces ONLY. Never gate salvage on this: both causes
  /// still have their audio and are still salvaged.
  public var isDeviceLoss: Bool {
    switch self {
    case .deviceRemoved: true
    case .engineLost: false
    }
  }
}
