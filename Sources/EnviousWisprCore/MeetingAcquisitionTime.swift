import Foundation

/// When a piece of meeting audio was acquired, on the host clock (#4355 plan §3.1).
///
/// One of the two temporal domains of a live meeting, and deliberately not convertible into the
/// other (`MeetingAudioSpan`, the written 16 kHz timeline): capture, echo cancellation and the
/// microphone mute hold reason in acquisition time; attribution of words to speakers reasons in
/// written samples. Mixing the two silently was the root the plan's review found three times, so
/// the types carry no conversion and every crossing is an explicit adapter.
///
/// `provenance` keeps how much the tick value can be trusted. The call-sound tap substitutes
/// `mach_absolute_time()` when Core Audio does not mark its timestamp valid
/// (`SystemAudioTap.swift`), and the microphone path estimates from arrival; neither may later be
/// treated as verified hardware acquisition.
public struct MeetingAcquisitionTime: Sendable, Hashable {
  public enum Provenance: Sendable, Hashable {
    /// The device's own acquisition timestamp (`AudioTimeStamp` with a valid host time).
    case hardware
    /// The host clock read when the audio was observed, not when it was acquired.
    case observed
    /// Derived from other values (for example arrival time minus buffered samples).
    case estimated
  }

  /// The meeting this time belongs to; times of different meetings are never compared.
  public let recording: UUID
  /// `mach_absolute_time()` units.
  public let hostTicks: UInt64
  public let provenance: Provenance

  public init(recording: UUID, hostTicks: UInt64, provenance: Provenance) {
    self.recording = recording
    self.hostTicks = hostTicks
    self.provenance = provenance
  }
}
