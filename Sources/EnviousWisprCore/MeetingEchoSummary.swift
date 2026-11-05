import Foundation

/// #4355 PR B: what echo cleanup did in one recording, frozen once when Stop or Quit settled the
/// echo worker. Counts and closed values only: never audio, text, names, paths, ids, the library
/// version or its configuration. Carried on the attempt like the mute summary; a Retry inherits
/// it, and an attempt recovered after a relaunch has none.
public struct MeetingEchoSummary: Sendable, Equatable {
  /// How echo cleanup started for the recording (`aec_init_outcome`).
  public enum InitOutcome: String, Sendable, CaseIterable, Equatable {
    /// The echo library was created and cleaned audio.
    case ok
    /// The echo library could not be created.
    case failed
    /// No call sound to clean against: the call sound was off, unsupported or failed to start.
    case noReference = "no_reference"
  }

  /// Why AEC3 actually started over (`aec_reset_reason`), counted when the reset ran, never when
  /// it was only asked for.
  public enum ResetCause: String, Sendable, CaseIterable, Equatable, Comparable {
    /// The microphone stream started a new run (a lost microphone reopened).
    case micRun = "mic_run"
    /// Microphone audio was refused between two accepted pieces.
    case micGap = "mic_gap"
    /// The call-sound stream started a new run.
    case callRun = "call_run"
    /// The call-sound capture was rebuilt (a route change).
    case callRebuild = "call_rebuild"
    /// The call sound stopped or could not be rebuilt.
    case callLost = "call_lost"
    /// The call-sound sample rate changed.
    case rateChange = "rate_change"
    case wake
    case divergence
    /// More reference arrived than the microphone caught up with.
    case referenceOverflow = "reference_overflow"
    /// The worker passed audio through raw (backlog or deadline) and started a new epoch.
    case passthrough
    /// A native call failed.
    case nativeFailure = "native_failure"

    public static func < (a: ResetCause, b: ResetCause) -> Bool { a.rawValue < b.rawValue }
  }

  /// Microphone audio offered to echo cleanup, in samples at the meeting rate.
  public let eligibleSamples: Int
  /// The part of `eligibleSamples` written with the raw audio as its cleaned copy (warm-up, no
  /// reference yet, reacquiring after a reset, backlog, deadline, refusal, Stop's raw takeover).
  public let passthroughSamples: Int
  /// Nil when not known (the library was never asked to start: no microphone audio arrived).
  public let initOutcome: InitOutcome?
  /// AEC3 resets that ran.
  public let resetCount: Int
  /// The causes of the resets that ran, each counted once per reset it caused.
  public let resetCauses: [ResetCause: Int]

  public init(
    eligibleSamples: Int, passthroughSamples: Int, initOutcome: InitOutcome?, resetCount: Int,
    resetCauses: [ResetCause: Int]
  ) {
    self.eligibleSamples = max(0, eligibleSamples)
    self.passthroughSamples = min(max(0, passthroughSamples), max(0, eligibleSamples))
    self.initOutcome = initOutcome
    self.resetCount = max(0, resetCount)
    self.resetCauses = resetCauses.filter { $0.value > 0 }
  }

  /// A recording with no call sound to clean against: nothing eligible, nothing reset.
  public static let noReference = MeetingEchoSummary(
    eligibleSamples: 0, passthroughSamples: 0, initOutcome: .noReference, resetCount: 0,
    resetCauses: [:])

  /// Whole milliseconds of `samples` at the meeting rate, converted once (rounded down).
  public static func milliseconds(samples: Int) -> Int {
    Int((Int64(max(0, samples)) * 1_000) / Int64(MeetingAudioFormat.sampleRate))
  }

  public var eligibleMs: Int { Self.milliseconds(samples: eligibleSamples) }
  public var passthroughMs: Int { Self.milliseconds(samples: passthroughSamples) }

  /// `aec_reset_reason`: `none`, the one cause seen, or `multiple`.
  public var resetReason: String {
    switch resetCauses.count {
    case 0: return "none"
    case 1: return resetCauses.keys.first!.rawValue
    default: return "multiple"
    }
  }
}
