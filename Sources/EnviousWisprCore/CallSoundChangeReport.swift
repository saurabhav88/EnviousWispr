import Foundation

/// #4121: one call-sound rebuild or stop as the telemetry row will carry it: closed vocabularies,
/// rates and a transport class. The recorder converts `SystemAudioTap.CaptureReport` into this
/// value so that code built for macOS 14.0 (the recorder, the wiring, the emitter) can carry it;
/// the tap itself exists only on macOS 14.2 and later.
public struct CallSoundChangeReport: Sendable, Equatable {
  /// `SystemAudioTap.CaptureReport.Outcome` raw value, e.g. `rebuilt`, `stopped_rate_mismatch`.
  public var outcome: String
  /// `SystemAudioTap.RebuildReason.telemetryValue`; nil for a layout stop.
  public var reason: String?
  public var configuredRateHz: Int?
  public var nominalRateHz: Int?
  public var measuredRateBucket: String?
  public var outputTransport: String?

  public init(
    outcome: String, reason: String?, configuredRateHz: Int?, nominalRateHz: Int?,
    measuredRateBucket: String?, outputTransport: String?
  ) {
    self.outcome = outcome
    self.reason = reason
    self.configuredRateHz = configuredRateHz
    self.nominalRateHz = nominalRateHz
    self.measuredRateBucket = measuredRateBucket
    self.outputTransport = outputTransport
  }
}
