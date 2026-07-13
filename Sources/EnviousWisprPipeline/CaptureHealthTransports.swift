import Foundation

/// #1434: public transport for the most recent recording's capture-health
/// facts — the App layer reads it off `KernelDictationDriver` for
/// `dictation.completed`, mirroring `ResolvedRouteTransports`. Hardware-class
/// numbers and flags only; no identifiers, no audio, no text.
public struct CaptureHealthTransports: Sendable, Equatable {
  public let nativeRateHz: Double?
  public let ringDropCount: Int?
  public let converterErrorCount: Int?
  public let zeroOutputCount: Int?
  public let rateDivergenceDetected: Bool?
  public let formatStabilized: Bool?
  public let captureRebuiltForFormat: Bool?
  /// #1523: the bound device's total native input channel count.
  public let nativeChannelCount: Int?

  public init(
    nativeRateHz: Double?,
    ringDropCount: Int?,
    converterErrorCount: Int?,
    zeroOutputCount: Int?,
    rateDivergenceDetected: Bool?,
    formatStabilized: Bool?,
    captureRebuiltForFormat: Bool?,
    nativeChannelCount: Int? = nil
  ) {
    self.nativeRateHz = nativeRateHz
    self.ringDropCount = ringDropCount
    self.converterErrorCount = converterErrorCount
    self.zeroOutputCount = zeroOutputCount
    self.rateDivergenceDetected = rateDivergenceDetected
    self.formatStabilized = formatStabilized
    self.captureRebuiltForFormat = captureRebuiltForFormat
    self.nativeChannelCount = nativeChannelCount
  }
}
