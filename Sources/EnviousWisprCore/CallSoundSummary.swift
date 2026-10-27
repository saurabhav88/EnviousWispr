import Foundation

/// #4121: what one meeting's call-sound capture started on and how often it rebuilt, for the
/// meeting's terminal telemetry row. Content-free: a transport class, a rate and counts.
public struct CallSoundSummary: Sendable, Equatable {
  /// The output device's transport class (`AudioDeviceEnumerator` labels, or `unknown`) of the
  /// capture that started; nil when the call-sound capture never started.
  public var outputTransport: String?
  /// The configured capture rate of the capture that started, in Hz; nil when it never started.
  public var configuredRateHz: Int?
  /// Successful startup-revalidation and runtime rebuilds.
  public var rebuilds: Int
  /// Change rows not sent because the per-meeting cap was reached.
  public var omittedReports: Int

  public init(
    outputTransport: String? = nil, configuredRateHz: Int? = nil, rebuilds: Int = 0,
    omittedReports: Int = 0
  ) {
    self.outputTransport = outputTransport
    self.configuredRateHz = configuredRateHz
    self.rebuilds = rebuilds
    self.omittedReports = omittedReports
  }
}
